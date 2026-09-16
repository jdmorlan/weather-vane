//
//  PressureBand.swift  (WeatherKit)
//
//  What pressure ACTUALLY DOES, which no barometer reading has ever told anyone.
//
//  "30.10 inHg" is the least legible number in weather. It has no felt referent — you
//  cannot walk outside and check it the way you can check 84° — and it lives in a band
//  so narrow that the digits barely move. Shown bare, the honest reaction is the one Jay
//  had: it seems constant, and within a pretty small band of values.
//
//  It IS a small band. That's the fact, and stating it is the whole insight: at a given
//  station essentially all weather happens inside about 1.5 inHg, so a tenth is a lot and
//  half an inch is a storm. A reading only means something against the record of the
//  place it was taken, which is exactly what the local archive is for. So this computes
//  the band from YOUR station's own history — never a textbook range — and places today
//  inside it as a percentile, because "lower than all but 3% of days here" is a sentence
//  a person can act on and "30.10" is not.
//

import Foundation

/// Where pressure lives at one station, learned from its own record.
public struct PressureBand: Equatable, Sendable {
    /// The lowest and highest sea-level pressure ever recorded here, with their days.
    public var lowest: WeatherExtreme
    public var highest: WeatherExtreme
    /// The middle 80% of daily means — "ordinary" for this station.
    public var usualLow: Double
    public var usualHigh: Double
    public var median: Double
    public var days: Int

    /// The full observed span, in inHg. Usually near 1.5 — the number that makes the
    /// case that a tenth of an inch is a big move.
    public var span: Double { highest.value - lowest.value }

    /// Where `value` sits in the record, 0…1. The percentile is the interpretation:
    /// the raw number can't be high or low without something to be high or low against.
    public func position(_ value: Double) -> Double {
        guard span > 0 else { return 0.5 }
        return min(1, max(0, (value - lowest.value) / span))
    }
}

extension Climatology {
    /// The pressure band for this station. nil when the archive holds too few days to
    /// say anything — a "record low" drawn from six days is a lie with a chart around it.
    public func pressureBand(minimumDays: Int = 60) -> PressureBand? {
        let withPressure = reliable.filter { $0.pressureMin != nil || $0.pressureMax != nil }
        guard withPressure.count >= minimumDays else { return nil }

        // The extremes come from the daily MIN/MAX (the actual lowest reading ever), the
        // usual range from daily MEANS (a day's character, not its worst minute) — two
        // different questions that would give a misleadingly wide band if pooled.
        var low: WeatherExtreme?
        var high: WeatherExtreme?
        for rec in withPressure {
            if let v = rec.pressureMin, v < (low?.value ?? .infinity) {
                low = WeatherExtreme(day: rec.day, value: v)
            }
            if let v = rec.pressureMax, v > (high?.value ?? -.infinity) {
                high = WeatherExtreme(day: rec.day, value: v)
            }
        }
        guard let lowest = low, let highest = high, highest.value > lowest.value else { return nil }

        let means = withPressure.compactMap(\.pressureMean).sorted()
        guard let median = means.median else { return nil }
        return PressureBand(lowest: lowest, highest: highest,
                            usualLow: Self.percentile(means, 0.10),
                            usualHigh: Self.percentile(means, 0.90),
                            median: median,
                            days: withPressure.count)
    }

    /// Linear-interpolated percentile of an already-sorted array.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        guard sorted.count > 1 else { return first }
        let pos = p * Double(sorted.count - 1)
        let i = Int(pos)
        guard i + 1 < sorted.count else { return last }
        return sorted[i] + (sorted[i + 1] - sorted[i]) * (pos - Double(i))
    }
}

extension WeatherInterpreter {
    /// What this reading means, said against the station's own record rather than a
    /// textbook. The rank is the teaching: it's what turns a number nobody can feel into
    /// a statement about how unusual today is.
    public static func pressureMeaning(_ value: Double, band: PressureBand,
                                       trend: String) -> String {
        let settled: String
        switch value {
        case ..<band.usualLow:
            settled = "unusually low for here — the range storms arrive in"
        case band.usualHigh...:
            settled = "unusually high for here — settled, fair-weather air"
        case ..<band.median:
            settled = "a touch below normal for here"
        default:
            settled = "a touch above normal for here"
        }
        // A trend beats a level: a falling barometer at an ordinary reading is the more
        // useful warning, and it's the half people were never shown.
        switch trend {
        case "falling": return "\(settled). Falling — the direction that brings weather in."
        case "rising":  return "\(settled). Rising — air settling, skies tending to clear."
        default:        return "\(settled). Holding steady."
        }
    }
}
