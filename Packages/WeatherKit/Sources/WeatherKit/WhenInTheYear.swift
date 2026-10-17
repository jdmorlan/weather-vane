//
//  WhenInTheYear.swift  (WeatherKit)
//
//  "When does this happen?" — any question Explore can ask, answered as a place
//  in the year.
//
//  WHY THIS EXISTS BESIDE `QueryResult`. The query result counts: how many days,
//  which dates, how often per month. That is a fine answer to "how many days hit
//  100" and the wrong one to "when is it hot", and the second kind of question is
//  the one people arrive with. Asked when the last cool night was, the old page
//  led with "65 days" and left the answer (May 2) as the last blue square on a
//  calendar. This file is the other half: one curve through the year, and the
//  dates read off it.
//
//  THE CURVE IS A SHARE OF DAYS. For each date: of the days within a week either
//  side, in every season on record, how many matched. It used to be described as
//  a share of YEARS, which overstates four or five seasons as a percentage; a
//  share of days pools fifteen days a season and says "about 1 in 4 days", which
//  is what the number is.
//
//  THE AXIS FOLLOWS THE QUESTION. It starts in the quietest month, so a season
//  is drawn whole: freezes run November to March, and an axis that started in
//  January would cut them in two. A question with a date scope is centred on its
//  dates instead. Then the drawn span is cropped to the season itself (three
//  weeks either side of the earliest first day and the latest last), because a
//  freeze chart that spends half its width on summer only shows readings far
//  above the line and invites "wait, what?".
//
//  THREE KINDS OF ANSWER, picked from the curve:
//    season     it has a real off season, so it's answered with dates: where the
//               curve is above half ("most days") and the typical first and last
//               day ("possible").
//    yearRound  it can happen any time, so it's answered with when it's likeliest.
//    scoped     the question names its own dates, so it's answered with whether
//               those dates usually do it: "4 of 4 Septembers had rain".
//
//  The honesty rule comes from `DayQuery`: a day that can't settle the question is
//  neither a yes nor a no, it's left out of both counts.
//

import Foundation

public struct WhenInTheYear: Equatable, Sendable {

    public enum Kind: String, Equatable, Sendable {
        case season, yearRound, scoped
    }

    /// One season's version of the question.
    ///
    /// A season is a year starting in the axis's first month, so with an August
    /// axis "2024" is August 2024 through July 2025. Labelled "Aug ’24 – Jul ’25"
    /// whenever it crosses New Year.
    public struct Season: Equatable, Sendable, Identifiable {
        public var year: Int
        public var label: String
        /// Per drawn slot: matched and answered days in the fortnight around it.
        /// What the hover shows, year by year, under the pooled share.
        public var window: [WindowCount]
        public var id: Int { year }
    }

    public struct WindowCount: Equatable, Sendable {
        public var matched: Int
        public var answered: Int
    }

    /// A season and the slot it did something on.
    public struct SeasonDate: Equatable, Sendable {
        public var season: Int
        public var slot: Int
        public var day: String
    }

    /// The measure itself, on the same date axis — so "below 50" can show
    /// whether it was 49 or 30.
    public struct Readings: Equatable, Sendable {
        public var measure: Measure
        /// The line the question draws, where it has one.
        public var threshold: Double?
        /// Average and the middle 80% across every season, per slot. Empty for a
        /// measure that adds up (rain, lightning): the average of a daily rain
        /// total describes no day that happened.
        public var mean: [Double?]
        public var low: [Double?]
        public var high: [Double?]
        /// This season's and last season's daily readings.
        public var current: [Double?]
        public var previous: [Double?]
    }

    /// One bar of the year-by-year view.
    public struct Count: Equatable, Sendable, Identifiable {
        public var label: String
        public var matched: Int
        /// Days that could settle the question.
        public var answerable: Int
        /// Days the season (or scope) has.
        public var span: Int
        /// The record covers it from end to end.
        public var isComplete: Bool
        /// Matches up to today's date in the season — what a running season is
        /// compared against. Nil for a scoped question, where the scope is the unit.
        public var byToday: Int?
        public var id: String { label }
    }

