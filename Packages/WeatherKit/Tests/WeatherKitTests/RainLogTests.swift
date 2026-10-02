import XCTest
@testable import WeatherKit

/// The rain gauge log: one reading over a span, resolved to days by keeping
/// the station's figure where it was right.
final class RainLogTests: XCTestCase {

    /// Oct 1–2, 2026: the station got Oct 1 right and missed Oct 2.
    func testKeepingAGoodDayLeavesTheRemainderForTheMissedOne() throws {
        let days = try GaugeSplit.resolve(total: 1.85,
                                          station: [("2026-10-01", 0.42), ("2026-10-02", 0)],
                                          keep: ["2026-10-01"], typed: [:]).get()
        XCTAssertEqual(days.map(\.amount), [0.42, 1.43])
        XCTAssertEqual(days.map(\.source), [.station, .remainder])
        XCTAssertEqual(days[1].station, 0)
    }

    func testAGaugeTotalSmallerThanTheKeptDaysIsRefused() {
        let result = GaugeSplit.resolve(total: 0.30, station: [("2026-10-01", 0.42), ("2026-10-02", 0)],
                                        keep: ["2026-10-01"], typed: [:])
        XCTAssertEqual(result, .failure(.keptExceedTotal(kept: 0.42, total: 0.30)))
    }

    /// Two days disagreed with, one typed: the other takes what's left.
    func testTypedDaysComeOffBeforeTheRemainder() throws {
        let days = try GaugeSplit.resolve(total: 2.0,
                                          station: [("2026-10-01", 0.5), ("2026-10-02", 0), ("2026-10-03", 0)],
                                          keep: ["2026-10-01"], typed: ["2026-10-02": 0.75]).get()
        XCTAssertEqual(days.map(\.amount), [0.5, 0.75, 0.75])
        XCTAssertEqual(days.map(\.source), [.station, .gauge, .remainder])
    }

    /// Two days left blank: no invented split — the last takes it all.
    func testABlankRunPutsTheRemainderOnTheLastDay() throws {
        let days = try GaugeSplit.resolve(total: 1.0,
                                          station: [("2026-10-02", 0), ("2026-10-03", 0)],
                                          keep: [], typed: [:]).get()
        XCTAssertEqual(days.map(\.amount), [0, 1.0])
    }

    func testEveryDayKeptMustAddUp() {
        XCTAssertEqual(GaugeSplit.resolve(total: 0.42, station: [("2026-10-01", 0.42)], keep: ["2026-10-01"], typed: [:]),
                       .success([.init(day: "2026-10-01", amount: 0.42, station: 0.42, source: .station)]))
        XCTAssertEqual(GaugeSplit.resolve(total: 1.0, station: [("2026-10-01", 0.42)], keep: ["2026-10-01"], typed: [:]),
                       .failure(.nothingLeftToAssign(difference: 0.58)))
    }

    func testMergingKeepsTheNewerEditAndCarriesDeletions() {
        let id = UUID()
        let old = GaugeReading(id: id, from: "2026-10-02", to: "2026-10-02", total: 1.0,
                               days: [.init(day: "2026-10-02", amount: 1.0, station: 0, source: .gauge)],
                               modified: Date(timeIntervalSince1970: 100))
        var gone = old
        gone.deleted = true
        gone.modified = Date(timeIntervalSince1970: 200)
        let merged = RainLog(readings: [old]).merged(with: RainLog(readings: [gone]))
        XCTAssertTrue(merged.live.isEmpty)
        XCTAssertTrue(merged.dailyAmounts.isEmpty)
    }

    func testTheSensorCheckPairsOnlyTheDaysTheGaugeCorrected() {
        let log = RainLog(readings: [GaugeReading(from: "2026-10-01", to: "2026-10-02", total: 1.85, days: [
            .init(day: "2026-10-01", amount: 0.42, station: 0.42, source: .station),
            .init(day: "2026-10-02", amount: 1.43, station: 0.10, source: .remainder),
        ])])
        let share = log.stationShare
        XCTAssertEqual(share?.days, 1)
        XCTAssertEqual(share?.gauge ?? 0, 1.43, accuracy: 0.001)
        XCTAssertEqual(share?.station ?? 0, 0.10, accuracy: 0.001)
        XCTAssertEqual(log.overriddenDays, ["2026-10-02"])
    }

    /// The gauge lays over the record without touching what else the day held,
    /// and fills a day the station never recorded at all.
    func testTheGaugeLaysOverTheDailyRecord() {
        var r = DailyRecord(day: "2026-10-02", sampleCount: 48, expectedSamples: 48)
        r.tempMax = 82
        r.precipTotal = 0
        let out = DailyRecord.applying(gauge: ["2026-10-02": 1.43, "2026-10-03": 0.2], to: [r])
        XCTAssertEqual(out.map(\.day), ["2026-10-02", "2026-10-03"])
        XCTAssertEqual(out[0].precipTotal, 1.43)
        XCTAssertEqual(out[0].tempMax, 82)
        XCTAssertEqual(out[0].precipFromGauge, true)
        XCTAssertEqual(out[1].precipTotal, 0.2)
    }
}
