//
//  RhythmQuestions.swift  (WeatherKit)
//
//  THE PAGE AS A LIST OF ANSWERED QUESTIONS, rather than as a chart you are left
//  to interrogate.
//
//  WHAT WENT WRONG THAT THIS FIXES. `YearRhythm` put four measures on one date
//  axis because they shared one — and a shared axis is a drawing convenience,
//  not a reason to fuse four answers into one picture. The chart was true, dense
//  and silent: it showed a FIELD and left the reader to find the finding in it.
//  The reaction it earned was the right one — "what is this actually telling
//  me". A reader standing in a hot September wants one sentence, and the chart
//  made them read twelve pills to assemble it.
//
//  So each question gets its own answer and its own small picture, and the
//  question is printed as the heading. One story per card.
//
//  IT IS NOT EXPLORE, and the difference is the RETURN TYPE. Explore takes
//  conditions and hands back a set of days — "which days were over 100°" — for
//  someone with a hypothesis, digging. These take no input and hand back a
//  POSITION ON THE CALENDAR — a date, a window, a month. Different question,
//  different reader: one has a theory, the other has just moved in.
//
//  THE PARAMETERS ARE PART OF THE ANSWER. "Fall starts October 12" is unusable
//  without knowing what this app thinks fall is, and burying that in a tooltip
//  is how a number gets trusted more than it deserves. Every question carries
//  the sentence that defines its own threshold, printed under the answer.
//
//  ONE THRESHOLD PER QUESTION. The year chart drew three per row — 85, 90, 95 —
//  which is three answers to a question that was only asked once. The canonical
//  one becomes the answer; the other two become a supporting line, which is
//  where an "and also" belongs.
//

import Foundation

/// One question this page answers, with everything needed to say it out loud.
public struct RhythmQuestion: Identifiable, Equatable, Sendable {
    /// The heading, phrased as the reader would ask it.
    public var question: String
    /// What the app means by the words in the question. Printed, never hidden —
    /// see the file header.
    public var basis: String
    public var measure: SeasonTrack.Measure
    public var direction: YearMilestone.Direction
    public var symbol: String

    /// The answer: typical date, and the window the record has seen it in.
    public var answer: YearMilestone
    /// The same crossing at the other thresholds, in calendar order. A
    /// supporting line, never a second answer.
    public var alternates: [YearMilestone]

    /// This measure's normal for every day of the year, so the card can draw the
    /// one strip its answer sits on. Shared with the year chart's rows.
    public var curve: [Double?]
    public var rampWarm: Double
    public var rampCold: Double

    public var id: String { "\(measure.rawValue)·\(direction.rawValue)" }

    /// Where the answer sits relative to a day, signed. Negative once this
    /// year's occurrence is behind us.
    public func daysFromToday(_ today: String) -> Int? {
        guard let now = YearAxis.day(of: DayKey.monthDay(of: today)) else { return nil }
        return answer.dayOfYear - now
    }

    public func intensity(_ value: Double) -> Double {
        let span = rampWarm - rampCold
        guard abs(span) > 0.001 else { return 1 }
        return min(1, max(0, (value - rampCold) / span))
    }
}

/// The catalogue: which crossings are worth asking about, in what words.
///
/// A table rather than a `switch` scattered through the views, because the
/// wording IS the feature here and it should be readable in one place — and
/// because the order of this array is the order of the page.
///
/// PUBLIC SO THE PAGE CAN HOLD A PLACE FOR EVERY QUESTION, answered or not. A
/// question the record can't answer yet — or one still being worked out — used
/// to be simply absent, and an absence is invisible: nobody can tell a page of
/// five questions from a page of seven that lost two.
public struct RhythmQuestionKind: Identifiable, Sendable {
    public var measure: SeasonTrack.Measure
    public var direction: YearMilestone.Direction
    /// The threshold that gets to be the answer. The others support it.
    public var threshold: Double
    public var question: String
    public var basis: String
    public var symbol: String

    /// The same identity as the `RhythmQuestion` it answers to.
    public var id: String { "\(measure.rawValue)·\(direction.rawValue)" }

    /// Ordered as the page reads. Heat first, and its ENDING before its
    /// beginning, because "when does it stop" is the question this page was
    /// asked for — standing in a hot September wanting to know when it lets go.
    public static let catalogue: [RhythmQuestionKind] = [
        .init(measure: .afternoons, direction: .easing, threshold: 90,
              question: "When does it stop being hot?",
              basis: "Hot means a week of afternoons averaging 90° or more. This is the date that week-long average finally drops below it.",
              symbol: "sun.max.fill"),
        .init(measure: .nights, direction: .easing, threshold: 65,
              question: "When does fall actually start?",
              basis: "Not the equinox — the date the overnight low settles below 65° and stays there. Nights let go of summer weeks before afternoons do.",
              symbol: "moon.stars.fill"),
        .init(measure: .humidity, direction: .easing, threshold: 65,
              question: "When does the air dry out?",
              basis: "The date the daily mean dew point falls below 65°, which is roughly where air stops feeling sticky.",
              symbol: "humidity.fill"),
        .init(measure: .freeze, direction: .easing, threshold: 32,
              question: "When does the first freeze come?",
              basis: "The first night the low touches 32° — the one that ends tomatoes and basil.",
              symbol: "snowflake"),
        .init(measure: .freeze, direction: .arriving, threshold: 32,
              question: "When is the last freeze of spring?",
              basis: "The last night the low touches 32°. After it, tender things can go in the ground.",
              symbol: "leaf.fill"),
        .init(measure: .nights, direction: .arriving, threshold: 65,
              question: "When do the warm nights come back?",
              basis: "The date the overnight low climbs above 65° and stays — spring's mirror of the night fall starts.",
              symbol: "moon.stars.fill"),
        .init(measure: .afternoons, direction: .arriving, threshold: 90,
              question: "When does it start being hot again?",
              basis: "The date a week of afternoons first averages 90° or more.",
              symbol: "sun.max.fill"),
    ]
}

