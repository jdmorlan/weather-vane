//
//  SeasonTimeline.swift  (WeatherKit)
//
//  The turning of the season as MILESTONES ON A SHARED CLOCK, rather than as
//  sentences.
//
//  Three curves let go of summer on their own schedule — afternoons, nights,
//  humidity — and what you actually want to know is the ORDER and the GAPS: how
//  many more days of everything being brutal, then how many more of just the
//  afternoons. That's a question about intervals, and a paragraph is a poor
//  instrument for reading intervals. Put the same date axis under all three and
//  the answer is visible without being stated.
//
//  The other rule here is CONTEXT. Every crossing this station knows about is
//  computed, then all but the near ones are dropped: in early August the first
//  freeze is real, ten weeks out, and not worth the space it would take. Nothing
//  is hidden permanently — it arrives as it becomes near.
//

import Foundation

/// What a crossing's date is actually standing on.
///
/// The archive answers "when does this usually happen"; the forecast answers
/// "what is going to happen", and inside its own ten days it is simply the
/// better instrument. The two are not merged into an average — that would blur
/// a fact into a tendency. The forecast REPLACES the normal where it reaches,
/// and the badge says which one you're reading.
public enum SeasonBasis: String, Equatable, Sendable {
    /// Pooled normals from the archive — the usual date.
    case normal
    /// The forecast crosses the threshold on this date.
    case forecast
    /// The forecast rules the crossing OUT through the end of its window, so
    /// this is a floor: it cannot happen before here, and when it does happen is
    /// beyond what anyone can say.
    case notBefore
}

/// One threshold crossing, placed relative to today.
public struct SeasonMilestone: Equatable, Sendable, Identifiable {
    /// "below 70°"
    public var label: String
    public var threshold: Double
    /// Typical `MM-dd` of the crossing.
    public var monthDay: String
    /// Days from today to the next occurrence — what makes it placeable, and
    /// what decides whether it's near enough to show at all.
    public var daysFromNow: Int
    public var earliest: String?
    public var latest: String?
    public var yearsObserved: Int
    /// Which instrument this date came from. See `SeasonBasis`.
    public var basis: SeasonBasis = .normal
    /// The archive's own date, kept when the forecast overrides it — the normal
    /// is the context that makes the override worth reading ("usually Sep 4;
    /// this year, not before the 12th").
    public var normalMonthDay: String?
    /// Where the archive's own date sits relative to today, SIGNED — negative
    /// means the usual date is already behind us.
    ///
    /// `daysFromNow` can't carry this, because it's the date you'd count down
    /// to and a countdown has no room for a number that's already run out. Two
    /// positions are what makes lateness drawable: the ghost where this should
    /// have happened, the notch where it's actually going to, and the distance
    /// between them is the answer.
    public var normalDaysFromNow: Int?

    /// The usual date has passed and this year still hasn't crossed the line.
    ///
    /// This is the state the card used to lose entirely: a crossing whose date
    /// is behind us rolled to next year's occurrence, landed ~350 days out, and
    /// was dropped as distant — so the one row that had something to say ("we're
    /// two weeks late") was the one row that went quiet.
    public var isOverdue: Bool { (normalDaysFromNow ?? 0) < 0 }

    /// How late, in days, once the forecast has said when it will happen.
    /// `nil` while the crossing is on time, or while nothing can date it yet.
    public var lateByDays: Int? {
        guard let normal = normalDaysFromNow, normal < 0, daysFromNow > normal else { return nil }
        return daysFromNow - normal
    }

    public var id: String { "\(label)·\(monthDay)" }

    /// How much the date moves year to year, in days.
    public var spreadDays: Int? {
        guard let earliest, let latest else { return nil }
        return DayKey.distance(from: "2001-\(earliest)", to: "2001-\(latest)")
    }
}

/// One measure's run of crossings — a single line on the timeline.
public struct SeasonTrack: Equatable, Sendable, Identifiable {
    public enum Measure: String, Equatable, Sendable {
        case afternoons, nights, humidity, freeze
    }

    public var name: String
    public var measure: Measure
    public var symbol: String
    /// Ordered by date, nearest first.
    public var milestones: [SeasonMilestone]