    /// A single fact worth naming: the earliest, the hottest, the most in a season.
    public struct Record: Equatable, Sendable, Identifiable {
        public var label: String
        /// The day it happened, when it was one day. Opens that day.
        public var day: String?
        /// The number, where the record is a number. A date record has none — the
        /// date IS the record.
        public var value: String?
        public var note: String?
        public var id: String { label }
    }

    public var kind: Kind
    /// 1–12. The month the axis (and every season) starts in.
    public var startMonth: Int
    /// The first slot drawn, as a day of the axis. Slots below count from here.
    public var offset: Int
    /// Share of nearby days that matched, per drawn slot. Nil where nothing could answer.
    public var share: [Double?]
    public var seasons: [Season]
    /// First and last matching day of each season the record covers at that end.
    public var firsts: [SeasonDate]
    public var lasts: [SeasonDate]
    /// Where the curve is above half: "most days". Slots.
    public var inner: ClosedRange<Int>?
    /// The typical (median) first and last day: "possible". Slots.
    public var outer: ClosedRange<Int>?
    /// Where the curve is highest.
    public var peak: Int
    public var readings: Readings?
    /// This season, its matches so far, and today's slot in it.
    public var current: Season?
    public var currentHits: [Int]
    public var through: Int
    public var previous: Season?
    public var previousHits: [Int]
    public var counts: [Count]
    /// Every matching day inside the question's dates, oldest first.
    public var matchedDays: [String]
    /// "days", or "nights" when the question is only about lows.
    public var noun: String
    public var records: [Record]
    /// The longest run of consecutive matches, and how many runs reached three.
    public var longest: Streak?
    public var runsOfThree: Int
    /// The question's dates, as slots, when it has them.
    public var scope: ClosedRange<Int>?

    public var lastEver: String? { matchedDays.last }
    public var slotCount: Int { share.count }

    // MARK: The axis

    /// The `MM-dd` a drawn slot stands for.
    public func monthDay(_ slot: Int) -> String {
        YearAxis.monthDay(of: WhenInTheYear.axisStart(startMonth) + offset + slot)
    }

    /// A drawn slot's date in one season, or nil where that season has no such
    /// date (Feb 29 in most years).
    public func day(_ slot: Int, season: Int) -> String? {
        WhenInTheYear.day(monthDay(slot), season: season, startMonth: startMonth)
    }

    /// Where a month starts on the drawn axis, for gridlines and labels. Months
    /// cut off by the crop are left out.
    public var monthMarks: [(slot: Int, name: String)] {
        (0..<12).compactMap { k in
            let month = (startMonth - 1 + k) % 12
            let slot = WhenInTheYear.slot(ofAxisDay: YearAxis.monthStart[month], startMonth: startMonth) - offset
            guard slot >= 0, slot < slotCount else { return nil }
            return (slot, YearAxis.months[month].name)
        }
    }

    static func axisStart(_ startMonth: Int) -> Int { YearAxis.monthStart[startMonth - 1] }

    /// A day of the calendar axis (0 = Jan 1) as a slot on an axis starting in `startMonth`.
    static func slot(ofAxisDay day: Int, startMonth: Int) -> Int {
        YearAxis.wrap(day - axisStart(startMonth))
    }

    static func slot(of monthDay: String, startMonth: Int) -> Int? {
        YearAxis.day(of: monthDay).map { slot(ofAxisDay: $0, startMonth: startMonth) }
    }

    /// The real date a `MM-dd` falls on inside the season that opened in `season`.
    static func day(_ monthDay: String, season: Int, startMonth: Int) -> String? {
        guard let month = Int(monthDay.prefix(2)) else { return nil }
        let year = month >= startMonth ? season : season + 1
        return WeatherPeriod.resolve(monthDay, inYear: year)
    }

    /// The season a day belongs to.
    static func season(of day: String, startMonth: Int) -> Int? {
        guard let year = DayKey.year(of: day), let month = Int(day.dropFirst(5).prefix(2)) else { return nil }
        return month >= startMonth ? year : year - 1
    }

