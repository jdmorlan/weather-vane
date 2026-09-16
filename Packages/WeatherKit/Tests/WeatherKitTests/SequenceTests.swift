import XCTest
@testable import WeatherKit

/// Clauses that reach beyond a single day — the day before it, and its place in
/// a run. Both make claims about days the archive may never have seen, so both
/// carry their own coverage gates.
final class SequenceTests: XCTestCase {

    private func day(_ key: String, high: Double? = nil, rain: Double? = nil,
                     samples: Int = 48) -> DailyRecord {
        var record = DailyRecord(day: key, sampleCount: samples, expectedSamples: 48)
        record.tempMax = high
        record.precipTotal = rain
        record.schemaVersion = DailyRecord.currentSchemaVersion
        return record
    }

    /// A full year at 70°, with the listed days hot.
    private func year(_ y: Int, hot: Set<String> = [], rain: Set<String> = [],
                      from: String? = nil, through: String? = nil) -> [DailyRecord] {
        var records: [DailyRecord] = []
        var cursor = from ?? "\(y)-01-01"
        let last = through ?? "\(y)-12-31"
        while cursor <= last {
            let monthDay = DayKey.monthDay(of: cursor)
            records.append(day(cursor,
                               high: hot.contains(monthDay) ? 101 : 70,
                               rain: rain.contains(monthDay) ? 0.5 : 0))
            guard let next = DayKey.next(cursor) else { break }
            cursor = next
        }
        return records
    }

    private let hot = [Condition(.high, .atOrAbove(100))]

    // MARK: First and last

    func testFirstEachYearPicksOnePerYear() {
        let records = year(2022, hot: ["06-10", "07-04", "08-20"])
            + year(2023, hot: ["05-01", "09-09"])
        let result = Climatology(records: records)
            .run(DayQuery(conditions: hot, sequence: .firstEachYear))

        XCTAssertEqual(result.days.map(\.day).sorted(), ["2022-06-10", "2023-05-01"])
    }

    func testLastEachYearPicksTheOtherEnd() {
        let records = year(2022, hot: ["06-10", "08-20"]) + year(2023, hot: ["05-01", "09-09"])
        let result = Climatology(records: records)
            .run(DayQuery(conditions: hot, sequence: .lastEachYear))

        XCTAssertEqual(result.days.map(\.day).sorted(), ["2022-08-20", "2023-09-09"])
    }

    /// THE gate. This archive opens in October 2022 — the first 100° day it
    /// holds for that year is not the first 100° day of that year, and claiming
    /// otherwise would be a fact about when the station was installed.
    func testAFirstIsWithheldWhenTheYearWasntWatchedUpToIt() {
        let records = year(2022, hot: ["10-20"], from: "2022-10-08")   // station's first days
            + year(2023, hot: ["05-01"])
        let result = Climatology(records: records)
            .run(DayQuery(conditions: hot, sequence: .firstEachYear))

        XCTAssertEqual(result.days.map(\.day), ["2023-05-01"],
                       "2022 can't name a first — its January through September are missing")
    }

    /// Mirrored: a "last" needs everything AFTER it watched.
    func testALastIsWithheldWhenTheYearEndsEarly() {
        let records = year(2022, hot: ["06-10"])
            + year(2023, hot: ["05-01"], through: "2023-07-01")   // record stops mid-year
        let result = Climatology(records: records)
            .run(DayQuery(conditions: hot, sequence: .lastEachYear))

        XCTAssertEqual(result.days.map(\.day), ["2022-06-10"])
    }

    /// The rule iterates instances of the SCOPE, not calendar years — so under
    /// a winter scope "first" means the first of each winter, and a winter runs
    /// December into February. Asking the year gives a different, less useful
    /// answer to a different question.
    func testFirstMeansFirstOfEachSCOPEInstanceNotEachCalendarYear() {
        // Every December 5 and every January 20 freezes.
        var records: [DailyRecord] = []
        for y in 2022...2024 {
            records += year(y, hot: [], from: "\(y)-01-01", through: "\(y)-12-31")
        }
        for index in records.indices {
            let monthDay = DayKey.monthDay(of: records[index].day)
            if monthDay == "12-05" || monthDay == "01-20" { records[index].tempMin = 28 }
            else { records[index].tempMin = 50 }
        }
        let freezing = [Condition(.low, .below(32))]
        let winter = WeatherPeriod.seasons.first { $0.name == "Winter" }!
        let climate = Climatology(records: records)

        // By calendar year the first freeze is in JANUARY.
        let byYear = climate.run(DayQuery(conditions: freezing, sequence: .firstEachYear))
        XCTAssertEqual(byYear.spread?.typical, "01-20")

        // By winter it's in DECEMBER — the same data, the right question.
        let byWinter = climate.run(DayQuery(conditions: freezing, scope: winter,
                                            sequence: .firstEachYear))
        XCTAssertEqual(byWinter.spread?.typical, "12-05")
        // And a winter's January belongs to the year the winter OPENED in.
        XCTAssertEqual(byWinter.spread?.occurrences.first?.year, 2022)
    }

