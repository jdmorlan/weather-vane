import XCTest
@testable import WeatherKit

/// Report questions get the picture that fits them, and never compare a partial year as if it were whole.
final class ReportPictureTests: XCTestCase {

    private func days(_ start: String, _ end: String, _ make: (String) -> DailyRecord) -> [DailyRecord] {
        var out: [DailyRecord] = []
        var cursor: String? = start
        while let key = cursor, key <= end { out.append(make(key)); cursor = DayKey.next(key) }
        return out
    }

    private func record(_ key: String, high: Double? = nil, low: Double? = nil, rain: Double? = nil) -> DailyRecord {
        var r = DailyRecord(day: key, sampleCount: 48, expectedSamples: 48)
        r.tempMax = high; r.tempMin = low; r.precipTotal = rain
        r.schemaVersion = DailyRecord.currentSchemaVersion
        return r
    }

    func testEachKindOfQuestionGetsItsPicture() {
        func kind(_ measure: Measure, _ reduce: Aggregate.Reduction, _ group: Aggregate.Grouping) -> ReportPicture.Kind {
            ReportPicture.Kind(Aggregate(measure: measure, reduce: reduce, groupBy: group))
        }
        XCTAssertEqual(kind(.rain, .sum, .year), .yearToDate)
        XCTAssertEqual(kind(.high, .mean, .year), .departureGrid)
        XCTAssertEqual(kind(.high, .max, .year), .extremes)
        XCTAssertEqual(kind(.gust, .max, .month), .monthGrid)
        XCTAssertEqual(kind(.rain, .mean, .monthOfYear), .monthOfYear)
        XCTAssertEqual(kind(.rain, .sum, .none), .single)
    }

    /// A tenth of an inch every day: each complete year adds up to its days, and the year in progress
    /// is read against the usual at the same date rather than against a whole year.
    func testRainIsAddedUpFromJanuaryFirstAndReadAtTheSameDate() throws {
        let climate = Climatology(records: days("2023-01-01", "2025-06-30") { self.record($0, rain: 0.1) })
        let p = try XCTUnwrap(climate.reportPicture(DayQuery(conditions: [],
            aggregate: Aggregate(measure: .rain, reduce: .sum, groupBy: .year))))
        XCTAssertEqual(p.running.map(\.isComplete), [true, true, false])
        XCTAssertEqual(p.running[0].total, 36.5, accuracy: 0.001)
        let today = ReportPicture.dayOfYear(p.recordEnd)
        XCTAssertEqual(p.running[2].total, p.usualRunning[today], accuracy: 0.11, "this year matches the usual by the same date")
    }

    /// A year missing its winter must not read as a hot year: highs at exactly normal are 0° whatever the months.
    func testAPartialYearIsJudgedAgainstNormalForItsDates() throws {
        let climate = Climatology(records: days("2023-01-01", "2025-06-30") { key in
            let slot = Double(YearAxis.day(of: DayKey.monthDay(of: key)) ?? 0)
            return self.record(key, high: 75 + 20 * sin(slot / 366 * 2 * .pi - .pi / 2))
        })
        let p = try XCTUnwrap(climate.reportPicture(DayQuery(conditions: [],
            aggregate: Aggregate(measure: .high, reduce: .mean, groupBy: .year))))
        XCTAssertEqual(p.kind, .departureGrid)
        let partial = try XCTUnwrap(p.years.last)
        XCTAssertFalse(partial.isWhole)
        XCTAssertEqual(partial.value ?? 99, 0, accuracy: 0.5)
    }

    /// The coldest night of each winter, with winters running across New Year.
    func testColdestNightIsDatedPerWinter() throws {
        let climate = Climatology(records: days("2023-07-01", "2025-06-30") { key in
            self.record(key, low: key == "2024-01-10" ? 20 : key == "2025-02-02" ? 25 : 50)
        })
        let p = try XCTUnwrap(climate.reportPicture(DayQuery(conditions: [],
            aggregate: Aggregate(measure: .low, reduce: .min, groupBy: .year))))
        XCTAssertEqual(p.kind, .extremes)
        XCTAssertEqual(p.line, 32)
        let seen = p.seasons.filter(\.isSeen)
        XCTAssertEqual(seen.map(\.day), ["2024-01-10", "2025-02-02"])
        XCTAssertTrue(seen.allSatisfy { $0.label.contains("–") }, "a winter is named by its months")
    }
}
