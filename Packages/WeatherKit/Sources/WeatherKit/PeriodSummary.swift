//
//  PeriodSummary.swift  (WeatherKit)
//
//  An INTERVAL as the unit of the question.
//
//  Everything else that reads the archive is anchored to a DATE — this day in
//  past years, the records board, the crossings near today. But a real question
//  is often about a stretch: "September is coming, does it actually let up, and
//  when?" That needs a different shape — the whole window summarized at once,
//  and the window's own INTERNAL trajectory, which is the part a single average
//  destroys.
//
//  Three things shape what's below:
//
//  1. A PERIOD IS HALF-OPEN, `start ..< endExclusive`, IN MONTH-DAYS. February
//     is 02-01 ..< 03-01, not 02-01 ... 02-28 — an inclusive end written as a
//     month-day string silently drops February 29 every leap year, which is a
//     bug this codebase has already paid for once. An exclusive boundary can't
//     express that mistake.
//  2. THE OVERALL AVERAGE IS THE LEAST USEFUL NUMBER IN HERE. "September's
//     average high is 91°" is true and answers nothing; the month is a slope,
//     and what you feel is where it crosses. So the summary carries the per-day
//     normal curve and the threshold crossings that land inside the window, and
//     treats the aggregates as backing detail rather than the headline.
//  3. EVERY AGGREGATE INHERITS THE ARCHIVE'S HONESTY RULES. Only reliable days
//     compute; a partial year is reported with its coverage rather than drawn
//     short in silence; precipitation totals are FLOORS, because the hour the
//     station missed may be the hour it rained.
//

import Foundation

// MARK: - The period itself

/// A stretch of the calendar, repeatable across years.
///
/// Held as month-days rather than dates precisely because the interesting
/// question is cross-year: "September" is a thing that happened four times here,
/// and the comparison between those four is most of the answer.
public struct WeatherPeriod: Equatable, Sendable, Identifiable, Hashable {

    public enum Kind: String, Equatable, Sendable, Hashable {
        case month, season, rolling, custom
    }

    public var name: String
    /// Inclusive `MM-dd`.
    public var start: String
    /// EXCLUSIVE `MM-dd`. See the header — this is what keeps Feb 29 alive.
    public var endExclusive: String
    public var kind: Kind

    public var id: String { "\(kind.rawValue)·\(start)·\(endExclusive)" }

    public init(name: String, start: String, endExclusive: String, kind: Kind = .custom) {
        self.name = name
        self.start = start
        self.endExclusive = endExclusive
        self.kind = kind
    }

    /// Built from inclusive dates, the way a date picker hands them over.
    public init?(name: String, from start: String, throughInclusive end: String, kind: Kind = .custom) {
        guard let exclusive = DayKey.next("2000-\(end)") else { return nil }
        self.init(name: name, start: start,
                  endExclusive: DayKey.monthDay(of: exclusive), kind: kind)
    }

    /// True when the window runs through New Year (winter, or a custom Nov–Feb).
    /// Everything that resolves the period to real dates has to branch on this.
    public var wrapsYearEnd: Bool { endExclusive <= start }

    public func contains(monthDay: String) -> Bool {
        wrapsYearEnd
            ? (monthDay >= start || monthDay < endExclusive)
            : (monthDay >= start && monthDay < endExclusive)
    }

    /// Every `MM-dd` in the window, in order.
    ///
    /// Stepped through the year 2000 — a leap year — so a window covering the
    /// end of February contains Feb 29 and its normal gets computed like any
    /// other day's.
    public var monthDays: [String] {
        var result: [String] = []
        var cursor = "2000-\(start)"
        while result.count < 400 {
            result.append(DayKey.monthDay(of: cursor))
            guard let next = DayKey.next(cursor) else { break }
            // Wrap back into the reference year rather than walking into 2001,
            // where February would lose its 29th.
            cursor = DayKey.year(of: next) == 2000 ? next : "2000-01-01"
            if DayKey.monthDay(of: cursor) == endExclusive { break }
        }
        return result
    }

