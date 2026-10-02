import XCTest
@testable import WeatherKit

/// Compare's month view: every year cut to the same days as the one running.
final class StretchComparisonTests: XCTestCase {

    private func day(_ key: String, high: Double = 85, low: Double = 70,
                     precip: Double = 0, coverage: Double = 1) -> DailyRecord {
        var record = DailyRecord(day: key, sampleCount: Int(48 * coverage), expectedSamples: 48)
        record.tempMax = high
        record.tempMin = low
        record.precipTotal = precip
        return record
    }

    /// Every day of October in a year, with rain on the days given.
    private func october(_ year: Int, high: Double = 85,
                         rain: [Int: Double] = [:]) -> [DailyRecord] {
        (1...31).map { d in
            day(String(format: "%04d-10-%02d", year, d), high: high, precip: rain[d] ?? 0)
        }
    }

    private let october2026 = WeatherPeriod.month(containing: "2026-10-02")

    /// Two days in: every year is tallied over Oct 1–2, not over its whole month.
    func testEveryYearIsCutToTheDaysTheRunningMonthHasReached() {
        let climate = Climatology(records:
            october(2024, rain: [1: 0.2, 20: 3.0])      // wet late, not early
            + october(2025, rain: [2: 0.5])
            + [day("2026-10-01", precip: 1.4)])          // archive stops at yesterday
        let s = climate.stretch(october2026, today: "2026-10-02")

        XCTAssertEqual(s.cut, 1)
        XCTAssertEqual(s.length, 31)
        XCTAssertEqual(s.years.map(\.year), [2026, 2025, 2024])
        XCTAssertTrue(s.years[0].isCurrent)
        // 2024's 3″ on the 20th is outside the cut and must not count.
        XCTAssertEqual(s.years[2].tally.rain, 0.2, accuracy: 0.001)
        XCTAssertEqual(s.years[1].tally.rain, 0, accuracy: 0.001)
        // But the full month is still drawn for the past years.
        XCTAssertEqual(s.years[2].days.count, 31)
        XCTAssertEqual(s.years[0].days.count, 1)
    }

    func testTheSentenceRanksTheRunningStartAgainstTheSameDays() {
        let climate = Climatology(records:
            october(2024, rain: [1: 0.2]) + october(2025)
            + [day("2026-10-01", precip: 1.4)])
        let text = climate.stretch(october2026, today: "2026-10-02").sentence()
        XCTAssertEqual(text?.hasPrefix("October so far: 1.40″ of rain — the wettest start of the 3 shown. 2024 had 0.20″ by now."), true, text ?? "nil")
    }

    /// When every other year was dry, say so — not "2025 had 0.00″".
    func testAWetStartAgainstDryYearsSaysTheyWereDry() {
        let climate = Climatology(records: october(2024) + october(2025) + [day("2026-10-01", precip: 1.49)])
        let text = climate.stretch(october2026, today: "2026-10-02").sentence()
        XCTAssertEqual(text?.hasPrefix("October so far: 1.49″ of rain — the wettest start of the 3 shown. None of the other 2 had any by now."), true, text ?? "nil")
    }

    /// Most of the way through, it's no longer a "start".
    func testLateInTheStretchItIsNotCalledAStart() {
        let climate = Climatology(records: october(2025, rain: [3: 0.1])
            + (1...20).map { day(String(format: "2026-10-%02d", $0), precip: $0 == 5 ? 1.0 : 0) })
        let text = climate.stretch(october2026, today: "2026-10-21").sentence()
        XCTAssertEqual(text?.hasPrefix("October so far: 1.00″ of rain — the wettest of the 2 shown."), true, text ?? "nil")
    }

    /// Choosing years re-ranks among the ones shown, never among hidden ones.
    func testChosenYearsAreTheOnlyOnesRanked() {
        let climate = Climatology(records:
            october(2024, rain: [1: 2.0]) + october(2025, rain: [1: 0.1])
            + [day("2026-10-01", precip: 1.4)])
        let s = climate.stretch(october2026, today: "2026-10-02")
        XCTAssertEqual(s.sentence()?.contains("2nd wettest start of the 3"), true)
        XCTAssertEqual(s.sentence(years: [2026, 2025])?.contains("the wettest start of the 2"), true)
    }

