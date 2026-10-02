import XCTest
@testable import WeatherKit

/// Compare's day: today's hours against the same date's hours in other years.
final class DayOverlayTests: XCTestCase {

    /// A smooth day: `low` at 6am, `high` at 3pm.
    private func shape(low: Double, high: Double) -> [Int: Double] {
        Dictionary(uniqueKeysWithValues: (0..<24).map { hour in
            let t = hour < 6 ? 0.0 : hour <= 15 ? Double(hour - 6) / 9 : 1 - Double(hour - 15) / 9
            return (hour, low + (high - low) * max(0, t))
        })
    }

    private func overlay(today: [Int: Double], measuredThrough: Int,
                         others: [(Int, Double, Double)]) -> DayOverlay {
        DayOverlay(dateLabel: "Oct 2",
                   subject: HourTrace(year: 2026, temps: today, observed: Set(0...measuredThrough)),
                   isToday: true,
                   others: others.map { HourTrace(year: $0.0, temps: shape(low: $0.1, high: $0.2)) })
    }

    func testACoolMorningIsSetAgainstTheSameHourInOtherYears() {
        var today = shape(low: 60, high: 88)
        today[8] = 64
        let text = overlay(today: today, measuredThrough: 8,
                           others: [(2025, 72, 92), (2024, 70, 90)]).sentence()
        XCTAssertEqual(text?.hasPrefix("At 8am it was 64° — cooler than every other Oct 2 at that hour"), true, text ?? "nil")
        XCTAssertEqual(text?.contains("The forecast peaks at 88° around 3pm; the other Oct 2s peaked at 90°–92°."), true, text ?? "nil")
    }

    /// Once the peak has been measured it's no longer "the forecast".
    func testAMeasuredPeakIsReportedAsWhatHappened() {
        let text = overlay(today: shape(low: 70, high: 91), measuredThrough: 18,
                           others: [(2025, 72, 92)]).sentence()
        XCTAssertEqual(text?.contains("It peaked at 91° around 3pm; the other Oct 2 peaked at 92°."), true, text ?? "nil")
    }

    /// Another date: no "now", and the newest year is the subject.
    func testAPastDateNamesItsYear() {
        let o = DayOverlay(dateLabel: "Oct 3",
                           subject: HourTrace(year: 2025, temps: shape(low: 70, high: 91)),
                           isToday: false,
                           others: [HourTrace(year: 2024, temps: shape(low: 65, high: 85))])
        XCTAssertEqual(o.sentence(), "2025 peaked at 91° around 3pm; the other Oct 3 peaked at 85°.")
    }

    /// Half a day's top reading is a floor on the peak, never the peak.
    func testAPartlyRecordedDayDoesNotClaimAPeak() {
        let half = shape(low: 70, high: 91).filter { $0.key >= 9 && $0.key <= 21 }
        let o = DayOverlay(dateLabel: "Jul 15",
                           subject: HourTrace(year: 2026, temps: half),
                           isToday: false,
                           others: [HourTrace(year: 2025, temps: shape(low: 75, high: 98))])
        XCTAssertEqual(o.sentence(), "2026 is only partly recorded (13 of 24 hours) — its highest reading was 91° at 3pm, which the real peak can only match or beat.")
    }

    func testTheBandSpansTheOtherYearsHourByHour() {
        let o = overlay(today: [:], measuredThrough: 0, others: [(2025, 70, 90), (2024, 60, 80)])
        let three = o.band.first { $0.hour == 15 }
        XCTAssertEqual(three?.low, 80)
        XCTAssertEqual(three?.high, 90)
        XCTAssertEqual(three?.mean, 85)
    }

    /// Hourly means are taken in the day's own zone, from the samples inside it.
    func testHourlyMeansComeFromTheSamplesInThatHour() {
        let zone = TimeZone(identifier: "America/Chicago")!
        let midnight = Int(DayKey.date(from: "2025-10-02", timeZone: zone)!.timeIntervalSince1970)
        var a = StationSample(timestamp: midnight + 8 * 3600, bucketMinutes: 1); a.airTemp = 60
        var b = StationSample(timestamp: midnight + 8 * 3600 + 1800, bucketMinutes: 1); b.airTemp = 64
        var c = StationSample(timestamp: midnight + 15 * 3600, bucketMinutes: 1); c.airTemp = 90
        let hourly = HourTrace.hourly([a, b, c], day: "2025-10-02", timeZone: zone)
        XCTAssertEqual(hourly[8], 62)
        XCTAssertEqual(hourly[15], 90)
        XCTAssertNil(hourly[9])
    }

    /// A low reads the bottom of the night, not the top of the afternoon.
    func testALowIsReadForItsTrough() {
        let o = DayOverlay(dateLabel: "Oct 3",
                           subject: HourTrace(year: 2025, temps: shape(low: 66, high: 91)),
                           isToday: false,
                           others: [HourTrace(year: 2024, temps: shape(low: 60, high: 85))],
                           measure: .low)
        XCTAssertEqual(o.sentence()?.hasPrefix("2025 bottomed out at 66° around"), true, o.sentence() ?? "nil")
        XCTAssertEqual(o.sentence()?.hasSuffix("the other Oct 3 bottomed at 60°."), true, o.sentence() ?? "nil")
    }

    func testAGustSpeaksInMilesPerHour() {
        let today = HourTrace(year: 2026, temps: [8: 6, 9: 9, 15: 30], observed: [8])
        let o = DayOverlay(dateLabel: "Oct 2", subject: today, isToday: true,
                           others: [HourTrace(year: 2025, temps: [8: 20, 15: 22]),
                                    HourTrace(year: 2024, temps: [8: 14, 15: 25])],
                           measure: .gust)
        XCTAssertEqual(o.sentence()?.hasPrefix("At 8am it was 6 mph — calmer than every other Oct 2 at that hour (14–20 mph)."), true,
                       o.sentence() ?? "nil")
    }
}