    /// Length of the CURVE, which is a leap-year length: a window touching the
    /// end of February is one day longer here than it will be in most real
    /// years. That's deliberate — Feb 29 is a date the archive has records for
    /// and deserves a normal — so a real year's length comes from `bounds`,
    /// never from this.
    public var curveLength: Int { monthDays.count }

    /// Concrete day keys for the instance of this period that STARTS in `year`.
    /// A wrapping period ends in the following year — winter 2025 runs into
    /// February 2026 — and belongs to the year it opened in.
    public func bounds(inYear year: Int) -> (start: String, end: String)? {
        guard let startKey = WeatherPeriod.resolve(start, inYear: year) else { return nil }
        let endYear = wrapsYearEnd ? year + 1 : year
        guard let exclusive = WeatherPeriod.resolve(endExclusive, inYear: endYear),
              let end = DayKey.previous(exclusive) else { return nil }
        return (startKey, end)
    }

    /// A `MM-dd` placed in a real year, or nil where it doesn't exist there
    /// (Feb 29 outside a leap year). Round-tripped rather than trusted, because
    /// a lenient parse would quietly hand back March 1 wearing February's name.
    static func resolve(_ monthDay: String, inYear year: Int) -> String? {
        let key = String(format: "%04d-%@", year, monthDay)
        guard let date = DayKey.date(from: key, timeZone: DayKey.keyZone),
              DayKey.string(for: date, timeZone: DayKey.keyZone) == key else { return nil }
        return key
    }
}

// MARK: - Presets

extension WeatherPeriod {

    /// The twelve calendar months.
    public static var months: [WeatherPeriod] {
        (1...12).map { month in
            let next = month == 12 ? 1 : month + 1
            return WeatherPeriod(name: WeatherAlmanac.monthName(String(format: "%02d", month)),
                                 start: String(format: "%02d-01", month),
                                 endExclusive: String(format: "%02d-01", next),
                                 kind: .month)
        }
    }

    /// Meteorological seasons — whole months, which is what makes them
    /// comparable year to year. (Astronomical seasons start mid-month and would
    /// split every monthly aggregate in this file down the middle.)
    ///
    /// Northern-hemisphere naming. The station's own record decides everything
    /// numeric; only these four labels assume which half of the world it's in.
    public static var seasons: [WeatherPeriod] {
        [WeatherPeriod(name: "Spring", start: "03-01", endExclusive: "06-01", kind: .season),
         WeatherPeriod(name: "Summer", start: "06-01", endExclusive: "09-01", kind: .season),
         WeatherPeriod(name: "Fall", start: "09-01", endExclusive: "12-01", kind: .season),
         WeatherPeriod(name: "Winter", start: "12-01", endExclusive: "03-01", kind: .season)]
    }

    /// A window of the last `days` ending yesterday — the archive's last day.
    ///
    /// This is Tempest's week/month/year selector, and it needs no separate
    /// machinery: a rolling window is just a period anchored to today, and it
    /// compares across years exactly like a calendar one does.
    public static func rolling(days: Int, name: String, endingAt day: String) -> WeatherPeriod? {
        guard let start = DayKey.step(day, by: -(days - 1)), let exclusive = DayKey.next(day)
        else { return nil }
        return WeatherPeriod(name: name, start: DayKey.monthDay(of: start),
                             endExclusive: DayKey.monthDay(of: exclusive), kind: .rolling)
    }

    /// The month a date falls in — the sensible default selection.
    public static func month(containing day: String) -> WeatherPeriod {
        let index = (Int(DayKey.monthDay(of: day).prefix(2)) ?? 1) - 1
        return months[min(11, max(0, index))]
    }

    /// One date, as a window of one.
    ///
    /// A day is not a special case of anything here — it's the shortest period,
    /// and making it one is what lets "September 1st, every year" and
    /// "September, every year" be the same question at two grains rather than
    /// two features.
    public static func day(containing day: String) -> WeatherPeriod {
        let monthDay = DayKey.monthDay(of: day)
        return WeatherPeriod(name: WeatherAlmanac.dateLabel(monthDay),
                             from: monthDay, throughInclusive: monthDay)
            ?? WeatherPeriod(name: monthDay, start: monthDay, endExclusive: monthDay)
    }

