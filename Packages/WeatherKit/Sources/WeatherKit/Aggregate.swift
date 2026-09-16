//
//  Aggregate.swift  (WeatherKit)
//
//  THE OTHER VERB. `DayQuery` selects days — "which days were over 100°" — and that is a predicate. It
//  has no way to say what to REPORT, so "which month got the most rain" couldn't be asked at all, even
//  though the archive answers questions of that shape all over the History tab.
//
//  Because that's what History IS: `PeriodSummary` already totals precip and rain days per year,
//  `rainfallSummary` already walks rain through the year, records are maxima, normals are means across
//  years. **The engine has always aggregated; the LANGUAGE stopped at selection.** So History wasn't a
//  set of very specific Explore questions — it was the same question shape with the other verb, and the
//  two only looked like separate features because one of them had no sentence.
//
//  Selection still applies. "How much rain fell on days that also had lightning" is a reduction OVER a
//  predicate, so an aggregate rides on the query it's part of rather than replacing it.
//
//  COVERAGE IS PART OF THE ANSWER, and sums are the worst case for it: a month missing four days
//  undercounts rain by exactly those days and the number looks no different. Every group therefore
//  carries what it was computed from, which is the same honesty `Reading` (floor/ceiling/central)
//  enforces for predicates and `PeriodSummary` already tracks with `daysCovered`/`daysExpected`.
//

import Foundation

/// What to report about the days a query selected.
public struct Aggregate: Equatable, Sendable, Hashable {

    /// How the days in a group become one number.
    ///
    /// `max`/`min` are honest about being a FLOOR/CEILING on a partial archive — the real extreme can
    /// only be further out — which is why they aren't held to the same coverage bar as a sum.
    public enum Reduction: String, Sendable, CaseIterable, Hashable {
        case sum, mean, max, min, count
    }

    /// What each number is per. `monthOfYear` is the one that answers "which month is usually wettest"
    /// — every July stacked together — as against `month`, which keeps July 2023 and July 2024 apart.
    public enum Grouping: String, Sendable, CaseIterable, Hashable {
        case year, month, monthOfYear, none
    }

    public enum Rank: String, Sendable, CaseIterable, Hashable {
        case highest, lowest
    }

    public var measure: Measure
    public var reduce: Reduction
    public var groupBy: Grouping
    /// Nil orders the groups chronologically, which is what a trend wants; a rank answers "the most".
    public var rank: Rank?
    /// How many groups to keep after ranking. Nil keeps them all.
    public var limit: Int?

    public init(measure: Measure, reduce: Reduction, groupBy: Grouping = .none,
                rank: Rank? = nil, limit: Int? = nil) {
        self.measure = measure
        self.reduce = reduce
        self.groupBy = groupBy
        self.rank = rank
        self.limit = limit
    }

    /// AN AVERAGE OF AN AMOUNT IS PER CYCLE, NOT PER DAY.
    ///
    /// "Average rain by month of the year" asked as a per-day mean answers **0.23"** for May — a
    /// month's worth of storms divided by the thirty-one days most of which were dry. It's arithmetic
    /// nobody wants and nobody can interpret; the number a person means by "May averages" is the
    /// month's TOTAL, averaged across the Mays on record. `PeriodSummary` and the conditional profile
    /// both already refused the per-day mean for rain for exactly this reason — this is the third time
    /// the same trap has been walked into, so it's now a property of the aggregate rather than a habit.
    ///
    /// A state measure (a temperature, a gust) is the opposite: its average IS per day, because each
    /// day carries one reading and no amount of them adds up to a cycle.
    public var meansPerCycle: Bool { reduce == .mean && measure.accumulates }

    /// What one cycle IS: the largest calendar unit strictly INSIDE the group. Across all time the
    /// amount is per year; within a year, or pooled across every July, it's per month. So the same
    /// button reads the way each question is actually spoken — "the year averages 34 inches", "a July
    /// averages 2.4" — without the grouping having to mean something different each time.
    public var cycleNoun: String { groupBy == .none ? "year" : "month" }

