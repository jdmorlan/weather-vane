//
//  YearRhythm.swift  (WeatherKit)
//
//  The whole year on one axis — the PLACE, not this September.
//
//  WHAT THIS IS FOR, AND WHY IT ISN'T `SeasonTimeline`. That file answers "what
//  is about to happen": it picks a direction from today's date, generates only
//  the crossings pointing that way, drops everything past a horizon, and lets
//  the forecast overrule the archive where it reaches. Every one of those is the
//  right call for a countdown, and each of them makes the answer a fact about
//  THIS year. Stand in February and the same page can't tell you when the first
//  freeze lands, because the first freeze is nine months out and pointing the
//  wrong way.
//
//  "When things usually happen here" is not a countdown. It is the same answer
//  in February and September, it runs in both directions, and it is a property
//  of the station rather than of the date — so it takes no `asOf` at all. Today
//  is a MARK the view draws on it, not an input that shapes it.
//
//  THE AXIS IS JANUARY TO DECEMBER, and the reason is the growing season. A
//  midsummer-anchored axis keeps winter contiguous and splits the frost-free
//  season across both ends; a January-anchored one does the reverse. The
//  headline fact on this page is "frost-free season runs 235 days here", and a
//  span you can see drawn between two marks beats a span you have to reassemble
//  from opposite edges of a chart. Winter pays for it, and winter's crossings
//  (the last freeze, the first) are the two ends of that same span anyway.
//
//  THE AXIS ITSELF is `YearAxis`, which the period brush already had and which
//  moved down into the package for this — 366 slots, so February 29 is a day
//  like any other rather than something folded onto the 28th.
//
//  THE SPREAD IS DRAWN, NOT DESCRIBED. On a 75-day axis a first-freeze window of
//  "Oct 28 to Nov 21" is most of the chart and can only be written down; across
//  a year it is three weeks of width and can simply be a band. That matters more
//  than it sounds: this whole area of the app is built on refusing to print a
//  single date for something the record only knows as a window, and until now
//  the window survived only in hover text. Here it is the shape you see first.
//

import Foundation

/// One crossing, as a date the year usually reaches it — plus the window the
/// record has actually seen it inside.
public struct YearMilestone: Equatable, Sendable, Identifiable {
    /// Which way the season is travelling through the line.
    ///
    /// Not derivable from the threshold: 70° nights are crossed twice a year,
    /// and "the night it last drops to 32°" and "the night it first drops to
    /// 32°" are the two ends of the growing season, not one fact stated twice.
    public enum Direction: String, Equatable, Sendable {
        /// Spring — the warm season arriving through this line.
        case arriving
        /// Autumn — the warm season letting go of it.
        case easing
    }

    public var threshold: Double
    public var direction: Direction
    /// `MM-dd` of the median occurrence.
    public var monthDay: String
    /// Its slot on the axis.
    public var dayOfYear: Int
    /// The earliest and latest the record has seen it, as axis slots. `nil` when
    /// the record has only ever seen it once, which is a date and not a window.
    public var earliest: Int?
    public var latest: Int?
    public var earliestMonthDay: String?
    public var latestMonthDay: String?
    public var yearsObserved: Int

    /// What the pill carries. The measure is the row and the date is the
    /// position, so the threshold is all that's left to print.
    public var short: String { "\(Int(threshold))°" }

    public var id: String { "\(direction.rawValue)·\(Int(threshold))" }

    /// How much the date moves year to year. `nil` under two observations, where
    /// a spread would be the distance between a date and itself.
    public var spreadDays: Int? {
        guard let earliest, let latest, latest >= earliest else { return nil }
        return latest - earliest
    }
}

/// A stretch of the year worth naming in its own right, drawn as a span rather
/// than as two marks the reader has to subtract.
public struct YearSpan: Equatable, Sendable {
    public var from: Int
    public var to: Int
    public var label: String
    public var days: Int { to - from }
}

/// One measure's year: its normal shape, and every line it crosses on the way.
public struct YearTrack: Equatable, Sendable, Identifiable {
    public var name: String
    public var measure: SeasonTrack.Measure
    public var symbol: String
    /// In calendar order across the year, both directions together.
    public var milestones: [YearMilestone]

    /// The normal for every day of the year — one per `YearAxis` slot,
    /// Jan 1 first. `nil`
    /// where the record can't answer, so an unwatched stretch draws as a gap
    /// and never as weather. Same rule as the near-term strip.
    public var normal: [Double?] = []