    /// The seven days ending on `day`.
    ///
    /// Deliberately NOT the calendar week. A week that starts on Sunday starts
    /// on a different date every year, so "this week, across the years" would
    /// compare seven different date-ranges and call it a comparison. Anchoring
    /// to the date keeps the window the same `MM-dd` span in every year, which
    /// is the only way the cross-year lens means anything.
    public static func week(ending day: String) -> WeatherPeriod {
        guard let start = DayKey.step(day, by: -6) else { return .day(containing: day) }
        let from = DayKey.monthDay(of: start), through = DayKey.monthDay(of: day)
        let name = "\(WeatherAlmanac.dateLabel(from)) – \(WeatherAlmanac.dateLabel(through))"
        return WeatherPeriod(name: name, from: from, throughInclusive: through)
            ?? .day(containing: day)
    }

    /// The whole calendar year, as a period. Wraps by definition, so its bounds
    /// resolve through `bounds(inYear:)` like every other window.
    public static var wholeYear: WeatherPeriod {
        WeatherPeriod(name: "the year", start: "01-01", endExclusive: "01-01")
    }

    /// The season a date falls in.
    public static func season(containing day: String) -> WeatherPeriod {
        let monthDay = DayKey.monthDay(of: day)
        return seasons.first { $0.contains(monthDay: monthDay) } ?? seasons[0]
    }
}

// MARK: - Grain

/// How wide a window the archive is being read through.
///
/// The selector this drives is Tempest's, with one addition Tempest has no
/// reason to want: a position here can be held in ONE year or pooled across
/// every year the archive holds. "September 2025" and "every September" are the
/// same grain at the same position, read two ways — which is the comparison the
/// whole local archive exists to make and the one thing a live station app
/// can't do.
public enum WeatherGrain: String, CaseIterable, Sendable, Identifiable, Hashable {
    case day, week, month, season, year, all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .season: return "Season"
        case .year: return "Year"
        case .all: return "All time"
        }
    }

    /// The whole archive isn't a position you can step to, so it has no period
    /// and no arrows — it's the one grain that's a destination rather than a
    /// window.
    public var isPositional: Bool { self != .all }

    /// Whether pooling across years says anything. A year pooled across years
    /// IS the whole archive, so the toggle would land on the grain next door.
    public var canPool: Bool {
        switch self {
        case .day, .week, .month, .season: return true
        case .year, .all: return false
        }
    }

    /// The window this grain makes around a date.
    public func period(containing day: String) -> WeatherPeriod? {
        switch self {
        case .day: return .day(containing: day)
        case .week: return .week(ending: day)
        case .month: return .month(containing: day)
        case .season: return .season(containing: day)
        case .year: return .wholeYear
        case .all: return nil
        }
    }

    /// Move the anchor one whole grain along the calendar.
    ///
    /// Stepping by the grain's own width is what makes the arrows a WALK rather
    /// than a nudge: from September, back is August, not August 31st. Months and
    /// seasons step by calendar month so the walk lands on month boundaries
    /// instead of drifting by the 30/31-day mismatch.
    public func step(_ day: String, by direction: Int) -> String? {
        switch self {
        case .day: return DayKey.step(day, by: direction)
        case .week: return DayKey.step(day, by: 7 * direction)
        case .month: return WeatherGrain.shiftMonths(day, by: direction)
        case .season: return WeatherGrain.shiftMonths(day, by: 3 * direction)
        case .year: return WeatherGrain.shiftMonths(day, by: 12 * direction)
        case .all: return nil
        }
    }

    /// Calendar-month arithmetic that clamps rather than overflowing: stepping
    /// back a month from March 31 lands on the last day of February, not on
    /// March 3rd.
    static func shiftMonths(_ day: String, by months: Int) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DayKey.keyZone
        guard let date = DayKey.date(from: day, timeZone: DayKey.keyZone),
              let shifted = calendar.date(byAdding: .month, value: months, to: date)
        else { return nil }
        return DayKey.string(for: shifted, timeZone: DayKey.keyZone)
    }
}

