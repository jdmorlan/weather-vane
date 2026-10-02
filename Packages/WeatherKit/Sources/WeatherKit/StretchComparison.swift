//
//  StretchComparison.swift  (WeatherKit)
//
//  ONE STRETCH OF THE CALENDAR, EVERY YEAR, DAY FOR DAY. What Compare draws.
//
//  `PeriodSummary` reads a window as a CLIMATE — smoothed normals, crossings,
//  a typical year — and lines the years up as whole-window aggregates. That's
//  the wrong shape for "how is this October going": two days of this October
//  against thirty-one of every other one is not a comparison, and a whole-month
//  total beside a two-day one says nothing about which is the wetter start.
//
//  So everything here is keyed by DAY INDEX — day 0 is the window's first day
//  in every year — and the "so far" figures for every year are cut at the same
//  index the current instance has reached. October 1–2 against October 1–2.
//
//  The instance still running is the subject. When the walk is somewhere the
//  calendar isn't (September, while it's October) there's no running instance,
//  and the most recent finished one stands in for it, compared whole.
//

import Foundation

/// One day of one year's instance of the stretch.
public struct StretchDay: Equatable, Sendable {
    /// Days since the stretch opened — the shared x-axis.
    public var index: Int
    public var day: String
    public var high: Double?
    public var low: Double?
    /// A floor on a partial day, like every rain total in this archive.
    public var precip: Double?
    public var isReliable: Bool
    /// The muggiest reading of the day, °F.
    public var dewPoint: Double? = nil
    /// The strongest gust, mph.
    public var gust: Double? = nil

    public func value(_ measure: DailyMeasure) -> Double? {
        switch measure {
        case .high: return high
        case .low: return low
        case .dewPoint: return dewPoint
        case .gust: return gust
        }
    }
}

/// The figures a year reached through the cut — the same days in every year.
public struct StretchTally: Equatable, Sendable {
    public var days: Int
    public var daysHeld: Int
    public var rain: Double
    public var wetDays: Int
    public var meanHigh: Double?
    public var meanLow: Double?
    public var hottest: Double?
    public var coldest: Double?
    public var meanDewPoint: Double? = nil
    public var meanGust: Double? = nil
    public var strongestGust: Double? = nil

    /// The mean of a measure's daily values through the cut — reliable days only.
    public func mean(_ measure: DailyMeasure) -> Double? {
        switch measure {
        case .high: return meanHigh
        case .low: return meanLow
        case .dewPoint: return meanDewPoint
        case .gust: return meanGust
        }
    }

    /// Most of the days watched — otherwise its rain is a floor too low to rank.
    public var isComparable: Bool { days > 0 && Double(daysHeld) / Double(days) >= 0.9 }
}

/// One year's instance of the stretch.
public struct StretchYear: Equatable, Sendable, Identifiable {
    /// The year the stretch OPENED in — a winter is filed under its December.
    public var year: Int
    public var start: String
    public var days: [StretchDay]
    /// The instance the calendar is standing in.
    public var isCurrent: Bool
    /// Through the cut (or the whole stretch, with no cut).
    public var tally: StretchTally

    public var id: Int { year }

    /// Rain to the end of each day, by index. A day the archive doesn't hold
    /// adds nothing — the line goes flat rather than inventing a shower.
    public var cumulativeRain: [(index: Int, total: Double)] {
        var total = 0.0
        return days.map { day in
            total += max(0, day.precip ?? 0)
            return (day.index, total)
        }
    }
}

/// The forecast reaching into the running instance.
public struct StretchForecastDay: Equatable, Sendable {
    public var index: Int
    public var day: String
    public var high: Double?
    public var low: Double?
    /// Nil when the hourly forecast doesn't reach that day — not zero.
    public var precip: Double?

    public init(index: Int, day: String, high: Double?, low: Double?, precip: Double?) {
        self.index = index
        self.day = day
        self.high = high
        self.low = low
        self.precip = precip
    }
}

public struct StretchComparison: Equatable, Sendable {
    public var period: WeatherPeriod
    /// Days in the stretch — its length in the current (or most recent) year.
    public var length: Int
    /// How many days of the running instance the archive holds — the cut every
    /// year is tallied to. Nil when nothing is running, and the years compare
    /// whole.
    public var cut: Int?
    /// Newest first.
    public var years: [StretchYear]
    /// Only for the running instance, and only from today on.
    public var forecast: [StretchForecastDay]