    /// One value per day across the whole axis — what the bar is drawn FROM.
    ///
    /// The crossings are only the dates a line gets stepped over; the shape of
    /// the descent between them is the thing you're actually asking about, and
    /// it's the one piece the milestone list can't say. `nil` where the record
    /// can't answer, so an unwatched stretch draws as a gap and not as weather.
    ///
    /// Three instruments in one array, in this order: what this year ACTUALLY
    /// did over the lookback, what the forecast says next, and the archive's
    /// normal for every day after that. They share a scale, so the strip reads
    /// continuously, and the two hairlines say where each hand-off happens.
    public var curve: [Double?] = []

    /// How many days of `curve` sit BEFORE today — so index `lookbackDays` is
    /// today, and everything left of it is this year's actual record.
    ///
    /// Zero unless something is overdue. The card's rule has always been that a
    /// stretch has to earn its space, and three weeks of history earns nothing
    /// in a season that's running on time: it would only squeeze the part of the
    /// axis you're actually reading.
    public var lookbackDays: Int = 0

    /// The ends of the colour ramp the curve is drawn against, named by SEASON
    /// rather than by temperature: `rampFull` is the value that means the season
    /// is still fully on, `rampEased` the value that means it has let go.
    ///
    /// Which end is the hotter one depends on the direction of travel — in
    /// spring the track is climbing and the cold end is the one you started
    /// from — so a hot/cold naming would invert the picture half the year.
    ///
    /// Taken from the thresholds this track ASKS about, widened to whatever the
    /// curve actually does, so the ramp and the labels beneath it can never
    /// disagree and the strip always spends its full range.
    public var rampFull: Double = 0
    public var rampEased: Double = 0

    /// How many days FROM TODAY came from the forecast rather than from the
    /// archive. The strip has to be able to say where knowing stops.
    public var forecastDays: Int = 0

    /// Index of today in `curve`. The one place the two offsets get combined, so
    /// nothing else has to remember which of them the array is indexed by.
    public var todayIndex: Int { lookbackDays }

    /// Where a value sits on the ramp: 1 = the season still fully on, 0 = eased.
    public func intensity(_ value: Double) -> Double {
        let span = rampFull - rampEased
        guard abs(span) > 0.001 else { return 1 }
        return min(1, max(0, (value - rampEased) / span))
    }

    public var id: String { name }
    /// Days until this track's next crossing — how tracks are ordered.
    public var nextInDays: Int { milestones.first?.daysFromNow ?? .max }

    /// Which way through the year this track was built for. The milestones
    /// can't carry it — a crossing of 70° looks identical in April and
    /// September — and the lead sentence is unreadable without it.
    public var cooling: Bool = true

    /// The subject and verb the lead sentence is built from.
    ///
    /// Not derivable from `name`, which is why the sentence was wrong for half
    /// the rows: "Humidity drop below 65°" and "Freeze drop 32°" are both
    /// broken English, and this is the first line on the page. Two rows take a
    /// plural verb, two take a singular one, and the freeze rows want the
    /// threshold inside the SUBJECT ("the first 32° night arrives") rather than
    /// hung off the verb.
    ///
    /// One verb form serves both sentence shapes — "nights usually settle
    /// below 70°" and "before nights settle below 70°" — because both agree
    /// with the same subject.
    public func phrase(_ milestone: SeasonMilestone) -> (subject: String, verb: String, plural: Bool) {
        let degrees = "\(Int(milestone.threshold))°"
        switch measure {
        case .afternoons:
            return ("Afternoons", cooling ? "ease below \(degrees)" : "reach \(degrees)", true)
        case .nights:
            return ("Nights", cooling ? "settle below \(degrees)" : "stay above \(degrees)", true)
        case .humidity:
            return ("The air", cooling ? "dries below \(degrees) dew point"
                                       : "thickens past \(degrees) dew point", false)
        case .freeze:
            return (cooling ? "The first \(degrees) night" : "The last \(degrees) night",
                    cooling ? "arrives" : "passes", false)
        }
    }

    /// The daily reading each measure is judged on. Kept beside the measure
    /// rather than at the call sites so the strip and the crossings can't end up
    /// drawn from two different numbers.
    public static func path(for measure: Measure) -> KeyPath<DailyRecord, Double?> {
        switch measure {
        case .afternoons: return \.tempMax
        case .nights, .freeze: return \.tempMin
        case .humidity: return \.dewPointMean
        }
    }

    /// The same reading, taken from a forecast day instead of an archived one.
    public static func forecastPath(for measure: Measure) -> KeyPath<SeasonForecastDay, Double?> {
        switch measure {
        case .afternoons: return \.tempMax
        case .nights, .freeze: return \.tempMin
        case .humidity: return \.dewPointMean
        }
    }
}

