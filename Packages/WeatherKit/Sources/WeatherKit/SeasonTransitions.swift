//
//  SeasonTransitions.swift  (WeatherKit)
//
//  When the year turns here — first frost, last frost, and the date summer heat
//  finally lets go — read out of the station's own record rather than a regional
//  map drawn from an airport forty miles away.
//
//  The output is deliberately a WINDOW, not a date. "First frost: October 24" is
//  a lie of precision; the record actually says "usually late October, as early
//  as the 9th and as late as November 12", and that range is the thing you plan
//  against. Every summary below carries its median with its spread.
//
//  Two rules keep these honest:
//
//  1. ABSENCE NEEDS COVERAGE, PRESENCE DOESN'T. Seeing 30° proves it froze, even
//     on a day the station only half-reported. NOT seeing a freeze proves nothing
//     unless we watched the whole season. So an event can come from any day, but
//     "no frost that year" is only ever claimed over a covered window.
//  2. THE YEAR IS SPLIT AT MIDSUMMER. A "last spring frost" and a "first fall
//     frost" are the same threshold read from opposite ends of the warm season;
//     without a pivot, one October morning would be both.
//

import Foundation

// MARK: - Vocabulary

/// The cold thresholds that mean different things to a garden.
public enum FrostLevel: Double, CaseIterable, Sendable {
    /// Tender plants die; tomatoes and basil are done.
    case frost = 32
    /// Hard freeze — most annuals gone, hardy greens survive.
    case hardFreeze = 28
    /// Killing freeze; the season is unambiguously over.
    case killingFreeze = 24

    public var name: String {
        switch self {
        case .frost: return "Frost"
        case .hardFreeze: return "Hard freeze"
        case .killingFreeze: return "Killing freeze"
        }
    }

    public var detail: String {
        switch self {
        case .frost: return "32° — tender plants done"
        case .hardFreeze: return "28° — most annuals gone"
        case .killingFreeze: return "24° — season over"
        }
    }
}

/// One year's answer for one transition.
public struct SeasonalEvent: Equatable, Sendable, Identifiable {
    public var year: Int
    /// The day it happened. Nil means it didn't — but only trust that when
    /// `hasCoverage` is true.
    public var day: String?
    /// The reading that triggered it (the morning's low, the week's mean high).
    public var value: Double?
    /// Whether the archive actually watched the window this event lives in.
    public var hasCoverage: Bool
    public var id: Int { year }

    /// A year that was watched and genuinely had no such day.
    public var isConfirmedAbsence: Bool { day == nil && hasCoverage }
}

/// A transition across all the years on record.
public struct TransitionSummary: Equatable, Sendable {
    public var name: String
    public var events: [SeasonalEvent]
    /// `MM-dd` of the median occurrence — the middle of the window.
    public var typical: String?
    public var earliest: String?
    public var latest: String?
    /// Years that were watched and saw it happen.
    public var yearsObserved: Int
    /// Years that were watched and saw it NOT happen — the interesting case in a
    /// mild climate, and one a median would silently swallow.
    public var yearsWithout: Int

    /// Two observations is an anecdote. Anything phrased as "usually" checks this.
    public var isMeaningful: Bool { yearsObserved >= 2 }
    /// Spread in days between the earliest and latest on record.
    public var spreadDays: Int?
}

/// A year's frost-free growing window.
public struct GrowingSeason: Equatable, Sendable, Identifiable {
    public var year: Int
    public var lastSpringFrost: String?
    public var firstFallFrost: String?
    public var days: Int?
    public var id: Int { year }
}

// MARK: - The analysis

extension Climatology {

    /// Midsummer. Everything before it is read as the tail of spring, everything
    /// after as the front of fall.
    static let seasonPivot = "07-15"

    // MARK: Frost

    /// The last spring occurrence of a threshold, per year.
    public func lastSpringFrost(_ level: FrostLevel = .frost) -> TransitionSummary {
        summarize(name: "Last \(level.name.lowercased()) in spring") { year in
            let window = ("\(year)-01-01", "\(year)-\(Climatology.seasonPivot)")
            let hit = all.last { $0.day >= window.0 && $0.day <= window.1 && ($0.tempMin ?? 999) <= level.rawValue }
            return SeasonalEvent(year: year, day: hit?.day, value: hit?.tempMin,
                                 hasCoverage: hasCoverage(from: window.0, through: window.1))
        }
    }

    /// The first fall occurrence of a threshold, per year.
    public func firstFallFrost(_ level: FrostLevel = .frost) -> TransitionSummary {
        summarize(name: "First \(level.name.lowercased()) in fall") { year in
            let window = ("\(year)-\(Climatology.seasonPivot)", "\(year)-12-31")
            let hit = all.first { $0.day >= window.0 && $0.day <= window.1 && ($0.tempMin ?? 999) <= level.rawValue }
            return SeasonalEvent(year: year, day: hit?.day, value: hit?.tempMin,
                                 hasCoverage: hasCoverage(from: window.0, through: window.1))
        }
    }