    public var subject: StretchYear? { years.first { $0.isCurrent } ?? years.first }
    public var isRunning: Bool { years.contains { $0.isCurrent } }
}

extension Climatology {

    /// Every year's instance of `period`, cut to match the one running on `today`.
    ///
    /// `latestDay` is the archive's last day — yesterday, by design — so the cut
    /// is how many days of the running instance have been measured, and today
    /// itself is forecast. `forecast` is keyed by day; anything outside the
    /// running instance, or before today, is dropped.
    public func stretch(_ period: WeatherPeriod, today: String,
                        forecast: [String: (high: Double?, low: Double?, precip: Double?)] = [:])
        -> StretchComparison {
        let todayYear = DayKey.year(of: today) ?? 0
        let last = latestDay ?? today
        let firstYear = earliestDay.flatMap(DayKey.year(of:)) ?? todayYear

        // A window that wraps the new year and holds today may have opened last
        // year — a January day is inside the winter that began in December.
        let runningYear = [todayYear, todayYear - 1].first { year in
            guard let bounds = period.bounds(inYear: year) else { return false }
            return bounds.start <= today && today <= bounds.end
        }

        // Instances that have begun by today, and that the archive reaches.
        let candidates = (firstYear - 1...todayYear).reversed().compactMap { year -> (Int, String, String)? in
            guard let bounds = period.bounds(inYear: year), bounds.start <= today else { return nil }
            if let first = earliestDay, bounds.end < first { return nil }
            return (year, bounds.start, bounds.end)
        }

        let cut: Int? = runningYear.flatMap { year in
            guard let bounds = period.bounds(inYear: year) else { return nil }
            return Self.days(from: bounds.start, through: min(last, bounds.end))
        }

        var years: [StretchYear] = []
        for (year, start, end) in candidates {
            let isCurrent = year == runningYear
            var days: [StretchDay] = []
            var key = start
            var index = 0
            while key <= end, !(isCurrent && key > last) {
                let record = record(on: key)
                days.append(StretchDay(index: index, day: key,
                                       high: record?.tempMax, low: record?.tempMin,
                                       precip: record?.precipTotal,
                                       isReliable: record?.isReliable ?? false,
                                       dewPoint: record?.dewPointMax,
                                       gust: record?.windGustMax))
                guard let next = DayKey.step(key, by: 1) else { break }
                key = next
                index += 1
            }
            let window = cut ?? (Self.days(from: start, through: end))
            let tally = Self.tally(days.filter { $0.index < window }, window: window)
            // An instance the archive holds nothing of isn't a year on record.
            guard tally.daysHeld > 0 || isCurrent else { continue }
            years.append(StretchYear(year: year, start: start, days: days,
                                     isCurrent: isCurrent, tally: tally))
        }

        let lengthYear = runningYear ?? years.first?.year ?? todayYear
        let length = period.bounds(inYear: lengthYear)
            .map { Self.days(from: $0.start, through: $0.end) } ?? 0

        var ahead: [StretchForecastDay] = []
        if let runningYear, let bounds = period.bounds(inYear: runningYear) {
            for (day, value) in forecast where day >= today && day >= bounds.start && day <= bounds.end {
                ahead.append(StretchForecastDay(index: Self.days(from: bounds.start, through: day) - 1,
                                                day: day, high: value.high, low: value.low,
                                                precip: value.precip))
            }
        }

        return StretchComparison(period: period, length: length, cut: cut,
                                 years: years, forecast: ahead.sorted { $0.index < $1.index })
    }

    /// Inclusive day count, 0 when `end` is before `start`.
    static func days(from start: String, through end: String) -> Int {
        guard end >= start else { return 0 }
        var count = 0
        var key = start
        while key <= end {
            count += 1
            guard let next = DayKey.step(key, by: 1) else { break }
            key = next
        }
        return count
    }

    static func tally(_ days: [StretchDay], window: Int) -> StretchTally {
        let held = days.filter { $0.high != nil || $0.precip != nil }
        let reliable = days.filter(\.isReliable)
        func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return StretchTally(days: window, daysHeld: held.count,
                            rain: days.reduce(0) { $0 + max(0, $1.precip ?? 0) },
                            wetDays: days.filter { ($0.precip ?? 0) >= 0.01 }.count,
                            meanHigh: mean(reliable.compactMap(\.high)),
                            meanLow: mean(reliable.compactMap(\.low)),
                            hottest: days.compactMap(\.high).max(),
                            coldest: days.compactMap(\.low).min(),
                            meanDewPoint: mean(reliable.compactMap(\.dewPoint)),
                            meanGust: mean(reliable.compactMap(\.gust)),
                            strongestGust: days.compactMap(\.gust).max())
    }
}

