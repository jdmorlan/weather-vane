import XCTest
@testable import WeatherKit

final class ClimatologyTests: XCTestCase {

    private func day(_ key: String, high: Double? = nil, low: Double? = nil,
                     precip: Double? = nil, gust: Double? = nil, dew: Double? = nil,
                     coverage: Double = 1.0) -> DailyRecord {
        var record = DailyRecord(day: key, sampleCount: Int(48 * coverage), expectedSamples: 48)
        record.tempMax = high
        record.tempMin = low
        record.tempMean = [high, low].compactMap { $0 }.mean
        record.precipTotal = precip
        record.windGustMax = gust
        record.dewPointMax = dew
        record.dewPointMean = dew
        return record
    }

    /// A run of consecutive days, so streak walks have no accidental gaps.
    private func run(from start: String, days: Int,
                     high: @escaping (Int) -> Double? = { _ in 70 },
                     low: @escaping (Int) -> Double? = { _ in 50 },
                     precip: @escaping (Int) -> Double? = { _ in 0 }) -> [DailyRecord] {
        var keys: [String] = [start]
        var cursor = start
        for _ in 1..<max(1, days) {
            guard let next = nextDay(cursor) else { break }
            keys.append(next)
            cursor = next
        }
        return keys.enumerated().map { i, key in day(key, high: high(i), low: low(i), precip: precip(i)) }
    }

