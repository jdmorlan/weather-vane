//
//  Climatology.swift  (WeatherKit)
//
//  The archive turned into answers. `DailyArchive` is the record; this is what
//  reads it — normals, rankings, streaks, extremes — so a live number can be
//  placed against everything the station has ever seen.
//
//  Three decisions shape everything below:
//
//  1. UNRELIABLE DAYS NEVER SET A STATISTIC. A day the station only half-saw is
//     still stored and still shown, but it can't set a record, move a normal, or
//     take a percentile — its "high" is the high of the hours we happened to
//     catch, which is a different quantity wearing the same name.
//  2. NORMALS USE A WINDOW, NOT A SINGLE DATE. Three or four Aug 6ths is a
//     rounding error, not a climate. Pooling ±7 days gives ~15× the sample for a
//     quantity that barely moves across two weeks. RANKINGS still use the exact
//     date, because "warmest Aug 6" is a claim about Aug 6.
//  3. A GAP IS NOT A ZERO. Streak walks stop at the first missing day rather than
//     stepping over it — "9 days since rain" must not be built by skipping the
//     day it rained.
//

import Foundation

// MARK: - Pieces

/// The usual weather for a date, pooled from a window of days across all years.
public struct DailyNormal: Equatable, Sendable {
    /// `MM-dd` this normal describes.
    public var monthDay: String
    public var high: Double?
    public var low: Double?
    public var mean: Double?
    /// Spread of the daily highs in the sample — what "unusual" is measured in.
    public var highSpread: Double?
    public var lowSpread: Double?
    /// The day's MEAN dew point.
    public var dewPoint: Double?
    /// The day's PEAK dew point — a different quantity, several degrees higher,
    /// and the one a "how muggy did it get" reading has to be judged against.
    public var dewPointPeak: Double?
    /// Mean precipitation on a single day in the window (most are 0.00).
    public var precip: Double?
    public var humidity: Double?
    public var wind: Double?
    public var gust: Double?
    public var pressure: Double?
    public var uv: Double?
    /// Share of days in the sample that saw measurable rain.
    ///
    /// A companion to `precip`, not a replacement: the mean amount answers "how
    /// wet is this date" and this answers "how OFTEN is it wet", and for rain the
    /// second is usually the question. A mean of 0.03" is a downpour divided by
    /// the days it didn't rain, and nothing to judge a single day against.
    public var rainFrequency: Double?
    /// Share of days in the sample that saw any lightning.
    ///
    /// The only baseline lightning can have. A mean strike count is 0.0 on
    /// almost every date, so a departure from it just restates the count.
    public var lightningFrequency: Double?
    /// Distinct years contributing, and total days pooled.
    public var years: Int
    public var sampleDays: Int

    /// Below this the "normal" is one or two years of coincidence. Everything
    /// user-facing checks this before phrasing a number as typical.
    public var isMeaningful: Bool { years >= 2 && sampleDays >= 10 }
}

/// One year's version of a given calendar date.
public struct HistoricalDay: Equatable, Sendable, Identifiable {
    public var year: Int
    public var record: DailyRecord
    public var id: Int { year }
}

/// Where a value sits among its historical peers.
public struct Ranking: Equatable, Sendable {
    /// 1 = highest.
    public var rank: Int
    public var total: Int
    /// Share of the sample this value exceeds, 0…100.
    public var percentile: Double

    public var isHighest: Bool { rank == 1 && total > 1 }
    public var isLowest: Bool { rank == total && total > 1 }
    /// Rank counted from the cold/low end, which is how a low record reads.
    public var rankFromBottom: Int { total - rank + 1 }
}

/// A run of consecutive days that all answered the same question the same way.
public struct Streak: Equatable, Sendable {
    public var length: Int
    public var firstDay: String
    public var lastDay: String
    /// True when the run hit a hole in the archive rather than a day that broke
    /// it — the real streak may be longer, and nothing should claim otherwise.
    public var endedAtGap: Bool
}

/// An extreme, with the day that holds it.
public struct WeatherExtreme: Equatable, Sendable {
    public var day: String
    public var value: Double
}