    /// "2025", or "Apr ’25 – Mar ’26" for a season that crosses New Year. Never "2025–26": that reads
    /// as all of 2025, which has already had the freezes a "2026–27, none yet" seems to deny.
    public static func label(season: Int, startMonth: Int) -> String {
        guard startMonth != 1 else { return String(season) }
        let opens = YearAxis.months[startMonth - 1].name, closes = YearAxis.months[(startMonth + 10) % 12].name
        return "\(opens) ’\(String(format: "%02d", season % 100)) – \(closes) ’\(String(format: "%02d", (season + 1) % 100))"
    }
}

// MARK: - Working it out

extension Climatology {

    /// The question as a place in the year.
    ///
    /// Reads the query's conditions and its DATE scope. Its year pin and its
    /// first/last rule are deliberately ignored: "when is it hot" is a question
    /// about every year, and a year pinned in the builder is answered by the
    /// page against this, not by narrowing this to one year's four dots.
    public func whenInTheYear(_ query: DayQuery) -> WhenInTheYear? {
        guard !query.isEmpty, let firstDay = earliestDay, let lastDay = latestDay else { return nil }
        var question = query
        question.years = .all
        question.sequence = nil
        question.aggregate = nil

        // Every day's answer, once.
        var verdicts: [String: Bool] = [:]
        for record in all {
            if let answer = verdict(question, on: record) { verdicts[record.day] = answer }
        }
        guard !verdicts.isEmpty else { return nil }

        let startMonth = WhenInTheYear.startMonth(for: question, verdicts: verdicts)
        let slots = YearAxis.dayCount

        // The seasons the record touches.
        let firstSeason = WhenInTheYear.season(of: firstDay, startMonth: startMonth) ?? 0
        let lastSeason = WhenInTheYear.season(of: lastDay, startMonth: startMonth) ?? 0
        let seasonYears = Array(firstSeason...max(firstSeason, lastSeason))

        // grid[season][slot]: nil where the day is missing or can't answer.
        var grid: [Int: [Bool?]] = [:]
        var days: [Int: [String?]] = [:]
        for season in seasonYears {
            var row = [Bool?](repeating: nil, count: slots)
            var keys = [String?](repeating: nil, count: slots)
            for slot in 0..<slots {
                let monthDay = YearAxis.monthDay(of: WhenInTheYear.axisStart(startMonth) + slot)
                guard let key = WhenInTheYear.day(monthDay, season: season, startMonth: startMonth) else { continue }
                keys[slot] = key
                row[slot] = verdicts[key]
            }
            grid[season] = row
            days[season] = keys
        }

        // How often: the fortnight around each slot, every season pooled.
        var share = [Double?](repeating: nil, count: slots)
        var windows: [Int: [WhenInTheYear.WindowCount]] = [:]
        for season in seasonYears {
            let row = grid[season] ?? []
            windows[season] = (0..<slots).map { slot in
                var matched = 0, answered = 0
                for j in max(0, slot - 7)...min(slots - 1, slot + 7) {
                    guard let answer = row[j] else { continue }
                    answered += 1
                    if answer { matched += 1 }
                }
                return WhenInTheYear.WindowCount(matched: matched, answered: answered)
            }
        }
        for slot in 0..<slots {
            let matched = seasonYears.reduce(0) { $0 + (windows[$1]?[slot].matched ?? 0) }
            let answered = seasonYears.reduce(0) { $0 + (windows[$1]?[slot].answered ?? 0) }
            if answered > 0 { share[slot] = Double(matched) / Double(answered) }
        }

        // First and last each season — only where the record reaches that end of
        // it. 2022's first 100° day happened in July, before the archive opened.
        var firsts: [WhenInTheYear.SeasonDate] = []
        var lasts: [WhenInTheYear.SeasonDate] = []
        var hits: [Int: [Int]] = [:]
        for season in seasonYears {
            let row = grid[season] ?? []
            let found = row.indices.filter { row[$0] == true }
            hits[season] = found
            guard let first = found.first, let last = found.last,
                  let opens = days[season]?.compactMap({ $0 }).first,
                  let closes = days[season]?.compactMap({ $0 }).last else { continue }
            if opens >= firstDay, let key = days[season]?[first] ?? nil {
                firsts.append(.init(season: season, slot: first, day: key))
            }
            if closes <= lastDay, let key = days[season]?[last] ?? nil {
                lasts.append(.init(season: season, slot: last, day: key))
            }
        }

        // The question's own dates, as slots.
        var scopeSlots: ClosedRange<Int>?
        if let period = question.scope, let first = period.monthDays.first, let last = period.monthDays.last,
           let a = WhenInTheYear.slot(of: first, startMonth: startMonth),
           let b = WhenInTheYear.slot(of: last, startMonth: startMonth), a <= b {
            scopeSlots = a...b
        }

        let kind: WhenInTheYear.Kind = question.scope != nil ? .scoped
            : WhenInTheYear.longestQuiet(share) >= 45 ? .season : .yearRound

        let currentSeason = seasonYears.last ?? 0
        let previousSeason = seasonYears.count > 1 ? seasonYears[seasonYears.count - 2] : nil
        let todaySlot = WhenInTheYear.slot(of: DayKey.monthDay(of: lastDay), startMonth: startMonth) ?? 0

        // The span drawn: the season and three weeks either side, or the scope and three weeks.
        var lower = 0, upper = slots - 1
        switch kind {
        case .season:
            let starts = firsts.map(\.slot) + [hits[currentSeason]?.first, previousSeason.flatMap { hits[$0]?.first }].compactMap { $0 }
            let ends = lasts.map(\.slot) + [hits[currentSeason]?.last, previousSeason.flatMap { hits[$0]?.last }].compactMap { $0 }
            if let a = starts.min(), let b = ends.max(), a < b {
                lower = max(0, a - 21); upper = min(slots - 1, b + 21)
            }
        case .scoped:
            if let scopeSlots {
                lower = max(0, scopeSlots.lowerBound - 21); upper = min(slots - 1, scopeSlots.upperBound + 21)
            }
        case .yearRound:
            break
        }
        let drawn = lower...upper
        func crop<T>(_ values: [T]) -> [T] { Array(values[drawn]) }
        func shift(_ slot: Int) -> Int { slot - lower }

        // The answer pairs, read off the whole curve and then placed on the drawn span.
        var inner: ClosedRange<Int>?
        var outer: ClosedRange<Int>?
        if kind == .season {
            var up: Int?, down: Int?
            for slot in 1..<slots {
                guard let before = share[slot - 1], let now = share[slot] else { continue }
                if up == nil, before < 0.5, now >= 0.5 { up = slot }
                if before >= 0.5, now < 0.5 { down = slot }
            }
            if let up, let down, down > up { inner = shift(up)...shift(down) }
            if let first = WhenInTheYear.median(firsts.map(\.slot)),
               let last = WhenInTheYear.median(lasts.map(\.slot)), first <= last {
                outer = shift(first)...shift(last)
            }
        }
        var peak = lower
        for slot in drawn where (share[slot] ?? -1) > (share[peak] ?? -1) { peak = slot }

        // Inside the question's dates: the matches every other number counts.
        let matchedDays = verdicts.keys
            .filter { verdicts[$0] == true && (question.scope?.contains(monthDay: DayKey.monthDay(of: $0)) ?? true) }
            .sorted()

        let seasonsOut = seasonYears.map { season in
            WhenInTheYear.Season(year: season, label: WhenInTheYear.label(season: season, startMonth: startMonth),
                                 window: crop(windows[season] ?? []))
        }
        let counts = yearCounts(question, verdicts: verdicts, grid: grid, seasons: seasonYears,
                                startMonth: startMonth, firstDay: firstDay, lastDay: lastDay, todaySlot: todaySlot)

        var shape = WhenInTheYear(
            kind: kind, startMonth: startMonth, offset: lower,
            share: crop(share), seasons: seasonsOut,
            firsts: firsts.filter { drawn.contains($0.slot) }.map { .init(season: $0.season, slot: shift($0.slot), day: $0.day) },
            lasts: lasts.filter { drawn.contains($0.slot) }.map { .init(season: $0.season, slot: shift($0.slot), day: $0.day) },
            inner: inner, outer: outer, peak: shift(peak),
            readings: nil,
            current: seasonsOut.last,
            currentHits: (hits[currentSeason] ?? []).filter(drawn.contains).map(shift),
            through: shift(todaySlot),
            previous: seasonsOut.count > 1 ? seasonsOut[seasonsOut.count - 2] : nil,
            previousHits: previousSeason.map { (hits[$0] ?? []).filter(drawn.contains).map(shift) } ?? [],
            counts: counts,
            matchedDays: matchedDays,
            noun: question.conditions.allSatisfy { $0.measure == .low } && !question.conditions.isEmpty ? "nights" : "days",
            records: [],
            longest: nil, runsOfThree: 0,
            scope: scopeSlots.map { shift(max(lower, $0.lowerBound))...shift(min(upper, $0.upperBound)) })

        shape.readings = readings(question, days: days, seasons: seasonYears, current: currentSeason,
                                  previous: previousSeason, drawn: drawn)
        let runs = DayKey.runs(of: matchedDays).map { run in
            Streak(length: (DayKey.distance(from: run.first, to: run.last) ?? 0) + 1,
                   firstDay: run.first, lastDay: run.last, endedAtGap: false)
        }
        shape.longest = runs.max { $0.length < $1.length }
        shape.runsOfThree = runs.filter { $0.length >= 3 }.count
        shape.records = records(question, shape: shape, allFirsts: firsts, allLasts: lasts)
        return shape
    }