/// One forecast day in the terms the archive is kept in, so the two can be read
/// on the same axis. Built from the ten-day outlook by the caller.
public struct SeasonForecastDay: Equatable, Sendable {
    public var day: String            // "yyyy-MM-dd"
    public var tempMax: Double?
    public var tempMin: Double?
    public var dewPointMean: Double?

    public init(day: String, tempMax: Double? = nil, tempMin: Double? = nil,
                dewPointMean: Double? = nil) {
        self.day = day
        self.tempMax = tempMax
        self.tempMin = tempMin
        self.dewPointMean = dewPointMean
    }
}

extension Climatology {

    /// Every near-term crossing, grouped into tracks and ordered by nearness.
    ///
    /// `horizonDays` is the whole context mechanism: it decides what counts as
    /// "soon enough to care about". At 75 days an early-August reader sees the
    /// three curves of summer letting go, and the first freeze — a real date,
    /// but a November one — stays out of the way until it's within a couple of
    /// months.
    /// `forecast` is the ten-day outlook, in archive terms. Where it reaches it
    /// OVERRIDES the normals — see `applyForecast`. Empty means the card falls
    /// back to pure climatology, which is what it always was.
    public func seasonalTracks(asOf day: String,
                               horizonDays: Int = 75,
                               window: Int = 7,
                               forecast: [SeasonForecastDay] = []) -> [SeasonTrack] {
        let monthDay = DayKey.monthDay(of: day)
        // Which half of the year we're in decides whether the interesting
        // crossings are the ones going down or the ones coming back up.
        let cooling = monthDay >= "06-15" && monthDay < "12-15"

        var tracks: [SeasonTrack] = [
            track(name: "Afternoons", measure: .afternoons, symbol: "sun.max.fill",
                  thresholds: cooling ? [95, 90, 85] : [85, 90, 95],
                  cooling: cooling, asOf: day, window: window),
            track(name: "Nights", measure: .nights, symbol: "moon.stars.fill",
                  thresholds: cooling ? [75, 70, 65] : [65, 70, 75],
                  cooling: cooling, asOf: day, window: window),
            track(name: "Mugginess", measure: .humidity, symbol: "humidity.fill",
                  thresholds: cooling ? [70, 65, 60] : [60, 65, 70],
                  cooling: cooling, asOf: day, window: window),
            freezeTrack(asOf: day, cooling: cooling),
        ]

        // The forecast gets to speak BEFORE the horizon filter: a crossing the
        // normals put two days out and the forecast rules out is still a real
        // milestone, just a later one, and it must not be dropped on the way.
        let series = Self.forecastSeries(forecast, from: day)
        for index in tracks.indices {
            tracks[index] = Self.applyForecast(tracks[index], series: series,
                                               cooling: cooling, asOf: day)
        }

        // Drop what's beyond the horizon, then drop tracks left with nothing.
        // Only the far end is filtered: a crossing behind us survived generation
        // precisely because it hasn't happened, and that's the one worth seeing.
        for index in tracks.indices {
            tracks[index].milestones = tracks[index].milestones
                .filter { $0.daysFromNow <= horizonDays }
                .sorted { $0.daysFromNow < $1.daysFromNow }
        }
        let survivors = tracks.filter { !$0.milestones.isEmpty }

        // The axis only makes room behind today when something is actually late
        // — the same rule the horizon follows at the other end. Three weeks of
        // history in an on-time season squeezes the part you're reading and
        // says nothing. Margin so the oldest ghost isn't drawn on the edge.
        let lateness = survivors.flatMap(\.milestones)
            .compactMap { $0.isOverdue ? -($0.normalDaysFromNow ?? 0) : nil }
        let lookbackDays = lateness.max().map { Swift.min($0 + 3, Climatology.overdueLimitDays) } ?? 0

        // Only the survivors pay for a curve — it's eleven weeks of pooled
        // normals per track, and a track nobody draws needs none of it.
        return survivors
            .sorted { $0.nextInDays < $1.nextInDays }
            .map { withCurve($0, asOf: day, horizonDays: horizonDays,
                             lookbackDays: lookbackDays, cooling: cooling,
                             forecast: forecast) }
    }

