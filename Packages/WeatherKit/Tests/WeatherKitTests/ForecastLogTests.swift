import Testing
import Foundation
@testable import WeatherKit

@Suite("Forecast log")
struct ForecastLogTests {

    private let zone = TimeZone(identifier: "America/Chicago")!

    /// An instant `hours` after local midnight on `day`.
    private func at(_ day: String, _ hours: Double) -> Date {
        DayKey.date(from: day, timeZone: zone)!.addingTimeInterval(hours * 3600)
    }

    private func note(_ validDay: String, issued: Date, high: Double?) -> ForecastNote {
        ForecastNote(issuedAt: Int(issued.timeIntervalSince1970), validDay: validDay, high: high)
    }

    // MARK: - Only revisions are kept

    @Test("An unchanged claim is not written twice")
    func unchangedClaimIsDropped() throws {
        let log = MemoryForecastLog()
        let day = "2026-09-14"

        try log.record([note(day, issued: at("2026-09-12", 7), high: 94)])
        let second = try log.record([note(day, issued: at("2026-09-12", 12), high: 94)])

        #expect(second.isEmpty)
        #expect(try log.claims(for: day).count == 1)
    }

    @Test("A revision is written, and both survive")
    func revisionIsKept() throws {
        let log = MemoryForecastLog()
        let day = "2026-09-14"

        try log.record([note(day, issued: at("2026-09-12", 7), high: 94)])
        try log.record([note(day, issued: at("2026-09-13", 7), high: 96)])

        let claims = try log.claims(for: day)
        #expect(claims.map(\.high) == [94, 96])
    }

    @Test("A claim is judged against the one standing at its instant, not the newest")
    func outOfOrderCaptureIsJudgedAgainstItsPredecessor() throws {
        let log = MemoryForecastLog()
        let day = "2026-09-14"

        try log.record([note(day, issued: at("2026-09-12", 7), high: 94)])
        try log.record([note(day, issued: at("2026-09-13", 7), high: 96)])
        // Arrives late, but belongs between the two — and says nothing the 94 didn't.
        let written = try log.record([note(day, issued: at("2026-09-12", 18), high: 94)])

        #expect(written.isEmpty)
        #expect(try log.claims(for: day).count == 2)
    }

    @Test("Re-recording the same instant is the same observation")
    func duplicateInstantIsDropped() throws {
        let log = MemoryForecastLog()
        let day = "2026-09-14"
        let issued = at("2026-09-12", 7)

        try log.record([note(day, issued: issued, high: 94)])
        let again = try log.record([note(day, issued: issued, high: 99)])

        #expect(again.isEmpty)
        #expect(try log.claims(for: day).map(\.high) == [94])
    }

    // MARK: - Reading a claim back

    @Test("The claim in force is the last one issued at or before the moment")
    func standingClaim() throws {
        let log = MemoryForecastLog()
        let day = "2026-09-14"
        try log.record([
            note(day, issued: at("2026-09-11", 7), high: 92),
            note(day, issued: at("2026-09-13", 7), high: 96),
        ])

        #expect(try log.claim(for: day, asOf: at("2026-09-12", 15))?.high == 92)
        #expect(try log.claim(for: day, asOf: at("2026-09-14", 8))?.high == 96)
        #expect(try log.claim(for: day, asOf: at("2026-09-10", 8)) == nil)
    }

    @Test("The morning's word is the last claim before local noon")
    func morningClaimPrefersTheDayItself() throws {
        let log = MemoryForecastLog()
        let day = "2026-09-14"
        try log.record([
            note(day, issued: at("2026-09-13", 7), high: 94),
            note(day, issued: at("2026-09-14", 6.5), high: 95),
            note(day, issued: at("2026-09-14", 17), high: 98),   // after the fact
        ])

        let claim = try log.morningClaim(for: day, timeZone: zone)
        #expect(claim?.high == 95)
        #expect(claim?.leadDays(timeZone: zone) == 0)
    }

    @Test("An unopened morning falls back to yesterday's standing word")
    func morningClaimFallsBack() throws {
        let log = MemoryForecastLog()
        let day = "2026-09-14"
        try log.record([note(day, issued: at("2026-09-13", 7), high: 94)])

        let claim = try log.morningClaim(for: day, timeZone: zone)
        #expect(claim?.high == 94)
        #expect(claim?.leadDays(timeZone: zone) == 1)
    }

    // MARK: - Reading a payload