    // MARK: Year by year

    private func yearCounts(_ question: DayQuery, verdicts: [String: Bool], grid: [Int: [Bool?]],
                            seasons: [Int], startMonth: Int, firstDay: String, lastDay: String,
                            todaySlot: Int) -> [WhenInTheYear.Count] {
        var out: [WhenInTheYear.Count] = []
        if let period = question.scope {
            // A scoped question's unit is the scope: four Septembers, not four seasons.
            let years = (DayKey.year(of: firstDay) ?? 0)...(DayKey.year(of: lastDay) ?? 0)
            for year in years {
                guard let bounds = period.bounds(inYear: year), bounds.end >= firstDay, bounds.start <= lastDay
                else { continue }
                var matched = 0, answered = 0
                var cursor: String? = bounds.start
                while let key = cursor, key <= bounds.end {
                    if let answer = verdicts[key] { answered += 1; if answer { matched += 1 } }
                    cursor = DayKey.next(key)
                }
                guard answered > 0 else { continue }
                out.append(.init(label: String(year), matched: matched, answerable: answered,
                                 span: (DayKey.distance(from: bounds.start, to: bounds.end) ?? 0) + 1,
                                 isComplete: bounds.start >= firstDay && bounds.end <= lastDay, byToday: nil))
            }
            return out
        }
        for season in seasons {
            let row = grid[season] ?? []
            let answered = row.compactMap { $0 }.count
            guard answered > 0 else { continue }
            let opens = WhenInTheYear.day(YearAxis.monthDay(of: WhenInTheYear.axisStart(startMonth)), season: season, startMonth: startMonth) ?? ""
            let closes = WhenInTheYear.day(YearAxis.monthDay(of: WhenInTheYear.axisStart(startMonth) + YearAxis.dayCount - 1),
                                           season: season, startMonth: startMonth)
                ?? WhenInTheYear.day(YearAxis.monthDay(of: WhenInTheYear.axisStart(startMonth) + YearAxis.dayCount - 2),
                                     season: season, startMonth: startMonth) ?? ""
            out.append(.init(label: WhenInTheYear.label(season: season, startMonth: startMonth),
                             matched: row.filter { $0 == true }.count,
                             answerable: answered,
                             span: (DayKey.distance(from: opens, to: closes) ?? 364) + 1,
                             isComplete: opens >= firstDay && closes <= lastDay,
                             byToday: row.prefix(todaySlot + 1).filter { $0 == true }.count))
        }
        return out
    }

