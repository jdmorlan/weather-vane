//
//  StretchStory.swift  (WeatherKit)
//
//  WHAT HAPPENED IN ONE STRETCH — History's sentence and its list of events.
//
//  `PeriodSummary` says how a September compared, in averages. That is not
//  what someone opening "September 2023" wants first; they want what it DID:
//  the fronts, the big rain, the hot run. Each of those is a pattern in the
//  daily record with a physical reason behind it, and the reason is stated in
//  the station's own numbers so it can be checked rather than trusted.
//
//  A FRONT is drier, denser air arriving: the dew point falls (the moisture
//  left with the old air mass) while the pressure rises (the new air is
//  heavier). Either alone is weak evidence — a dry afternoon mixes the dew
//  point down, a ridge raises pressure — together, over a day or two, they are
//  the signature. Found at daily resolution here, so the day is right and the
//  hour is left to the day view.
//
//  A STORM-COOLED day is the impostor: the high crashes under heavy rain, but
//  the dew point doesn't move, because the air mass never changed — the rain
//  cooled the air it fell through. On a chart of highs alone the two look the
//  same, which is exactly why the event list says which one it was.
//

import Foundation

public struct StoryDay: Equatable, Sendable, Identifiable {
    public var index: Int
    public var day: String
    public var high: Double?
    public var low: Double?
    public var precip: Double?
    public var normalHigh: Double?
    public var normalLow: Double?
    public var isReliable: Bool
    /// The day's muggiest reading and strongest gust, with their normals —
    /// for History's dew point and gust cards.
    public var dewPoint: Double? = nil
    public var gust: Double? = nil
    public var normalDewPoint: Double? = nil
    public var normalGust: Double? = nil
    /// The day's rain is from the person's own gauge, not the station.
    public var rainFromGauge: Bool = false
    public var id: String { day }

    public func value(_ measure: DailyMeasure) -> Double? {
        switch measure {
        case .high: return high
        case .low: return low
        case .dewPoint: return dewPoint
        case .gust: return gust
        }
    }

    public func normal(_ measure: DailyMeasure) -> Double? {
        switch measure {
        case .high: return normalHigh
        case .low: return normalLow
        case .dewPoint: return normalDewPoint
        case .gust: return normalGust
        }
    }

    /// How far the day ran from its date's normal, in the measure's units.
    public func departure(_ measure: DailyMeasure) -> Double? {
        guard let v = value(measure), let n = normal(measure) else { return nil }
        return v - n
    }
}

public struct StoryEvent: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case front, humidReturn, rain, warmSpell, coolSpell, gust, hottest, coldest
    }
    public var kind: Kind
    /// First day of the event — where a click lands.
    public var day: String
    public var end: String?
    public var title: String
    /// The numbers that make it this kind of event, in plain terms.
    public var detail: String
    /// For ranking within a kind — inches, degrees, mph.
    public var size: Double

    public var id: String { "\(kind.rawValue)·\(day)" }

    public var symbol: String {
        switch kind {
        case .front: return "wind"
        case .humidReturn: return "humidity.fill"
        case .rain: return "cloud.heavyrain.fill"
        case .warmSpell: return "thermometer.sun.fill"
        case .coolSpell: return "thermometer.snowflake"
        case .gust: return "tornado"
        case .hottest: return "flame"
        case .coldest: return "snowflake"
        }
    }
}

public struct StretchStory: Equatable, Sendable {
    /// "September 2023", "Fall 2024", "2025".
    public var title: String
    public var days: [StoryDay]
    /// The stretch's last calendar day, whether or not it has happened yet —
    /// `days` stops at the latest day held, so a running month's charts use
    /// this to keep their full width and leave the days to come empty.
    public var lastDay: String
    /// In date order.
    public var events: [StoryEvent]
    /// Mean of (high − normal high) over the days held.
    public var departure: Double?
    public var rain: Double
    public var daysHeld: Int

    public var fronts: [StoryEvent] { events.filter { $0.kind == .front } }
}

