//
//  FieldLoopClock.swift  (WeatherKit)
//
//  WHERE THE LOOP IS, as a continuous position rather than an index.
//
//  THE WHOLE BUG, STATED ONCE. The old loop was an `Int` advanced on a timer, and
//  an `Int` cannot express the state a smooth animation spends most of its time
//  in: PART WAY BETWEEN TWO FRAMES. Every advance was therefore a cut — one scan
//  replaced by another in a single display refresh — and ten cuts a loop at two a
//  second is not an animation, it is a strobe. No amount of tuning the hold fixes
//  that, because the hold was never the problem; the discontinuity was.
//
//  So the clock reports a frame, the NEXT frame, and how far between them the
//  loop currently is. A renderer that can draw two frames at two weights turns
//  that into a dissolve.
//
//  WHY THE FADE IS SHORTER THAN THE HOLD. Crossfading across the entire hold
//  means no frame is ever shown cleanly — the picture is a permanent double
//  exposure and a storm's edge never looks sharp. Real radar loops hold a frame
//  crisp and then dissolve quickly. `fadeDuration` is that dissolve, and it stays
//  CONSTANT rather than scaling with the hold, so the long beat on the newest
//  scan is a longer look at it and not a longer smear.
//
//  Pure value type on purpose: the timing is the part worth checking without a
//  map, a network, or a display attached.
//

import Foundation

public struct FieldLoopClock: Equatable, Sendable {

    /// How many frames the loop walks.
    public var frameCount: Int

    /// How long an ordinary frame is on screen, dissolve included.
    public var frameHold: Double

    /// The EXTRA beat on the newest scan — the one you actually came to read, and
    /// the one that used to flash past at the same speed as fifty-minute-old
    /// weather.
    public var endHold: Double

    /// WHICH frame gets that extra beat. Negative means the last one.
    ///
    /// IT IS NOT THE LAST FRAME ANY MORE, and that is the whole reason this is a
    /// property. Once the loop runs past NOW into a forecast, the last frame is an
    /// hour of extrapolation — the least certain thing on the strip — and holding
    /// there would give the longest look to the weakest claim. The beat belongs on
    /// the newest OBSERVATION: the seam is where the loop pauses, which is also
    /// the moment that reads as "and here is where we actually are".
    public var holdIndex: Int = -1

    /// How long the dissolve between two frames takes. Constant, not a fraction
    /// of the hold; see the note above.
    public var fadeDuration: Double

    /// Index of the frame currently being drawn.
    public private(set) var index: Int = 0

    /// Seconds spent on `index` so far.
    public private(set) var elapsed: Double = 0

    /// A whole lap, near enough, whatever the loop is made of.
    ///
    /// THE LOOP GOT TWICE AS LONG WHEN IT GREW A FUTURE, and a fixed per-frame
    /// hold turned a brisk five-second lap into a ten-second one — the same
    /// weather, watched at half speed. A lap is a unit of attention rather than a
    /// count of frames, so the hold is derived from it and clamped at both ends:
    /// long enough that a short loop is not a flicker, short enough that a long
    /// one does not drag.
    public static func hold(forFrames count: Int, lap: Double = 5.0) -> Double {
        guard count > 1 else { return 0.42 }
        return max(0.16, min(0.42, lap / Double(count)))
    }

    public init(frameCount: Int = 0,
                frameHold: Double = 0.42,
                endHold: Double = 1.15,
                fadeDuration: Double = 0.26) {
        self.frameCount = frameCount
        self.frameHold = frameHold
        self.endHold = endHold
        self.fadeDuration = fadeDuration
    }

    /// The frame the loop pauses on, resolved.
    public var heldFrame: Int {
        guard frameCount > 0 else { return 0 }
        guard holdIndex >= 0, holdIndex < frameCount else { return frameCount - 1 }
        return holdIndex
    }

    /// How long frame `i` holds. Only the held one differs.
    public func duration(of i: Int) -> Double {
        (frameCount > 0 && i == heldFrame) ? frameHold + endHold : frameHold
    }