    // MARK: Readings

    /// Only when the question is about one measure — "lightning and rain" has no
    /// single number to draw.
    private func readings(_ question: DayQuery, days: [Int: [String?]], seasons: [Int], current: Int,
                          previous: Int?, drawn: ClosedRange<Int>) -> WhenInTheYear.Readings? {
        guard let measure = question.conditions.first?.measure,
              question.conditions.allSatisfy({ $0.measure == measure }) else { return nil }
        func value(_ key: String?) -> Double? { key.flatMap { record(on: $0)?[keyPath: measure.path] } }
        func row(_ season: Int?) -> [Double?] {
            guard let season, let keys = days[season] else { return Array(repeating: nil, count: drawn.count) }
            return drawn.map { value(keys[$0]) }
        }

        var mean: [Double?] = [], low: [Double?] = [], high: [Double?] = []
        if !measure.accumulates {
            // A week around each date, every season, only days watched throughout.
            for slot in drawn {
                var pool: [Double] = []
                for season in seasons {
                    guard let keys = days[season] else { continue }
                    for j in max(0, slot - 3)...min(keys.count - 1, slot + 3) {
                        guard let key = keys[j], let record = record(on: key), record.isReliable,
                              let v = record[keyPath: measure.path] else { continue }
                        pool.append(v)
                    }
                }
                guard pool.count >= 4 else { mean.append(nil); low.append(nil); high.append(nil); continue }
                pool.sort()
                mean.append(pool.reduce(0, +) / Double(pool.count))
                low.append(WhenInTheYear.percentile(pool, 0.1))
                high.append(WhenInTheYear.percentile(pool, 0.9))
            }
        }
        let threshold: Double? = question.conditions.compactMap { condition -> Double? in
            switch condition.test {
            case .atOrAbove(let v), .below(let v), .atOrBelow(let v): return v
            case .between, .inBand: return nil
            }
        }.first
        return .init(measure: measure, threshold: threshold, mean: mean, low: low, high: high,
                     current: row(current), previous: row(previous))
    }

