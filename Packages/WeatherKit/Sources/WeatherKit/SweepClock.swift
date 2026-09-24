//
//  SweepClock.swift  (WeatherKit)
//
//  Sweep mode's clock: a line turning round the radar at a fixed, calm pace,
//  sweeping each new scan in as it passes.
//
//  WHY A SEPARATE MODE FROM THE LOOP. The loop shows DIRECTION — ten scans in
//  quick order and your eye reads the motion. Sweep mode shows how the picture
//  is MADE: a beam going round, returns appearing as it passes, one direction at
//  a time. They answer different questions, so neither is a setting on the other.
//
//  FIXED AND CALM, NOT THE RADAR'S OWN PACE. A real 0.5° sweep takes about
//  12 seconds in rain and over a minute in clear air. Played at that pace the
//  line would crawl on a quiet day and nothing would seem to happen; so it turns
//  at one steady speed, and the readout states the real sweep time instead.
//
//  BUT THE ORDER IS REAL. Each scan began wherever the previous tilt left the
//  dish, not at north, so the line starts there and the returns come in, around
//  the circle, in the order the radar collected them.
//
//  THE LINE ONLY TURNS WHEN IT HAS SOMETHING TO SHOW. It used to turn
//  continuously, sweeping each new scan in as it passed that scan's start — but
//  new scans come every four to ten minutes, so almost every turn went round
//  over a picture that did not change. Watching that, the natural reading is
//  "the radar is scanning and nothing is different", which is false: nothing
//  was being scanned. Now a turn means a new scan, and between scans the line
//  is gone.
//

import Foundation

public struct SweepClock: Equatable, Sendable {
    /// One scan the clock can sweep in.
    public struct Scan: Equatable, Sendable {
        public let stamp: String
        /// Where the dish was pointing at the first radial, degrees from north.
        public let startAzimuth: Double
        public init(stamp: String, startAzimuth: Double) {
            self.stamp = stamp; self.startAzimuth = startAzimuth
        }
    }

    /// A scan partway in: where it began, and how far round the line has taken it.
    public struct Reveal: Equatable, Sendable {
        public let scan: Scan
        /// Degrees turned since the line crossed `scan.startAzimuth`, 0...360.
        public var turned: Double
    }

    /// Seconds per full turn.
    public static let secondsPerTurn = 14.0

    /// The scan fully drawn. Nil before the first one lands.
    public private(set) var shown: String?
    /// The scan being swept in, if one is. Nil means the line is parked.
    public private(set) var revealing: Reveal?

    /// Where the line points while it is turning, degrees from north.
    public var azimuth: Double? {
        revealing.map { ($0.scan.startAzimuth + $0.turned).truncatingRemainder(dividingBy: 360) }
    }

    public init(shown: String? = nil) {
        self.shown = shown
    }

    /// Move the line on by `delta` seconds. `next` is the scan waiting to be
    /// swept in, if any — the caller decides which one that is. A waiting scan
    /// starts at once, from its own first radial.
    public mutating func advance(by delta: Double, next: Scan?) {
        guard delta > 0 else { return }
        // Capped like the loop clock: a long gap (sleep, a hidden window) is
        // not time the line should spend turning a dozen times at once.
        let step = 360 * min(delta, 0.25) / Self.secondsPerTurn

        if var reveal = revealing {
            reveal.turned += step
            if reveal.turned >= 360 {
                shown = reveal.scan.stamp
                revealing = nil
            } else {
                revealing = reveal
            }
        } else if let next, next.stamp != shown {
            revealing = Reveal(scan: next, turned: 0)
        }
    }

    /// Show a scan outright, with no sweep — what entering the mode does with
    /// the scan already on screen.
    public mutating func show(_ stamp: String?) {
        shown = stamp
        revealing = nil
    }

    /// WHICH SCAN GOES NEXT, given the loop's scans oldest first. The one after
    /// the scan on screen — so if three arrived while the window was hidden,
    /// each still gets its turn, in order. If what is on screen has rotated out
    /// of the list, jump to the newest rather than replaying history.
    public static func next(after shown: String?, in stamps: [String]) -> String? {
        guard let newest = stamps.last else { return nil }
        guard let shown, let i = stamps.firstIndex(of: shown) else { return newest }
        return i + 1 < stamps.count ? stamps[i + 1] : nil
    }
}