// MARK: - Pieces of a summary

/// One calendar day inside the window: what's usual there, and what this
/// instance of the period actually did.
public struct PeriodDay: Equatable, Sendable, Identifiable {
    public var monthDay: String
    /// Pooled ±7 days across every year — see below for why this isn't the raw
    /// per-date mean.
    public var normal: DailyNormal
    /// The focus year's actual day, when the archive holds it.
    public var actual: DailyRecord?
    public var id: String { monthDay }
}

/// One year's version of the whole window.
public struct PeriodYear: Equatable, Sendable, Identifiable {
    /// The year the window OPENED in — a wrapping winter is filed under its December.
    public var year: Int
    public var start: String
    public var end: String

    /// Means of the daily values across the window, from reliable days only.
    public var high: Double?
    public var low: Double?
    public var mean: Double?
    public var dewPoint: Double?

    public var hottest: WeatherExtreme?
    public var coldest: WeatherExtreme?
    /// A FLOOR. Every hour the station missed is rain that may have fallen.
    public var precip: Double
    public var rainDays: Int

    public var daysCovered: Int
    public var daysExpected: Int
    /// The window hasn't finished yet, so its aggregates aren't comparable.
    public var isInProgress: Bool

    public var id: Int { year }

    public var coverage: Double {
        guard daysExpected > 0 else { return 0 }
        return min(1, Double(daysCovered) / Double(daysExpected))
    }
    /// Complete and well-watched enough to sit in a "typical".
    public var isTrustworthy: Bool { !isInProgress && coverage >= 0.9 }
}

/// How far the window moves from its own start to its own end.
///
/// The answer to "does it get cooler" — but only the magnitude half of it. The
/// crossings are the other half, and the more useful one.
public struct PeriodDrift: Equatable, Sendable {
    /// Days averaged at each end.
    public var span: Int
    public var startHigh: Double?
    public var endHigh: Double?
    public var startLow: Double?
    public var endLow: Double?
    public var startDewPoint: Double?
    public var endDewPoint: Double?

    public var highChange: Double? { difference(startHigh, endHigh) }
    public var lowChange: Double? { difference(startLow, endLow) }
    public var dewPointChange: Double? { difference(startDewPoint, endDewPoint) }

    private func difference(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return b - a
    }
}

/// A threshold the station typically crosses INSIDE this window.
public struct PeriodCrossing: Equatable, Sendable, Identifiable {
    public var track: String
    public var symbol: String
    /// "below 70°"
    public var label: String
    public var threshold: Double
    public var monthDay: String
    public var earliest: String?
    public var latest: String?
    public var yearsObserved: Int
    /// The individual years behind `monthDay` — the evidence for the claim.
    ///
    /// A crossing is a MEDIAN of a handful of real dates, and stating it alone
    /// gives a four-year estimate the look of a fact. The dates were always
    /// computed (one per year, off that year's own smoothed series); until now
    /// they were reduced to a median here and thrown away, so the one card that
    /// makes a dated prediction was the one card that couldn't show its work.
    ///
    /// Only the watched years appear, on the same rule `summarize` uses to rank
    /// them: a year the station half-missed holds a real date that can't be
    /// called earliest or latest.
    public var spread: OccurrenceSpread?

    public var id: String { "\(track)·\(label)" }
}

// MARK: - The summary

public struct PeriodSummary: Equatable, Sendable {
    public var period: WeatherPeriod
    /// The window's internal shape — the part an average erases.
    public var days: [PeriodDay]
    /// Every year's instance, newest first.
    public var years: [PeriodYear]
    /// The most recent instance that has begun — what the curve draws as "actual".
    public var focusYear: Int?

    public var typicalHigh: Double?
    public var typicalLow: Double?
    public var typicalMean: Double?
    public var typicalDewPoint: Double?
    /// Median of the complete years' totals — a median, not a mean, so one
    /// tropical remnant doesn't become "usual".
    public var typicalPrecip: Double?
    public var typicalRainDays: Double?

