//
//  DayOverlay.swift  (WeatherKit)
//
//  ONE DATE, HOUR BY HOUR, IN EVERY YEAR. What Compare's day draws.
//
//  The day's high and low are the archive's summary of it; the question that
//  brings someone to Compare at eight in the morning is about the HOURS — "it's
//  64° out, is that cool for an October 2 morning?" — and a daily low can't
//  answer it, because the low might have come at 6am or at midnight. The sample
//  archive holds every minute of every past October 2, so this reduces each to
//  hourly temperatures and lines them up by clock hour.
//
//  Today is the subject while it is today: measured up to now, forecast after,
//  and the two are kept apart all the way to the sentence ("the forecast peaks
//  at…"), because one is a reading and the other is a guess. On any other date
//  the newest year shown stands in for it, and everything is measured.
//

import Foundation

/// One year's version of the date, as temperature by clock hour.
public struct HourTrace: Equatable, Sendable, Identifiable {
    public var year: Int
    /// Clock hour (0–23) → mean temperature that hour.
    public var temps: [Int: Double]
    /// Hours that were measured rather than forecast. Every hour, for a past year.
    public var observed: Set<Int>

    public var id: Int { year }

    public init(year: Int, temps: [Int: Double], observed: Set<Int>? = nil) {
        self.year = year
        self.temps = temps
        self.observed = observed ?? Set(temps.keys)
    }

    /// The last hour the station measured — "now", for today.
    public var lastObserved: Int? { observed.max() }
    /// Most of the day held — a peak read off half a day is only the peak of
    /// the hours the station caught. Today counts its forecast hours.
    public var isNearlyWhole: Bool { temps.count >= 20 }
    public var isPartlyForecast: Bool { temps.keys.contains { !observed.contains($0) } }

    public var peak: (hour: Int, value: Double)? {
        temps.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
            .map { ($0.key, $0.value) }
    }

    public var trough: (hour: Int, value: Double)? {
        temps.min { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
            .map { ($0.key, $0.value) }
    }

    /// Hourly values from a day's samples, in the zone the day was kept in:
    /// the hour's mean temperature (for a high or a low), its mean dew point,
    /// or its strongest gust — the same reductions `DayStrip` makes for Now.
    public static func hourly(_ samples: [StationSample], day: String,
                              timeZone: TimeZone, measure: DailyMeasure = .high) -> [Int: Double] {
        let strip = DayStrip.build(day: day, samples: samples, forecast: [],
                                   timeZone: timeZone, sunriseHour: 7, sunsetHour: 19)
        var out: [Int: Double] = [:]
        for (hour, slice) in strip.hours.enumerated() where slice.isObserved {
            if let value = slice.value(measure) { out[hour] = value }
        }
        return out
    }
}

extension HourSlice {
    /// One hour's reading of a daily measure: temperature for a high or a low.
    public func value(_ measure: DailyMeasure) -> Double? {
        switch measure {
        case .high, .low: return temperature
        case .dewPoint: return dewPoint
        case .gust: return windGust
        }
    }
}

public struct DayOverlay: Equatable, Sendable {
    public var dateLabel: String
    /// What the hours are of. A low is temperature too, read for its trough.
    public var measure: DailyMeasure = .high
    /// Today, or the newest year shown.
    public var subject: HourTrace?
    public var isToday: Bool
    /// Every other year shown, newest first.
    public var others: [HourTrace]

    public init(dateLabel: String, subject: HourTrace?, isToday: Bool, others: [HourTrace],
                measure: DailyMeasure = .high) {
        self.measure = measure
        self.dateLabel = dateLabel
        self.subject = subject
        self.isToday = isToday
        self.others = others
    }

    /// Per clock hour: the span the other years covered, and their mean.
    public var band: [(hour: Int, low: Double, high: Double, mean: Double)] {
        (0..<24).compactMap { hour in
            let values = others.compactMap { $0.temps[hour] }
            guard let low = values.min(), let high = values.max() else { return nil }
            return (hour, low, high, values.reduce(0, +) / Double(values.count))
        }
    }

