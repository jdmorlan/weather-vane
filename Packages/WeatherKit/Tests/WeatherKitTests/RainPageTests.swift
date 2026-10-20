import XCTest
@testable import WeatherKit

final class RainPageTests: XCTestCase {

    /// A watched day per date across an inclusive range, rain chosen per day.
    private func days(from start: String, to end: String, rain: (String) -> Double) -> [DailyRecord] {
        var result: [DailyRecord] = []
        var cursor = start
        while cursor <= end {
            var record = DailyRecord(day: cursor, sampleCount: 48, expectedSamples: 48)
            record.precipTotal = rain(cursor)
            record.schemaVersion = DailyRecord.currentSchemaVersion
            result.append(record)
            guard let next = DayKey.next(cursor) else { break }
            cursor = next
        }
        return result
    }

    // MARK: Pace

    func testUsualLineAtTodayIsTheHeadlineNumber() {
        // An inch on the 1st of every month in 2023 and 2024, two inches in 2025.
        var records: [DailyRecord] = []
        for (year, inches) in [(2023, 1.0), (2024, 1.0), (2025, 2.0)] {
            records += days(from: "\(year)-01-01", to: "\(year)-12-31") { $0.hasSuffix("-01") ? inches : 0 }
        }
        records += days(from: "2026-01-01", to: "2026-06-15") { $0.hasSuffix("-01") ? 0.5 : 0 }
        let climate = Climatology(records: records)

        let pace = climate.rainPace(asOf: "2026-06-15")
        XCTAssertEqual(pace.toDate, 3.0)          // six half-inches
        XCTAssertEqual(pace.usualToDate, 6.0)     // median of 6, 6, 12
        XCTAssertEqual(pace.departure, -3.0)
        XCTAssertEqual(pace.usualYear, 12.0)
        XCTAssertEqual(pace.usualToDate, climate.rainfallSummary(asOf: "2026-06-15").typicalToDate)
        XCTAssertNil(pace.thisYear[pace.throughSlot + 1], "the line stops at the last archived day")
    }

    func testAYearThatDidNotWatchAStretchStaysOutOfTheUsual() {
        var records: [DailyRecord] = []
        records += days(from: "2023-01-01", to: "2023-12-31") { _ in 0.1 }
        records += days(from: "2024-01-01", to: "2024-12-31") { _ in 0.1 }
        // 2025 only from July, so it can't speak for spring.
        records += days(from: "2025-07-01", to: "2025-12-31") { _ in 1.0 }
        records += days(from: "2026-01-01", to: "2026-02-20") { _ in 0 }
        let pace = Climatology(records: records).rainPace(asOf: "2026-02-20")
        XCTAssertEqual(pace.usualToDate ?? 0, 5.1, accuracy: 0.001)   // 51 days of 0.1, not pulled down by 2025
    }

    // MARK: Lately

    func testLatelyComparesTheSameWindowInEarlierYears() {
        var records: [DailyRecord] = []
        for year in 2023...2025 {
            records += days(from: "\(year)-09-01", to: "\(year)-10-31") { $0.hasSuffix("-10-01") ? 2 : 0 }
        }
        records += days(from: "2026-09-01", to: "2026-10-20") { $0 == "2026-10-16" ? 0.18 : 0 }
        let lately = Climatology(records: records).rainLately(asOf: "2026-10-19")

        XCTAssertEqual(lately.window, 30)
        XCTAssertEqual(lately.days.first?.day, "2026-09-20")
        XCTAssertEqual(lately.total, 0.18, accuracy: 0.001)
        XCTAssertEqual(lately.usual, 2)
        XCTAssertEqual(lately.dryDays, 3)
        XCTAssertEqual(lately.lastRain?.day, "2026-10-16")
    }

    // MARK: The record, a row per year

    func testADrySpellAcrossNewYearIsDrawnOnBothRows() {
        // Rain every day except Dec 20 2023 – Jan 23 2024.
        let records = days(from: "2023-01-01", to: "2024-06-30") { day in
            day >= "2023-12-20" && day <= "2024-01-23" ? 0 : 0.05
        }
        let record = Climatology(records: records).rainYears(asOf: "2024-06-30")

        let y2024 = record.years.first { $0.year == 2024 }, y2023 = record.years.first { $0.year == 2023 }
        XCTAssertEqual(record.years.map(\.year), [2024, 2023], "newest first")
        XCTAssertEqual(y2023?.spells.first?.days, 35)
        XCTAssertEqual(y2023?.spells.first?.slots, 353...364)
        XCTAssertEqual(y2024?.spells.first?.slots, 0...22)
        XCTAssertEqual(y2024?.spells.first?.continues, true)
    }