extension Climatology {

    /// The story of one instance of `period` — the one opening in `year` —
    /// through `latestDay` at most.
    public func story(_ period: WeatherPeriod, year: Int, title: String,
                      latestDay last: String? = nil) -> StretchStory? {
        guard let bounds = period.bounds(inYear: year) else { return nil }
        let end = min(bounds.end, last ?? latestDay ?? bounds.end)
        var days: [StoryDay] = []
        var records: [DailyRecord?] = []
        var key = bounds.start
        var index = 0
        while key <= end {
            let record = record(on: key)
            let normal = normal(monthDay: DayKey.monthDay(of: key))
            days.append(StoryDay(index: index, day: key, high: record?.tempMax, low: record?.tempMin,
                                 precip: record?.precipTotal,
                                 normalHigh: normal.high, normalLow: normal.low,
                                 isReliable: record?.isReliable ?? false,
                                 dewPoint: record?.dewPointMax, gust: record?.windGustMax,
                                 normalDewPoint: normal.dewPointPeak, normalGust: normal.gust,
                                 rainFromGauge: record?.precipFromGauge ?? false))
            records.append(record)
            guard let next = DayKey.step(key, by: 1) else { break }
            key = next
            index += 1
        }
        guard !days.isEmpty else { return nil }

        var events = Self.fronts(records) + Self.humidReturns(records)
        events += Self.rainEvents(records)
        events += Self.spells(days)
        events += Self.gusts(records)
        events += extremes(days)
        events.sort { $0.day < $1.day || ($0.day == $1.day && $0.kind.rawValue < $1.kind.rawValue) }

        let departures = days.compactMap { day -> Double? in
            guard day.isReliable, let high = day.high, let normal = day.normalHigh else { return nil }
            return high - normal
        }
        let held = records.compactMap { $0 }
        return StretchStory(title: title, days: days, lastDay: bounds.end, events: events,
                            departure: departures.isEmpty ? nil
                                : departures.reduce(0, +) / Double(departures.count),
                            rain: held.reduce(0) { $0 + max(0, $1.precipTotal ?? 0) },
                            daysHeld: held.count)
    }

    // MARK: Fronts

    /// Runs of days whose mean dew point fell, where at least one day fell 8°
    /// or more and the pressure rose across the run. Consecutive days merge: a
    /// front that arrives late in the evening splits its drop across two dates.
    static func fronts(_ records: [DailyRecord?]) -> [StoryEvent] {
        airMassChanges(records, falling: true).compactMap { run in
            let before = run.before, after = run.after
            guard let dewBefore = before.dewPointMean, let dewAfter = after.dewPointMean,
                  run.pressureRise >= 0.05 else { return nil }
            var detail = "Dew point fell \(deg(dewBefore)) → \(deg(dewAfter)) and pressure rose "
                + String(format: "%.2f inHg", run.pressureRise)
            if let hi0 = before.tempMax, let hi1 = after.tempMax, hi0 - hi1 >= 3 {
                detail += "; highs \(deg(hi0)) → \(deg(hi1))"
            }
            detail += " — drier, heavier air replacing the old air mass."
            return StoryEvent(kind: .front, day: run.first.day, end: run.last.day == run.first.day ? nil : run.last.day,
                              title: "A front came through", detail: detail,
                              size: dewBefore - dewAfter)
        }
    }

    /// The other direction: moisture back after a front — the dew point
    /// climbing 8°+ with the pressure easing.
    static func humidReturns(_ records: [DailyRecord?]) -> [StoryEvent] {
        airMassChanges(records, falling: false).compactMap { run in
            guard let dewBefore = run.before.dewPointMean, let dewAfter = run.after.dewPointMean,
                  run.pressureRise <= -0.03 else { return nil }
            return StoryEvent(kind: .humidReturn, day: run.first.day,
                              end: run.last.day == run.first.day ? nil : run.last.day,
                              title: "Humid air came back",
                              detail: "Dew point rose \(deg(dewBefore)) → \(deg(dewAfter)) as the pressure eased "
                                  + String(format: "%.2f inHg", -run.pressureRise) + ".",
                              size: dewAfter - dewBefore)
        }
    }