    // MARK: Records

    private func records(_ question: DayQuery, shape: WhenInTheYear,
                         allFirsts: [WhenInTheYear.SeasonDate],
                         allLasts: [WhenInTheYear.SeasonDate]) -> [WhenInTheYear.Record] {
        var out: [WhenInTheYear.Record] = []
        let matched = shape.matchedDays.compactMap { record(on: $0) }
        guard !matched.isEmpty else { return [] }
        let scopeName = question.scope?.name ?? ""

        if shape.kind == .season {
            if let first = allFirsts.min(by: { $0.slot < $1.slot }) {
                out.append(.init(label: "Earliest on record", day: first.day))
            }
            if let last = allLasts.max(by: { $0.slot < $1.slot }) {
                out.append(.init(label: "Latest on record", day: last.day))
            }
        }

        // The most extreme day for each measure asked about, in the direction asked.
        var seen = Set<Measure>()
        for condition in question.conditions where seen.insert(condition.measure).inserted {
            let measure = condition.measure
            let highest: Bool
            switch condition.test {
            case .atOrAbove: highest = true
            case .below, .atOrBelow: highest = false
            case .between, .inBand: highest = measure.reading != .ceiling
            }
            // "The lowest rain on a day below 0.1 inches" is zero, many times over.
            if measure.accumulates && !highest { continue }
            let ranked = matched.compactMap { r in r[keyPath: measure.path].map { (r.day, $0) } }
            guard let best = highest ? ranked.max(by: { $0.1 < $1.1 }) : ranked.min(by: { $0.1 < $1.1 }) else { continue }
            var label = WhenInTheYear.extremeLabel(measure, highest: highest)
            if !scopeName.isEmpty { label += " in \(scopeName)" }
            out.append(.init(label: label, day: best.0, value: WhenInTheYear.format(measure, best.1)))
        }

        let onlyRain = question.conditions.allSatisfy { $0.measure == .rain }
        if onlyRain, question.scope == nil {
            // A week, because a wet spell is how a flood actually arrives.
            var best: (end: String, total: Double)?
            var window: [Double] = []
            var cursor = earliestDay
            while let key = cursor, let last = latestDay, key <= last {
                window.append(record(on: key)?.precipTotal ?? 0)
                if window.count > 7 { window.removeFirst() }
                let total = window.reduce(0, +)
                if total > (best?.total ?? 0) { best = (key, total) }
                cursor = DayKey.next(key)
            }
            if let best, let start = DayKey.step(best.end, by: -6) {
                out.append(.init(label: "Wettest week", day: start, value: Measure.rain.format(best.total),
                                 note: "through \(WeatherAlmanac.dayLabel(best.end))"))
            }
        }

        if let period = question.scope, onlyRain {
            // Totals per complete instance of the scope: the wettest and driest September.
            let totals = shape.counts.filter(\.isComplete).compactMap { count -> (String, Double)? in
                guard let year = Int(count.label), let bounds = period.bounds(inYear: year) else { return nil }
                return (count.label, precipTotal(from: bounds.start, through: bounds.end).total)
            }
            if let wettest = totals.max(by: { $0.1 < $1.1 }), let driest = totals.min(by: { $0.1 < $1.1 }), totals.count > 1 {
                out.append(.init(label: "Wettest \(period.name)", value: Measure.rain.format(wettest.1), note: wettest.0))
                out.append(.init(label: "Driest \(period.name)", value: Measure.rain.format(driest.1), note: driest.0))
            }
        } else if let most = shape.counts.max(by: { $0.matched < $1.matched }), most.matched > 0 {
            let unit = question.scope.map { "a \($0.name)" } ?? (shape.startMonth == 1 ? "a year" : "a season")
            out.append(.init(label: "Most in \(unit)", value: "\(most.matched) \(shape.noun)",
                             note: most.label + (most.isComplete ? "" : ", so far")))
        }
        return out
    }
}