    /// Fill in the strip: what this year did, what's forecast, what's usual —
    /// and the two ends of the ramp all three are drawn against.
    private func withCurve(_ track: SeasonTrack, asOf day: String,
                           horizonDays: Int, lookbackDays: Int, cooling: Bool,
                           forecast: [SeasonForecastDay]) -> SeasonTrack {
        var track = track
        track.lookbackDays = lookbackDays
        let measurePath = SeasonTrack.path(for: track.measure)

        // Behind today the strip is this year's ACTUAL record, never the normal.
        // Drawing normals there would paint the season easing on schedule across
        // the very stretch whose point is that it didn't — the strip would argue
        // with the ghost sitting on top of it.
        var past: [Double?] = []
        if lookbackDays > 0, let start = DayKey.step(day, by: -lookbackDays) {
            past = (0..<lookbackDays).map { offset in
                DayKey.step(start, by: offset).flatMap { record(on: $0)?[keyPath: measurePath] }
            }
        }
        track.curve = past + normalCurve(measurePath, from: day, days: horizonDays)

        // Then the week ahead we actually know about. Painting the normal there
        // when a real number exists is the same error the milestone dates were
        // making, one pixel at a time.
        let path = SeasonTrack.forecastPath(for: track.measure)
        for entry in forecast {
            guard let offset = DayKey.distance(from: day, to: entry.day),
                  offset >= 0, track.todayIndex + offset < track.curve.count,
                  let value = entry[keyPath: path] else { continue }
            track.curve[track.todayIndex + offset] = value
            track.forecastDays = Swift.max(track.forecastDays, offset + 1)
        }

        // The thresholds are the ramp's reason for existing — they're the values
        // the labels name — but a curve that runs past them on either side would
        // flatten out against a clamp, hiding exactly the stretch where the
        // season is moving fastest. So the thresholds set the ends and the curve
        // is allowed to widen them.
        let values = track.curve.compactMap { $0 } + track.milestones.map(\.threshold)
        guard let low = values.min(), let high = values.max() else { return track }
        track.rampFull = cooling ? high : low
        track.rampEased = cooling ? low : high
        return track
    }

    /// How far behind its usual date a crossing is still allowed to count as
    /// LATE rather than as next season's.
    ///
    /// Without a bound the test is nonsense out of season: standing in December,
    /// "afternoons rise above 85°" has a usual date ten months back and today's
    /// reading is nowhere near it, which satisfies "hasn't happened yet" and
    /// would place a ghost most of a year to the left. Six weeks is about as
    /// late as a real season runs, and past it the honest answer is that the
    /// date is simply not this year's business.
    static let overdueLimitDays = 45

    /// Where a crossing sits on the axis, and where its usual date sits — the
    /// same number twice, until the season starts running late.
    ///
    /// `nil` drops the crossing, which is the right answer for the common case
    /// of a date that has passed BECAUSE IT HAPPENED. Telling that apart from a
    /// date that has passed because the season is late is the whole job here,
    /// and only the record of this year can do it.
    private func placement(ofCrossing typical: String, threshold: Double,
                           measure: KeyPath<DailyRecord, Double?>,
                           cooling: Bool, asOf day: String,
                           window: Int) -> (days: Int, normalDays: Int)? {
        guard let signed = Climatology.signedDaysUntil(monthDay: typical, from: day) else { return nil }
        if signed >= 0 { return (signed, signed) }
        guard -signed <= Climatology.overdueLimitDays else { return nil }

        // No recent reading means no verdict, and the old behaviour — assume it
        // happened, roll to next year, drop as distant — is the safe one: it
        // stays quiet instead of announcing a delay it can't see.
        guard let current = currentReading(measure, asOf: day, window: window) else { return nil }
        let eased = cooling ? current <= threshold : current >= threshold
        return eased ? nil : (signed, signed)
    }