    func testAnUnwatchedDayIsAGapNotADryDay() {
        var records = days(from: "2024-01-01", to: "2024-12-31") { $0 == "2024-06-01" ? 2 : 0 }
        records.removeAll { $0.day == "2024-03-15" }
        let row = Climatology(records: records).rainYears(asOf: "2025-01-01").years.first { $0.year == 2024 }
        XCTAssertNil(row?.amounts[YearSlot.of("2024-03-15")!])
        XCTAssertEqual(row?.amounts[YearSlot.of("2024-03-14")!], 0)
        // The outage splits what would have been one long spell from Jan 1.
        XCTAssertEqual(row?.spells.first?.endDay, "2024-03-14")
    }

    func testARowsTotalIsTheYearTotalTheRestOfThePageQuotes() {
        var records = days(from: "2024-01-01", to: "2024-12-31") { $0.hasSuffix("-15") ? 1 : 0 }
        // A half-watched day with rain on it still counts toward the total.
        if let i = records.firstIndex(where: { $0.day == "2024-07-15" }) {
            records[i] = DailyRecord(day: "2024-07-15", sampleCount: 10, expectedSamples: 48)
            records[i].precipTotal = 0.4
        }
        let climate = Climatology(records: records)
        let row = climate.rainYears(asOf: "2025-01-01").years.first { $0.year == 2024 }
        let annual = climate.rainfallSummary(asOf: "2025-01-01").years.first { $0.year == 2024 }
        XCTAssertEqual(row?.total ?? 0, annual?.total ?? -1, accuracy: 0.0001)
        XCTAssertEqual(row?.amounts[YearSlot.of("2024-07-15")!], 0.4)
    }

    func testTheBiggestDaysAreRanked() {
        let records = days(from: "2024-01-01", to: "2024-12-31") { day in
            ["2024-05-04": 2.0, "2024-06-19": 2.36, "2024-10-03": 2.5][day] ?? 0
        }
        let record = Climatology(records: records).rainYears(asOf: "2025-01-01", biggest: 2)
        XCTAssertEqual(record.biggest.map(\.day), ["2024-10-03", "2024-06-19"])
        XCTAssertEqual(record.biggest.map(\.rank), [1, 2])
        XCTAssertEqual(record.peak, 2.5)
    }

    // MARK: Drought

    func testDroughtWeeksDecodeAndSayWhenTheyEased() throws {
        let json = """
        [{"mapDate":"2026-10-13T00:00:00","fips":"48193","d0":100.00,"d1":100.00,"d2":0.00,"d3":0.00,"d4":0.00},
         {"mapDate":"2026-09-29T00:00:00","fips":"48193","d0":100.00,"d1":100.00,"d2":100.00,"d3":0.00,"d4":0.00},
         {"mapDate":"2026-10-06T00:00:00","fips":"48193","d0":100.00,"d1":100.00,"d2":0.00,"d3":0.00,"d4":0.00},
         {"mapDate":"2026-09-15T00:00:00","fips":"48193","d0":100.00,"d1":100.00,"d2":78.04,"d3":0.00,"d4":0.00}]
        """
        let weeks = try DroughtMonitorClient.decode(Data(json.utf8))
        XCTAssertEqual(weeks.map(\.mapDate), ["2026-09-15", "2026-09-29", "2026-10-06", "2026-10-13"])
        XCTAssertEqual(weeks.last?.prevailing, .d1)
        XCTAssertEqual(weeks.first?.prevailing, .d2)

        let report = DroughtReport(countyName: "Hamilton", state: "TX", fips: "48193", weeks: weeks, fetched: Date())
        XCTAssertEqual(report.lastChange?.week.mapDate, "2026-10-06")
        XCTAssertEqual(report.lastChange?.from, .d2)
    }

    func testACountyMostlyClearIsNotCalledADrought() {
        let week = DroughtWeek(mapDate: "2026-01-06", atLeast: [30, 10, 0, 0, 0])
        XCTAssertNil(week.prevailing)
        XCTAssertEqual(week.worst, .d1)
    }
}
