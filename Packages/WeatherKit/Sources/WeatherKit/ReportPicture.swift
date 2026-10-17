//
//  ReportPicture.swift  (WeatherKit)
//
//  "Report a number" questions, drawn as the picture that fits the question.
//
//  WHY NOT BARS. Every report question used to come back as one bar per group,
//  and a bar per year is wrong in a way that looks right: the archive starts in
//  October 2022 and the current year is running, so "Average high by year" put
//  83° beside 79° for 2026 — a year without its winter — and called it the
//  hottest. Rain by year did the same with totals. The fix isn't a caveat under
//  the bars, it's asking each question the way a person means it:
//
//    yearToDate      total by year       → every year added up from Jan 1, read
//                                          at the same date as this one
//    departureGrid   average by year     → each month against normal for its
//                                          dates, so a partial year is fair
//    monthGrid       by month            → every month on record, years by
//                                          months; the standouts and the season
//                                          show together
//    monthOfYear     by month of year    → each year's month as a dot beside the
//                                          usual: when, and how much it varies
//    extremes        highest/lowest      → the date of each season's extreme on
//                    by year               a calendar axis: WHEN, not only how much
//    single          no grouping         → the number
//
//  The days are the query's own: its dates, its years and its conditions, the
//  same selection `aggregate(_:)` reduces.
//

import Foundation

public struct ReportPicture: Equatable, Sendable {

    public enum Kind: String, Equatable, Sendable {
        case yearToDate, departureGrid, monthGrid, monthOfYear, extremes, single
    }

    /// One month of one year.
    public struct Month: Equatable, Sendable, Identifiable {
        public var year: Int
        public var month: Int          // 1–12
        /// The month's number: its total for an amount, otherwise the query's reduction.
        public var value: Double?
        /// Highs against normal for the same dates, averaged — the departure grid's number.
        public var departure: Double?
        /// How much of the month the station recorded.
        public var coverage: Double
        /// The day behind the number, where one day is: the wettest, the gustiest.
        public var day: String?
        public var dayValue: Double?
        /// Selected days that carried a reading.
        public var days: Int
        public var id: String { "\(year)-\(month)" }
        public var isWhole: Bool { coverage >= 0.95 }
    }

    /// One year's figure beside the grid.
    public struct Year: Equatable, Sendable, Identifiable {
        public var year: Int
        public var value: Double?
        public var coverage: Double
        public var id: Int { year }
        public var isWhole: Bool { coverage >= 0.95 }
    }

    /// One year added up from January 1.
    public struct Running: Equatable, Sendable, Identifiable {
        public var year: Int
        /// Day of the year the record starts on, for a year it opened partway through.
        public var start: Int
        /// The running total for each day from `start`, up to the last day recorded.
        public var values: [Double]
        public var isComplete: Bool
        public var id: Int { year }
        public var total: Double { values.last ?? 0 }
        /// The running total on a day of the year, or nil outside what's recorded.
        public func value(onDay day: Int) -> Double? {
            let i = day - start
            return i >= 0 && i < values.count ? values[i] : nil
        }
    }

    /// One season's extreme, and where it fell.
    public struct Season: Equatable, Sendable, Identifiable {
        public var label: String
        /// The first day of the drawn window in this season.
        public var windowStart: String
        public var day: String?
        public var value: Double?
        /// The stretch past the line: first and last day, and how many.
        public var firstPast: String?
        public var lastPast: String?
        public var pastCount: Int
        /// The window was recorded well enough to name its extreme.
        public var isSeen: Bool
        /// The season is still running.
        public var isRunning: Bool
        public var id: String { label }
    }

    public var kind: Kind
    public var aggregate: Aggregate
    public var measure: Measure { aggregate.measure }
    public var recordEnd: String

    public var months: [Month] = []
    public var years: [Year] = []
    /// The usual value for each month of the year (index 0 = January), from whole months.
    public var usualByMonth: [Double?] = []

    public var running: [Running] = []
    /// The usual running total for each day of the year, from the complete years.
    public var usualRunning: [Double] = []

    public var seasons: [Season] = []
    /// The line an extreme is measured past — 100° for heat, 32° for cold — when there is one.
    public var line: Double?
    /// Days in the drawn window, and the month it opens in.
    public var windowLength: Int = 0
    public var windowMonth: Int = 1