    /// Found against real data: 2024's and 2025's first freeze both fell on
    /// January 1, and the coverage helper measures a span EXCLUSIVELY — so a
    /// one-day window read as no window and both were withheld. A candidate on
    /// the window's opening day has nothing before it that could be missed.
    func testAnOccurrenceOnTheWindowsFirstDayIsNotWithheld() {
        var records = year(2023) + year(2024)
        for index in records.indices {
            records[index].tempMin = records[index].day == "2024-01-01" ? 28 : 50
        }
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.low, .below(32))], sequence: .firstEachYear))

        XCTAssertEqual(result.days.map(\.day), ["2024-01-01"])
    }

    /// A wrapping scope reads December before January. Sorting the raw
    /// month-days would report the season's end as its beginning.
    func testTheSpreadIsOrderedAlongTheScopeNotTheCalendar() {
        var records: [DailyRecord] = []
        for y in 2022...2024 { records += year(y) }
        // Freezes on Dec 20 of one winter and Jan 5 of the next.
        for index in records.indices {
            let day = records[index].day
            records[index].tempMin = (day == "2022-12-20" || day == "2024-01-05") ? 28 : 50
        }
        let winter = WeatherPeriod.seasons.first { $0.name == "Winter" }!
        let spread = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.low, .below(32))],
                          scope: winter, sequence: .firstEachYear)).spread

        // December is EARLIER in a winter than January, however the strings sort.
        XCTAssertEqual(spread?.earliest, "12-20")
        XCTAssertEqual(spread?.latest, "01-05")
    }

    /// A frequency curve over one date a year is flat noise, and reporting
    /// "never becomes the norm" about a first-freeze query is a category error.
    func testTheSeasonalCurveIsSuppressedUnderAFirstOrLastRule() {
        let records = year(2022, hot: ["06-10"]) + year(2023, hot: ["06-10"])
            + year(2024, hot: ["06-10"])
        let climate = Climatology(records: records)

        XCTAssertNotNil(climate.run(DayQuery(conditions: hot)).season)
        XCTAssertNil(climate.run(DayQuery(conditions: hot, sequence: .firstEachYear)).season)
        // …and the spread takes its place.
        XCTAssertNotNil(climate.run(DayQuery(conditions: hot, sequence: .firstEachYear)).spread)
        XCTAssertNil(climate.run(DayQuery(conditions: hot)).spread)
    }

    // MARK: Runs

    func testARunKeepsEveryDayInIt() {
        let records = year(2023, hot: ["07-01", "07-02", "07-03", "07-04", "08-15"])
        let result = Climatology(records: records)
            .run(DayQuery(conditions: hot, sequence: .inRunOfAtLeast(3)))

        XCTAssertEqual(result.days.map(\.day).sorted(),
                       ["2023-07-01", "2023-07-02", "2023-07-03", "2023-07-04"])
        XCTAssertFalse(result.days.contains { $0.day == "2023-08-15" }, "a lone day is not a run")
    }

    /// A hole in the record ENDS a run rather than being stepped over: two
    /// three-day runs either side of a missing day are not a seven-day run.
    func testAGapEndsARunRatherThanBeingBridged() {
        var records = year(2023, hot: ["07-01", "07-02", "07-03", "07-05", "07-06", "07-07"])
        records.removeAll { $0.day == "2023-07-04" }
        let result = Climatology(records: records)
            .run(DayQuery(conditions: hot, sequence: .inRunOfAtLeast(6)))

        XCTAssertTrue(result.days.isEmpty, "six hot days with a hole in them is not a run of six")
    }

    // MARK: The day before

    func testTheDayBeforeIsACondition() {
        let records = year(2023, hot: ["07-02", "07-20"], rain: ["07-01"])
        let result = Climatology(records: records)
            .run(DayQuery(conditions: hot,
                          precededBy: PrecedingClause(conditions: [Condition(.rain, .atOrAbove(0.1))])))

        XCTAssertEqual(result.days.map(\.day), ["2023-07-02"])
    }

    /// The same asymmetry, one day back: "we don't know if it rained yesterday"
    /// must never be recorded as "it didn't rain yesterday".
    func testAMissingYesterdayIsUnknownNotNo() {
        var records = year(2023, hot: ["07-02"], rain: [])
        records.removeAll { $0.day == "2023-07-01" }
        let result = Climatology(records: records)
            .run(DayQuery(conditions: hot,
                          precededBy: PrecedingClause(conditions: [Condition(.rain, .atOrAbove(0.1))])))

        XCTAssertEqual(result.matchCount, 0)
        XCTAssertTrue(result.isFloor, "the day couldn't be settled, so the count is a floor")
    }

    func testAWiderWindowLooksFurtherBack() {
        let records = year(2023, hot: ["07-04"], rain: ["07-01"])
        let narrow = PrecedingClause(conditions: [Condition(.rain, .atOrAbove(0.1))], within: 1)
        let wide = PrecedingClause(conditions: [Condition(.rain, .atOrAbove(0.1))], within: 4)
        let climate = Climatology(records: records)

        XCTAssertEqual(climate.run(DayQuery(conditions: hot, precededBy: narrow)).matchCount, 0)
        XCTAssertEqual(climate.run(DayQuery(conditions: hot, precededBy: wide)).matchCount, 1)
    }

    /// "Days after it rained" says nothing about the day itself.
    func testAQueryMayHaveNoConditionOnTheDayItself() {
        let records = year(2023, rain: ["07-01", "09-01"])
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [],
                          precededBy: PrecedingClause(conditions: [Condition(.rain, .atOrAbove(0.1))])))

        XCTAssertEqual(result.days.map(\.day).sorted(), ["2023-07-02", "2023-09-02"])
    }

    // MARK: What a sequence rule does to the rest of the result

    /// "The first 100° day of each year" is four days out of fourteen hundred.
    /// 0.3% is a true fraction that means nothing — the denominator stopped
    /// corresponding to the thing being counted.
    func testTheRateIsWithheldUnderASequenceRule() {
        let records = year(2022, hot: ["06-10"]) + year(2023, hot: ["05-01"])
        let climate = Climatology(records: records)

        XCTAssertNotNil(climate.run(DayQuery(conditions: hot)).rate)
        XCTAssertNil(climate.run(DayQuery(conditions: hot, sequence: .firstEachYear)).rate)
    }

    /// Every grouping is rebuilt from the surviving days, not the candidates.
    func testTheCalendarAndMonthsDescribeTheSurvivingDays() {
        let records = year(2022, hot: ["06-10", "08-20"]) + year(2023, hot: ["06-10", "08-20"])
        let result = Climatology(records: records)
            .run(DayQuery(conditions: hot, sequence: .firstEachYear))

        XCTAssertEqual(result.months.first { $0.month == 6 }?.matched, 2)
        XCTAssertEqual(result.months.first { $0.month == 8 }?.matched, 0,
                       "August's days were candidates but not survivors")
        XCTAssertEqual(result.calendar.first { $0.monthDay == "06-10" }?.yearsMatched, 2)
        XCTAssertEqual(result.calendar.first { $0.monthDay == "08-20" }?.yearsMatched, 0)
    }
}

