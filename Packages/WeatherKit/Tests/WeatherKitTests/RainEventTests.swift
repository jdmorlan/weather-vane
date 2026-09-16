import Testing
import Foundation
@testable import WeatherKit

@Suite("Rain events")
struct RainEventTests {

    private let zone = TimeZone(identifier: "America/Chicago")!
    private let day = "2026-09-04"

    /// Midnight of the test day, station-local.
    private var midnight: Date { DayKey.date(from: day, timeZone: zone)! }

    private func at(_ minute: Int) -> Date { midnight.addingTimeInterval(TimeInterval(minute * 60)) }

    /// A sample timestamped `minute` minutes after local midnight.
    private func sample(_ minute: Int, _ precip: Double, bucket: Int = 1) -> StationSample {
        var s = StationSample(timestamp: Int(at(minute).timeIntervalSince1970), bucketMinutes: bucket)
        s.precip = precip
        return s
    }

    /// A full day of one-minute samples, dry unless `wet` says otherwise.
    private func fullDay(wet: [Int: Double], bucket: Int = 1) -> [StationSample] {
        stride(from: bucket, through: 1_440, by: bucket).map { sample($0, wet[$0] ?? 0, bucket: bucket) }
    }

    // MARK: Segmentation

    @Test("A lull shorter than the tolerance stays one spell")
    func lullDoesNotSplit() {
        // Rain 2:00–2:10, nothing for 20 minutes, rain again 2:30–2:40.
        var wet: [Int: Double] = [:]
        for m in 121...130 { wet[m] = 0.01 }
        for m in 151...160 { wet[m] = 0.01 }

        let rain = RainEvents.find(in: fullDay(wet: wet), day: day, timeZone: zone)
        #expect(rain.events.count == 1)
        #expect(rain.events[0].startMinute == 120)
        #expect(rain.events[0].endMinute == 160)
    }

    @Test("A dry stretch past the tolerance ends the spell")
    func gapSplits() {
        var wet: [Int: Double] = [:]
        for m in 121...130 { wet[m] = 0.01 }
        for m in 200...210 { wet[m] = 0.01 }   // 70 minutes later

        let rain = RainEvents.find(in: fullDay(wet: wet), day: day, timeZone: zone)
        #expect(rain.events.count == 2)
        #expect(rain.events[1].startMinute == 199)
    }

    @Test("A spit too small to be a spell still counts toward the day")
    func belowThresholdIsNotAnEvent() {
        let rain = RainEvents.find(in: fullDay(wet: [300: 0.004]), day: day, timeZone: zone)
        #expect(rain.events.isEmpty)
        #expect(rain.didRain)
        #expect(!rain.hasSomethingToSay)
        #expect(abs(rain.total - 0.004) < 0.0001)
    }

    // MARK: Rate

    @Test("Rate is per hour, whatever the bucket")
    func rateIsBucketIndependent() {
        // 0.05" in one minute and 1.50" over thirty are the same 3 in/hr.
        let minute = RainSample(timestamp: 0, minuteOfDay: 0, amount: 0.05, bucketMinutes: 1)
        let half = RainSample(timestamp: 0, minuteOfDay: 0, amount: 1.50, bucketMinutes: 30)
        #expect(abs(minute.rate - 3.0) < 0.0001)
        #expect(abs(half.rate - 3.0) < 0.0001)
    }

    @Test("Peak is the hardest reading, not the mean")
    func peakIsNotMean() {
        // Ten minutes of drizzle with one hard minute in the middle.
        var wet = Dictionary(uniqueKeysWithValues: (121...130).map { ($0, 0.002) })
        wet[126] = 0.04                       // 2.4 in/hr for that minute

        let rain = RainEvents.find(in: fullDay(wet: wet), day: day, timeZone: zone)
        let event = try! #require(rain.events.first)
        #expect(event.peak.minuteOfDay == 126)
        #expect(event.peakIntensity == .violent)
        // The spell as a whole was nothing like that.
        #expect(event.meanIntensity < .violent)
    }

    @Test("A peak from a coarse bucket declares itself diluted")
    func coarseBucketIsFlagged() {
        let samples = [sample(120, 0.30, bucket: 30), sample(150, 0.05, bucket: 30)]
        let rain = RainEvents.find(in: samples, day: day, timeZone: zone)
        let event = try! #require(rain.events.first)
        #expect(event.bucketMinutes == 30)
        #expect(event.peakIsDiluted)

        let fine = RainEvents.find(in: fullDay(wet: [121: 0.01]), day: day, timeZone: zone)
        #expect(fine.events.first?.peakIsDiluted == false)
    }

    @Test("Intensity thresholds sit where the scale says")
    func intensityScale() {
        #expect(RainIntensity.of(rate: 0.005) == .trace)
        #expect(RainIntensity.of(rate: 0.05) == .light)
        #expect(RainIntensity.of(rate: 0.2) == .moderate)
        #expect(RainIntensity.of(rate: 0.9) == .heavy)
        #expect(RainIntensity.of(rate: 3.0) == .violent)
    }

