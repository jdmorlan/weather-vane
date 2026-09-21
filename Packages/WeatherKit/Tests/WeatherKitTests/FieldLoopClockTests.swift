//
//  FieldLoopClockTests.swift
//
//  The timing, checked without a map attached — which is the only way to check it
//  at all. "Does it look smooth" is not a test, and it is what let the old loop's
//  unevenness survive for as long as it did.
//

import XCTest
@testable import WeatherKit

final class FieldLoopClockTests: XCTestCase {

    private func clock(_ count: Int = 10) -> FieldLoopClock {
        FieldLoopClock(frameCount: count, frameHold: 0.4, endHold: 1.0, fadeDuration: 0.2)
    }

    /// A frame is crisp for the part of its hold before the dissolve starts. THIS
    /// IS THE PROPERTY THE OLD LOOP COULD NOT HAVE — it was only ever at blend 0,
    /// which is why every change was a cut.
    func testFrameIsCrispThenDissolves() {
        var c = clock()
        XCTAssertEqual(c.blend, 0, "a fresh frame is fully itself")

        c.advance(by: 0.19)
        XCTAssertEqual(c.blend, 0, accuracy: 1e-9, "still crisp before the fade window")

        c.advance(by: 0.1)     // 0.29 of a 0.4 hold — 0.09 into a 0.2 fade
        XCTAssertGreaterThan(c.blend, 0)
        XCTAssertLessThan(c.blend, 1)
        XCTAssertEqual(c.index, 0, "dissolving out of a frame is still that frame")
        XCTAssertEqual(c.nextIndex, 1)
    }

    /// Smoothstep, so the dissolve eases in and out rather than reading as a
    /// linear ramp with a visible corner at each end.
    func testBlendIsEasedNotLinear() {
        var c = clock()
        c.advance(by: 0.25)               // a quarter into the fade
        let quarter = c.blend
        XCTAssertLessThan(quarter, 0.25, "eased in: slower than linear at the start")

        var d = clock()
        d.advance(by: 0.3)                // halfway through the fade
        XCTAssertEqual(d.blend, 0.5, accuracy: 0.02, "symmetric at the midpoint")
    }

    func testAdvancesOneFrameAtATime() {
        var c = clock()
        c.advance(by: 0.4)
        XCTAssertEqual(c.index, 1)
        c.advance(by: 0.4)
        XCTAssertEqual(c.index, 2)
    }

    /// THE NEWEST SCAN GETS A LONGER LOOK. It is the one you came to read, and it
    /// used to flash past at the same speed as fifty-minute-old weather.
    func testLastFrameHoldsLonger() {
        var c = clock()
        XCTAssertEqual(c.duration(of: 8), 0.4, accuracy: 1e-9)
        XCTAssertEqual(c.duration(of: 9), 1.4, accuracy: 1e-9)

        c.jump(to: 9)
        c.advance(by: 0.4)
        XCTAssertEqual(c.index, 9, "still on the newest a full ordinary hold later")
        c.advance(by: 1.0)
        XCTAssertEqual(c.index, 0, "and round to the oldest once the beat is up")
    }

    /// The long hold must not become a long SMEAR — the dissolve is the same
    /// length wherever it happens.
    func testFadeDurationDoesNotScaleWithTheHold() {
        var c = clock()
        c.jump(to: 9)
        c.advance(by: 1.2)                 // 0.2 left of a 1.4 hold: the fade start
        XCTAssertEqual(c.blend, 0, accuracy: 1e-9)
        c.advance(by: 0.1)
        XCTAssertEqual(c.blend, 0.5, accuracy: 0.02, "halfway through the SAME 0.2 fade")
    }

    /// A LATE TICK IS NOT A REASON TO RACE. Waking from sleep hands the clock a
    /// delta of minutes; racing through the loop to "catch up" animates weather
    /// nobody was watching, at a speed nobody can read.
    func testLateTickDoesNotSpinTheLoop() {
        var c = clock()
        c.advance(by: 600)
        XCTAssertEqual(c.index, 1, "one frame, not fifteen hundred")
    }

    func testWrapsBackToTheOldest() {
        var c = clock(3)
        c.jump(to: 2)
        XCTAssertEqual(c.nextIndex, 0, "the end dissolves back to the beginning")
    }

    /// A single frame has nothing to dissolve into and must sit still rather than
    /// crossfading with itself.
    func testSingleFrameNeverDissolves() {
        var c = clock(1)
        c.advance(by: 5)
        XCTAssertEqual(c.index, 0)
        XCTAssertEqual(c.blend, 0)
        XCTAssertFalse(c.isDissolving)
    }

    func testEmptyLoopIsInert() {
        var c = clock(0)
        c.advance(by: 1)
        XCTAssertEqual(c.index, 0)
        XCTAssertEqual(c.blend, 0)
    }

    // MARK: Reloads

    /// A viewer parked on the newest scan stays on the newest scan when the
    /// five-minute composite lands and the loop gains a frame.
    func testReloadKeepsAViewerAtTheEnd() {
        var c = clock(10)
        c.jump(to: 9)
        c.resize(to: 10, keepingEnd: true)
        XCTAssertEqual(c.index, 9, "still the newest, which is now a different scan")
    }

    /// Someone who scrubbed back to look at something keeps looking at it.
    func testReloadLeavesAScrubbedViewerAlone() {
        var c = clock(10)
        c.jump(to: 3)
        c.resize(to: 10, keepingEnd: true)
        XCTAssertEqual(c.index, 3)
    }

    /// A loop that got shorter must not leave the clock pointing off the end.
    func testShrinkingLoopClampsTheIndex() {
        var c = clock(10)
        c.jump(to: 9)
        c.resize(to: 4, keepingEnd: false)
        XCTAssertEqual(c.index, 3)
    }

    // MARK: The shape of a whole pass

    /// One full pass takes the time it says it does — nine ordinary holds plus
    /// the long one — and every frame is visited exactly once in order.
    func testOnePassVisitsEveryFrameInOrderAndTakesTheStatedTime() {
        var c = clock(10)
        var seen: [Int] = [c.index]
        var time = 0.0
        let tick = 1.0 / 60

        while time < 10 {
            c.advance(by: tick)
            time += tick
            if c.index != seen.last { seen.append(c.index) }
            if seen.count > 1 && c.index == 0 && seen.count > 10 { break }
        }

        XCTAssertEqual(Array(seen.prefix(11)), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0])
        // 9 x 0.4 + 1 x 1.4 = 5.0 seconds a lap.
        XCTAssertEqual(time, 5.0, accuracy: 0.1)
    }
}
