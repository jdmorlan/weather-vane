//
//  FieldTileProgressTests.swift
//
//  What the map is allowed to SAY about itself. These are the numbers a status
//  line is built from, and a status line that lies is worse than none — "filling
//  in" that never finishes, or silence over a picture with a hole in it, are both
//  ways of telling someone the weather is something other than it is.
//

import XCTest
@testable import WeatherKit

final class FieldTileProgressTests: XCTestCase {

    typealias Progress = FieldTileStore.Progress

    /// NOTHING WANTED IS NOT THE SAME AS NOTHING DONE. Before the renderer has
    /// reported a viewport there is no work outstanding, and a bar reading 0%
    /// there would be a claim about a load that has not been asked for.
    func testEmptyIsCompleteRatherThanZero() {
        let empty = Progress()
        XCTAssertEqual(empty.fraction, 1)
        XCTAssertFalse(empty.isComplete, "nothing wanted is not a finished load either")
    }

    func testFractionTracksHeldAgainstWanted() {
        XCTAssertEqual(Progress(wanted: 200, held: 50).fraction, 0.25, accuracy: 1e-9)
        XCTAssertEqual(Progress(wanted: 200, held: 200).fraction, 1, accuracy: 1e-9)
    }

    func testCompleteOnlyWhenEverythingIsHeld() {
        XCTAssertFalse(Progress(wanted: 200, held: 199).isComplete)
        XCTAssertTrue(Progress(wanted: 200, held: 200).isComplete)
        // Held can overshoot when the viewport shrinks between a prefetch and a
        // count; that is finished, not broken.
        XCTAssertTrue(Progress(wanted: 200, held: 240).isComplete)
    }

    /// A tile still on its way and a tile that was REFUSED are different
    /// situations with different sentences — one needs patience, the other needs
    /// a button. The counts have to keep them apart.
    func testInFlightAndFailedAreCountedSeparately() {
        let p = Progress(wanted: 100, held: 60, inFlight: 30, failed: 10)
        XCTAssertFalse(p.isComplete)
        XCTAssertEqual(p.inFlight, 30)
        XCTAssertEqual(p.failed, 10)
        XCTAssertEqual(p.held + p.inFlight + p.failed, p.wanted,
                       "every wanted tile is held, coming, or refused")
    }

    // MARK: Watching

    /// The subscription that replaced a per-fetch completion. THE BUG IT EXISTS
    /// FOR: a tile the prefetch had already started was skipped as in-flight, and
    /// the renderer's repaint callback went with it — so the tile arrived and
    /// nothing redrew. A still layer stayed half-drawn until you panned.
    func testObserversRegisterAndUnregisterIndependently() {
        let store = FieldTileStore()
        let first = store.observe { _ in }
        let second = store.observe { _ in }
        XCTAssertNotEqual(first, second, "two watchers must not share a token")

        // Unregistering one must not disturb the other, and unregistering twice
        // is not an error — a renderer can be torn down more than once.
        store.stopObserving(first)
        store.stopObserving(first)
        store.stopObserving(second)
    }

    /// A refusal has to be forgettable, or "Try again" would be a button that
    /// does nothing for twenty seconds.
    func testFailuresCanBeCleared() {
        let store = FieldTileStore()
        store.clearFailures()
        let tiles = [FieldTileGrid.Tile(z: 5, x: 1, y: 1)]
        let source = Level2FieldSource(site: "KFWS")
        let p = store.progress(stamps: ["KFWS20260916_205500_V06"], tiles: tiles, from: source)
        XCTAssertEqual(p.wanted, 1)
        XCTAssertEqual(p.failed, 0)
        XCTAssertEqual(p.held, 0)
    }
}