    @Test("A rate becomes a duration, and a drizzle refuses to")
    func inchDuration() {
        #expect(RainEvents.timeForAnInch(atRate: 3.0) == "20 minutes")
        #expect(RainEvents.timeForAnInch(atRate: 1.0) == "an hour")
        // 72 minutes is an hour to a person, not "1 hours".
        #expect(RainEvents.timeForAnInch(atRate: 0.83) == "an hour")
        #expect(RainEvents.timeForAnInch(atRate: 0.67) == "an hour and a half")
        #expect(RainEvents.timeForAnInch(atRate: 0.40) == "2 and a half hours")
        #expect(RainEvents.timeForAnInch(atRate: 0.001) == nil)
    }

    // MARK: Open vs closed — the same event, two moments

    @Test("Rain still arriving leaves the spell open")
    func openWhileRaining() {
        var wet: [Int: Double] = [:]
        for m in 121...140 { wet[m] = 0.01 }
        let samples = fullDay(wet: wet).filter { $0.timestamp <= Int(at(141).timeIntervalSince1970) }

        let raining = RainEvents.find(in: samples, day: day, timeZone: zone, asOf: at(142))
        #expect(raining.isRaining)
        #expect(raining.events.last?.isOpen == true)
        #expect(raining.nowSentence != nil)

        // An hour of silence later, the same samples describe a spell that ended.
        let stopped = RainEvents.find(in: samples, day: day, timeZone: zone, asOf: at(200))
        #expect(!stopped.isRaining)
        #expect(stopped.nowSentence == nil)
        // And it's the same spell, not a different reading of the day.
        #expect(stopped.events.count == raining.events.count)
        #expect(stopped.events.first?.total == raining.events.first?.total)
    }

    @Test("Today is measured against the minutes elapsed, not a whole day")
    func coverageUsesElapsedTime() {
        // Six hours of one-minute samples, asked at six in the morning.
        let samples = (1...360).map { sample($0, 0) }
        let rain = RainEvents.find(in: samples, day: day, timeZone: zone, asOf: at(360))
        #expect(rain.samplesExpected == 360)
        #expect(rain.isReliable)
        #expect(rain.coverageNote == nil)
    }

    @Test("A half-watched day says its total is a floor")
    func gapsAreDeclared() {
        let samples = (1...200).map { sample($0, 0) }      // 200 of 1,440 minutes
        let rain = RainEvents.find(in: samples, day: day, timeZone: zone)
        #expect(!rain.isReliable)
        #expect(rain.coverageNote != nil)
    }

    // MARK: Corrected series

    @Test("The corrected series wins, as it does in the daily rollup")
    func prefersCorrected() {
        var s = sample(121, 0.10)
        s.precipCorrected = 0.02
        let rain = RainEvents.find(in: [s], day: day, timeZone: zone)
        #expect(abs(rain.total - 0.02) < 0.0001)
    }

    // MARK: Clock

    @Test("Minutes since midnight read as a clock")
    func clockFormatting() {
        #expect(RainEvents.clock(0) == "12:00 am")
        #expect(RainEvents.clock(9 * 60 + 5) == "9:05 am")
        #expect(RainEvents.clock(12 * 60) == "12:00 pm")
        #expect(RainEvents.clock(14 * 60 + 40) == "2:40 pm")
    }

    // MARK: Rank against the archive

    @Test("A thin archive refuses to rank a day")
    func rankNeedsRecord() {
        let records = (0..<60).map { i -> DailyRecord in
            var r = DailyRecord(day: DayKey.string(for: Date(timeIntervalSince1970: TimeInterval(i * 86_400)),
                                                   timeZone: .gmt))
            r.precipTotal = 0.1
            r.sampleCount = 48
            r.expectedSamples = 48
            return r
        }
        #expect(Climatology(records: records).rainDayRank(0.5) == nil)
    }

    @Test("A day is ranked among rainy days, not among all days")
    func rankUsesRainyDaysOnly() throws {
        // 400 days, every tenth one wet — 40 rainy days from 0.05" to 2.00".
        let records = (0..<400).map { i -> DailyRecord in
            var r = DailyRecord(day: DayKey.string(for: Date(timeIntervalSince1970: TimeInterval(i * 86_400)),
                                                   timeZone: .gmt))
            r.precipTotal = i % 10 == 0 ? 0.05 * Double(i / 10 + 1) : 0
            r.sampleCount = 48
            r.expectedSamples = 48
            return r
        }
        let rank = try #require(Climatology(records: records).rainDayRank(1.0))
        #expect(rank.rainyDays == 41)
        #expect(rank.daysOnRecord == 400)
        // Twenty of the forty brought more than an inch.
        #expect(rank.wetterDays == 20)
        #expect(rank.wettest?.value == 2.0)
    }

    @Test("The biggest day on record says so, with the record's size")
    func rankNamesTheRecord() throws {
        let records = (0..<400).map { i -> DailyRecord in
            var r = DailyRecord(day: DayKey.string(for: Date(timeIntervalSince1970: TimeInterval(i * 86_400)),
                                                   timeZone: .gmt))
            r.precipTotal = i % 10 == 0 ? 0.05 * Double(i / 10 + 1) : 0
            r.sampleCount = 48
            r.expectedSamples = 48
            return r
        }
        let rank = try #require(Climatology(records: records).rainDayRank(3.0))
        #expect(rank.wetterDays == 0)
        #expect(rank.sentence.contains("400"))
    }
}
