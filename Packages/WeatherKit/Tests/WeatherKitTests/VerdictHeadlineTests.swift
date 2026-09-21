import XCTest
@testable import WeatherKit

/// `headline` rides above the ten-day it grades, so it has to survive being read
/// in half a second next to a forecast. These pin the three findings it can
/// report and the boundary between them.
final class VerdictHeadlineTests: XCTestCase {

    private func verdict(bias: Double, mae: Double, cold: Int, warm: Int, close: Int,
                         days: Int, tolerance: Double = 2) -> ForecastVerdict {
        ForecastVerdict(checks: (0..<days).map {
            ForecastCheck(day: "2026-09-\(String(format: "%02d", $0 + 1))",
                          issuedAt: 0, leadDays: 1, forecastHigh: 80, actualHigh: 80)
        },
        tolerance: tolerance, bias: bias, meanAbsoluteError: mae,
        coldDays: cold, warmDays: warm, closeDays: close,
        largestMiss: nil, sentence: "", caveat: nil)
    }

    func testAConsistentColdBiasNamesTheDirection() {
        let v = verdict(bias: -3.4, mae: 3.4, cold: 9, warm: 1, close: 0, days: 10)
        XCTAssertEqual(v.headline, "Runs 3.4° cold over 10 days")
        XCTAssertFalse(v.isReassuring)
    }

    func testAConsistentWarmBiasNamesTheOtherDirection() {
        let v = verdict(bias: 3, mae: 3, cold: 1, warm: 9, close: 0, days: 10)
        XCTAssertEqual(v.headline, "Runs 3° warm over 10 days")
    }

    /// Scatter without direction. Averaging to nearly zero is NOT the same as
    /// being accurate, and a headline that said "runs 0° cold" would be the most
    /// misleading thing on the screen.
    func testMissesInBothDirectionsReportScatterNotDirection() {
        let v = verdict(bias: 0.2, mae: 4, cold: 5, warm: 5, close: 1, days: 10)
        XCTAssertEqual(v.headline, "Off 4° either way over 10 days")
        XCTAssertFalse(v.isReassuring)
    }

    func testAForecastInsideToleranceReportsHowOften() {
        let v = verdict(bias: 0.4, mae: 1.1, cold: 2, warm: 2, close: 8, days: 10)
        XCTAssertEqual(v.headline, "Within 2° on 8 of 10 days")
        XCTAssertTrue(v.isReassuring)
    }

    /// A bias larger than tolerance that ISN'T consistent falls through to the
    /// scatter phrasing — the direction is only worth naming when the days
    /// actually agree on it.
    func testALargeButInconsistentBiasDoesNotClaimADirection() {
        let v = verdict(bias: -2.5, mae: 3.5, cold: 6, warm: 4, close: 0, days: 10)
        XCTAssertFalse(v.isConsistent)
        XCTAssertEqual(v.headline, "Off 3.5° either way over 10 days")
    }

    /// Whole numbers print without a decimal. "Runs 3.0° cold" is the kind of
    /// detail that makes a headline read as machine output.
    func testWholeDegreesDropTheDecimal() {
        XCTAssertEqual(verdict(bias: -4, mae: 4, cold: 10, warm: 0, close: 0, days: 10).headline,
                       "Runs 4° cold over 10 days")
    }
}

/// The evening window, and the nouns every window can now supply.
final class ClockWindowNamingTests: XCTestCase {

    func testThePresetsAreInClockOrder() {
        XCTAssertEqual(ClockWindow.presets.map(\.startHour), [6, 13, 17])
        XCTAssertEqual(ClockWindow.presets.map(\.name), ["morning", "afternoon", "evening"])
    }

    func testEveningIsFivePmToNine() {
        XCTAssertEqual(ClockWindow.evening.startHour, 17)
        XCTAssertEqual(ClockWindow.evening.endHour, 21)
        XCTAssertEqual(ClockWindow.evening.hours, 4)
    }

    /// The noun comes off the start hour, not off a match against the presets,
    /// so dragging the hours somewhere custom still yields prose.
    func testACustomWindowStillHasANoun() {
        XCTAssertEqual(ClockWindow(startHour: 4, endHour: 7).name, "morning")
        XCTAssertEqual(ClockWindow(startHour: 15, endHour: 19).name, "afternoon")
        XCTAssertEqual(ClockWindow(startHour: 22, endHour: 24).name, "night")
    }

    func testTheLabelReadsAsClockTime() {
        XCTAssertEqual(ClockWindow.morning.label, "6am–10am")
        XCTAssertEqual(ClockWindow.afternoon.label, "1pm–5pm")
        XCTAssertEqual(ClockWindow.evening.label, "5pm–9pm")
        XCTAssertEqual(ClockWindow(startHour: 0, endHour: 6).label, "12am–6am")
    }
}