    private struct AirMassRun {
        var before: DailyRecord
        var first: DailyRecord
        var last: DailyRecord
        var after: DailyRecord { last }
        /// Highest pressure in the run minus the lowest from the day before
        /// through the run — so a dip ahead of the front doesn't cancel the
        /// rise behind it. Negative for a falling run.
        var pressureRise: Double
    }

    /// Chained over days the station saw at least a fifth of, and across a
    /// single missing day. NOT the 80% reliability gate the statistics use: a
    /// front often arrives with the storms that knock the station offline, and
    /// October 28–30, 2023 — the sharpest front in the record, 70° dew point to
    /// 30° — was 90%, 21% and 58% watched. A mean dew point over a few hours is
    /// still plainly 40° and not 70°.
    private static func airMassChanges(_ records: [DailyRecord?], falling: Bool) -> [AirMassRun] {
        let usable = records.compactMap { $0 }.filter { $0.coverage >= 0.2 && $0.dewPointMean != nil }
        func change(_ a: DailyRecord, _ b: DailyRecord) -> Double? {
            guard let x = a.dewPointMean, let y = b.dewPointMean,
                  let gap = DayKey.step(a.day, by: 2), b.day <= gap else { return nil }
            return falling ? x - y : y - x
        }
        var runs: [AirMassRun] = []
        var i = 1
        while i < usable.count {
            let a = usable[i - 1], b = usable[i]
            guard let step = change(a, b), step >= 5 else { i += 1; continue }
            var members = [b]
            var biggest = step
            var j = i + 1
            while j < usable.count, let more = change(usable[j - 1], usable[j]), more >= 5 {
                members.append(usable[j]); biggest = max(biggest, more); j += 1
            }
            if biggest >= 8 {
                let pressures = ([a] + members).compactMap(\.pressureMean)
                let rise: Double
                if falling {
                    rise = (members.compactMap(\.pressureMean).max() ?? 0) - (pressures.min() ?? 0)
                } else {
                    rise = (members.compactMap(\.pressureMean).min() ?? 0) - (pressures.max() ?? 0)
                }
                if !pressures.isEmpty {
                    runs.append(AirMassRun(before: a, first: members[0], last: members[members.count - 1],
                                           pressureRise: rise))
                }
            }
            i = j
        }
        return runs
    }

    // MARK: Rain

    /// Runs of wet days holding a quarter inch or more. A run whose first day
    /// knocked the high down 8°+ with the dew point holding is said to be what
    /// it was — rain-cooled air, not a change of air mass.
    static func rainEvents(_ records: [DailyRecord?]) -> [StoryEvent] {
        var events: [StoryEvent] = []
        var i = 0
        while i < records.count {
            guard let r = records[i], (r.precipTotal ?? 0) >= 0.01 else { i += 1; continue }
            var run = [r]
            var j = i + 1
            while j < records.count, let next = records[j], (next.precipTotal ?? 0) >= 0.01 {
                run.append(next); j += 1
            }
            let total = run.reduce(0) { $0 + ($1.precipTotal ?? 0) }
            if total >= 0.25 {
                let strikes = run.reduce(0) { $0 + ($1.strikeCount ?? 0) }
                let wettest = run.max { ($0.precipTotal ?? 0) < ($1.precipTotal ?? 0) }!
                var detail = run.count == 1 ? "" : "Most on \(WeatherAlmanac.dayLabel(wettest.day)) (\(inches(wettest.precipTotal ?? 0))). "
                if strikes >= 20 {
                    detail += "Thunderstorms — \(strikes.formatted()) lightning strikes detected. "
                }
                if i > 0, let before = records[i - 1], let hi0 = before.tempMax, let hi1 = r.tempMax,
                   hi0 - hi1 >= 8, let dew0 = before.dewPointMean, let dew1 = r.dewPointMean, abs(dew0 - dew1) < 3 {
                    detail += "Highs fell \(deg(hi0)) → \(deg(hi1)) with the dew point unchanged — rain-cooled air, not a front."
                }
                events.append(StoryEvent(kind: .rain, day: run[0].day,
                                         end: run.count == 1 ? nil : run[run.count - 1].day,
                                         title: "\(inches(total)) of rain",
                                         detail: detail.trimmingCharacters(in: .whitespaces),
                                         size: total))
            }
            i = j
        }
        return events
    }