    /// One grouping holds exactly one cycle: July 2023 IS a July, so its per-cycle mean is the total
    /// wearing another word. The number stays right, so nothing is refused — but a builder shouldn't
    /// offer two buttons that draw identical bars under different names.
    public var meanRestatesTotal: Bool { meansPerCycle && groupBy == .month }

    public var describe: String {
        var text: String
        switch reduce {
        case .sum:   text = "Total \(measure.name.lowercased())"
        case .mean:  text = "Average \(measure.name.lowercased())"
        case .max:   text = "Highest \(measure.name.lowercased())"
        case .min:   text = "Lowest \(measure.name.lowercased())"
        case .count: text = "Number of days"
        }
        // A per-cycle mean has to say what it's per, or it reads as the per-day number it isn't.
        if meansPerCycle, !meanRestatesTotal {
            switch groupBy {
            case .monthOfYear: return withRank(text + " in each month of the year")
            case .year:        return withRank(text + " in a month, by year")
            case .none:        return withRank(text + " per year")
            case .month:       break
            }
        }
        switch groupBy {
        case .year:        text += " by year"
        case .month:       text += " by month"
        case .monthOfYear: text += " by month of the year"
        case .none:        break
        }
        return withRank(text)
    }

    private func withRank(_ text: String) -> String {
        guard let rank else { return text }
        return text + ", \(rank.rawValue) first"
    }
}

// MARK: - Named questions

public extension DayQuery {
    /// Report questions, the way `presets` are selection questions.
    ///
    /// These are the History tab's cards written as sentences in the query language — which is the point
    /// of the exercise: a card that used to be a hand-built view is now a QUESTION you can open, edit,
    /// and take somewhere else. The tuned cards stay where they are for now; what changes is that they're
    /// no longer the only way to ask.
    static var reportPresets: [DayQuery] {
        [DayQuery(name: "Wettest months", conditions: [],
                  aggregate: Aggregate(measure: .rain, reduce: .sum, groupBy: .month,
                                       rank: .highest, limit: 12)),
         DayQuery(name: "Rain by month of the year", conditions: [],
                  aggregate: Aggregate(measure: .rain, reduce: .sum, groupBy: .monthOfYear)),
         DayQuery(name: "Rain by year", conditions: [],
                  aggregate: Aggregate(measure: .rain, reduce: .sum, groupBy: .year)),
         DayQuery(name: "Average high by year", conditions: [],
                  aggregate: Aggregate(measure: .high, reduce: .mean, groupBy: .year)),
         DayQuery(name: "Hottest day each year", conditions: [],
                  aggregate: Aggregate(measure: .high, reduce: .max, groupBy: .year)),
         DayQuery(name: "Coldest night each year", conditions: [],
                  aggregate: Aggregate(measure: .low, reduce: .min, groupBy: .year)),
         DayQuery(name: "Windiest months", conditions: [],
                  aggregate: Aggregate(measure: .gust, reduce: .max, groupBy: .month,
                                       rank: .highest, limit: 12))]
    }
}

// MARK: - What comes back

public struct AggregateGroup: Equatable, Sendable, Identifiable {
    /// Sortable key — "2023", "2023-07", "07", "all".
    public var key: String
    /// How it reads: "July 2023", "July", "2023".
    public var label: String
    public var value: Double
    /// Days that fed the number — after the query's conditions.
    public var daysCounted: Int
    /// Days the archive OBSERVED in this group, whatever the conditions said. The coverage question is
    /// "how much of this stretch did the station see", and a day that simply didn't match is not a gap:
    /// reporting a lightning total as "76 of 365 days on record" reads as a broken archive when it means
    /// 289 quiet days.
    public var daysObserved: Int
    /// Calendar days this group owes.
    public var daysExpected: Int
    /// Whole cycles this group pools — the Julys behind "average rain in a month of the year", the
    /// years behind a per-year average. 1 for a group that IS one cycle (July 2023), and the divisor
    /// for a per-cycle mean. Counted from what the station OBSERVED, not from what matched: a July
    /// with no rain is still a July, and dropping it would average the wet ones together.
    public var cycles: Int
    public var id: String { key }