    /// "At 8am it was 64° — cooler than every other Oct 2 at that hour (70°–75°).
    /// The forecast peaks at 88° around 3pm; the others peaked at 85°–92°."
    ///
    /// For a low, the second half is about the bottom of the night instead:
    /// "It bottomed out at 66° around 6am; the other Oct 2s bottomed at 58°–64°."
    public func sentence() -> String? {
        let parts = [nowClause(), extremeClause()].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "At 8am it was 64° — cooler than every other Oct 2 at that hour." Only
    /// while today is still being measured.
    public func nowClause() -> String? {
        guard let subject, !others.isEmpty else { return nil }
        var parts: [String] = []
        let name = dateLabel
        let m = measure

        // NOW, against the same hour — only while today is still being measured.
        if isToday, subject.isPartlyForecast, let hour = subject.lastObserved,
           let value = subject.temps[hour] {
            let then = others.compactMap { $0.temps[hour] }
            if let low = then.min(), let high = then.max() {
                let reading = "At \(Self.clock(hour)) it was \(m.format(value))"
                let span = span(low, high)
                if value < low - 0.5 {
                    parts.append("\(reading) — \(m.lessWord) than every other \(name) at that hour (\(span)).")
                } else if value > high + 0.5 {
                    parts.append("\(reading) — \(m.moreWord) than every other \(name) at that hour (\(span)).")
                } else {
                    parts.append("\(reading) — inside what other \(name)s did at that hour (\(span)).")
                }
            }
        }

        return parts.first
    }

    /// The day's top — or for a low, its bottom — against the other years':
    /// "The forecast peaks at 88° around 3pm; the other Oct 2s peaked at 85°–92°."
    public func extremeClause() -> String? {
        guard let subject, !others.isEmpty else { return nil }
        var parts: [String] = []
        let name = dateLabel
        let m = measure

        // The extreme of the day: the bottom for a low, the top otherwise.
        let low = m == .low
        func extreme(_ t: HourTrace) -> (hour: Int, value: Double)? { low ? t.trough : t.peak }
        let verbPast = low ? "bottomed out at" : "peaked at"
        let verbOthers = low ? "bottomed at" : "peaked at"

        // Only whole days set the range: a half-recorded day's top reading is
        // a floor on its peak, not its peak.
        let extremes = others.filter(\.isNearlyWhole).compactMap { extreme($0)?.value }
        // Today is never "partly recorded": its missing hours are the future,
        // or minutes still on their way, and the forecast covers them.
        if !isToday, !subject.isNearlyWhole, let top = extreme(subject) {
            parts.append("\(subject.year) is only partly recorded "
                         + "(\(subject.temps.count) of 24 hours) — its \(low ? "lowest" : "highest") reading was "
                         + "\(m.format(top.value)) at \(Self.clock(top.hour)), which the real \(low ? "low" : "peak") can only match or \(low ? "undercut" : "beat").")
        } else if let top = extreme(subject), let lo = extremes.min(), let hi = extremes.max() {
            let forecastExtreme = !subject.observed.contains(top.hour)
            let lead: String
            if isToday {
                lead = forecastExtreme
                    ? "The forecast \(low ? "bottoms out" : "peaks") at \(m.format(top.value)) around \(Self.clock(top.hour))"
                    : "It \(verbPast) \(m.format(top.value)) around \(Self.clock(top.hour))"
            } else {
                lead = "\(subject.year) \(verbPast) \(m.format(top.value)) around \(Self.clock(top.hour))"
            }
            let who = extremes.count == 1 ? "the other \(name)" : "the other \(name)s"
            parts.append("\(lead); \(who) \(verbOthers) \(span(lo, hi)).")
        }
        return parts.first
    }

    func span(_ low: Double, _ high: Double) -> String {
        Int(low.rounded()) == Int(high.rounded()) ? measure.format(low)
            : "\(measure.format(low).replacingOccurrences(of: " mph", with: ""))–\(measure.format(high))"
    }

    static func deg(_ value: Double) -> String { "\(Int(value.rounded()))°" }

    /// "8am", "noon" — the sentence's clock, public for the hover readout.
    public static func clock(_ hour: Int) -> String {
        switch hour {
        case 0: return "midnight"
        case 12: return "noon"
        case 1..<12: return "\(hour)am"
        default: return "\(hour - 12)pm"
        }
    }
}
