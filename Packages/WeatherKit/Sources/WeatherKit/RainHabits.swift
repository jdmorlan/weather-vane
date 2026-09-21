//
//  RainHabits.swift  (WeatherKit)
//
//  How the rain ARRIVES, which is a different question from how much of it there
//  is and is not answerable from `RainfallSummary`.
//
//  Two Octobers can hold the same four inches and be nothing alike: one dripped
//  it out over fourteen grey days, the other dropped it in a single afternoon
//  and stayed dry the rest of the month. A bar chart of monthly totals draws
//  those identically. The distinction is what you actually plan around — whether
//  to expect a wet month or one big storm — so it needs its own numbers.
//
//  `ClimateNormal.rainFrequency` has been computing half of this all along, per
//  date, and nothing ever showed it. This rolls it up to the month, adds the
//  intensity that survives on wet days only, and puts the dry spells beside it.
//

import Foundation

/// One month's rain habits, pooled across every year in the archive.
public struct MonthWetness: Equatable, Sendable, Identifiable {
    public var month: Int
    /// Share of days in this month, across all years, that saw measurable rain.
    public var wetShare: Double
    /// Typical number of wet days in this month — `wetShare` expressed the way a
    /// person thinks about it. "Nine days in October" lands where "0.29" doesn't.
    public var wetDays: Double
    /// Mean fall on the days it DID rain. The whole point of separating the two:
    /// a month's total divided by its length is a number no day ever looked like.
    public var meanOnWetDays: Double
    /// The single biggest day this month has ever produced.
    public var wettestDay: Double
    /// Days of this month in the archive, across all years.
    public var daysSampled: Int

    public var id: Int { month }
    public var name: String { WeatherAlmanac.monthName(String(format: "%02d", month), long: false) }
    /// Under a month of pooled record is not a habit, it's an anecdote.
    public var isMeaningful: Bool { daysSampled >= 28 }
}

/// A run of days with no measurable rain.
public struct DrySpell: Equatable, Sendable, Identifiable {
    public var startDay: String
    public var endDay: String
    public var days: Int
    /// True when the spell runs to the end of the record — it hasn't broken yet.
    public var isOpen: Bool
    public var id: String { startDay }
}

public struct RainHabits: Equatable, Sendable {
    public var months: [MonthWetness]
    /// Days since it last rained, counting back from today.
    public var currentDryDays: Int
    /// The last day that saw measurable rain, and how much.
    public var lastRain: (day: String, amount: Double)?
    /// The longest dry runs in the record, longest first.
    public var longestDrySpells: [DrySpell]
    /// The biggest single days in the record, wettest first.
    public var biggestDays: [(day: String, amount: Double)]

    public static func == (a: RainHabits, b: RainHabits) -> Bool {
        a.months == b.months && a.currentDryDays == b.currentDryDays
            && a.longestDrySpells == b.longestDrySpells
            && a.lastRain?.day == b.lastRain?.day
            && a.biggestDays.map(\.day) == b.biggestDays.map(\.day)
    }

    /// Nothing here means anything without a year or so of days behind it.
    public var isMeaningful: Bool { months.contains(where: \.isMeaningful) }
}

extension Climatology {

    /// Measurable, in US practice. A trace that never wet the ground is not a
    /// wet day and must not break a dry spell.
    public static let measurableRain: Double = 0.01

    public func rainHabits(asOf day: String, topN: Int = 8) -> RainHabits {
        let threshold = Self.measurableRain

        // ONLY days the station actually watched. An unreliable day reports a
        // precip total that is a floor, and a floor of 0.00 is indistinguishable
        // from a dry day — which would quietly inflate every dry spell in the
        // record and drag `wetShare` down with it.
        let usable = all.filter { $0.isReliable && $0.precipTotal != nil && $0.day <= day }

        var months: [MonthWetness] = []
        for month in 1...12 {
            let key = String(format: "%02d", month)
            let sample = usable.filter { DayKey.monthDay(of: $0.day).hasPrefix(key) }
            guard !sample.isEmpty else { continue }
            let wet = sample.compactMap(\.precipTotal).filter { $0 >= threshold }
            let share = Double(wet.count) / Double(sample.count)
            months.append(MonthWetness(
                month: month,
                wetShare: share,
                // Scaled to the month's real length, not to the sample size —
                // the answer wanted is "days in a typical October", and the
                // sample is several Octobers deep.
                wetDays: share * Double(Self.daysIn(month: month)),
                meanOnWetDays: wet.isEmpty ? 0 : wet.reduce(0, +) / Double(wet.count),
                wettestDay: wet.max() ?? 0,
                daysSampled: sample.count))
        }

        let last = usable.last { ($0.precipTotal ?? 0) >= threshold }
        let dry = daysSincePrecip(before: DayKey.next(day) ?? day, threshold: threshold)

        let biggest = usable
            .compactMap { r -> (day: String, amount: Double)? in
                guard let p = r.precipTotal, p >= threshold else { return nil }
                return (r.day, p)
            }
            .sorted { $0.amount > $1.amount }
            .prefix(topN)

        return RainHabits(months: months,
                          currentDryDays: dry?.length ?? 0,
                          lastRain: last.flatMap { r in r.precipTotal.map { (r.day, $0) } },
                          longestDrySpells: Self.drySpells(in: usable, threshold: threshold,
                                                           topN: topN),
                          biggestDays: Array(biggest))
    }

    /// Every dry run in the record, longest first.
    ///
    /// Built by walking the usable days in order rather than by asking
    /// `streak(before:)` at each one, which would be quadratic over a record
    /// that is already thousands of days long and still growing.
    ///
    /// A GAP IN THE ARCHIVE ENDS A SPELL rather than extending it. Days the
    /// station didn't watch are absent from `usable`, and treating "no record"
    /// as "no rain" is how you end up claiming a 60-day drought that was really
    /// two dry weeks either side of an outage.
    static func drySpells(in days: [DailyRecord], threshold: Double, topN: Int) -> [DrySpell] {
        var spells: [DrySpell] = []
        var runStart: String?
        var runEnd: String?
        var count = 0

        func close(open: Bool) {
            if let s = runStart, let e = runEnd, count >= 2 {
                spells.append(DrySpell(startDay: s, endDay: e, days: count, isOpen: open))
            }
            runStart = nil; runEnd = nil; count = 0
        }

        for (index, record) in days.enumerated() {
            let isDry = (record.precipTotal ?? 0) < threshold
            let continuous = runEnd.map { DayKey.next($0) == record.day } ?? true
            if isDry {
                if !continuous { close(open: false) }
                if runStart == nil { runStart = record.day; count = 0 }
                runEnd = record.day
                count += 1
            } else {
                close(open: false)
            }
            if index == days.count - 1 { close(open: isDry) }
        }
        return Array(spells.sorted { $0.days > $1.days }.prefix(topN))
    }

    static func daysIn(month: Int) -> Int {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][max(0, min(11, month - 1))]
    }
}
