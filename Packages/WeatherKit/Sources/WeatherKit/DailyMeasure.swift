//
//  DailyMeasure.swift  (WeatherKit)
//
//  THE DAY'S NUMBERS THAT CAN BE COMPARED — and graded — beyond the high.
//
//  Compare and Forecast Check both grew up on the afternoon high alone, not by
//  choice but because it is the one number every source has. The daily record
//  holds the night's low, the muggiest dew point and the strongest gust too,
//  and the forecast log holds the low (and, from October 2026, the gust and
//  dew point). This is the one place that knows, for each, what it is called,
//  where it lives, which way is "more", and how close counts as right.
//

import Foundation

public enum DailyMeasure: String, CaseIterable, Sendable, Identifiable, Hashable {
    case high, low, dewPoint, gust

    public var id: String { rawValue }

    /// For a picker: "High".
    public var label: String {
        switch self {
        case .high: return "High"
        case .low: return "Low"
        case .dewPoint: return "Dew point"
        case .gust: return "Gust"
        }
    }

    /// For a sentence's subject: "Highs are averaging…".
    public var plural: String {
        switch self {
        case .high: return "Highs"
        case .low: return "Lows"
        case .dewPoint: return "Peak dew points"
        case .gust: return "Peak gusts"
        }
    }

    /// For a chart's title: "Daily highs".
    public var dailyTitle: String {
        switch self {
        case .high: return "Daily highs"
        case .low: return "Overnight lows"
        case .dewPoint: return "Peak dew point"
        case .gust: return "Peak gust"
        }
    }

    /// For "the measured ___": "high", "low", "peak gust".
    public var noun: String {
        switch self {
        case .high: return "high"
        case .low: return "low"
        case .dewPoint: return "peak dew point"
        case .gust: return "peak gust"
        }
    }

    public var record: KeyPath<DailyRecord, Double?> {
        switch self {
        case .high: return \.tempMax
        case .low: return \.tempMin
        case .dewPoint: return \.dewPointMax
        case .gust: return \.windGustMax
        }
    }

    public func value(_ note: ForecastNote) -> Double? {
        switch self {
        case .high: return note.high
        case .low: return note.low
        case .dewPoint: return note.dewPoint
        case .gust: return note.gust
        }
    }

    public var isTemperature: Bool { self == .high || self == .low }

    /// "°" or " mph", for printing a value: `"\(v)\(m.unit)"`.
    public var unit: String { self == .gust ? " mph" : "°" }

    public func format(_ value: Double) -> String { "\(Int(value.rounded()))\(unit)" }

    /// A difference: "3°", "4 mph".
    public func formatDelta(_ value: Double) -> String { "\(Int(abs(value).rounded()))\(unit)" }

    /// Which way "more" reads in words — warmer, muggier, windier.
    public var moreWord: String {
        switch self {
        case .high, .low: return "warmer"
        case .dewPoint: return "muggier"
        case .gust: return "windier"
        }
    }

    public var lessWord: String {
        switch self {
        case .high, .low: return "cooler"
        case .dewPoint: return "drier"
        case .gust: return "calmer"
        }
    }

    /// How a forecast that missed reads: it "ran cold" or "ran low".
    public var underWord: String { isTemperature ? "cold" : "low" }
    public var overWord: String { isTemperature ? "warm" : "high" }

    /// Within this, a forecast did its job. Two degrees is about what a
    /// station's own reading moves from one side of a yard to the other; a gust
    /// forecast is a guess at the strongest three seconds of a day, and five
    /// miles an hour is as close as it can honestly be held to.
    public var tolerance: Double { self == .gust ? 5 : 2 }

    /// Which forecast to grade it against.
    ///
    /// The MORNING's word for a high, a gust or the day's muggiest air — all
    /// afternoon things. The low is the exception: the night's low has usually
    /// come and gone by breakfast, so grading the morning forecast of it would
    /// grade a forecast made after the fact. The low is held to the forecast
    /// standing at midnight — what you went to bed with.
    public var gradesNightBefore: Bool { self == .low }

    /// "the morning forecast", "the night-before forecast".
    public var claimName: String { gradesNightBefore ? "night-before forecast" : "morning forecast" }
}

extension Climatology {
    /// One measure's usual on a date, as a middle and a typical spread — the
    /// smooth band Compare draws behind a year. Pooled ±`radius` days across
    /// every year, like every normal here; nil below ten days of sample.
    public func normalBand(_ measure: DailyMeasure, monthDay: String,
                           radius: Int = 7) -> (mid: Double, spread: Double)? {
        let keys = Climatology.monthDayWindow(around: monthDay, radius: radius)
        let values = keys.flatMap { reliableRecords(monthDay: $0) }.compactMap { $0[keyPath: measure.record] }
        guard values.count >= 10, let mid = values.mean else { return nil }
        return (mid, values.standardDeviation ?? 0)
    }
}