    public var warmestYear: PeriodYear?
    public var coolestYear: PeriodYear?
    public var wettestYear: PeriodYear?
    public var driestYear: PeriodYear?
    /// The board, scoped to this window across every year.
    public var extremes: ArchiveExtremes

    public var drift: PeriodDrift?
    /// Ordered by date within the window.
    public var crossings: [PeriodCrossing]

    /// Years complete and well-watched enough to have informed the typicals.
    public var comparableYears: Int { years.filter(\.isTrustworthy).count }

    /// Two comparable years is the floor for the word "usually". Below it the
    /// surface shows the record it has and says nothing about what's typical —
    /// a young archive should read as quiet, never as confident and wrong.
    public var isMeaningful: Bool { comparableYears >= 2 }

    public var current: PeriodYear? {
        guard let focusYear else { return nil }
        return years.first { $0.year == focusYear }
    }
}

// MARK: - Building it

extension Climatology {

    /// Everything the archive knows about one stretch of the calendar.
    ///
    /// `day` anchors two things only: which instance of the period counts as
    /// current, and where a still-running window has to stop.
    public func summary(for period: WeatherPeriod, asOf day: String) -> PeriodSummary {
        let monthDays = period.monthDays

        // MARK: Which instance is "this one"
        //
        // The latest year whose window has already OPENED. In August, asking
        // about September gets last September — which is the right answer: the
        // comparison you want against the typical curve is the most recent real
        // one, not an empty line for a month that hasn't started.
        let focusYear = years.reversed().first { year in
            guard let bounds = period.bounds(inYear: year) else { return false }
            return bounds.start <= day
        }

        // MARK: The curve
        let focusBounds = focusYear.flatMap { period.bounds(inYear: $0) }
        let days: [PeriodDay] = monthDays.map { monthDay in
            PeriodDay(monthDay: monthDay,
                      normal: normal(monthDay: monthDay),
                      actual: focusBounds.flatMap { bounds in
                          // A wrapping window spans two calendar years, so the
                          // day's year can't be assumed — walk the bounds.
                          actualRecord(monthDay: monthDay, within: bounds)
                      })
        }

        // MARK: Every year's instance
        let instances = years.compactMap { year -> PeriodYear? in
            guard let bounds = period.bounds(inYear: year) else { return nil }
            return periodYear(year, bounds: bounds, asOf: day)
        }
        .filter { $0.daysCovered > 0 }
        .sorted { $0.year > $1.year }

        let comparable = instances.filter(\.isTrustworthy)

        var summary = PeriodSummary(
            period: period,
            days: days,
            years: instances,
            focusYear: focusYear,
            typicalHigh: comparable.compactMap(\.high).mean,
            typicalLow: comparable.compactMap(\.low).mean,
            typicalMean: comparable.compactMap(\.mean).mean,
            typicalDewPoint: comparable.compactMap(\.dewPoint).mean,
            typicalPrecip: comparable.map(\.precip).sorted().median,
            typicalRainDays: comparable.map { Double($0.rainDays) }.sorted().median,
            warmestYear: comparable.max { ($0.high ?? -999) < ($1.high ?? -999) },
            coolestYear: comparable.min { ($0.low ?? 999) < ($1.low ?? 999) },
            wettestYear: comparable.max { $0.precip < $1.precip },
            driestYear: comparable.min { $0.precip < $1.precip },
            extremes: extremes(within: period),
            drift: drift(over: days),
            crossings: crossings(within: period))
        // Nothing to compare means nothing to call typical.
        if summary.comparableYears < 2 {
            summary.typicalHigh = nil; summary.typicalLow = nil
            summary.typicalMean = nil; summary.typicalDewPoint = nil
            summary.typicalPrecip = nil; summary.typicalRainDays = nil
        }
        return summary
    }