    public var coverage: Double {
        daysExpected == 0 ? 0 : Double(daysObserved) / Double(daysExpected)
    }

    /// A number worth quoting without a caveat. Deliberately strict, because the failure mode is
    /// invisible: an undercounted total is still a plausible total.
    public var isTrustworthy: Bool { coverage >= 0.95 }
}

public struct AggregateResult: Equatable, Sendable {
    public var query: DayQuery
    public var aggregate: Aggregate
    /// Ranked if the aggregate asked for it, else chronological.
    public var groups: [AggregateGroup]
    /// Groups dropped by `limit` — so a summary can say "of 14 months" rather than implying it saw four.
    public var groupsConsidered: Int

    public var isEmpty: Bool { groups.isEmpty }

    /// The headline group — the answer to "the most/least", or the latest when nothing was ranked.
    public var leader: AggregateGroup? { groups.first }

    public func format(_ value: Double) -> String {
        aggregate.reduce == .count ? "\(Int(value.rounded())) days" : aggregate.measure.format(value)
    }
}

// MARK: - Running it

extension Climatology {

    /// Reduce the days a query selects. Nil when the query has no aggregate — the caller wants `run`.
    public func aggregate(_ query: DayQuery) -> AggregateResult? {
        guard let aggregate = query.aggregate else { return nil }
        let scoped = daysInScope(of: query)

        // Selection first: an aggregate reports on the days the predicate chose. A condition that can't
        // be answered for a day excludes it, exactly as it does for a count — a day that MIGHT have
        // qualified must not silently contribute to a total.
        let selected = query.conditions.isEmpty
            ? scoped
            : scoped.filter { record in query.conditions.allSatisfy { $0.evaluate(record) == true } }

        var values: [String: [Double]] = [:]
        for record in selected {
            guard let value = record[keyPath: aggregate.measure.path] else { continue }
            values[Self.groupKey(of: record.day, by: aggregate.groupBy), default: []].append(value)
        }
        // Observation counted BEFORE conditions, for the coverage question above. The CYCLES a group
        // pools are counted the same way and for the same reason: a July the station watched and that
        // stayed dry belongs in the divisor of "average rain in a July".
        var observed: [String: Int] = [:]
        var cycles: [String: Set<String>] = [:]
        for record in scoped where record[keyPath: aggregate.measure.path] != nil {
            let key = Self.groupKey(of: record.day, by: aggregate.groupBy)
            observed[key, default: 0] += 1
            cycles[key, default: []].insert(Self.cycleKey(of: record.day, by: aggregate.groupBy))
        }
        guard !values.isEmpty else {
            return AggregateResult(query: query, aggregate: aggregate, groups: [], groupsConsidered: 0)
        }

        let expected = expectedDays(for: query, by: aggregate.groupBy)
        var groups = values.map { key, measured -> AggregateGroup in
            let spanned = max(cycles[key]?.count ?? 1, 1)
            return AggregateGroup(key: key,
                           label: Self.groupLabel(key, by: aggregate.groupBy),
                           value: Self.reduce(measured, by: aggregate.reduce,
                                              perCycles: aggregate.meansPerCycle ? spanned : nil),
                           daysCounted: measured.count,
                           daysObserved: observed[key] ?? measured.count,
                           daysExpected: max(expected[key] ?? measured.count, observed[key] ?? measured.count),
                           cycles: spanned)
        }

        switch aggregate.rank {
        case .highest: groups.sort { $0.value > $1.value }
        case .lowest:  groups.sort { $0.value < $1.value }
        case nil:      groups.sort { $0.key < $1.key }
        }
        let considered = groups.count
        if let limit = aggregate.limit, limit > 0 { groups = Array(groups.prefix(limit)) }
        return AggregateResult(query: query, aggregate: aggregate,
                               groups: groups, groupsConsidered: considered)
    }