    // MARK: Spells, gusts, extremes

    /// Three or more days in a row that stood out — 5°+ off normal, AND 5°+
    /// off the stretch's own run.
    ///
    /// The second half is what makes a spell an event. September 2026 averaged
    /// 4° warm and was above normal on 28 of its 30 days; measured against
    /// normal alone it listed two "4 days warm in a row" spells, which said
    /// nothing the month hadn't. Measured against the month, a September that
    /// warm needs 9°+ days to have a warm spell, and a cool run inside it is
    /// news. A stretch near normal is unchanged by this.
    static func spells(_ days: [StoryDay]) -> [StoryEvent] {
        let offsets = days.compactMap { d -> Double? in
            guard d.isReliable, let h = d.high, let n = d.normalHigh else { return nil }
            return h - n
        }
        let runMean = offsets.isEmpty ? 0 : offsets.reduce(0, +) / Double(offsets.count)
        var events: [StoryEvent] = []
        for warm in [true, false] {
            var run: [StoryDay] = []
            func close() {
                defer { run = [] }
                guard run.count >= 3 else { return }
                let offsets = run.compactMap { d in d.high.flatMap { h in d.normalHigh.map { h - $0 } } }
                let mean = offsets.reduce(0, +) / Double(max(1, offsets.count))
                events.append(StoryEvent(kind: warm ? .warmSpell : .coolSpell, day: run[0].day,
                                         end: run[run.count - 1].day,
                                         title: "\(run.count) days \(warm ? "warm" : "cool") in a row",
                                         detail: "Highs ran \(deg(abs(mean))) \(warm ? "above" : "below") normal on average.",
                                         size: abs(mean) * Double(run.count)))
            }
            for day in days {
                guard day.isReliable, let high = day.high, let normal = day.normalHigh else { close(); continue }
                let off = high - normal
                let stands = warm ? off >= 5 && off >= runMean + 5 : off <= -5 && off <= runMean - 5
                if stands { run.append(day) } else { close() }
            }
            close()
        }
        return events
    }

    static func gusts(_ records: [DailyRecord?]) -> [StoryEvent] {
        records.compactMap { $0 }.compactMap { r in
            guard let gust = r.windGustMax, gust >= 35 else { return nil }
            return StoryEvent(kind: .gust, day: r.day, end: nil,
                              title: "Gust to \(Int(gust.rounded())) mph",
                              detail: (r.strikeCount ?? 0) >= 20 ? "During thunderstorms." : "",
                              size: gust)
        }
    }

    /// The stretch's hottest afternoon and coldest night, each ranked against
    /// the same date in the other years on record.
    func extremes(_ days: [StoryDay]) -> [StoryEvent] {
        var events: [StoryEvent] = []
        if let hot = days.filter({ $0.isReliable && $0.high != nil }).max(by: { $0.high! < $1.high! }),
           let value = hot.high {
            let others = history(monthDay: DayKey.monthDay(of: hot.day),
                                 excludingYear: DayKey.year(of: hot.day)).compactMap(\.record.tempMax)
            events.append(StoryEvent(kind: .hottest, day: hot.day, end: nil,
                                     title: "Hottest: \(Self.deg(value))",
                                     detail: Self.rank(value, among: others, warmer: true,
                                                       date: WeatherAlmanac.dayLabel(hot.day)),
                                     size: value))
        }
        if let cold = days.filter({ $0.isReliable && $0.low != nil }).min(by: { $0.low! < $1.low! }),
           let value = cold.low {
            let others = history(monthDay: DayKey.monthDay(of: cold.day),
                                 excludingYear: DayKey.year(of: cold.day)).compactMap(\.record.tempMin)
            events.append(StoryEvent(kind: .coldest, day: cold.day, end: nil,
                                     title: "Coldest night: \(Self.deg(value))",
                                     detail: Self.rank(value, among: others, warmer: false,
                                                       date: WeatherAlmanac.dayLabel(cold.day)),
                                     size: value))
        }
        return events
    }