    /// The focus year's record for a month-day, found by scanning the concrete
    /// window rather than by gluing a year onto the front of a `MM-dd`.
    private func actualRecord(monthDay: String, within bounds: (start: String, end: String)) -> DailyRecord? {
        let startYear = DayKey.year(of: bounds.start) ?? 0
        for year in [startYear, startYear + 1] {
            guard let key = WeatherPeriod.resolve(monthDay, inYear: year),
                  key >= bounds.start, key <= bounds.end else { continue }
            if let record = record(on: key) { return record }
        }
        return nil
    }

    /// Roll one concrete window up into a year's instance.
    private func periodYear(_ year: Int,
                            bounds: (start: String, end: String),
                            asOf day: String) -> PeriodYear? {
        let span = all.filter { $0.day >= bounds.start && $0.day <= bounds.end }
        let solid = span.filter(\.isReliable)

        // Days ELAPSED AND ARCHIVABLE, never days scheduled. The archive stops
        // at yesterday by design, so a running window must expect days only
        // through yesterday — counting today (and everything after it) as days
        // the station missed makes every window in progress read short.
        let lastPossible = min(bounds.end, DayKey.previous(day) ?? day)
        let expected = max(0, (DayKey.distance(from: bounds.start, to: lastPossible) ?? -1) + 1)

        func best(_ measure: KeyPath<DailyRecord, Double?>,
                  by compare: (Double, Double) -> Bool) -> WeatherExtreme? {
            solid.compactMap { rec in rec[keyPath: measure].map { (rec.day, $0) } }
                .max { compare($1.1, $0.1) }
                .map { WeatherExtreme(day: $0.0, value: $0.1) }
        }

        // A mean over a handful of a window's days is not that window's mean —
        // it's whatever the station happened to catch, wearing the window's
        // name. Below a quarter watched, the temperatures are withheld rather
        // than printed in a column beside years that were watched throughout.
        // Rain is different and stays: a floor is still a floor, and the day it
        // poured is still a day it poured.
        let enoughToAverage = expected > 0 && Double(span.count) / Double(expected) >= 0.25

        return PeriodYear(
            year: year,
            start: bounds.start,
            end: bounds.end,
            high: enoughToAverage ? solid.compactMap(\.tempMax).mean : nil,
            low: enoughToAverage ? solid.compactMap(\.tempMin).mean : nil,
            mean: enoughToAverage ? solid.compactMap(\.tempMean).mean : nil,
            dewPoint: enoughToAverage ? solid.compactMap(\.dewPointMean).mean : nil,
            hottest: best(\.tempMax, by: >),
            coldest: best(\.tempMin, by: <),
            // Precip counts every day the station saw, reliable or not: a
            // half-watched day that recorded an inch still recorded an inch.
            precip: span.compactMap(\.precipTotal).reduce(0, +),
            rainDays: span.filter { ($0.precipTotal ?? 0) >= 0.01 }.count,
            daysCovered: span.count,
            daysExpected: expected,
            isInProgress: bounds.end >= day)
    }

