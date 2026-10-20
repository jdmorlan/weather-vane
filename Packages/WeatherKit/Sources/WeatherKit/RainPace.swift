//
//  RainPace.swift  (WeatherKit)
//
//  The two numbers the top of the Rain page leads with: how this year's rain
//  has piled up against the usual, and what the last few weeks brought.
//
//  A RUNNING TOTAL, NOT A MONTH CHART. "1.49" ahead" is a statement about a
//  running total, so it is drawn as one: this year's line against the usual
//  line. Where the two part is where the year went wrong — a short May shows as
//  the line falling away, a 2.5" storm as a step back up — which grouped monthly
//  bars leave the reader to add up in their head.
//
//  THE USUAL LINE IS A MEDIAN PER DAY, built from each prior year's own running
//  total, and only from years that watched that stretch: the same rule as
//  `RainfallSummary.typicalToDate`, so the number at today's end of the line is
//  the number in the headline. A median of running totals is not itself any
//  year's running total, and it's allowed to be: it is "what's usual by this
//  date", asked of every date.
//
//  LATELY IS ITS OWN WINDOW. A calendar year can be on pace and still have had
//  two dry months at the end of it; the year-to-date total hides that, and it is
//  the thing a yard or a tank actually feels. Thirty days, compared with the same
//  thirty days in prior years.
//

import Foundation

/// A day's place in a year with no Feb 29: 0 for Jan 1, 364 for Dec 31.
/// Feb 29 shares Feb 28's slot, so its rain lands in the right running total
/// without every leap year being a day longer than the axis.
public enum YearSlot {
    public static let count = 365
    private static let starts = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]

    public static func of(_ day: String) -> Int? {
        let md = DayKey.monthDay(of: day)
        guard let m = Int(md.prefix(2)), let d = Int(md.suffix(2)), (1...12).contains(m) else { return nil }
        if m == 2 && d == 29 { return 58 }
        return min(count - 1, starts[m - 1] + d - 1)
    }

    /// The first slot of each month, for axis marks.
    public static var monthStarts: [Int] { starts }
}

public struct RainPace: Equatable, Sendable {
    /// This year's running total per slot, through the last archived day. Nil
    /// past it.
    public var thisYear: [Double?]
    /// The usual running total per slot, through Dec 31. Nil where fewer than two
    /// prior years watched that far.
    public var usual: [Double?]
    /// The slot of the last archived day.
    public var throughSlot: Int
    /// Prior years behind `usual` at its widest.
    public var years: Int

    public var monthStarts: [Int] { YearSlot.monthStarts }

    public var toDate: Double? { thisYear.indices.contains(throughSlot) ? thisYear[throughSlot] : nil }
    public var usualToDate: Double? { usual.indices.contains(throughSlot) ? usual[throughSlot] : nil }
    public var usualYear: Double? { usual.last ?? nil }

    public var departure: Double? {
        guard let toDate, let usualToDate else { return nil }
        return toDate - usualToDate
    }

    public var isMeaningful: Bool { usualToDate != nil }
}

/// The last few weeks, against the same weeks before.
public struct RainLately: Equatable, Sendable {
    public struct Day: Equatable, Sendable, Identifiable {
        public var day: String
        /// Nil for a day the station didn't watch.
        public var amount: Double?
        public var id: String { day }
    }

    public var days: [Day]
    public var total: Double
    /// Median of prior years' totals for the same window. Nil under two years.
    public var usual: Double?
    public var years: Int
    /// Days since the last measurable rain.
    public var dryDays: Int
    /// The last day with measurable rain, and how much.
    public var lastRain: Day?

    public var window: Int { days.count }
    public var daysMissed: Int { days.filter { $0.amount == nil }.count }
}

extension Climatology {

    public func rainPace(asOf day: String) -> RainPace {
        let empty = RainPace(thisYear: [], usual: [], throughSlot: 0, years: 0)
        guard let currentYear = DayKey.year(of: day) else { return empty }

        /// One year's running total and how many days it watched, per slot.
        func running(_ year: Int, through end: String) -> (total: [Double], watched: [Int]) {
            var total = [Double](repeating: 0, count: YearSlot.count)
            var watched = [Int](repeating: 0, count: YearSlot.count)
            for record in all where record.day.hasPrefix("\(year)-") && record.day <= end {
                guard let slot = YearSlot.of(record.day) else { continue }
                total[slot] += record.precipTotal ?? 0
                watched[slot] += 1
            }
            for i in 1..<YearSlot.count {
                total[i] += total[i - 1]
                watched[i] += watched[i - 1]
            }
            return (total, watched)
        }

        let through = YearSlot.of(day) ?? 0
        let current = running(currentYear, through: day)
        var thisYear = [Double?](repeating: nil, count: YearSlot.count)
        for i in 0...through { thisYear[i] = current.total[i] }

        let prior = years.filter { $0 < currentYear }.map { running($0, through: "\($0)-12-31") }
        var usual = [Double?](repeating: nil, count: YearSlot.count)
        var widest = 0
        for i in 0..<YearSlot.count {
            // Only years that watched nine days in ten up to here.
            let values = prior.filter { Double($0.watched[i]) >= Double(i + 1) * 0.9 }.map { $0.total[i] }
            guard values.count >= 2 else { continue }
            usual[i] = values.sorted().median
            widest = max(widest, values.count)
        }
        return RainPace(thisYear: thisYear, usual: usual, throughSlot: through, years: widest)
    }

    public func rainLately(asOf day: String, window: Int = 30) -> RainLately {
        let start = DayKey.step(day, by: -(window - 1)) ?? day
        var days: [RainLately.Day] = []
        var cursor = start
        while cursor <= day {
            let record = record(on: cursor)
            // An unreliable day's total is a floor and reads as dry; it counts as unwatched here.
            let amount = record.flatMap { $0.isReliable ? $0.precipTotal : nil }
            days.append(.init(day: cursor, amount: amount))
            guard let next = DayKey.next(cursor) else { break }
            cursor = next
        }

        let measurable = Self.measurableRain
        let currentYear = DayKey.year(of: day) ?? 0
        let prior = years.filter { $0 < currentYear }.compactMap { year -> Double? in
            let offset = year - currentYear
            guard let a = DayKey.step(start, byYears: offset), let b = DayKey.step(day, byYears: offset) else { return nil }
            let (total, watched) = precipTotal(from: a, through: b)
            guard Double(watched) >= Double(window) * 0.9 else { return nil }
            return total
        }

        let dry = daysSincePrecip(before: DayKey.next(day) ?? day, threshold: measurable)
        let last = all.last { $0.day <= day && $0.isReliable && ($0.precipTotal ?? 0) >= measurable }
        return RainLately(days: days,
                          total: days.compactMap(\.amount).reduce(0, +),
                          usual: prior.count >= 2 ? prior.sorted().median : nil,
                          years: prior.count,
                          dryDays: dry?.length ?? 0,
                          lastRain: last.map { .init(day: $0.day, amount: $0.precipTotal) })
    }
}

extension DayKey {
    /// The same date in another year; Feb 29 lands on Feb 28 where there is none.
    static func step(_ key: String, byYears years: Int) -> String? {
        guard let year = DayKey.year(of: key) else { return nil }
        let md = DayKey.monthDay(of: key)
        return md == "02-29" && !isLeap(year + years) ? "\(year + years)-02-28" : "\(year + years)-\(md)"
    }

    private static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
}