extension Climatology {

    /// Every question this station can answer, in page order.
    ///
    /// Built from `yearRhythm()` rather than recomputing: the crossings, their
    /// windows and the normal curves are the same numbers, and computing them
    /// twice would be two seconds of archive scanning for one page.
    ///
    /// A question whose crossing this record can't support is simply absent. A
    /// station that has never seen 32° has no first-freeze date, and inventing
    /// one is worse than the page being shorter.
    public func rhythmQuestions(window: Int = 7) -> [RhythmQuestion] {
        let tracks = yearRhythm(window: window)
        return RhythmQuestionKind.catalogue.compactMap { kind in
            guard let track = tracks.first(where: { $0.measure == kind.measure }) else { return nil }
            let matching = track.milestones.filter { $0.direction == kind.direction }
            guard let answer = matching.first(where: { $0.threshold == kind.threshold }) else { return nil }
            return RhythmQuestion(
                question: kind.question, basis: kind.basis,
                measure: kind.measure, direction: kind.direction, symbol: kind.symbol,
                answer: answer,
                alternates: matching.filter { $0.threshold != kind.threshold }
                    .sorted { $0.dayOfYear < $1.dayOfYear },
                curve: track.normal, rampWarm: track.rampWarm, rampCold: track.rampCold)
        }
    }
}

// MARK: - What this year is doing about it

extension RhythmQuestion {

    /// How this particular year is answering the question, if it has anything to
    /// say — the one line the climatology can't supply.
    ///
    /// Read out of `seasonalTracks`, which is the instrument that already knows
    /// how to tell a crossing that is LATE from one that has simply happened,
    /// and which lets the ten-day forecast overrule the normals where it reaches.
    /// Only the direction the season is currently travelling has a counterpart
    /// there, so half these questions return nothing half the year — correctly.
    /// "When is the last freeze of spring" has no news in October.
    public func thisYear(_ tracks: [SeasonTrack]) -> String? {
        guard let track = tracks.first(where: { $0.measure == measure }),
              track.cooling == (direction == .easing) else { return nil }
        let live = track.milestones.first { $0.threshold == answer.threshold }

        if let live, live.isOverdue { return Self.overdue(live, naming: nil) }

        // A DIFFERENT THRESHOLD ON THE SAME MEASURE RUNNING LATE IS STILL NEWS
        // ABOUT THIS QUESTION, and this card is the only place it can land.
        // Standing in this September the record says the 70° night crossing is
        // seventeen days overdue while the 65° one — the answer printed above —
        // is three days out and perfectly ordinary. Reporting only the canonical
        // threshold would leave the page silent about the single most unusual
        // thing the archive currently knows. The threshold gets named, because a
        // note about 70° under an answer about 65° must not read as one about
        // the answer.
        if let late = track.milestones.filter(\.isOverdue)
            .min(by: { ($0.normalDaysFromNow ?? 0) < ($1.normalDaysFromNow ?? 0) }) {
            return Self.overdue(late, naming: late.threshold)
        }

        guard let live else { return nil }
        switch live.basis {
        case .forecast:
            return "The forecast crosses it \(WeatherAlmanac.dateLabel(live.monthDay)) — \(live.daysFromNow) \(live.daysFromNow == 1 ? "day" : "days") away."
        case .notBefore:
            // A floor, not a date. It must not be printed as one.
            return "The forecast stays on the far side of it for its whole window, so not before \(WeatherAlmanac.dateLabel(live.monthDay))."
        case .normal:
            guard live.daysFromNow <= 45 else { return nil }
            return "About \(live.daysFromNow) \(live.daysFromNow == 1 ? "day" : "days") away."
        }
    }

    /// A late crossing, optionally naming which threshold is late.
    private static func overdue(_ milestone: SeasonMilestone, naming threshold: Double?) -> String {
        let behind = -(milestone.normalDaysFromNow ?? 0)
        let subject = threshold.map { "The \(Int($0))° crossing is running late" } ?? "Running late"
        let opening = "\(subject): \(behind) \(behind == 1 ? "day" : "days") past its usual date and still not crossed"
        switch milestone.basis {
        case .forecast:
            return opening + ". The forecast reaches it \(WeatherAlmanac.dateLabel(milestone.monthDay))."
        default:
            return opening + ", and the forecast doesn't reach it either."
        }
    }
}