    public var single: Double?
    public var singleCoverage: Double = 1

    /// The day of the year (0 = Jan 1) of a day key.
    public static func dayOfYear(_ day: String) -> Int {
        guard let year = DayKey.year(of: day) else { return 0 }
        return DayKey.distance(from: "\(year)-01-01", to: day) ?? 0
    }
}

extension ReportPicture.Kind {
    /// Which picture answers an aggregate.
    public init(_ aggregate: Aggregate) {
        switch (aggregate.groupBy, aggregate.reduce) {
        case (.none, _): self = .single
        case (.month, _): self = .monthGrid
        case (.monthOfYear, _): self = .monthOfYear
        case (.year, .sum), (.year, .count): self = .yearToDate
        case (.year, .mean): self = aggregate.measure.accumulates ? .yearToDate : .departureGrid
        case (.year, .max), (.year, .min): self = .extremes
        }
    }
}

// MARK: - Working it out

extension Climatology {

    public func reportPicture(_ query: DayQuery) -> ReportPicture? {
        guard let aggregate = query.aggregate, let lastDay = latestDay, let firstDay = earliestDay else { return nil }
        let scoped = daysInScope(of: query)
        let selected = query.conditions.isEmpty
            ? scoped
            : scoped.filter { record in query.conditions.allSatisfy { $0.evaluate(record) == true } }
        let measure = aggregate.measure
        var picture = ReportPicture(kind: ReportPicture.Kind(aggregate), aggregate: aggregate, recordEnd: lastDay)

        // How much of a stretch the station recorded — every day it holds, whatever the conditions said.
        let held = Set(scoped.filter { $0[keyPath: measure.path] != nil }.map(\.day))
        func coverage(_ from: String, _ to: String) -> Double {
            let end = min(to, lastDay)
            guard end >= from, let span = DayKey.distance(from: from, to: to) else { return 0 }
            var count = 0
            var cursor: String? = from
            while let key = cursor, key <= end { if held.contains(key) { count += 1 }; cursor = DayKey.next(key) }
            return Double(count) / Double(span + 1)
        }
        func reduce(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return aggregate.reduce == .count ? 0 : nil }
            switch aggregate.reduce {
            case .sum: return values.reduce(0, +)
            // A month's average of an amount is its total — see `Aggregate.meansPerCycle`.
            case .mean: return measure.accumulates ? values.reduce(0, +) : values.reduce(0, +) / Double(values.count)
            case .max: return values.max()
            case .min: return values.min()
            case .count: return Double(values.count)
            }
        }
        let highest = aggregate.reduce != .min