    /// A named stretch between two of this track's own milestones. Only the
    /// freeze row has one — the frost-free season.
    public var span: YearSpan?

    /// The ends of the colour ramp. Unlike `SeasonTrack`, these are fixed to
    /// warm and cold rather than to a direction of travel: a year axis contains
    /// both directions at once, so "the end the season starts from" isn't a
    /// thing the row can have.
    public var rampWarm: Double = 0
    public var rampCold: Double = 0

    public var id: String { name }

    /// 1 = the warm end of this row's year, 0 = the cold end.
    public func intensity(_ value: Double) -> Double {
        let span = rampWarm - rampCold
        guard abs(span) > 0.001 else { return 1 }
        return min(1, max(0, (value - rampCold) / span))
    }

    /// The unit the thresholds are in, for anything that spells them out. Every
    /// row but one is degrees of air temperature; mugginess is a dew point, and
    /// a row labelled in degrees that isn't the temperature has to say so.
    public var unitNote: String { measure == .humidity ? "° dew point" : "°" }
}

extension Climatology {

    /// The year the 366-slot normal is walked through. Any leap year does; this
    /// one is the same reference year the archive's periods already use.
    static let referenceYear = "2000"

    /// Every threshold this station crosses in a normal year, in both
    /// directions, placed on one calendar axis.
    ///
    /// No `asOf`. That absence is the point — see the file header.
    ///
    /// COST: four measures × three thresholds × two directions, each smoothing
    /// half a year per year of record, plus a year-long normal per surviving row.
    /// That is roughly twice what `seasonalTracks` pays and lands in the same
    /// order — a second or so on a full archive — so it belongs off the main
    /// thread and behind a per-day cache, exactly like its sibling.
    public func yearRhythm(window: Int = 7) -> [YearTrack] {
        let tracks: [YearTrack] = [
            yearTrack(name: "Afternoons", measure: .afternoons, symbol: "sun.max.fill",
                      thresholds: [85, 90, 95], window: window),
            yearTrack(name: "Nights", measure: .nights, symbol: "moon.stars.fill",
                      thresholds: [65, 70, 75], window: window),
            yearTrack(name: "Mugginess", measure: .humidity, symbol: "humidity.fill",
                      thresholds: [60, 65, 70], window: window),
            freezeYearTrack(),
        ]
        // Rows keep a fixed order — warmest measure at the top, the freeze at the
        // bottom — rather than sorting by nearness the way the countdown does.
        // Nearness is a fact about today, and a chart that re-orders itself
        // through the year can't be learned.
        return tracks.filter { !$0.milestones.isEmpty }.map { withNormal($0, window: window) }
    }

    /// Both directions through each threshold, ordered along the calendar.
    private func yearTrack(name: String, measure: SeasonTrack.Measure, symbol: String,
                           thresholds: [Double], window: Int) -> YearTrack {
        let path = SeasonTrack.path(for: measure)

        func crossings(_ direction: YearMilestone.Direction) -> [YearMilestone] {
            // Loosest threshold first in the direction of travel, so the dates
            // that come out should run forward through the season. Spring climbs
            // 85 → 95; autumn falls 95 → 85.
            let ordered = direction == .arriving ? thresholds : thresholds.reversed().map { $0 }
            let found = ordered.compactMap { threshold -> YearMilestone? in
                let summary = direction == .arriving
                    ? springCrossing(name: "", measure: path, risingAbove: threshold, window: window)
                    : fallCrossing(name: "", measure: path, fallingBelow: threshold, window: window)
                return milestone(from: summary, threshold: threshold, direction: direction,
                                 requiringEveryYear: true)
            }
            return Self.monotonic(found)
        }

        return YearTrack(name: name, measure: measure, symbol: symbol,
                         milestones: (crossings(.arriving) + crossings(.easing))
                             .sorted { $0.dayOfYear < $1.dayOfYear })
    }