/// The normals gained several measures at once, and wiring them up exposed a
/// mismatch that had been quietly inflating one of them.
final class NormalCoverageTests: XCTestCase {

    private func climate() -> Climatology {
        var records: [DailyRecord] = []
        for year in 2021...2024 {
            var cursor = "\(year)-01-01"
            while cursor <= "\(year)-12-31" {
                var record = DailyRecord(day: cursor, sampleCount: 48, expectedSamples: 48)
                record.dewPointMean = 60
                record.dewPointMax = 68          // peaks 8° above the mean, as they do
                record.humidityMean = 55
                record.windAvgMean = 8
                record.windGustMax = 22
                record.pressureMean = 29.9
                record.uvMax = 7
                record.tempMax = 90
                record.tempMin = 68
                record.schemaVersion = DailyRecord.currentSchemaVersion
                records.append(record)
                guard let next = DayKey.next(cursor) else { break }
                cursor = next
            }
        }
        return Climatology(records: records)
    }

    /// A PEAK dew point judged against the MEAN dew-point normal is inflated by
    /// the gap between them — around 5° at this station, enough to make an
    /// ordinary muggy afternoon read as a notable one.
    func testPeakDewPointIsJudgedAgainstThePeakNormal() {
        let normal = climate().normal(monthDay: "07-15")
        XCTAssertEqual(normal.dewPoint ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(normal.dewPointPeak ?? 0, 68, accuracy: 0.01)

        let result = climate().run(DayQuery(conditions: [Condition(.dewPointPeak, .atOrAbove(60))]))
        let sample = result.days.first { $0.day == "2024-07-15" }
        // 68 against a 68 normal is ordinary — against the 60 mean it would
        // have reported +8 every single day of the year.
        XCTAssertEqual(sample?.departure ?? 99, 0, accuracy: 0.01)
    }

    /// Humidity was the first example asked for and had no baseline at all.
    func testTheNewMeasuresAllCarryABaseline() {
        let normal = climate().normal(monthDay: "07-15")
        XCTAssertEqual(normal.humidity ?? 0, 55, accuracy: 0.01)
        XCTAssertEqual(normal.wind ?? 0, 8, accuracy: 0.01)
        XCTAssertEqual(normal.gust ?? 0, 22, accuracy: 0.01)
        XCTAssertEqual(normal.pressure ?? 0, 29.9, accuracy: 0.01)
        XCTAssertEqual(normal.uv ?? 0, 7, accuracy: 0.01)

        for measure in [Measure.humidity, .wind, .gust, .pressure, .uv, .dewPointPeak] {
            XCTAssertNotNil(measure.normalPath, "\(measure.name) still has no baseline")
        }
        // Lightning deliberately keeps none: a "normal" strike count is 0.0 on
        // almost every date, and a departure from it just restates the count.
        XCTAssertNil(Measure.lightning.normalPath)
    }
}