/// The all-time board.
public struct ArchiveExtremes: Equatable, Sendable {
    public var hottest: WeatherExtreme?
    public var coldest: WeatherExtreme?
    public var wettestDay: WeatherExtreme?
    public var strongestGust: WeatherExtreme?
    public var muggiest: WeatherExtreme?
}

// MARK: - Climatology

/// A read-only view over the archive. Build once from `[DailyRecord]` and query;
/// the month-day index is what makes the anniversary lookups cheap enough to do
/// on every render.
public struct Climatology: Sendable {

    /// Everything, including partial days — lookups and display use these.
    public let all: [DailyRecord]
    /// The subset trustworthy enough to compute with.
    public let reliable: [DailyRecord]

    private let byDay: [String: DailyRecord]
    private let byMonthDay: [String: [DailyRecord]]

    public init(records: [DailyRecord]) {
        let sorted = records.sorted { $0.day < $1.day }
        all = sorted
        reliable = sorted.filter(\.isReliable)
        byDay = Dictionary(sorted.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        byMonthDay = Dictionary(grouping: reliable) { DayKey.monthDay(of: $0.day) }
        annualMedianMean = sorted.filter(\.isReliable).compactMap(\.tempMean).sorted().median
    }

    public var isEmpty: Bool { all.isEmpty }
    public var dayCount: Int { all.count }
    public var earliestDay: String? { all.first?.day }
    public var latestDay: String? { all.last?.day }

    /// Distinct calendar years with at least one reliable day.
    public var yearsOfRecord: Int {
        Set(reliable.compactMap { DayKey.year(of: $0.day) }).count
    }

    public func record(on day: String) -> DailyRecord? { byDay[day] }

    /// The reliable days on one `MM-dd`, every year — for pooled normals built
    /// outside this file.
    func reliableRecords(monthDay: String) -> [DailyRecord] { byMonthDay[monthDay] ?? [] }

    // MARK: Which end of the day matters

    /// Whether a date is better judged by its high or its low.
    public enum TemperatureEmphasis: String, Sendable {
        case high, low
    }

    /// Median of every reliable day's mean temperature — the year's midpoint,
    /// computed once so the emphasis question is answered by a comparison rather
    /// than by a scan.
    public let annualMedianMean: Double?

    /// In the warm half of the year the day's HIGH is the fact you want ("how hot
    /// did it get"); in the cold half it's the LOW ("how cold did it get"). Asking
    /// the record where this date sits, rather than hardcoding a list of months,
    /// keeps it right for any station in any hemisphere.
    public func seasonalEmphasis(monthDay: String) -> TemperatureEmphasis {
        guard let annual = annualMedianMean,
              let dateMean = normal(monthDay: monthDay).mean else { return .high }
        return dateMean >= annual ? .high : .low
    }

    // MARK: Anniversaries

    /// Every year's version of a calendar date, newest first. Includes partial
    /// days — seeing a thin year listed is better than silently dropping it — so
    /// callers that rank must filter on `isReliable` themselves.
    public func history(monthDay: String, excludingYear year: Int? = nil) -> [HistoricalDay] {
        all.filter { DayKey.monthDay(of: $0.day) == monthDay }
            .compactMap { rec in
                guard let y = DayKey.year(of: rec.day), y != year else { return nil }
                return HistoricalDay(year: y, record: rec)
            }
            .sorted { $0.year > $1.year }
    }

    // MARK: Normals

    /// The usual weather for `monthDay`, pooled over ±`radius` days across all years.
    public func normal(monthDay: String, radius: Int = 7) -> DailyNormal {
        let keys = Climatology.monthDayWindow(around: monthDay, radius: radius)
        let sample = keys.flatMap { byMonthDay[$0] ?? [] }

        var normal = DailyNormal(monthDay: monthDay,
                                 years: Set(sample.compactMap { DayKey.year(of: $0.day) }).count,
                                 sampleDays: sample.count)
        normal.high = sample.compactMap(\.tempMax).mean
        normal.low = sample.compactMap(\.tempMin).mean
        normal.mean = sample.compactMap(\.tempMean).mean
        normal.highSpread = sample.compactMap(\.tempMax).standardDeviation
        normal.lowSpread = sample.compactMap(\.tempMin).standardDeviation
        normal.dewPoint = sample.compactMap(\.dewPointMean).mean
        normal.dewPointPeak = sample.compactMap(\.dewPointMax).mean
        normal.precip = sample.compactMap(\.precipTotal).mean
        normal.humidity = sample.compactMap(\.humidityMean).mean
        normal.wind = sample.compactMap(\.windAvgMean).mean
        normal.gust = sample.compactMap(\.windGustMax).mean
        normal.pressure = sample.compactMap(\.pressureMean).mean
        normal.uv = sample.compactMap(\.uvMax).mean
        normal.rainFrequency = share(of: sample, \.precipTotal, atOrAbove: 0.01)
        normal.lightningFrequency = share(of: sample, \.strikeCountValue, atOrAbove: 1)
        return normal
    }

    /// One measure's normal for each of `days` days starting at `day`.
    ///
    /// Pooled exactly the way `normal(monthDay:)` pools — ±`radius` days across
    /// every year — but reading ONE keypath, because a strip wants eleven weeks
    /// of a single measure and building thirteen aggregates per day to use one of
    /// them is nearly all of the cost.
    ///
    /// A day the record can't answer stays `nil` rather than being interpolated
    /// across: a gap in the archive is not a temperature.
    public func normalCurve(_ measure: KeyPath<DailyRecord, Double?>,
                            from day: String, days: Int, radius: Int = 7) -> [Double?] {
        (0...max(0, days)).map { offset in
            guard let key = DayKey.step(day, by: offset) else { return nil }
            let keys = Climatology.monthDayWindow(around: DayKey.monthDay(of: key), radius: radius)
            let sample = keys.flatMap { byMonthDay[$0] ?? [] }.compactMap { $0[keyPath: measure] }
            // The same bar `DailyNormal.isMeaningful` sets: below this a "normal"
            // is one week of one year, and a strip would paint it as fact.
            guard sample.count >= 10 else { return nil }
            return sample.mean
        }
    }

    /// Share of the days that RECORDED the measure and cleared the bar.
    ///
    /// The denominator is days that recorded it, not days in the sample — a
    /// station that wasn't logging strikes must not read as a quiet fortnight.
    private func share(of sample: [DailyRecord], _ path: KeyPath<DailyRecord, Double?>,
                       atOrAbove bar: Double) -> Double? {
        let values = sample.compactMap { $0[keyPath: path] }
        guard !values.isEmpty else { return nil }
        return Double(values.filter { $0 >= bar }.count) / Double(values.count)
    }

    // MARK: Rankings

    /// Rank `value` against this exact calendar date in every other year.
    ///
    /// Exact date, not the window: a claim about "the warmest Aug 6" is only
    /// honest if it was compared against Aug 6ths.
    public func rank(_ value: Double,
                     monthDay: String,
                     by measure: KeyPath<DailyRecord, Double?>,
                     excludingYear year: Int? = nil) -> Ranking? {
        var values = (byMonthDay[monthDay] ?? [])
            .filter { year == nil || DayKey.year(of: $0.day) != year }
            .compactMap { $0[keyPath: measure] }
        guard !values.isEmpty else { return nil }

        values.append(value)
        let sorted = values.sorted(by: >)
        // Ties share the best rank, so two 97° days are both "warmest", not
        // first and second.
        let rank = (sorted.firstIndex { $0 <= value } ?? 0) + 1
        let below = values.filter { $0 < value }.count
        let percentile = Double(below) / Double(values.count) * 100
        return Ranking(rank: rank, total: values.count, percentile: percentile)
    }

    /// How unusual a value is for the season, in units of the sample's own
    /// spread. ±1 is an ordinary swing; beyond ±2 is genuinely uncommon.
    public func anomalyScore(_ value: Double, normal: Double?, spread: Double?) -> Double? {
        guard let normal, let spread, spread > 0.5 else { return nil }
        return (value - normal) / spread
    }

    // MARK: Streaks

    /// Consecutive days back from `day` (exclusive) with no measurable precip.
    ///
    /// 0.01" is the threshold because that's what "measurable" means in US
    /// practice — a trace that never wet the ground shouldn't break a dry spell.
    public func daysSincePrecip(before day: String, threshold: Double = 0.01) -> Streak? {
        streak(before: day) { ($0.precipTotal ?? 0) < threshold }
    }

    /// The most recent day at or above the threshold, on or before `day`.
    public func lastPrecipDay(onOrBefore day: String, threshold: Double = 0.01) -> DailyRecord? {
        all.last { $0.day <= day && ($0.precipTotal ?? 0) >= threshold }
    }

    /// Walk backwards from `day` (exclusive) while `matches` holds, stopping at
    /// the first day that breaks it — or the first day that isn't in the archive.
    public func streak(before day: String, matches: (DailyRecord) -> Bool) -> Streak? {
        let earlier = all.filter { $0.day < day }
        guard var cursor = earlier.last, matches(cursor) else { return nil }

        var length = 0
        var first = cursor.day
        var endedAtGap = false
        var index = earlier.count - 1
        var expected: String? = nil

        while index >= 0 {
            cursor = earlier[index]
            // A missing calendar day between records means we can't vouch for
            // what happened; stop and say so rather than stepping across it.
            if let expected, cursor.day != expected { endedAtGap = true; break }
            guard matches(cursor) else { break }
            length += 1
            first = cursor.day
            expected = DayKey.previous(cursor.day)
            index -= 1
        }
        if index < 0 && length > 0 { endedAtGap = true }  // ran off the start of the record

        guard length > 0 else { return nil }
        return Streak(length: length, firstDay: first,
                      lastDay: earlier.last?.day ?? first, endedAtGap: endedAtGap)
    }

    /// The run of days ending at `day` (inclusive) that all satisfy `matches` —
    /// "third day in a row above 90°".
    public func currentRun(endingAt day: String, matches: (DailyRecord) -> Bool) -> Streak? {
        guard let today = byDay[day], matches(today) else { return nil }
        guard let earlier = streak(before: day, matches: matches) else {
            return Streak(length: 1, firstDay: day, lastDay: day, endedAtGap: false)
        }
        return Streak(length: earlier.length + 1, firstDay: earlier.firstDay,
                      lastDay: day, endedAtGap: earlier.endedAtGap)
    }

    // MARK: Extremes

    /// The all-time board, or one year's, from reliable days only.
    public func extremes(inYear year: Int? = nil) -> ArchiveExtremes {
        let pool = year.map { y in reliable.filter { DayKey.year(of: $0.day) == y } } ?? reliable
        func best(_ measure: KeyPath<DailyRecord, Double?>,
                  by compare: (Double, Double) -> Bool) -> WeatherExtreme? {
            pool.compactMap { rec in rec[keyPath: measure].map { (rec.day, $0) } }
                .max { compare($1.1, $0.1) }
                .map { WeatherExtreme(day: $0.0, value: $0.1) }
        }
        return ArchiveExtremes(hottest: best(\.tempMax, by: >),
                               coldest: best(\.tempMin, by: <),
                               wettestDay: best(\.precipTotal, by: >),
                               strongestGust: best(\.windGustMax, by: >),
                               muggiest: best(\.dewPointMax, by: >))
    }

    /// Precipitation total across a span of days, and how much of that span the
    /// archive actually covers — a 3" total over 60% of a month isn't a month's
    /// rainfall, and the caller needs to be able to tell.
    public func precipTotal(from start: String, through end: String) -> (total: Double, days: Int) {
        let span = all.filter { $0.day >= start && $0.day <= end }
        return (span.compactMap(\.precipTotal).reduce(0, +), span.count)
    }

    // MARK: Calendar helpers

    /// `MM-dd` keys within `radius` days of a center, wrapping across new year.
    /// Stepped in the year 2000 so Feb 29 exists in the window.
    static func monthDayWindow(around center: String, radius: Int) -> Set<String> {
        let formatter = DayKey.formatter(timeZone: TimeZone(identifier: "UTC") ?? .current)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let base = formatter.date(from: "2000-\(center)") else { return [center] }

        var keys = Set<String>()
        for offset in -radius...radius {
            guard let shifted = calendar.date(byAdding: .day, value: offset, to: base) else { continue }
            keys.insert(DayKey.monthDay(of: formatter.string(from: shifted)))
        }
        return keys
    }

}

extension Array where Element == Double {
    /// Population standard deviation. Nil under two samples, where "spread" has
    /// no meaning to report.
    var standardDeviation: Double? {
        guard count > 1, let mean else { return nil }
        let variance = reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(count)
        return variance.squareRoot()
    }
}