    @Test("A payload becomes one claim per day, keyed by the local day it starts")
    func notesFromPayload() {
        var monday = DailyForecast()
        monday.dayStartLocal = Int(at("2026-09-14", 0).timeIntervalSince1970)
        monday.airTempHigh = 95
        monday.airTempLow = 74
        monday.precipProbability = 20

        var tuesday = DailyForecast()
        tuesday.dayStartLocal = Int(at("2026-09-15", 0).timeIntervalSince1970)
        tuesday.airTempHigh = 97

        let payload = BetterForecast(timezone: "America/Chicago",
                                     forecast: Forecast(daily: [monday, tuesday], hourly: []))
        let notes = ForecastNote.notes(from: payload, issuedAt: at("2026-09-14", 7))

        #expect(notes.map(\.validDay) == ["2026-09-14", "2026-09-15"])
        #expect(notes[0].high == 95)
        #expect(notes[0].low == 74)
        #expect(notes[1].high == 97)
        #expect(notes[0].issuedAt == notes[1].issuedAt)
    }

    @Test("Each day's strongest forecast gust and muggiest forecast hour are logged from the hourly")
    func notesCarryHourlyGustAndDew() throws {
        var monday = DailyForecast()
        monday.dayStartLocal = Int(at("2026-09-14", 0).timeIntervalSince1970)
        monday.airTempHigh = 95
        func hour(_ h: Double, gust: Double, temp: Double, rh: Double) -> HourlyForecast {
            var x = HourlyForecast()
            x.time = Int(at("2026-09-14", h).timeIntervalSince1970)
            x.windGust = gust; x.airTemperature = temp; x.relativeHumidity = rh
            return x
        }
        let payload = BetterForecast(timezone: "America/Chicago",
                                     forecast: Forecast(daily: [monday], hourly: [
                                        hour(9, gust: 12, temp: 85, rh: 70),
                                        hour(15, gust: 24, temp: 95, rh: 45),
                                     ]))
        let note = ForecastNote.notes(from: payload, issuedAt: at("2026-09-14", 7))[0]
        #expect(note.gust == 24)
        // Magnus: 85°F at 70% is the muggier hour (~74°), not 95°F at 45% (~71°).
        #expect(note.dewPoint.map { abs($0 - 74.1) < 0.6 } == true)

        // Lines written before these fields existed still read.
        let old = #"{"issuedAt":1,"validDay":"2026-09-14","high":95}"#
        let decoded = try JSONDecoder().decode(ForecastNote.self, from: Data(old.utf8))
        #expect(decoded.gust == nil && decoded.high == 95)
    }

    @Test("A day with no start epoch is skipped rather than keyed by day-of-month")
    func dayWithoutStartIsSkipped() {
        var vague = DailyForecast()
        vague.dayNum = 14
        vague.airTempHigh = 95

        let payload = BetterForecast(timezone: "America/Chicago",
                                     forecast: Forecast(daily: [vague], hourly: []))
        #expect(ForecastNote.notes(from: payload).isEmpty)
    }

    // MARK: - On disk