    /// Frost-free days per year, newest first.
    public func growingSeasons(_ level: FrostLevel = .frost) -> [GrowingSeason] {
        let spring = Dictionary(uniqueKeysWithValues: lastSpringFrost(level).events.map { ($0.year, $0) })
        let fall = Dictionary(uniqueKeysWithValues: firstFallFrost(level).events.map { ($0.year, $0) })

        return years.map { year in
            let last = spring[year]?.day
            let first = fall[year]?.day
            // Only a year watched at BOTH ends can report a length; half a year
            // of coverage gives half an answer, which is no answer.
            let complete = spring[year]?.hasCoverage == true && fall[year]?.hasCoverage == true
            return GrowingSeason(year: year, lastSpringFrost: last, firstFallFrost: first,
                                 days: complete ? Climatology.daysBetween(last, first) : nil)
        }.sorted { $0.year > $1.year }
    }

    // MARK: Seasonal crossings

    /// The date, each autumn, that a smoothed measure falls below a threshold
    /// and stays there.
    ///
    /// Generic over the measure because SUMMER DOESN'T END IN ONE PLACE. At this
    /// station the afternoon high barely moves between August and late September
    /// (98° → 91°) while the overnight low drops decisively (74° → 67°) — so a
    /// highs-only reading calls summer over in October, weeks after it stopped
    /// feeling like summer. Which curve you watch IS the question; the engine
    /// shouldn't presume an answer.
    public func fallCrossing(name: String,
                             measure: KeyPath<DailyRecord, Double?>,
                             fallingBelow threshold: Double,
                             window: Int = 7) -> TransitionSummary {
        summarize(name: name) { year in
            let bounds = ("\(year)-\(Climatology.seasonPivot)", "\(year)-12-31")
            let series = smoothedMean(measure, from: bounds.0, through: bounds.1, window: window)
            // The last day still above; the crossing is what follows it.
            let last = series.last { $0.mean >= threshold }
            return SeasonalEvent(year: year,
                                 day: last.flatMap { Climatology.nextDay(of: $0.day) },
                                 value: last?.mean,
                                 hasCoverage: hasCoverage(from: bounds.0, through: bounds.1))
        }
    }

    /// The spring counterpart: the first date a smoothed measure reaches a threshold.
    public func springCrossing(name: String,
                               measure: KeyPath<DailyRecord, Double?>,
                               risingAbove threshold: Double,
                               window: Int = 7) -> TransitionSummary {
        summarize(name: name) { year in
            let bounds = ("\(year)-02-01", "\(year)-\(Climatology.seasonPivot)")
            let series = smoothedMean(measure, from: bounds.0, through: bounds.1, window: window)
            let first = series.first { $0.mean >= threshold }
            return SeasonalEvent(year: year, day: first?.day, value: first?.mean,
                                 hasCoverage: hasCoverage(from: bounds.0, through: bounds.1))
        }
    }

    /// When afternoons stop being brutal.
    public func heatBreak(threshold: Double = 90, window: Int = 7) -> TransitionSummary {
        fallCrossing(name: "Afternoons ease below \(Int(threshold))°",
                     measure: \.tempMax, fallingBelow: threshold, window: window)
    }

    public func heatArrives(threshold: Double = 90, window: Int = 7) -> TransitionSummary {
        springCrossing(name: "Afternoons reach \(Int(threshold))°",
                       measure: \.tempMax, risingAbove: threshold, window: window)
    }

    /// When NIGHTS start letting go — the measure that actually tracks whether a
    /// building sheds its heat overnight and starts the next day cool.
    public func nightsCool(below threshold: Double = 70, window: Int = 7) -> TransitionSummary {
        fallCrossing(name: "Nights settle below \(Int(threshold))°",
                     measure: \.tempMin, fallingBelow: threshold, window: window)
    }

    public func nightsWarm(above threshold: Double = 70, window: Int = 7) -> TransitionSummary {
        springCrossing(name: "Nights stay above \(Int(threshold))°",
                       measure: \.tempMin, risingAbove: threshold, window: window)
    }

    /// When the air dries out. Dew point is the third thing that moves in early
    /// autumn, and it moves with the nights rather than with the highs.
    public func mugginessEases(below threshold: Double = 65, window: Int = 7) -> TransitionSummary {
        fallCrossing(name: "Mugginess eases below \(Int(threshold))° dew point",
                     measure: \.dewPointMean, fallingBelow: threshold, window: window)
    }

