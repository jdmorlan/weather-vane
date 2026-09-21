//
//  RadarPrefetchOrderTests.swift
//
//  WHICH FRAME IS FETCHED FIRST, which is not a detail. A loop is two hundred
//  tile requests and ten run at a time, so position in the prefetch list is very
//  nearly arrival time — and getting this backwards meant the one frame on screen
//  was the last one to arrive, eight seconds after the map opened.
//

import XCTest
@testable import WeatherKit

@MainActor
final class RadarPrefetchOrderTests: XCTestCase {

    private func model(_ count: Int) -> RadarModel {
        let model = RadarModel()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        model.setFramesForTesting((0..<count).map {
            RadarFrame(time: base.addingTimeInterval(Double($0) * Radar.scanInterval))
        })
        return model
    }

    /// The timeline reads oldest to newest, and must keep doing so — the scrub
    /// strip's leftmost tick is the oldest scan.
    func testStampsStayOldestFirstForTheTimeline() {
        let m = model(5)
        XCTAssertEqual(m.stamps, m.frames.map(\.stamp))
        XCTAssertEqual(m.stamps.first, m.frames.first?.stamp)
        XCTAssertEqual(m.stamps.last, m.frames.last?.stamp)
    }

    /// THE FIX. A freshly loaded loop sits on the newest scan, so that is the
    /// frame the prefetch must ask for first.
    func testPrefetchStartsWithTheFrameOnScreen() {
        let m = model(10)
        XCTAssertEqual(m.index, 9, "a fresh loop holds the newest scan")
        XCTAssertEqual(m.stampsByUrgency.first, m.frames[9].stamp,
                       "the frame being drawn must be fetched first")
    }

    /// After the frame on screen, the order is the order the animation walks —
    /// so each frame arrives before the dissolve reaches it.
    func testPrefetchThenFollowsPlayOrder() {
        let m = model(10)
        let expected = [9, 0, 1, 2, 3, 4, 5, 6, 7, 8].map { m.frames[$0].stamp }
        XCTAssertEqual(m.stampsByUrgency, expected)
    }

    /// Scrubbing back to look at something makes THAT the frame worth having.
    func testPrefetchFollowsAScrub() {
        let m = model(10)
        m.scrub(to: 3)
        XCTAssertEqual(m.stampsByUrgency.first, m.frames[3].stamp)
        XCTAssertEqual(m.stampsByUrgency.count, 10, "still the whole loop, just reordered")
    }

    /// Every frame exactly once, however it is rotated — a prefetch that dropped
    /// or duplicated one would leave a permanent hole in the loop.
    func testEveryFrameAppearsExactlyOnce() {
        let m = model(10)
        m.scrub(to: 6)
        XCTAssertEqual(Set(m.stampsByUrgency), Set(m.stamps))
        XCTAssertEqual(m.stampsByUrgency.count, m.stamps.count)
    }

    func testEmptyLoopAsksForNothing() {
        XCTAssertTrue(model(0).stampsByUrgency.isEmpty)
    }
}