        switch picture.kind {
        case .single:
            picture.single = reduce(selected.compactMap { $0[keyPath: measure.path] })
            picture.singleCoverage = coverage(firstDay, lastDay)

        case .monthGrid, .monthOfYear, .departureGrid:
            let byMonth = Dictionary(grouping: selected) { String($0.day.prefix(7)) }
            var normals: [String: Double?] = [:]
            func normal(_ day: String) -> Double? {
                let md = DayKey.monthDay(of: day)
                if let cached = normals[md] { return cached }
                let n = self.normal(monthDay: md)
                let value = n.isMeaningful ? measure.normalPath.flatMap { n[keyPath: $0] } : nil
                normals[md] = value
                return value
            }
            let firstYear = DayKey.year(of: firstDay) ?? 0, lastYear = DayKey.year(of: lastDay) ?? 0
            for year in firstYear...lastYear {
                for month in 1...12 {
                    let key = String(format: "%04d-%02d", year, month)
                    let start = key + "-01"
                    guard start <= lastDay, let next = DayKey.step(start, by: 31).map({ String($0.prefix(7)) + "-01" }),
                          let end = DayKey.previous(next), end >= firstDay else { continue }
                    let days = byMonth[key] ?? []
                    let readings = days.compactMap { r in r[keyPath: measure.path].map { (r.day, $0) } }
                    let pick = highest ? readings.max { $0.1 < $1.1 } : readings.min { $0.1 < $1.1 }
                    let departures = readings.compactMap { day, v in normal(day).map { v - $0 } }
                    picture.months.append(.init(
                        year: year, month: month, value: reduce(readings.map(\.1)),
                        departure: departures.isEmpty ? nil : departures.reduce(0, +) / Double(departures.count),
                        coverage: coverage(start, end), day: pick?.0, dayValue: pick?.1, days: readings.count))
                }
            }
            picture.usualByMonth = (1...12).map { month in
                let whole = picture.months.filter { $0.month == month && $0.isWhole }.compactMap(\.value)
                return whole.isEmpty ? nil : whole.reduce(0, +) / Double(whole.count)
            }
            for year in firstYear...lastYear {
                let readings = selected.filter { DayKey.year(of: $0.day) == year }
                    .compactMap { r in r[keyPath: measure.path].map { (r.day, $0) } }
                let departures = readings.compactMap { day, v in normal(day).map { v - $0 } }
                let value: Double? = picture.kind == .departureGrid
                    ? (departures.isEmpty ? nil : departures.reduce(0, +) / Double(departures.count))
                    : reduce(readings.map(\.1))
                picture.years.append(.init(year: year, value: value, coverage: coverage("\(year)-01-01", "\(year)-12-31")))
            }

        case .yearToDate:
            let byDay = Dictionary(selected.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
            let firstYear = DayKey.year(of: firstDay) ?? 0, lastYear = DayKey.year(of: lastDay) ?? 0
            for year in firstYear...lastYear {
                let opens = max("\(year)-01-01", firstDay), closes = min("\(year)-12-31", lastDay)
                var values: [Double] = []
                var total = 0.0
                var cursor: String? = opens
                while let key = cursor, key <= closes {
                    if let record = byDay[key] {
                        total += aggregate.reduce == .count ? 1 : (record[keyPath: measure.path] ?? 0)
                    }
                    values.append(total)
                    cursor = DayKey.next(key)
                }
                picture.running.append(.init(year: year, start: ReportPicture.dayOfYear(opens), values: values,
                                             isComplete: opens == "\(year)-01-01" && closes == "\(year)-12-31"))
            }
            let complete = picture.running.filter(\.isComplete)
            if !complete.isEmpty {
                picture.usualRunning = (0..<365).map { day in
                    complete.compactMap { $0.value(onDay: day) }.reduce(0, +) / Double(complete.count)
                }
            }

        case .extremes:
            seasonExtremes(&picture, selected: selected, highest: highest, firstDay: firstDay, lastDay: lastDay,
                           coverage: coverage)
        }
        return picture
    }