    private func track(name: String, measure: SeasonTrack.Measure, symbol: String,
                       thresholds: [Double],
                       cooling: Bool, asOf day: String, window: Int) -> SeasonTrack {
        let measurePath = SeasonTrack.path(for: measure)
        let milestones = thresholds.compactMap { threshold -> SeasonMilestone? in
            let summary = cooling
                ? fallCrossing(name: "", measure: measurePath, fallingBelow: threshold, window: window)
                : springCrossing(name: "", measure: measurePath, risingAbove: threshold, window: window)
            guard summary.isMeaningful, let typical = summary.typical else { return nil }

            // A crossing only EXISTS in a year that was on the far side to begin
            // with: "nights settle below 75°" is meaningless in a summer whose
            // nights never reached 75. Averaging only the years that did cross
            // draws the date from the hot subset and drags it late — which is how
            // "below 75°" ended up dated AFTER "below 70°". If any watched year
            // lacks the crossing, the median isn't describing the same thing
            // across years, so the milestone is dropped.
            guard summary.yearsWithout == 0 else { return nil }

            guard let place = placement(ofCrossing: typical, threshold: threshold,
                                        measure: measurePath, cooling: cooling,
                                        asOf: day, window: window) else { return nil }

            return SeasonMilestone(label: "\(cooling ? "below" : "above") \(Int(threshold))°",
                                   threshold: threshold, monthDay: typical, daysFromNow: place.days,
                                   earliest: summary.earliest, latest: summary.latest,
                                   yearsObserved: summary.yearsObserved,
                                   normalDaysFromNow: place.normalDays)
        }
        // Belt and braces: thresholds arrive ordered from loosest to strictest, so
        // their dates must not run backwards through the season. Anything that
        // still does is an artifact of uneven samples, not a thing that happens.
        //
        // Compared on the CALENDAR date, not on days-from-now. Days-from-now wraps
        // at the end of the year — on October 15 a crossing dated October 2 has
        // already passed and rolls to +352 — so comparing those would read the
        // season as running backwards and discard the milestone that's a week out.
        // Both crossing windows sit inside one calendar year, so the month-day
        // string orders them correctly.
        var monotonic: [SeasonMilestone] = []
        for milestone in milestones where milestone.monthDay >= (monotonic.last?.monthDay ?? "") {
            monotonic.append(milestone)
        }
        return SeasonTrack(name: name, measure: measure, symbol: symbol,
                           milestones: monotonic, cooling: cooling)
    }

    private func freezeTrack(asOf day: String, cooling: Bool) -> SeasonTrack {
        let milestones = FrostLevel.allCases.compactMap { level -> SeasonMilestone? in
            let summary = cooling ? firstFallFrost(level) : lastSpringFrost(level)
            guard summary.isMeaningful, let typical = summary.typical,
                  let signed = Climatology.signedDaysUntil(monthDay: typical, from: day) else { return nil }

            var days = signed
            if signed < 0 {
                // Frost is a single night touching the line, not a week
                // averaging below it, so the smoothed test the other tracks use
                // would answer a different question here.
                guard cooling, -signed <= Climatology.overdueLimitDays,
                      hasFrosted(level, asOf: day) == false else { return nil }
                days = signed
            }
            return SeasonMilestone(label: "\(Int(level.rawValue))°", threshold: level.rawValue,
                                   monthDay: typical, daysFromNow: days,
                                   earliest: summary.earliest, latest: summary.latest,
                                   yearsObserved: summary.yearsObserved,
                                   normalDaysFromNow: signed)
        }
        return SeasonTrack(name: cooling ? "Freeze" : "Last freeze", measure: .freeze,
                           symbol: "snowflake", milestones: milestones, cooling: cooling)
    }

    /// Has this autumn already reached a frost level? `nil` when the stretch
    /// since midsummer wasn't watched closely enough for "no" to mean anything.
    private func hasFrosted(_ level: FrostLevel, asOf day: String) -> Bool? {
        guard let year = DayKey.year(of: day) else { return nil }
        let start = "\(year)-\(Climatology.seasonPivot)"
        guard start <= day, hasCoverage(from: start, through: day) else { return nil }
        return all.contains { $0.day >= start && $0.day <= day && ($0.tempMin ?? 999) <= level.rawValue }
    }

    /// The outlook as a dense day-indexed array from `day`, so a hole in it stays
    /// a hole instead of shifting everything after it a day early.
    static func forecastSeries(_ forecast: [SeasonForecastDay],
                               from day: String) -> [SeasonForecastDay?] {
        var byOffset: [Int: SeasonForecastDay] = [:]
        for entry in forecast {
            guard let offset = DayKey.distance(from: day, to: entry.day), offset >= 0 else { continue }
            byOffset[offset] = entry
        }
        guard let last = byOffset.keys.max() else { return [] }
        return (0...last).map { byOffset[$0] }
    }