// MARK: - The sentence

extension StretchComparison {

    /// What the chart is there to prove, said first.
    ///
    /// "October so far: 1.40″ of rain — the wettest start of the 4 on record.
    /// 2024 had 0.80″ by now." Then the temperature, against the other years'
    /// same days. Ranks are out of the years shown, never bare superlatives.
    public func sentence(years shown: Set<Int>? = nil, measure: DailyMeasure = .high) -> String? {
        let pool = years.filter { shown?.contains($0.year) ?? true }
        guard let subject = pool.first(where: \.isCurrent) ?? pool.first else { return nil }
        let others = pool.filter { $0.year != subject.year && $0.tally.isComparable }
        let name = period.name
        let label = subject.isCurrent ? "\(name) so far" : "\(name) \(subject.year)"
        let byNow = subject.isCurrent ? " by now" : ""

        if subject.isCurrent, (cut ?? 0) == 0 {
            return "\(name) starts today — nothing measured yet to set against other years."
        }

        var parts: [String] = []
        let rain = subject.tally.rain
        if others.isEmpty {
            parts.append("\(label): \(Self.inches(rain)) of rain.")
        } else if rain < 0.01 {
            let wetOthers = others.filter { $0.tally.rain >= 0.01 }.count
            parts.append(wetOthers == 0
                ? "\(label): dry — and so was every other \(name) shown\(byNow)."
                : "\(label): no rain yet — \(wetOthers) of the other \(others.count) had some\(byNow).")
        } else {
            let wetter = others.filter { $0.tally.rain > rain }
            let total = others.count + 1
            let place = wetter.isEmpty ? "the wettest"
                      : wetter.count == others.count ? "the driest"
                      : "the \(Self.ordinal(wetter.count + 1)) wettest"
            // "Start" only while most of the stretch is still ahead — six days
            // into a seven-day week is not the start of anything.
            let early = subject.isCurrent && (cut ?? 0) * 2 < length
            let noun = early ? " start" : (subject.isCurrent ? "" : " \(name)")
            var text = "\(label): \(Self.inches(rain)) of rain — \(place)\(noun) of the \(total) shown."
            // The nearest year on the far side says how big the lead is.
            let foil = wetter.isEmpty
                ? others.max { $0.tally.rain < $1.tally.rain }
                : wetter.min { $0.tally.rain < $1.tally.rain }
            if let foil, foil.tally.rain < 0.01 {
                text += others.count == 1 ? " \(foil.year) was dry\(byNow)."
                                          : " None of the other \(others.count) had any\(byNow)."
            } else if let foil {
                text += " \(foil.year) had \(Self.inches(foil.tally.rain))\(byNow)."
            }
            parts.append(text)
        }

        // The second clause follows the measure being compared: highs, lows,
        // the muggiest air or the strongest gusts, against the same days.
        if let clause = clause(measure, years: shown) { parts.append(clause) }
        return parts.joined(separator: " ")
    }

    /// One measure against the other years' same days: "Lows are averaging
    /// 72°, 5° warmer than other years' same days." Each of Compare's measure
    /// cards leads with its own.
    public func clause(_ measure: DailyMeasure, years shown: Set<Int>? = nil) -> String? {
        let pool = years.filter { shown?.contains($0.year) ?? true }
        guard let subject = pool.first(where: \.isCurrent) ?? pool.first else { return nil }
        let others = pool.filter { $0.year != subject.year && $0.tally.isComparable }
        let otherValues = others.compactMap { $0.tally.mean(measure) }
        guard let value = subject.tally.mean(measure), !otherValues.isEmpty else { return nil }
        let typical = otherValues.reduce(0, +) / Double(otherValues.count)
        let delta = Int((value - typical).rounded())
        let against = subject.isCurrent ? "other years' same days" : "the other years shown"
        return abs(delta) < 1
            ? "\(measure.plural) are running right with \(against), near \(measure.format(value))."
            : "\(measure.plural) \(subject.isCurrent ? "are averaging" : "averaged") \(measure.format(value)), "
              + "\(measure.formatDelta(Double(delta))) \(delta > 0 ? measure.moreWord : measure.lessWord) than \(against)."
    }

    static func inches(_ value: Double) -> String { String(format: "%.2f″", value) }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch n % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }
}