    /// The all-time board scoped to the window, pooled across every year.
    public func extremes(within period: WeatherPeriod) -> ArchiveExtremes {
        let pool = reliable.filter { period.contains(monthDay: DayKey.monthDay(of: $0.day)) }
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

    /// Start-of-window versus end-of-window, off the normal curve.
    ///
    /// Off the CURVE, not off the raw days, because the curve is already pooled
    /// ±7 days across every year — with three or four Septembers on record, the
    /// raw first-of-the-month mean is three numbers and its "change" would be
    /// mostly which years happened to be windy.
    func drift(over days: [PeriodDay]) -> PeriodDrift? {
        guard days.count >= 9 else { return nil }
        let span = max(3, days.count / 5)
        let head = days.prefix(span).map(\.normal)
        let tail = days.suffix(span).map(\.normal)

        let drift = PeriodDrift(span: span,
                                startHigh: head.compactMap(\.high).mean,
                                endHigh: tail.compactMap(\.high).mean,
                                startLow: head.compactMap(\.low).mean,
                                endLow: tail.compactMap(\.low).mean,
                                startDewPoint: head.compactMap(\.dewPoint).mean,
                                endDewPoint: tail.compactMap(\.dewPoint).mean)
        // A curve built from one year isn't a climate, it's last year's weather.
        guard head.allSatisfy(\.isMeaningful), tail.allSatisfy(\.isMeaningful) else { return nil }
        return drift
    }

    /// Thresholds the station typically crosses inside the window.
    ///
    /// This is the answer to "when in September", and it's deliberately the same
    /// engine the season timeline uses — the finding that nights let go weeks
    /// before afternoons do came out of comparing CROSSINGS rather than drops,
    /// and a period view that only reported drops would lose it again.
    public func crossings(within period: WeatherPeriod) -> [PeriodCrossing] {
        // Each direction only exists in half the year; skip the battery entirely
        // when the window doesn't reach into that half.
        let touchesFall = period.intersects(from: "07-15", toExclusive: "12-31")
        let touchesSpring = period.intersects(from: "02-01", toExclusive: "07-15")

        let tracks: [(String, String, KeyPath<DailyRecord, Double?>, [Double])] = [
            ("Afternoons", "sun.max.fill", \.tempMax, [100, 95, 90, 85, 80, 70, 60]),
            ("Nights", "moon.stars.fill", \.tempMin, [75, 70, 65, 60, 50, 40]),
            ("Humidity", "humidity.fill", \.dewPointMean, [70, 65, 60, 55]),
        ]

        var found: [PeriodCrossing] = []
        for (name, symbol, measure, thresholds) in tracks {
            if touchesFall {
                found += batchedCrossings(track: name, symbol: symbol, measure: measure,
                                          thresholds: thresholds, cooling: true, in: period)
            }
            if touchesSpring {
                found += batchedCrossings(track: name, symbol: symbol, measure: measure,
                                          thresholds: thresholds, cooling: false, in: period)
            }
        }

        // Ordered along the window, not by the calendar: a wrapping winter has
        // December before January, and sorting the raw month-days would put the
        // window's end at its front.
        let order = Dictionary(uniqueKeysWithValues: period.monthDays.enumerated().map { ($1, $0) })
        return found.sorted { (order[$0.monthDay] ?? 0) < (order[$1.monthDay] ?? 0) }
    }

    /// Every threshold on one measure, in one direction, from ONE pass.
    ///
    /// `fallCrossing` smooths the whole half-year per call, so asking it for
    /// seventeen thresholds smoothed the same series seventeen times — about
    /// 450 ms per period, on a screen whose whole job is switching periods. The
    /// series doesn't depend on the threshold, so it's computed once per year
    /// and every threshold is read off it. Same numbers, same honesty rules
    /// (`summarize` still owns those), one pass.
    private func batchedCrossings(track: String, symbol: String,
                                  measure: KeyPath<DailyRecord, Double?>,
                                  thresholds: [Double],
                                  cooling: Bool,
                                  in period: WeatherPeriod,
                                  window: Int = 7) -> [PeriodCrossing] {
        var byThreshold: [Double: [SeasonalEvent]] = [:]
        for year in years {
            let bounds = cooling
                ? ("\(year)-\(Climatology.seasonPivot)", "\(year)-12-31")
                : ("\(year)-02-01", "\(year)-\(Climatology.seasonPivot)")
            let series = smoothedMean(measure, from: bounds.0, through: bounds.1, window: window)
            let covered = hasCoverage(from: bounds.0, through: bounds.1)

            for threshold in thresholds {
                let event: SeasonalEvent
                if cooling {
                    // The last day still above; the crossing is what follows it.
                    let last = series.last { $0.mean >= threshold }
                    event = SeasonalEvent(year: year,
                                          day: last.flatMap { Climatology.nextDay(of: $0.day) },
                                          value: last?.mean, hasCoverage: covered)
                } else {
                    let first = series.first { $0.mean >= threshold }
                    event = SeasonalEvent(year: year, day: first?.day,
                                          value: first?.mean, hasCoverage: covered)
                }
                byThreshold[threshold, default: []].append(event)
            }
        }

        return thresholds.compactMap { threshold in
            guard let events = byThreshold[threshold] else { return nil }
            return crossing(summarize(name: "", events: events), in: period,
                            track: track, symbol: symbol,
                            threshold: threshold, direction: cooling ? "below" : "above")
        }
    }

    private func crossing(_ summary: TransitionSummary, in period: WeatherPeriod,
                          track: String, symbol: String,
                          threshold: Double, direction: String) -> PeriodCrossing? {
        guard summary.isMeaningful, let typical = summary.typical,
              period.contains(monthDay: typical) else { return nil }
        // A crossing only EXISTS in a year that started on the far side. If any
        // watched year never crossed, the median is drawn from a biased subset
        // and dates the crossing late — the bug that once printed "below 75°"
        // after "below 70°".
        guard summary.yearsWithout == 0 else { return nil }

        return PeriodCrossing(track: track, symbol: symbol,
                              label: "\(direction) \(Int(threshold))°",
                              threshold: threshold, monthDay: typical,
                              earliest: summary.earliest, latest: summary.latest,
                              yearsObserved: summary.yearsObserved,
                              spread: spread(of: summary, along: period))
    }

    /// The crossing's per-year dates in the shape the occurrence views already
    /// draw.
    ///
    /// The window numbers are taken from the SUMMARY rather than recomputed off
    /// the axis, because `summary.typical` is what the headline date is — a
    /// second derivation could land a day apart and put the emphasis on a date
    /// the sentence doesn't name.
    private func spread(of summary: TransitionSummary,
                        along period: WeatherPeriod) -> OccurrenceSpread? {
        let occurrences = summary.events
            .filter(\.hasCoverage)
            .compactMap { event in event.day.map { Occurrence(year: event.year, day: $0) } }
            .sorted { $0.year < $1.year }
        guard !occurrences.isEmpty else { return nil }
        return OccurrenceSpread(occurrences: occurrences,
                                typical: summary.typical,
                                earliest: summary.earliest,
                                latest: summary.latest,
                                spreadDays: summary.spreadDays,
                                axis: period.monthDays)
    }
}

extension WeatherPeriod {
    /// Whether the window overlaps another month-day span at all.
    func intersects(from start: String, toExclusive end: String) -> Bool {
        monthDays.contains { $0 >= start && $0 < end }
    }
}

// MARK: - Saying it

extension WeatherAlmanac {