    /// Correct a track's crossings against what the forecast actually says.
    ///
    /// The two directions are NOT symmetric, and that asymmetry is the whole
    /// idea. Ruling a crossing OUT is near-certain: if every night for ten days
    /// is forecast at 74°, then "nights settle below 70° in two days" is simply
    /// false, whatever thirty Septembers say — so the date becomes a FLOOR at the
    /// end of the forecast, and stops claiming to know when. Pulling a crossing
    /// FORWARD is weaker evidence, because one cool front is not the season
    /// turning, so it has to hold for the days the window has left to show.
    ///
    /// Inside the forecast's own reach the forecast simply wins: there is no
    /// sense in averaging a fact with a tendency.
    static func applyForecast(_ track: SeasonTrack, series: [SeasonForecastDay?],
                              cooling: Bool, asOf day: String) -> SeasonTrack {
        let path = SeasonTrack.forecastPath(for: track.measure)
        let values: [Double?] = series.map { $0?[keyPath: path] }
        guard values.contains(where: { $0 != nil }) else { return track }
        let reach = values.count

        var track = track
        track.milestones = track.milestones.map { milestone -> SeasonMilestone in
            let eased: (Double) -> Bool = cooling
                ? { $0 <= milestone.threshold } : { $0 >= milestone.threshold }

            // The first day that crosses and doesn't immediately come back.
            var crossing: Int?
            for index in values.indices where values[index].map(eased) == true {
                let run = index...Swift.min(values.count - 1, index + 2)
                if run.allSatisfy({ values[$0].map(eased) ?? true }) {
                    crossing = index
                    break
                }
            }
            // A crossing on the very last forecast day has nothing after it to
            // confirm it — enough to answer a question inside the window, not
            // enough to overturn a normal that sits outside it.
            let isFirm = crossing.map { $0 <= values.count - 2 } ?? false

            var days: Int
            var basis: SeasonBasis
            if milestone.daysFromNow < reach {
                days = crossing ?? reach
                basis = crossing == nil ? .notBefore : .forecast
            } else if let crossing, isFirm, crossing < milestone.daysFromNow {
                days = crossing
                basis = .forecast
            } else {
                return milestone
            }

            guard let key = DayKey.step(day, by: days) else { return milestone }
            var moved = milestone
            moved.daysFromNow = days
            moved.normalMonthDay = milestone.monthDay
            moved.monthDay = DayKey.monthDay(of: key)
            moved.basis = basis
            return moved
        }
        .sorted { $0.daysFromNow < $1.daysFromNow }
        return track
    }

    /// Days from `day` to THIS year's occurrence of a `MM-dd`, signed — negative
    /// once the date is behind us.
    ///
    /// The companion to `daysUntil`, which can only count down: rolling a passed
    /// date into next year is right for "when is the next one" and wrong for "is
    /// this one late", and the card needs both answers.
    static func signedDaysUntil(monthDay: String, from day: String) -> Int? {
        guard let year = DayKey.year(of: day) else { return nil }
        return DayKey.distance(from: day, to: "\(year)-\(monthDay)")
    }

    /// Where a measure stands RIGHT NOW, smoothed the way the crossings are.
    ///
    /// The instrument that tells an overdue crossing from a finished one. Both
    /// have a usual date behind them, and nothing in the climatology can say
    /// which is which — only this year's record can.
    ///
    /// Takes the last `window` days the archive actually HOLDS rather than the
    /// last `window` calendar days, because the daily rollup runs a day or two
    /// behind live and a strict calendar window would go empty every morning.
    /// It still refuses to reach back further than a fortnight for them.
    public func currentReading(_ measure: KeyPath<DailyRecord, Double?>,
                               asOf day: String, window: Int = 7) -> Double? {
        guard let floor = DayKey.step(day, by: -14) else { return nil }
        let values = all.filter { $0.day >= floor && $0.day <= day }
            .compactMap { $0[keyPath: measure] }
            .suffix(window)
        // Half a window is enough to say which side of a line we're standing on.
        // Less than that is a guess, and a guess here either invents a two-week
        // delay or hides one.
        guard values.count * 2 >= window else { return nil }
        return Array(values).mean
    }

    /// Days from `day` to the next occurrence of a `MM-dd`, rolling to next year
    /// when the date has already passed.
    static func daysUntil(monthDay: String, from day: String) -> Int? {
        guard let year = DayKey.year(of: day) else { return nil }
        let thisYear = "\(year)-\(monthDay)"
        if thisYear >= day { return DayKey.distance(from: day, to: thisYear) }
        return DayKey.distance(from: day, to: "\(year + 1)-\(monthDay)")
    }
}