    private func nextDay(_ key: String) -> String? {
        let zone = TimeZone(identifier: "UTC")!
        guard let date = DayKey.date(from: key, timeZone: zone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
        return DayKey.string(for: next, timeZone: zone)
    }

    // MARK: Reliability gate

    /// The central promise: a half-seen day is kept and shown, but can never set
    /// a statistic. Its "high" is only the high of the hours we caught.
    func testPartialDaysAreExcludedFromStatisticsButNotFromLookups() {
        let climate = Climatology(records: [
            day("2023-08-06", high: 88, low: 66, coverage: 1.0),
            // A sensor spike during a day we only caught a third of. Plausible
            // enough to survive decoding, and exactly what must not become a record.
            day("2024-08-06", high: 105, low: 80, coverage: 0.3),
        ])
        XCTAssertEqual(climate.all.count, 2)
        XCTAssertEqual(climate.reliable.count, 1)
        // Still listed in the anniversary view…
        XCTAssertEqual(climate.history(monthDay: "08-06").count, 2)
        // …but it doesn't hold the all-time record…
        XCTAssertEqual(climate.extremes().hottest?.day, "2023-08-06")
        XCTAssertEqual(climate.extremes().hottest?.value, 88)
        // …and it isn't in the field today gets ranked against.
        XCTAssertEqual(climate.rank(90, monthDay: "08-06", by: \.tempMax)?.total, 2)
    }

    // MARK: Normals

    func testNormalPoolsAWindowAcrossYears() {
        // Three Augusts, every day 80°/60°.
        var records: [DailyRecord] = []
        for year in 2022...2024 {
            records += run(from: "\(year)-08-01", days: 20, high: { _ in 80 }, low: { _ in 60 })
        }
        let normal = Climatology(records: records).normal(monthDay: "08-10")
        XCTAssertEqual(normal.high ?? 0, 80, accuracy: 0.001)
        XCTAssertEqual(normal.low ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(normal.years, 3)
        // ±7 days × 3 years = 45 pooled days, vs. 3 if we'd used the exact date.
        XCTAssertEqual(normal.sampleDays, 45)
        XCTAssertTrue(normal.isMeaningful)
    }

    /// One year of record is not a climate, and nothing user-facing may phrase it
    /// as one.
    func testNormalFromASingleYearIsNotMeaningful() {
        let normal = Climatology(records: run(from: "2024-08-01", days: 20)).normal(monthDay: "08-10")
        XCTAssertEqual(normal.years, 1)
        XCTAssertFalse(normal.isMeaningful)
    }

    func testNormalWindowWrapsAcrossNewYear() {
        let keys = Climatology.monthDayWindow(around: "12-29", radius: 7)
        XCTAssertTrue(keys.contains("12-29"))
        XCTAssertTrue(keys.contains("01-05"))   // wrapped forward
        XCTAssertTrue(keys.contains("12-22"))
        XCTAssertEqual(keys.count, 15)
    }

    /// Stepping the window in a leap year is what keeps Feb 29 reachable at all.
    func testNormalWindowIncludesLeapDay() {
        XCTAssertTrue(Climatology.monthDayWindow(around: "03-01", radius: 3).contains("02-29"))
    }

    // MARK: Rankings

    func testRankingUsesTheExactDateNotTheWindow() {
        let climate = Climatology(records: [
            day("2021-08-06", high: 85), day("2022-08-06", high: 91),
            day("2023-08-06", high: 78), day("2024-08-06", high: 88),
            day("2024-08-07", high: 105),   // a hotter neighbour must not count
        ])
        let rank = climate.rank(95, monthDay: "08-06", by: \.tempMax)
        XCTAssertEqual(rank?.rank, 1)
        XCTAssertEqual(rank?.total, 5)      // four archived Aug 6ths plus today
        XCTAssertTrue(rank?.isHighest == true)
        XCTAssertEqual(rank?.percentile ?? 0, 80, accuracy: 0.001)
    }

    func testRankingCanExcludeThisYearsOwnRecord() {
        let climate = Climatology(records: [
            day("2023-08-06", high: 85), day("2024-08-06", high: 91),
        ])
        // Without exclusion, 2024's archived value competes with 2024's live one.
        XCTAssertEqual(climate.rank(91, monthDay: "08-06", by: \.tempMax)?.total, 3)
        XCTAssertEqual(climate.rank(91, monthDay: "08-06", by: \.tempMax, excludingYear: 2024)?.total, 2)
    }

    func testTiedValuesShareTheBestRank() {
        let climate = Climatology(records: [day("2023-08-06", high: 97), day("2022-08-06", high: 80)])
        let rank = climate.rank(97, monthDay: "08-06", by: \.tempMax)
        XCTAssertEqual(rank?.rank, 1)       // ties the record, so it ties for first
    }

    // MARK: Streaks

    func testDaysSincePrecipCountsBackToTheLastWetDay() {
        // 2024-06-01 wet, then nine dry days, asking as of the 11th.
        let records = run(from: "2024-06-01", days: 10, precip: { $0 == 0 ? 0.34 : 0 })
        let climate = Climatology(records: records)
        let streak = climate.daysSincePrecip(before: "2024-06-11")
        XCTAssertEqual(streak?.length, 9)
        XCTAssertEqual(streak?.firstDay, "2024-06-02")
        XCTAssertFalse(streak?.endedAtGap ?? true)
        XCTAssertEqual(climate.lastPrecipDay(onOrBefore: "2024-06-11")?.day, "2024-06-01")
    }

    /// The one that matters: a hole in the archive must stop the walk. Stepping
    /// over a missing day would let the count cross the day it rained.
    func testStreakStopsAtAGapInsteadOfCountingThrough() {
        let climate = Climatology(records: [
            day("2024-06-01", precip: 0), day("2024-06-02", precip: 0),
            // 06-03 and 06-04 missing entirely
            day("2024-06-05", precip: 0), day("2024-06-06", precip: 0),
        ])
        let streak = climate.daysSincePrecip(before: "2024-06-07")
        XCTAssertEqual(streak?.length, 2)               // only the 5th and 6th
        XCTAssertTrue(streak?.endedAtGap ?? false)
    }

    func testTraceRainDoesNotBreakADrySpell() {
        let records = run(from: "2024-06-01", days: 6, precip: { $0 == 3 ? 0.004 : 0 })
        let streak = Climatology(records: records).daysSincePrecip(before: "2024-06-07")
        XCTAssertEqual(streak?.length, 6)
    }

    func testCurrentRunIncludesToday() {
        let records = run(from: "2024-07-01", days: 5, high: { _ in 94 })
        let run = Climatology(records: records).currentRun(endingAt: "2024-07-05") { ($0.tempMax ?? 0) >= 90 }
        XCTAssertEqual(run?.length, 5)
        XCTAssertEqual(run?.firstDay, "2024-07-01")
    }

    // MARK: Extremes

    func testExtremesScopeToAYearWhenAsked() {
        let climate = Climatology(records: [
            day("2023-07-04", high: 101, low: 70, precip: 0.1, gust: 40),
            day("2024-01-15", high: 20, low: -4, precip: 0, gust: 55),
            day("2024-07-04", high: 96, low: 68, precip: 2.6, gust: 30),
        ])
        let allTime = climate.extremes()
        XCTAssertEqual(allTime.hottest?.day, "2023-07-04")
        XCTAssertEqual(allTime.coldest?.value, -4)
        XCTAssertEqual(allTime.wettestDay?.day, "2024-07-04")
        XCTAssertEqual(allTime.strongestGust?.value, 55)

        let thisYear = climate.extremes(inYear: 2024)
        XCTAssertEqual(thisYear.hottest?.day, "2024-07-04")
    }

    // MARK: Sentences

    func testComparisonPhrasesADepartureFromNormal() {
        var records: [DailyRecord] = []
        for year in 2021...2024 {
            records += run(from: "\(year)-08-01", days: 20, high: { _ in 84 }, low: { _ in 63 })
        }
        let climate = Climatology(records: records)
        let comparison = WeatherAlmanac.comparison(climate, day: "2025-08-06", high: 96, low: 70)

        XCTAssertEqual(comparison.highDelta ?? 0, 12, accuracy: 0.001)
        XCTAssertEqual(comparison.headline, "12° warmer than usual for August 6")
        XCTAssertEqual(comparison.rankText, "Warmest August 6 in 5 years of record")
        XCTAssertTrue(comparison.detail?.contains("84° / 63°") ?? false)
    }

    func testComparisonSaysNothingWithoutEnoughRecord() {
        let climate = Climatology(records: run(from: "2025-08-01", days: 12))
        let comparison = WeatherAlmanac.comparison(climate, day: "2025-08-06", high: 96, low: 70)
        XCTAssertFalse(comparison.hasSomethingToSay)
        XCTAssertNil(comparison.headline)
        XCTAssertNil(comparison.detail)
    }

    func testSmallDeparturesReadAsNormalRatherThanAsANumber() {
        XCTAssertEqual(WeatherAlmanac.departure(1.2, on: "August 6"), "Right about normal for August 6")
        XCTAssertEqual(WeatherAlmanac.departure(-7, on: "August 6"), "7° cooler than usual for August 6")
    }

    func testHighlightsReportADrySpellWithItsLastRain() {
        let records = run(from: "2024-06-01", days: 10, precip: { $0 == 0 ? 0.34 : 0 })
        let lines = WeatherAlmanac.highlights(Climatology(records: records), today: "2024-06-11")
        let dry = lines.first { $0.id == "dry-spell" }
        XCTAssertEqual(dry?.text, "9 days without measurable rain — last was 0.34\" on Jun 1")
    }

    /// Rain falling right now ends the dry spell, even though today isn't
    /// archived yet — the screen must not say "9 days without rain" in a storm.
    func testTodaysRainSuppressesTheDrySpellLine() {
        let records = run(from: "2024-06-01", days: 10, precip: { $0 == 0 ? 0.34 : 0 })
        let lines = WeatherAlmanac.highlights(Climatology(records: records),
                                              today: "2024-06-11", precipToday: 0.22)
        XCTAssertNil(lines.first { $0.id == "dry-spell" })
    }

    /// Month-to-date compares against the same stretch of past years, not a
    /// whole-month total — otherwise every month looks like a drought on the 6th.
    func testMonthToDateComparesLikeForLike() {
        var records: [DailyRecord] = []
        for year in 2022...2024 {
            // 0.20" per day for the first 10 days = 2.00" by the 10th.
            records += run(from: "\(year)-06-01", days: 30, precip: { $0 < 10 ? 0.20 : 0 })
        }
        // This year: bone dry through the 10th.
        records += run(from: "2025-06-01", days: 10, precip: { _ in 0 })

        let line = WeatherAlmanac.monthToDate(Climatology(records: records), day: "2025-06-10")
        XCTAssertEqual(line?.id, "month-precip")
        XCTAssertTrue(line?.text.contains("below") ?? false, line?.text ?? "nil")
        // Ten days at 0.20" is the 2.00" a normal June has by the 10th.
        XCTAssertTrue(line?.text.contains("2.00\" usual") ?? false, line?.text ?? "nil")
    }
}

extension ClimatologyTests {

    /// Which end of the day matters is seasonal, and asked of the record rather
    /// than hardcoded to a list of months — a hemisphere or a climate the author
    /// didn't have in mind still gets it right.
    func testEmphasisFollowsWhereTheDateSitsInTheYear() {
        // A smooth seasonal curve rather than two flat levels: with only two
        // distinct values the year's median sits exactly ON one of them, and the
        // tie decides the answer instead of the season doing it.
        let monthlyMean: [Int: Double] = [1: 40, 2: 45, 3: 55, 4: 65, 5: 73, 6: 80,
                                          7: 85, 8: 86, 9: 78, 10: 68, 11: 55, 12: 44]
        var records: [DailyRecord] = []
        for year in 2022...2024 {
            var cursor = "\(year)-01-01"
            while cursor <= "\(year)-12-31" {
                let month = Int(cursor.dropFirst(5).prefix(2)) ?? 1
                let mean = monthlyMean[month] ?? 60
                var record = DailyRecord(day: cursor, sampleCount: 48, expectedSamples: 48)
                record.tempMean = mean
                record.tempMax = mean + 12
                record.tempMin = mean - 12
                records.append(record)
                guard let next = DayKey.next(cursor) else { break }
                cursor = next
            }
        }
        let climate = Climatology(records: records)
        XCTAssertEqual(climate.seasonalEmphasis(monthDay: "07-15"), .high, "in summer, how hot it got")
        XCTAssertEqual(climate.seasonalEmphasis(monthDay: "01-15"), .low, "in winter, how cold it got")
        // The shoulders resolve either way, but they must resolve consistently
        // with where they sit relative to the year's midpoint.
        XCTAssertEqual(climate.seasonalEmphasis(monthDay: "08-15"), .high)
        XCTAssertEqual(climate.seasonalEmphasis(monthDay: "12-15"), .low)
    }

    /// An empty or measureless archive must still answer, rather than trapping.
    func testEmphasisDefaultsSafelyWithNoRecord() {
        XCTAssertEqual(Climatology(records: []).seasonalEmphasis(monthDay: "08-06"), .high)
    }
}