    /// One line for the top of a period view — the shape of the window, not its
    /// average. Nil when the record can't support a claim about what's typical.
    public static func periodHeadline(_ summary: PeriodSummary) -> String? {
        guard summary.isMeaningful else { return nil }
        let name = summary.period.name

        // Prefer the crossings: a date you can plan against beats a delta.
        if let first = summary.crossings.first {
            let track = first.track.lowercased()
            let when = dateLabel(first.monthDay)
            // Pair it with a DIFFERENT measure where there is one. Two nights
            // thresholds in one sentence say the same thing twice; nights and
            // then afternoons is the whole finding — that the two let go weeks
            // apart, and a stretch reads as summer at 3pm and not by morning.
            let partner = summary.crossings.last { $0.track != first.track }
                ?? summary.crossings.last { $0.id != first.id }
            if let partner {
                return "\(name) turns: \(track) go \(first.label) around \(when), "
                     + "\(partner.track.lowercased()) \(partner.label) by \(dateLabel(partner.monthDay))."
            }
            return "\(name) turns: \(track) go \(first.label) around \(when)."
        }

        // No crossing inside the window — say which way it leans, if either.
        if let drift = summary.drift, let high = drift.highChange, let low = drift.lowChange {
            let move = (abs(high) + abs(low)) / 2
            guard move >= 2 else {
                return "\(name) holds steady — highs near \(degrees(summary.typicalHigh ?? 0)), "
                     + "lows near \(degrees(summary.typicalLow ?? 0))."
            }
            let direction = high + low > 0 ? "warms" : "cools"
            return "\(name) \(direction) as it goes — highs \(degrees(abs(high))) and "
                 + "nights \(degrees(abs(low))) \(high + low > 0 ? "higher" : "lower") "
                 + "at the end than the start."
        }
        return nil
    }
}