    /// The two ends of the cold season, and the span between them.
    ///
    /// Each frost level appears twice — the last night of spring that reached it
    /// and the first night of autumn that did — which is the pair the whole
    /// planting calendar is built out of. The near-term chart can only ever show
    /// one of the two, because only one of them is ahead of you.
    private func freezeYearTrack() -> YearTrack {
        var milestones: [YearMilestone] = []
        for level in FrostLevel.allCases {
            // Frost is a single night touching the line, not a week averaging
            // below it — so these come from the frost summaries and not from the
            // smoothed crossings the other rows use.
            if let last = milestone(from: lastSpringFrost(level), threshold: level.rawValue,
                                    direction: .arriving, requiringEveryYear: false) {
                milestones.append(last)
            }
            if let first = milestone(from: firstFallFrost(level), threshold: level.rawValue,
                                     direction: .easing, requiringEveryYear: false) {
                milestones.append(first)
            }
        }
        milestones.sort { $0.dayOfYear < $1.dayOfYear }

        // The frost-free season, drawn rather than stated: from the last spring
        // 32° to the first autumn 32°. It's the one fact on this page a reader
        // is most likely to have come for, and on a year axis it is simply the
        // distance between two marks already on the row.
        var span: YearSpan?
        let opening = milestones.first { $0.direction == .arriving && $0.threshold == FrostLevel.frost.rawValue }
        let closing = milestones.first { $0.direction == .easing && $0.threshold == FrostLevel.frost.rawValue }
        if let opening, let closing, closing.dayOfYear > opening.dayOfYear {
            span = YearSpan(from: opening.dayOfYear, to: closing.dayOfYear, label: "Frost-free")
        }

        return YearTrack(name: "Freeze", measure: .freeze, symbol: "snowflake",
                         milestones: milestones, span: span)
    }

    /// A transition summary as a placeable milestone, or nothing.
    ///
    /// `requiringEveryYear` carries the rule `seasonalTracks` arrived at the hard
    /// way: a crossing only EXISTS in a year that was on the far side to begin
    /// with, so a median taken over just the years that crossed is drawn from a
    /// biased subset and comes out late — which is how "below 75°" once ended up
    /// dated after "below 70°". Frost opts out, because a winter with no 24°
    /// night is a fact about the winter rather than a hole in the sample.
    private func milestone(from summary: TransitionSummary, threshold: Double,
                           direction: YearMilestone.Direction,
                           requiringEveryYear: Bool) -> YearMilestone? {
        guard summary.isMeaningful, let typical = summary.typical,
              let slot = YearAxis.day(of: typical) else { return nil }
        if requiringEveryYear, summary.yearsWithout > 0 { return nil }

        let earliest = summary.earliest.flatMap(YearAxis.day(of:))
        let latest = summary.latest.flatMap(YearAxis.day(of:))
        // A window that wraps the new year can't be drawn as one band on this
        // axis, and a band drawn the short way round would claim the opposite of
        // what the record says. It keeps its date and loses its window.
        let wraps = (earliest.map { $0 > slot } ?? false) || (latest.map { $0 < slot } ?? false)

        return YearMilestone(threshold: threshold, direction: direction,
                             monthDay: typical, dayOfYear: slot,
                             earliest: wraps ? nil : earliest,
                             latest: wraps ? nil : latest,
                             earliestMonthDay: wraps ? nil : summary.earliest,
                             latestMonthDay: wraps ? nil : summary.latest,
                             yearsObserved: summary.yearsObserved)
    }

    /// Dates that run backwards through the season are an artifact of uneven
    /// samples, not a thing that happens. Same belt-and-braces as the countdown,
    /// applied within one direction — across directions the dates are SUPPOSED
    /// to run the other way.
    private static func monotonic(_ milestones: [YearMilestone]) -> [YearMilestone] {
        var kept: [YearMilestone] = []
        for milestone in milestones where milestone.dayOfYear >= (kept.last?.dayOfYear ?? 0) {
            kept.append(milestone)
        }
        return kept
    }

    /// The row's normal for all 365 days, and the ramp it is shaded against.
    ///
    /// Walked through a LEAP year, because the axis has 366 slots and an array
    /// one short of its axis puts every shade after February a day out.
    /// `normalCurve` pools by month-day, so which year the keys claim to be from
    /// never reaches the numbers — only how many of them there are.
    private func withNormal(_ track: YearTrack, window: Int) -> YearTrack {
        var track = track
        track.normal = normalCurve(SeasonTrack.path(for: track.measure),
                                   from: "\(Self.referenceYear)-01-01",
                                   days: YearAxis.dayCount - 1, radius: window)

        // The thresholds set the ends and the curve widens them, so the shading
        // and the pills sitting under it can never disagree about where a line
        // falls — the same contract `SeasonTrack`'s ramp keeps.
        let values = track.normal.compactMap { $0 } + track.milestones.map(\.threshold)
        guard let low = values.min(), let high = values.max() else { return track }
        track.rampWarm = high
        track.rampCold = low
        return track
    }
}