    @Test("The file log round-trips and shards by the day predicted")
    func fileRoundTrip() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("forecast-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let log = FileForecastLog(root: root)
        try log.record([
            note("2026-09-14", issued: at("2026-09-12", 7), high: 94),
            note("2026-09-15", issued: at("2026-09-12", 7), high: 96),
        ])
        try log.record([note("2026-09-14", issued: at("2026-09-13", 7), high: 97)])

        #expect(try log.loggedDays() == ["2026-09-14", "2026-09-15"])
        #expect(try log.claims(for: "2026-09-14").map(\.high) == [94, 97])
        #expect(try log.claims(for: "2026-09-16").isEmpty)

        let file = root.appendingPathComponent("2026").appendingPathComponent("2026-09-14.ndjson.gz")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite("Forecast accuracy")
struct ForecastAccuracyTests {

    private let zone = TimeZone(identifier: "America/Chicago")!

    private func at(_ day: String, _ hours: Double) -> Date {
        DayKey.date(from: day, timeZone: zone)!.addingTimeInterval(hours * 3600)
    }

    private func day(_ offset: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let base = DayKey.date(from: "2026-09-01", timeZone: zone)!
        return DayKey.string(for: calendar.date(byAdding: .day, value: offset, to: base)!, timeZone: zone)
    }

    /// A fully-watched day whose measured high is `high`.
    private func record(_ key: String, high: Double, coverage: Double = 1) -> DailyRecord {
        var r = DailyRecord(day: key)
        r.expectedSamples = 1_440
        r.sampleCount = Int(1_440 * coverage)
        r.tempMax = high
        return r
    }

    /// `n` days, each forecast at `promised` that morning and measuring `actual`.
    private func scenario(days n: Int, promised: Double, actual: Double)
        throws -> (MemoryForecastLog, [String: DailyRecord], [String]) {
        let log = MemoryForecastLog()
        var records: [String: DailyRecord] = [:]
        var keys: [String] = []
        for i in 0..<n {
            let key = day(i)
            keys.append(key)
            try log.record([ForecastNote(issuedAt: Int(at(key, 7).timeIntervalSince1970),
                                         validDay: key, high: promised)])
            records[key] = record(key, high: actual)
        }
        return (log, records, keys)
    }

    @Test("A consistent cold miss is reported with its direction")
    func consistentColdBias() throws {
        let (log, records, keys) = try scenario(days: 10, promised: 94, actual: 98)
        let verdict = ForecastAccuracy.verdict(days: keys, log: log, records: records, timeZone: zone)

        let v = try #require(verdict)
        #expect(v.dayCount == 10)
        #expect(v.bias == -4)
        #expect(v.meanAbsoluteError == 4)
        #expect(v.coldDays == 10)
        #expect(v.warmDays == 0)
        #expect(v.isConsistent)
        #expect(v.sentence.contains("4° cold"))
        #expect(v.caveat != nil)
    }

    @Test("Scatter without direction is not called a bias")
    func scatterIsNotBias() throws {
        let log = MemoryForecastLog()
        var records: [String: DailyRecord] = [:]
        var keys: [String] = []
        // Alternating +5 / -5: no bias at all, but badly imprecise.
        for i in 0..<10 {
            let key = day(i)
            keys.append(key)
            let promised = i.isMultiple(of: 2) ? 95.0 : 85.0
            try log.record([ForecastNote(issuedAt: Int(at(key, 7).timeIntervalSince1970),
                                         validDay: key, high: promised)])
            records[key] = record(key, high: 90)
        }

        let v = try #require(ForecastAccuracy.verdict(days: keys, log: log,
                                                      records: records, timeZone: zone))
        #expect(v.bias == 0)
        #expect(v.meanAbsoluteError == 5)
        #expect(v.coldDays == 5)
        #expect(v.warmDays == 5)
        #expect(!v.isConsistent)
        #expect(v.sentence.contains("both directions"))
        #expect(v.caveat == nil)
    }

