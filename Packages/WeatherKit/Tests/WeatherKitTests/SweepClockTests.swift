import XCTest
@testable import WeatherKit

final class SweepClockTests: XCTestCase {
    private let tick = 1.0 / 60

    private func run(_ clock: inout SweepClock, seconds: Double, next: SweepClock.Scan?) {
        var t = 0.0
        while t < seconds { clock.advance(by: tick, next: next); t += tick }
    }

    func testTheLineIsParkedWithNothingNew() {
        var clock = SweepClock(shown: "A")
        run(&clock, seconds: 30, next: nil)
        XCTAssertNil(clock.azimuth, "no new scan, no turning")
        XCTAssertNil(clock.revealing)
    }

    func testANewScanStartsAtOnceFromItsOwnFirstRadial() {
        var clock = SweepClock(shown: "A")
        let b = SweepClock.Scan(stamp: "B", startAzimuth: 213)
        clock.advance(by: tick, next: b)
        XCTAssertEqual(clock.revealing?.scan, b)
        XCTAssertEqual(clock.azimuth ?? -1, 213, accuracy: 0.01)
        run(&clock, seconds: SweepClock.secondsPerTurn / 4, next: b)
        XCTAssertEqual(clock.azimuth ?? -1, 303, accuracy: 1, "a steady quarter turn on from the start")
    }

    func testOneTurnSweepsTheScanInAndParks() {
        var clock = SweepClock(shown: "A")
        let b = SweepClock.Scan(stamp: "B", startAzimuth: 90)
        run(&clock, seconds: SweepClock.secondsPerTurn + 0.2, next: b)
        XCTAssertEqual(clock.shown, "B")
        run(&clock, seconds: 5, next: b)
        XCTAssertNil(clock.azimuth, "B is on screen; nothing more to sweep")
    }

    func testTurnsWrapPastNorth() {
        var clock = SweepClock(shown: "A")
        run(&clock, seconds: SweepClock.secondsPerTurn / 2, next: .init(stamp: "B", startAzimuth: 300))
        XCTAssertEqual(clock.azimuth ?? -1, 120, accuracy: 1)
    }

    func testTheShownScanIsNeverSweptOverItself() {
        var clock = SweepClock(shown: "A")
        run(&clock, seconds: 5, next: .init(stamp: "A", startAzimuth: 10))
        XCTAssertNil(clock.revealing)
    }

    func testAGapDoesNotSpinTheLine() {
        var clock = SweepClock(shown: "A")
        clock.advance(by: 1.0 / 60, next: .init(stamp: "B", startAzimuth: 0))
        clock.advance(by: 30, next: nil)
        XCTAssertLessThan(clock.revealing?.turned ?? 999, 10)
    }

    func testNextWalksForwardOneScanAtATime() {
        let stamps = ["A", "B", "C", "D"]
        XCTAssertEqual(SweepClock.next(after: "B", in: stamps), "C")
        XCTAssertNil(SweepClock.next(after: "D", in: stamps), "nothing newer: the line stays parked")
        XCTAssertEqual(SweepClock.next(after: "gone", in: stamps), "D", "rotated out: go to the newest")
        XCTAssertEqual(SweepClock.next(after: nil, in: stamps), "D")
    }
}
