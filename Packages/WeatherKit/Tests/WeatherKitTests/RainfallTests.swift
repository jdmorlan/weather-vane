import XCTest
@testable import WeatherKit

final class RainfallTests: XCTestCase {

    /// A year of days, with rain chosen per day.
    private func year(_ y: Int, through end: String? = nil,
                      precip: (String) -> Double?) -> [DailyRecord] {
        var records: [DailyRecord] = []
        var cursor = "\(y)-01-01"
        let last = end ?? "\(y)-12-31"
        while cursor <= last {
            var record = DailyRecord(day: cursor, sampleCount: 48, expectedSamples: 48)
            record.precipTotal = precip(cursor)
            record.schemaVersion = DailyRecord.currentSchemaVersion
            records.append(record)
            guard let next = DayKey.next(cursor) else { break }
            cursor = next
        }
        return records
    }

    /// Quarter of an inch on the 10th of each month = 0.25"/month, 3.00"/year.
    private func steady(_ y: Int, perMonth: Double = 0.25) -> [DailyRecord] {
        year(y) { day in DayKey.monthDay(of: day).hasSuffix("-10") ? perMonth : 0 }
    }

    // MARK: Monthly shape

    func testMonthlyTypicalIsTheMedianAcrossYears() {
        var records = steady(2022) + steady(2023) + steady(2024)
        // 2025 runs to Aug 5, with a wet May.
        records += year(2025, through: "2025-08-05") { day in
            DayKey.monthDay(of: day) == "05-10" ? 4.0 : (DayKey.monthDay(of: day).hasSuffix("-10") ? 0.25 : 0)
        }
        let summary = Climatology(records: records).rainfallSummary(asOf: "2025-08-06")

        let may = summary.months.first { $0.month == 5 }
        XCTAssertEqual(may?.typical ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(may?.thisYear ?? 0, 4.0, accuracy: 0.001)
        XCTAssertEqual(may?.years, 3)

        // A month that hasn't started reports no total, only the usual.
        let october = summary.months.first { $0.month == 10 }
        XCTAssertNil(october?.thisYear)
        XCTAssertEqual(october?.typical ?? 0, 0.25, accuracy: 0.001)
    }

    /// The archive stops at yesterday BY DESIGN, so today must not be counted as
    /// a day the station missed — otherwise every running month reads as short.
    func testTodayIsNotCountedAsAMissedDay() {
        let records = steady(2023) + steady(2024) + year(2025, through: "2025-08-05") { _ in 0 }
        let summary = Climatology(records: records).rainfallSummary(asOf: "2025-08-06")

        XCTAssertEqual(summary.daysMissedThisYear, 0)
        let august = summary.months.first { $0.month == 8 }
        XCTAssertTrue(august?.isInProgress ?? false)
        XCTAssertEqual(august?.coverage ?? 0, 1.0, accuracy: 0.001)
        XCTAssertTrue(august?.isTrustworthy ?? false)
    }

    /// Rain is the measure a gap destroys outright: the missing hour may be the
    /// hour it rained, and nothing nearby recovers it. A month with holes reports
    /// what it SAW and is marked untrustworthy rather than drawn short in silence.
    func testAMonthWithHolesIsAFloorAndSaysSo() {
        var records = steady(2023) + steady(2024)
        var thisYear = year(2025, through: "2025-08-05") { _ in 0 }
        thisYear.removeAll { $0.day >= "2025-03-05" && $0.day <= "2025-03-20" }   // 16 days gone
        records += thisYear

        let summary = Climatology(records: records).rainfallSummary(asOf: "2025-08-06")
        let march = summary.months.first { $0.month == 3 }
        XCTAssertLessThan(march?.coverage ?? 1, 0.9)
        XCTAssertFalse(march?.isTrustworthy ?? true)
        // The rain it did see is still reported — the gap widens doubt, it doesn't
        // erase the month.
        XCTAssertNotNil(march?.thisYear)
    }

    /// A half-watched month must not inform the usual, or it drags the typical
    /// down by exactly the rain nobody recorded.
    func testAHalfWatchedMonthDoesNotInformTheTypical() {
        var records = steady(2023, perMonth: 2.0) + steady(2024, perMonth: 2.0)
        // 2022 saw only the back half of June, and none of its rain.
        var thin = year(2022, through: "2022-12-31") { _ in 0 }
        thin.removeAll { $0.day >= "2022-06-01" && $0.day <= "2022-06-20" }
        records += thin

        let summary = Climatology(records: records).rainfallSummary(asOf: "2025-08-06")
        let june = summary.months.first { $0.month == 6 }
        XCTAssertEqual(june?.years, 2, "the gappy June is excluded from the usual")
        XCTAssertEqual(june?.typical ?? 0, 2.0, accuracy: 0.001)
    }

    // MARK: Year to date

    /// To-date against the same stretch of past years — never against a whole-year
    /// normal, or every January reads as a drought.
    func testYearToDateComparesTheSameStretchOfPastYears() {
        // Prior years: 1.00" by Mar 6 (Jan and Feb only). This year: bone dry.
        var records = year(2023) { day in DayKey.monthDay(of: day).hasSuffix("-10") ? 0.5 : 0 }
        records += year(2024) { day in DayKey.monthDay(of: day).hasSuffix("-10") ? 0.5 : 0 }
        records += year(2025, through: "2025-03-05") { _ in 0 }

        let summary = Climatology(records: records).rainfallSummary(asOf: "2025-03-06")
        XCTAssertEqual(summary.yearToDate, 0, accuracy: 0.001)
        XCTAssertEqual(summary.typicalToDate ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(summary.departureToDate ?? 0, -1.0, accuracy: 0.001)
        // Not the 6.00" a full prior year held — that comparison would be a lie.
        XCTAssertEqual(summary.typicalYear ?? 0, 6.0, accuracy: 0.001)
    }

    // MARK: Year by year

    func testAnnualTotalsRankAndFlagIncompleteYears() {
        var records = year(2023) { day in DayKey.monthDay(of: day).hasSuffix("-10") ? 1.0 : 0 }   // 12"
        records += year(2024) { day in DayKey.monthDay(of: day).hasSuffix("-10") ? 2.0 : 0 }      // 24"
        // 2022 starts in October — a real archive's first months.
        records += year(2022) { _ in 0 }.filter { $0.day >= "2022-10-08" }
        records += year(2025, through: "2025-08-05") { _ in 0 }

        let summary = Climatology(records: records).rainfallSummary(asOf: "2025-08-06")
        XCTAssertEqual(summary.wettestYear?.year, 2024)
        XCTAssertEqual(summary.driestYear?.year, 2023)

        let partial = summary.years.first { $0.year == 2022 }
        XCTAssertFalse(partial?.isTrustworthy ?? true, "a quarter of a year can't be ranked against whole ones")
        let running = summary.years.first { $0.year == 2025 }
        XCTAssertTrue(running?.isInProgress ?? false)
        XCTAssertFalse(running?.isTrustworthy ?? true)
    }

    func testSummaryStaysQuietUntilThereAreTwoComparableYears() {
        let records = year(2024) { _ in 0.1 } + year(2025, through: "2025-08-05") { _ in 0 }
        let summary = Climatology(records: records).rainfallSummary(asOf: "2025-08-06")
        XCTAssertFalse(summary.isMeaningful)
    }

    func testMonthBoundsHandleDecemberAndLeapFebruary() {
        XCTAssertEqual(Climatology.monthBounds(year: 2024, month: 12).end, "2024-12-31")
        XCTAssertEqual(Climatology.monthBounds(year: 2024, month: 12).days, 31)
        XCTAssertEqual(Climatology.monthBounds(year: 2024, month: 2).end, "2024-02-29")
        XCTAssertEqual(Climatology.monthBounds(year: 2023, month: 2).end, "2023-02-28")
    }
}