// MARK: - Helpers

extension WhenInTheYear {

    /// The month the curve is quietest in, so a season is drawn whole. A scoped
    /// question is centred on its dates instead.
    static func startMonth(for question: DayQuery, verdicts: [String: Bool]) -> Int {
        if let scope = question.scope, let first = scope.monthDays.first, let last = scope.monthDays.last,
           let a = YearAxis.day(of: first), let b = YearAxis.day(of: last) {
            let middle = a <= b ? (a + b) / 2 : YearAxis.wrap((a + b + YearAxis.dayCount) / 2)
            return YearAxis.monthAndDay(of: middle + YearAxis.dayCount / 2).month + 1
        }
        var matched = [Int](repeating: 0, count: 13), answered = [Int](repeating: 0, count: 13)
        for (key, answer) in verdicts {
            guard let month = Int(key.dropFirst(5).prefix(2)) else { continue }
            answered[month] += 1
            if answer { matched[month] += 1 }
        }
        let rates = (1...12).map { month in
            (month, answered[month] > 0 ? Double(matched[month]) / Double(answered[month]) : 2)
        }
        return rates.min { $0.1 < $1.1 }?.0 ?? 1
    }

    /// The longest stretch where the curve sits at essentially nothing. Forty-five
    /// days of it is an off season.
    static func longestQuiet(_ share: [Double?]) -> Int {
        var best = 0, run = 0
        for value in share {
            run = (value.map { $0 < 0.02 } ?? false) ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }

    static func median(_ values: [Int]) -> Int? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : Int((Double(sorted[n / 2 - 1] + sorted[n / 2]) / 2).rounded())
    }

    /// Linear between ranks, the usual definition.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let rank = p * Double(sorted.count - 1)
        let below = Int(rank.rounded(.down)), above = min(sorted.count - 1, below + 1)
        return sorted[below] + (sorted[above] - sorted[below]) * (rank - Double(below))
    }

    static func extremeLabel(_ measure: Measure, highest: Bool) -> String {
        switch (measure, highest) {
        case (.high, true): return "Hottest day"
        case (.high, false): return "Coldest day"
        case (.low, true): return "Warmest night"
        case (.low, false): return "Coldest night"
        case (.rain, _): return "Wettest day"
        case (.lightning, _): return "Most lightning"
        case (.gust, true): return "Strongest gust"
        case (.dewPoint, true), (.dewPointPeak, true): return "Muggiest day"
        case (.dewPoint, false), (.dewPointPeak, false): return "Driest air"
        default: return highest ? "Highest \(measure.name.lowercased())" : "Lowest \(measure.name.lowercased())"
        }
    }

    /// Lightning reads as a count with its thousands separated: "7,070 strikes".
    static func format(_ measure: Measure, _ value: Double) -> String {
        measure == .lightning ? "\(Int(value).formatted()) strikes" : measure.format(value)
    }
}

extension WhenInTheYear {
    /// The middle of a set of season dates, as a slot.
    public enum Median {
        public static func of(_ dates: [SeasonDate]) -> Int? { WhenInTheYear.median(dates.map(\.slot)) }
    }
}