    /// The frame dissolving IN. Wraps, so the end of the loop dissolves back to
    /// the oldest scan rather than cutting — a reset you can see happening beats
    /// a reset that looks like a dropped frame.
    public var nextIndex: Int {
        guard frameCount > 0 else { return 0 }
        return (index + 1) % frameCount
    }

    /// 0 while `index` is crisp, rising to 1 as `nextIndex` takes over.
    ///
    /// Smoothstepped rather than linear: a linear crossfade reads as a visible
    /// start and stop at each end, because the eye notices the corner in the
    /// brightness curve. Easing both ends is what makes it read as flowing.
    public var blend: Double {
        guard frameCount > 1, fadeDuration > 0 else { return 0 }
        let start = max(0, duration(of: index) - fadeDuration)
        guard elapsed > start else { return 0 }
        let t = min(1, (elapsed - start) / min(fadeDuration, duration(of: index)))
        return t * t * (3 - 2 * t)
    }

    /// True while the picture is actually changing. The renderer repaints only
    /// when this is true, so a frame's crisp hold costs nothing at all — which is
    /// what makes a sixty-hertz dissolve affordable in the first place.
    public var isDissolving: Bool { blend > 0 }

    /// Move the clock on. `delta` is seconds since the last tick.
    ///
    /// Walks frame by frame rather than dividing, because the last frame's hold
    /// is longer than the others and a single modulo would put the loop in the
    /// wrong place whenever a tick is late — which on a display link is exactly
    /// when the app was busy, i.e. constantly.
    public mutating func advance(by delta: Double) {
        guard frameCount > 1, delta > 0 else {
            if frameCount <= 1 { index = 0; elapsed = 0 }
            return
        }
        // A LATE TICK IS NOT A REASON TO RACE. Coming back from a sleep or a
        // stalled main thread hands us a delta of minutes; without this the loop
        // spins through hundreds of frames to "catch up" on weather nobody was
        // watching. Capped at one frame's worth, a missed beat just resumes.
        //
        // Against THIS frame's duration, not `frameHold`. Capping at the ordinary
        // hold meant the last frame — which holds for `frameHold + endHold` —
        // could never be advanced off by a single tick however large, so a loop
        // that reached the newest scan stuck there permanently.
        elapsed += min(delta, duration(of: index))

        var steps = 0
        while elapsed >= duration(of: index), steps < frameCount * 2 {
            elapsed -= duration(of: index)
            index = (index + 1) % frameCount
            steps += 1
        }
    }

    /// Jump to a frame and show it cleanly — what scrubbing does.
    public mutating func jump(to newIndex: Int) {
        guard frameCount > 0 else { return }
        index = max(0, min(frameCount - 1, newIndex))
        elapsed = 0
    }

    /// Re-point the clock at a loop that has changed length.
    ///
    /// HOLDING THE NEWEST FRAME ACROSS A RELOAD IS THE POINT. A composite lands
    /// every five minutes and the loop gains a frame; snapping back to the start
    /// would yank the picture out from under someone watching a storm approach.
    /// So a viewer already at the end stays at the new end.
    /// THE NEW SEAM COMES IN WITH THE NEW LENGTH, and the two cannot be separated.
    /// Setting `holdIndex` after the resize meant the resize asked "were you at
    /// the seam?" and answered "then stay at" — using the OLD seam for both. Every
    /// five minutes the loop gained a scan, the seam moved one frame right, and
    /// the playhead was put back one frame LEFT of it: a viewer watching now
    /// drifted quietly into the past, one scan per reload.
    public mutating func resize(to newCount: Int, keepingEnd: Bool, holdIndex newHold: Int? = nil) {
        // Asked of the loop being left — that is the seam they were sitting on.
        let wasAtEnd = keepingEnd && index >= heldFrame
        frameCount = max(0, newCount)
        if let newHold { holdIndex = newHold }
        guard frameCount > 0 else { index = 0; elapsed = 0; return }
        if wasAtEnd || index >= frameCount {
            // THE HELD FRAME, NOT THE LAST ONE. With a forecast on the end of the
            // loop, landing on "the last frame" after a reload would drop the
            // viewer an hour into extrapolation every five minutes. Where they
            // were is NOW, and now is the seam.
            index = heldFrame
            elapsed = 0
        }
    }
}