    static func rank(_ value: Double, among others: [Double], warmer: Bool, date: String) -> String {
        guard !others.isEmpty else { return "" }
        let beat = others.filter { warmer ? $0 > value : $0 < value }.count
        let total = others.count + 1
        let word = warmer ? "warmest" : "coldest"
        if beat == 0 { return "The \(word) \(date) of the \(total) on record." }
        return "The \(StretchComparison.ordinal(beat + 1)) \(word) \(date) of the \(total) on record."
    }

    static func deg(_ value: Double) -> String { "\(Int(value.rounded()))°" }
    static func inches(_ value: Double) -> String { String(format: "%.2f″", value) }
}

// MARK: - The sentence

extension StretchStory {

    /// "September 2023 ran 2° warm. Two fronts came through (Sep 12, Sep 24),
    /// and 3.10″ of rain fell — most of it Sep 18–19."
    public func sentence(isRunning: Bool = false) -> String {
        var parts: [String] = []
        let verb = isRunning ? "is running" : "ran"
        if let departure {
            let d = Int(departure.rounded())
            parts.append(abs(d) < 1 ? "\(title) \(verb) about normal."
                                    : "\(title) \(verb) \(abs(d))° \(d > 0 ? "warm" : "cool").")
        } else {
            parts.append("\(title).")
        }

        let fronts = self.fronts
        switch fronts.count {
        case 0:
            parts.append("No front came through.")
        case 1:
            parts.append("One front came through, on \(WeatherAlmanac.dayLabel(fronts[0].day)).")
        case 2...4:
            let dates = fronts.map { WeatherAlmanac.dayLabel($0.day) }.joined(separator: ", ")
            parts.append("\(Self.number(fronts.count)) fronts came through (\(dates)).")
        default:
            let strongest = fronts.max { $0.size < $1.size }!
            parts.append("\(fronts.count) fronts came through, the sharpest on \(WeatherAlmanac.dayLabel(strongest.day)).")
        }

        let rains = events.filter { $0.kind == .rain }
        if rain < 0.01 {
            parts.append("It didn't rain.")
        } else if let biggest = rains.max(by: { $0.size < $1.size }) {
            let when = Self.span(biggest.day, biggest.end)
            if biggest.size >= rain * 0.5 {
                parts.append("\(Climatology.inches(rain)) of rain fell, most of it \(when).")
            } else {
                let spread = rains.count == 1 ? "mostly in light showers" : "spread over \(rains.count) rains"
                parts.append("\(Climatology.inches(rain)) of rain fell, \(spread); "
                             + "the biggest was \(Climatology.inches(biggest.size)) \(biggest.end == nil ? "on" : "over") \(when).")
            }
        } else {
            parts.append("\(Climatology.inches(rain)) of rain fell, all of it in light showers.")
        }
        return parts.joined(separator: " ")
    }

    /// "Oct 27–28", "Sep 30–Oct 2", "Oct 5".
    public static func span(_ start: String, _ end: String?) -> String {
        let first = WeatherAlmanac.dayLabel(start)
        guard let end, end != start else { return first }
        let last = WeatherAlmanac.dayLabel(end)
        if start.prefix(7) == end.prefix(7), let day = Int(end.suffix(2)) { return "\(first)–\(day)" }
        return "\(first)–\(last)"
    }

    static func number(_ n: Int) -> String {
        ["zero", "One", "Two", "Three", "Four"][min(n, 4)]
    }
}