    /// Each season's extreme, dated, on one window of the calendar wide enough for all of them.
    ///
    /// A season is the calendar year for a high and July to June for a low, so a cold snap at New Year
    /// stays in its winter. The window is where the extremes and the stretches past the line actually
    /// fall — May to September for heat here, October to March for cold — and a season is only named
    /// when the station recorded that window: 2022's hottest day isn't "90° in October".
    private func seasonExtremes(_ picture: inout ReportPicture, selected: [DailyRecord], highest: Bool,
                                firstDay: String, lastDay: String,
                                coverage: (String, String) -> Double) {
        let measure = picture.measure
        let opensIn = highest ? 1 : 7
        picture.line = {
            switch (measure, highest) {
            case (.high, true): return 100
            case (.low, false): return 32
            default: return nil
            }
        }()
        func past(_ v: Double) -> Bool {
            guard let line = picture.line else { return false }
            return highest ? v >= line : v <= line
        }
        let firstYear = (DayKey.year(of: firstDay) ?? 0) - (opensIn == 1 ? 0 : 1)
        let lastYear = DayKey.year(of: lastDay) ?? 0
        struct Raw { var year: Int; var start: String; var end: String; var day: String?; var value: Double?
                     var firstPast: String?; var lastPast: String?; var count: Int }
        var raws: [Raw] = []
        for year in firstYear...lastYear {
            let start = String(format: "%04d-%02d-01", year, opensIn)
            guard let end = DayKey.previous(String(format: "%04d-%02d-01", year + 1, opensIn)),
                  start <= lastDay, end >= firstDay else { continue }
            let readings = selected.filter { $0.day >= start && $0.day <= end }
                .compactMap { r in r[keyPath: measure.path].map { (r.day, $0) } }
            let pick = highest ? readings.max { $0.1 < $1.1 } : readings.min { $0.1 < $1.1 }
            let beyond = readings.filter { past($0.1) }.map(\.0)
            raws.append(Raw(year: year, start: start, end: end, day: pick?.0, value: pick?.1,
                            firstPast: beyond.first, lastPast: beyond.last, count: beyond.count))
        }
        // The window: every extreme and every stretch past the line, from seasons the record covers
        // whole, with a fortnight's margin, in whole months.
        let whole = raws.filter { coverage($0.start, $0.end) >= 0.9 }
        let offsets = (whole.isEmpty ? raws : whole).flatMap { raw in
            [raw.day, raw.firstPast, raw.lastPast].compactMap { $0 }.compactMap { DayKey.distance(from: raw.start, to: $0) }
        }
        let lo = max(0, (offsets.min() ?? 0) - 14), hi = min(364, (offsets.max() ?? 364) + 14)
        // Snap to month starts, counted from the season's first month.
        let monthStarts = (0...12).map { k in
            DayKey.distance(from: "2001-\(String(format: "%02d", opensIn))-01",
                            to: String(format: "%04d-%02d-01", opensIn + k > 12 ? 2002 : 2001, (opensIn - 1 + k) % 12 + 1)) ?? 0
        }
        let firstMonth = monthStarts.lastIndex { $0 <= lo } ?? 0
        let lastMonth = monthStarts.firstIndex { $0 > hi } ?? 12
        picture.windowMonth = (opensIn - 1 + firstMonth) % 12 + 1
        picture.windowLength = monthStarts[lastMonth] - monthStarts[firstMonth]

        for raw in raws {
            guard let windowStart = DayKey.step(raw.start, by: monthStarts[firstMonth]),
                  let windowEnd = DayKey.step(windowStart, by: picture.windowLength - 1) else { continue }
            let running = raw.end > lastDay
            let seen = running ? windowStart <= lastDay : coverage(windowStart, windowEnd) >= 0.9
            let crosses = DayKey.year(of: windowStart) != DayKey.year(of: windowEnd)
            let label = crosses
                ? "\(Self.monthAbbrev(windowStart)) ’\(windowStart.dropFirst(2).prefix(2)) – \(Self.monthAbbrev(windowEnd)) ’\(windowEnd.dropFirst(2).prefix(2))"
                : String(windowStart.prefix(4))
            picture.seasons.append(.init(label: label, windowStart: windowStart, day: raw.day, value: raw.value,
                                         firstPast: raw.firstPast, lastPast: raw.lastPast, pastCount: raw.count,
                                         isSeen: seen && raw.day != nil, isRunning: running))
        }
    }

    private static func monthAbbrev(_ day: String) -> String {
        WeatherAlmanac.monthName(String(day.dropFirst(5).prefix(2)), long: false)
    }
}

// MARK: - The questions, in words

public extension DayQuery {
    /// The report questions, worded as what a person asks. Each one's picture comes from its aggregate,
    /// so a question built by hand gets the same treatment.
    static var reportQuestions: [DayQuery] {
        [DayQuery(name: "Is this year wet or dry?", conditions: [],
                  aggregate: Aggregate(measure: .rain, reduce: .sum, groupBy: .year)),
         DayQuery(name: "When does it rain here?", conditions: [],
                  aggregate: Aggregate(measure: .rain, reduce: .mean, groupBy: .monthOfYear)),
         DayQuery(name: "Which months were the wettest?", conditions: [],
                  aggregate: Aggregate(measure: .rain, reduce: .sum, groupBy: .month, rank: .highest)),
         DayQuery(name: "Is this year running hot?", conditions: [],
                  aggregate: Aggregate(measure: .high, reduce: .mean, groupBy: .year)),
         DayQuery(name: "How hot does it get?", conditions: [],
                  aggregate: Aggregate(measure: .high, reduce: .max, groupBy: .year)),
         DayQuery(name: "How cold does it get?", conditions: [],
                  aggregate: Aggregate(measure: .low, reduce: .min, groupBy: .year)),
         DayQuery(name: "Which months were the windiest?", conditions: [],
                  aggregate: Aggregate(measure: .gust, reduce: .max, groupBy: .month, rank: .highest))]
    }
}