    /// `perCycles` non-nil switches the mean's DIVISOR from days to cycles — see `meansPerCycle`.
    private static func reduce(_ values: [Double], by reduction: Aggregate.Reduction,
                               perCycles: Int? = nil) -> Double {
        switch reduction {
        case .sum:   return values.reduce(0, +)
        case .mean:
            if let perCycles { return values.reduce(0, +) / Double(max(perCycles, 1)) }
            return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        case .max:   return values.max() ?? 0
        case .min:   return values.min() ?? 0
        case .count: return Double(values.count)
        }
    }

    static func groupKey(of day: String, by grouping: Aggregate.Grouping) -> String {
        switch grouping {
        case .year:        return String(day.prefix(4))
        case .month:       return String(day.prefix(7))              // 2023-07
        case .monthOfYear: return String(DayKey.monthDay(of: day).prefix(2))
        case .none:        return "all"
        }
    }

    /// Which CYCLE a day belongs to, within its group — the unit a per-cycle mean divides by. One step
    /// finer than the grouping: across all time that's the year, inside any grouping that's a month.
    static func cycleKey(of day: String, by grouping: Aggregate.Grouping) -> String {
        grouping == .none ? String(day.prefix(4)) : String(day.prefix(7))   // 2023 · 2023-07
    }

    static func groupLabel(_ key: String, by grouping: Aggregate.Grouping) -> String {
        switch grouping {
        case .year:        return key
        case .month:
            let month = WeatherAlmanac.monthName(String(key.suffix(2)))
            return "\(month) \(key.prefix(4))"
        case .monthOfYear: return WeatherAlmanac.monthName(key)
        case .none:        return "All years"
        }
    }

    /// How many calendar days each group COULD have held — the group's WHOLE span, not the part the
    /// archive happens to reach.
    ///
    /// The clipped version was wrong in a way that mattered. This archive starts late in 2022, so 2022
    /// held only an autumn — and clipping made those days look like a complete year, reporting "2022:
    /// 65°" beside "2023: 79°" as though the year had been cool. A partial year isn't slightly less
    /// certain, it's SEASONALLY BIASED, and that bias is invisible in the number. Same for the year in
    /// progress, which is the group most likely to be asked about.
    ///
    /// So a group is measured against its own calendar: a year owes 365 days, a month owes its length,
    /// and every year the record touches counts toward a stacked month. Under-covered groups then say so.
    private func expectedDays(for query: DayQuery, by grouping: Aggregate.Grouping) -> [String: Int] {
        guard let firstDay = all.first?.day, let lastDay = all.last?.day,
              let firstYear = DayKey.year(of: firstDay), let lastYear = DayKey.year(of: lastDay)
        else { return [:] }
        var counts: [String: Int] = [:]
        var day = "\(firstYear)-01-01"
        let end = "\(lastYear)-12-31"
        while day <= end {
            if inScope(day, of: query) { counts[Self.groupKey(of: day, by: grouping), default: 0] += 1 }
            guard let next = DayKey.next(day) else { break }
            day = next
        }
        return counts
    }

    /// The scope test on a bare date — `daysInScope` needs records, and counting what's MISSING means
    /// asking about days that have none.
    private func inScope(_ day: String, of query: DayQuery) -> Bool {
        switch query.years {
        case .all: break
        case .year(let year): if DayKey.year(of: day) != year { return false }
        }
        guard let period = query.scope else { return true }
        return period.contains(monthDay: DayKey.monthDay(of: day))
    }
}