    /// Nights that never dropped below `threshold` — the ones that leave a
    /// building holding yesterday's heat.
    public func warmNights(inYear year: Int, atOrAbove threshold: Double = 75) -> Int {
        reliable.filter { DayKey.year(of: $0.day) == year && ($0.tempMin ?? 0) >= threshold }.count
    }

    /// Median of a measure across a month-day range, pooled over every year.
    /// Used to compare one stretch of the season against another.
    public func median(_ measure: KeyPath<DailyRecord, Double?>,
                       from startMonthDay: String, through endMonthDay: String) -> Double? {
        let values = reliable.filter {
            let monthDay = DayKey.monthDay(of: $0.day)
            return monthDay >= startMonthDay && monthDay <= endMonthDay
        }.compactMap { $0[keyPath: measure] }.sorted()
        return values.median
    }

    /// Mean of daily highs over a window CENTERED on each day.
    ///
    /// Centered, not trailing. A trailing mean carries the week behind it, so it
    /// only falls below a threshold once the cool spell is most of a window old —
    /// it reports every transition several days late, in the same direction every
    /// time. Centering costs nothing and removes that bias, which matters when the
    /// whole output is a date.
    ///
    /// Only emits where the entire window is present and contiguous, so a hole in
    /// the record can't average itself into a cool week.
    func smoothedMean(_ measure: KeyPath<DailyRecord, Double?>,
                      from start: String, through end: String,
                      window: Int) -> [(day: String, mean: Double)] {
        let span = all.filter { $0.day >= start && $0.day <= end }
        let half = window / 2
        guard span.count >= window else { return [] }

        var result: [(String, Double)] = []
        for index in half..<(span.count - half) {
            let slice = Array(span[(index - half)...(index + half)])
            guard Climatology.isContiguous(slice) else { continue }
            let values = slice.compactMap { $0[keyPath: measure] }
            guard values.count == slice.count, let mean = values.mean else { continue }
            result.append((span[index].day, mean))
        }
        return result
    }

    // MARK: Plumbing

    /// Calendar years the archive touches at all.
    public var years: [Int] {
        Array(Set(all.compactMap { DayKey.year(of: $0.day) })).sorted()
    }

    /// Did we watch this stretch closely enough to trust a "never happened"?
    public func hasCoverage(from start: String, through end: String, minimum: Double = 0.9) -> Bool {
        guard let expected = Climatology.daysBetween(start, end), expected > 0 else { return false }
        let held = all.filter { $0.day >= start && $0.day <= end }.count
        return Double(held) / Double(expected) >= minimum
    }

    /// Run a per-year probe across the record and reduce it to a window.
    func summarize(name: String, probe: (Int) -> SeasonalEvent) -> TransitionSummary {
        summarize(name: name, events: years.map(probe))
    }

    /// The reduction on its own, so a caller that already has the per-year
    /// events — because it computed one smoothed series and read many
    /// thresholds off it — doesn't have to restate these rules.
    func summarize(name: String, events unsorted: [SeasonalEvent]) -> TransitionSummary {
        let events = unsorted.sorted { $0.year > $1.year }
        // Only years we actually watched inform the window — an event found in a
        // barely-covered year is real, but it can't be ranked as "earliest".
        let observed = events.filter { $0.hasCoverage }.compactMap(\.day).sorted()
        let monthDays = observed.map { DayKey.monthDay(of: $0) }.sorted()

        var summary = TransitionSummary(name: name, events: events,
                                        typical: monthDays.middle,
                                        earliest: monthDays.first,
                                        latest: monthDays.last,
                                        yearsObserved: observed.count,
                                        yearsWithout: events.filter(\.isConfirmedAbsence).count)
        if let first = monthDays.first, let last = monthDays.last {
            summary.spreadDays = Climatology.daysBetween("2001-\(first)", "2001-\(last)")
        }
        return summary
    }

    static func daysBetween(_ start: String?, _ end: String?) -> Int? {
        guard let start, let end else { return nil }
        return DayKey.distance(from: start, to: end)
    }

    static func nextDay(of key: String) -> String? { DayKey.next(key) }

    /// Days are unique and sorted, so a run is contiguous exactly when its span
    /// equals its count — one date calculation instead of one per adjacent pair,
    /// which matters because every smoothing window calls this.
    static func isContiguous(_ records: [DailyRecord]) -> Bool {
        guard let first = records.first, let last = records.last else { return true }
        return DayKey.distance(from: first.day, to: last.day) == records.count - 1
    }
}

extension Array where Element == String {
    /// Middle element of a sorted list — the median date. Takes the LATER of the
    /// two middles on an even count: for a frost date, the conservative half.
    var middle: String? {
        isEmpty ? nil : self[count / 2]
    }
}