    /// Walked to a month the calendar isn't in: nothing is running, so the most
    /// recent instance is the subject and every year is compared whole.
    func testAFinishedMonthComparesWhole() {
        let climate = Climatology(records:
            october(2024, rain: [20: 3.0]) + october(2025, rain: [2: 0.5])
            + [day("2026-10-01")])
        let s = climate.stretch(october2026, today: "2026-11-15")
        XCTAssertNil(s.cut)
        XCTAssertFalse(s.isRunning)
        XCTAssertEqual(s.subject?.year, 2026)
        // Asked from mid-November, October 2026 is finished, though the archive
        // here only holds its first day.
        let thin = s.years.first { $0.year == 2026 }
        XCTAssertEqual(thin?.tally.isComparable, false)
        XCTAssertEqual(s.years.first { $0.year == 2024 }?.tally.rain ?? 0, 3.0, accuracy: 0.001)
    }

    func testOnTheFirstDayThereIsNothingToRankYet() {
        let climate = Climatology(records: october(2025))
        let s = climate.stretch(october2026, today: "2026-10-01")
        XCTAssertEqual(s.cut, 0)
        XCTAssertEqual(s.sentence(), "October starts today — nothing measured yet to set against other years.")
    }

    /// The forecast belongs to the running instance from today on, and nowhere else.
    func testForecastIsFencedToTheRunningInstanceFromToday() {
        let climate = Climatology(records: october(2025) + [day("2026-10-01")])
        let s = climate.stretch(october2026, today: "2026-10-02", forecast: [
            "2026-10-01": (90, 70, 0.1),      // yesterday — measured, not forecast
            "2026-10-02": (88, 71, 0.3),
            "2026-10-03": (87, 70, nil),
            "2026-11-01": (80, 60, 1.0),      // the next month
        ])
        XCTAssertEqual(s.forecast.map(\.index), [1, 2])
        XCTAssertNil(s.forecast[1].precip, "a day the hourly doesn't reach is unknown, not dry")
    }

    /// A winter that holds today opened LAST December.
    func testAWrappingSeasonFindsTheInstanceThatOpenedLastYear() {
        let winter = WeatherPeriod.season(containing: "2026-01-10")
        let climate = Climatology(records: [day("2025-12-01", precip: 0.5), day("2026-01-09")])
        let s = climate.stretch(winter, today: "2026-01-10")
        XCTAssertEqual(s.subject?.year, 2025)
        XCTAssertTrue(s.isRunning)
        XCTAssertEqual(s.cut, 40)   // Dec 1 through Jan 9
    }

    func testCumulativeRainGoesFlatOverMissingDays() {
        let climate = Climatology(records: [day("2025-10-01", precip: 0.5), day("2025-10-03", precip: 0.25)])
        let year = climate.stretch(october2026, today: "2026-11-01").years.first { $0.year == 2025 }
        let totals = year?.cumulativeRain.prefix(3).map(\.total)
        XCTAssertEqual(totals, [0.5, 0.5, 0.75])
    }

    /// The second clause follows the measure being compared.
    func testTheSentenceFollowsTheChosenMeasure() {
        func gusty(_ key: String, _ gust: Double) -> DailyRecord {
            var r = day(key); r.windGustMax = gust; r.dewPointMax = 70; return r
        }
        let climate = Climatology(records:
            (1...31).map { gusty(String(format: "2025-10-%02d", $0), 15) }
            + [gusty("2026-10-01", 24)])
        let text = climate.stretch(october2026, today: "2026-10-02").sentence(measure: .gust)
        XCTAssertEqual(text?.hasSuffix("Peak gusts are averaging 24 mph, 9 mph windier than other years' same days."), true,
                       text ?? "nil")
    }
}