    @Test("A forecast inside tolerance is reported as fine")
    func closeEnough() throws {
        let (log, records, keys) = try scenario(days: 8, promised: 95, actual: 96)
        let v = try #require(ForecastAccuracy.verdict(days: keys, log: log,
                                                      records: records, timeZone: zone))
        #expect(v.closeDays == 8)
        #expect(v.sentence.contains("within"))
    }

    @Test("Too few graded days means no verdict at all")
    func refusesToSpeakEarly() throws {
        let (log, records, keys) = try scenario(days: 4, promised: 94, actual: 98)
        #expect(ForecastAccuracy.verdict(days: keys, log: log,
                                         records: records, timeZone: zone) == nil)
    }

    @Test("A half-watched day is not graded")
    func partialDayIsNotGraded() throws {
        let key = day(0)
        let log = MemoryForecastLog()
        try log.record([ForecastNote(issuedAt: Int(at(key, 7).timeIntervalSince1970),
                                     validDay: key, high: 94)])

        let thin = record(key, high: 88, coverage: 0.4)
        #expect(ForecastAccuracy.check(day: key, log: log, record: thin, timeZone: zone) == nil)

        let full = record(key, high: 88)
        #expect(ForecastAccuracy.check(day: key, log: log, record: full, timeZone: zone)?.error == 6)
    }

    @Test("A day never captured is not graded")
    func uncapturedDayIsNotGraded() {
        let key = day(0)
        #expect(ForecastAccuracy.check(day: key, log: MemoryForecastLog(),
                                       record: record(key, high: 98), timeZone: zone) == nil)
    }

    @Test("The curve holds every revision with its lead")
    func curveByLead() throws {
        let key = day(5)
        let log = MemoryForecastLog()
        try log.record([
            ForecastNote(issuedAt: Int(at(day(2), 7).timeIntervalSince1970), validDay: key, high: 92),
            ForecastNote(issuedAt: Int(at(day(4), 7).timeIntervalSince1970), validDay: key, high: 95),
            ForecastNote(issuedAt: Int(at(key, 7).timeIntervalSince1970), validDay: key, high: 97),
        ])

        let curve = ForecastAccuracy.curve(day: key, log: log,
                                           record: record(key, high: 99), timeZone: zone)
        #expect(curve.points.map(\.leadDays) == [3, 1, 0])
        #expect(curve.points.map(\.value) == [92, 95, 97])
        #expect(curve.actual == 99)
        #expect(curve.error(at: curve.points[0]) == -7)
        #expect(curve.error(at: curve.points[2]) == -2)
    }

    @Test("A claim that stood unchanged counts at every lead it stood through")
    func standingClaimCoversUnrevisedLeads() throws {
        let key = day(5)
        let log = MemoryForecastLog()
        try log.record([
            ForecastNote(issuedAt: Int(at(day(0), 7).timeIntervalSince1970), validDay: key, high: 94),
            ForecastNote(issuedAt: Int(at(day(4), 7).timeIntervalSince1970), validDay: key, high: 97),
        ])
        let curve = ForecastAccuracy.curve(day: key, log: log, record: record(key, high: 98), timeZone: zone)
        #expect(ForecastAccuracy.standingClaim(curve, lead: 3)?.value == 94)
        #expect(ForecastAccuracy.standingClaim(curve, lead: 1)?.value == 97)
        #expect(ForecastAccuracy.standingClaim(curve, lead: 6) == nil)
    }

    @Test("Skill by lead: further out misses by more, and thin leads are left out")
    func leadSkillGrowsWithLead() throws {
        let log = MemoryForecastLog()
        var records: [String: DailyRecord] = [:]
        var days: [String] = []
        for offset in 10..<16 {
            let key = day(offset)
            days.append(key)
            records[key] = record(key, high: 90)
            try log.record([
                // Four days out: 6° low. The morning of: 1° low.
                ForecastNote(issuedAt: Int(at(day(offset - 4), 7).timeIntervalSince1970), validDay: key, high: 84),
                ForecastNote(issuedAt: Int(at(key, 7).timeIntervalSince1970), validDay: key, high: 89),
            ])
        }
        let skill = ForecastAccuracy.leadSkill(days: days, log: log, records: records, timeZone: zone)
        #expect(skill.map(\.leadDays) == [0, 1, 2, 3, 4])
        #expect(skill.first?.typicalMiss == 1)
        #expect(skill.last?.typicalMiss == 6)
        #expect(skill.last?.bias == -6)
        #expect(ForecastAccuracy.leadSentence(skill)
                == "Made the morning of, the forecast high misses by 1° on a typical day; made 3 days out, 6°; made 4 days out, 6°.")
    }

    @Test("The low is graded against the forecast standing at midnight, not the morning's")
    func lowIsGradedAgainstTheNightBefore() throws {
        let key = day(10)
        let log = MemoryForecastLog()
        try log.record([
            ForecastNote(issuedAt: Int(at(day(9), 20).timeIntervalSince1970), validDay: key, high: 90, low: 70),
            // Issued after the night's low had already happened.
            ForecastNote(issuedAt: Int(at(key, 7).timeIntervalSince1970), validDay: key, high: 91, low: 66),
        ])
        var r = record(key, high: 92)
        r.tempMin = 65
        let low = ForecastAccuracy.check(day: key, log: log, record: r, timeZone: zone, measure: .low)
        #expect(low?.forecast == 70)
        #expect(low?.error == 5)
        let high = ForecastAccuracy.check(day: key, log: log, record: r, timeZone: zone)
        #expect(high?.forecast == 91)
    }

    @Test("A chance of rain is graded by how often it rained at that chance")
    func rainCalibrationGroupsByChance() throws {
        let log = MemoryForecastLog()
        var records: [String: DailyRecord] = [:]
        var days: [String] = []
        let plan: [(Double, Double)] = [(60, 0.4), (70, 0), (80, 1.1), (0, 0), (10, 0), (0, 0.02)]
        for (i, (chance, rain)) in plan.enumerated() {
            let key = day(20 + i)
            days.append(key)
            var r = record(key, high: 90)
            r.precipTotal = rain
            records[key] = r
            try log.record([ForecastNote(issuedAt: Int(at(key, 7).timeIntervalSince1970), validDay: key,
                                         high: 90, precipProbability: chance)])
        }
        let cal = ForecastAccuracy.rainCalibration(days: days, log: log, records: records, timeZone: zone)
        #expect(cal.buckets.first { $0.lower == 50 }?.days == 2)
        #expect(cal.buckets.first { $0.lower == 50 }?.wetDays == 1)
        #expect(cal.sentence == "When it said 50% or more, it rained on 2 of 3 days. When it said 10% or less, it rained on 1 of 3 days.")
    }
}
