//
//  DayStrip.swift  (WeatherKit)
//
//  TODAY, MIDNIGHT TO MIDNIGHT — the half of the day the app never drew.
//
//  Every card on the Now tab was anchored at the present instant or ahead of it:
//  the conditions, the radar, the ten-day, and the hourly strip, which
//  `WeatherReport.hours` still describes honestly as "next ~24h". The archive
//  cards look years back. Nothing rendered the stretch between local midnight
//  and now — so at ten in the morning you could not find out that it had been
//  65° at eight, and the only number offered about the morning was the day's
//  forecast LOW, which is a different fact entirely. A low of 50° reached at
//  four this afternoon says nothing about how cool it was at breakfast.
//
//  That is the same mistake `RainEvent` already corrected once: "it's raining"
//  and "it rained today" were treated as two features until they turned out to
//  be one projection over a day's samples. Temperature never got the same move.
//  This is it.
//
//  THE FRAME IS FIXED — 24 columns, local midnight to local midnight, whatever
//  time you open it. A strip that starts at "now" slides all day, so the same
//  hour sits somewhere new every time you look, and yesterday's glance can't be
//  compared to this one. `PeriodBrush` settled this argument already: the axis
//  holds still and the SELECTION moves. Here the selection is the seam at now.
//  What's ahead of tonight belongs to the ten-day card, which is the next card
//  down.
//
//  OBSERVED AND FORECAST ARE DIFFERENT KINDS OF NUMBER and must not be drawn
//  alike. Behind the seam the station measured it; ahead of it a model guessed.
//  So `HourSlice.isObserved` travels with the column and the ribbon strokes the
//  two halves differently — otherwise the strip quietly claims to have measured
//  tonight.
//
//  An observed hour carries no SKY. The station reports temperature, humidity,
//  wind, pressure, rain and strikes; it does not report "partly cloudy", and
//  inventing an icon from solar radiation would be a guess dressed as a record.
//  So the icon lane simply starts at the seam.
//

import Foundation

/// A measured extreme, with the moment it happened.
///
/// The time is the whole point. "Low 61°" is the number the forecast already
/// gave you; "61° at 6:12a" is the answer to how cool the morning was.
public struct ObservedExtreme: Equatable, Sendable {
    public var value: Double
    public var timestamp: Int

    public init(value: Double, timestamp: Int) {
        self.value = value
        self.timestamp = timestamp
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
}

/// One local day as a strip of 24 hours, spliced from what was measured and
/// what is still expected.
public struct DayStrip: Equatable, Sendable {
    /// Exactly 24, indexed by local clock hour. An hour with neither samples nor
    /// a forecast is present but empty — dropping it would shift every column
    /// after it, and the ribbon addresses columns by position.
    public var hours: [HourSlice]
    /// The coldest and warmest readings taken SO FAR today, with their times.
    /// Nil before the first sample of the day arrives.
    public var low: ObservedExtreme?
    public var high: ObservedExtreme?
    /// How many of the 24 columns the station actually filled. A day watched for
    /// two of its ten elapsed hours must not read like a measured one.
    public var observedHours: Int

    public var hasObservations: Bool { observedHours > 0 }
}

extension DayStrip {
    /// Build the strip for one local day.
    ///
    /// `samples` are that day's station observations at whatever resolution they
    /// were taken; `forecast` is `WeatherReport.hours`, which starts at the
    /// current hour and runs into tomorrow. Observed wins wherever it exists —
    /// including the hour in progress, which is partially measured and whose
    /// forecast the "Right now" card has already superseded.
    public static func build(day: String,
                             samples: [StationSample],
                             forecast: [HourSlice],
                             timeZone: TimeZone,
                             sunriseHour: Int,
                             sunsetHour: Int) -> DayStrip {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let dayStart = DayKey.date(from: day, timeZone: timeZone) else {
            return DayStrip(hours: [], low: nil, high: nil, observedHours: 0)
        }

        // Samples can arrive for a neighbouring day (a fetch window is clamped in
        // seconds, a local day is not always 24 hours). Key them by the calendar,
        // never by arithmetic on the timestamp.
        let keyOf = DayKey.formatter(timeZone: timeZone)
        let mine = samples.filter { keyOf.string(from: $0.date) == day }

        var byHour: [Int: [StationSample]] = [:]
        for sample in mine {
            let hour = calendar.component(.hour, from: sample.date)
            byHour[hour, default: []].append(sample)
        }

        let observed = byHour.reduce(into: [Int: HourSlice]()) { out, entry in
            out[entry.key] = slice(from: entry.value, hour: entry.key,
                                   dayStart: Int(dayStart.timeIntervalSince1970),
                                   sunriseHour: sunriseHour, sunsetHour: sunsetHour)
        }

        // The forecast half, keyed the same way and fenced to this day — the
        // report's hours run past midnight and those columns aren't ours.
        var ahead: [Int: HourSlice] = [:]
        for slice in forecast {
            let date = Date(timeIntervalSince1970: TimeInterval(slice.epoch))
            guard keyOf.string(from: date) == day else { continue }
            ahead[calendar.component(.hour, from: date)] = slice
        }

        let hours: [HourSlice] = (0..<24).map { hour in
            if let measured = observed[hour] { return measured }
            if let predicted = ahead[hour] { return predicted }
            let epoch = Int(dayStart.timeIntervalSince1970) + hour * 3600
            return HourSlice(epoch: epoch,
                             clock: WeatherInterpreter.clock(hour),
                             temperature: nil, precipProbability: nil, precip: nil,
                             windAvg: nil, windGust: nil, windDirectionCardinal: nil,
                             windDirection: nil, pressure: nil, dewPoint: nil,
                             icon: "", conditions: "",
                             isNight: isNight(hour, sunriseHour, sunsetHour))
        }

        var low: ObservedExtreme?
        var high: ObservedExtreme?
        for sample in mine {
            guard let temp = sample.airTemp else { continue }
            if low == nil || temp < low!.value {
                low = ObservedExtreme(value: temp, timestamp: sample.timestamp)
            }
            if high == nil || temp > high!.value {
                high = ObservedExtreme(value: temp, timestamp: sample.timestamp)
            }
        }

        return DayStrip(hours: hours, low: low, high: high, observedHours: observed.count)
    }

    private static func isNight(_ hour: Int, _ sunrise: Int, _ sunset: Int) -> Bool {
        hour < sunrise || hour >= sunset
    }

    /// The 16-point rounding the API already applies to its own forecast hours,
    /// so a measured hour's hover reads the same as a predicted one. The app's
    /// `Compass` does this too, but it lives in the macOS target alongside the
    /// facing vocabulary; this is the arithmetic half and nothing more.
    private static let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                                 "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    private static func cardinal(_ degrees: Double) -> String {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return points[Int((d / 22.5).rounded()) % 16]
    }

    /// One hour reduced from its samples.
    ///
    /// Each measure gets the reduction it deserves rather than a blanket mean.
    /// A gust is a MAXIMUM — averaging it away is exactly the dilution
    /// `StationSample` was written to stop — and rain is a SUM over the
    /// intervals, never a mean, for the reason `RainEvent` gives. Direction is
    /// taken from the hour's strongest reading, because a mean of a circular
    /// quantity is meaningless and the direction that matters is the one the
    /// wind was actually blowing when it blew.
    private static func slice(from samples: [StationSample], hour: Int, dayStart: Int,
                              sunriseHour: Int, sunsetHour: Int) -> HourSlice? {
        guard !samples.isEmpty else { return nil }

        func mean(_ path: (StationSample) -> Double?) -> Double? {
            let values = samples.compactMap(path)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        let rain = samples.reduce(0.0) { $0 + Swift.max(0, $1.precipCorrected ?? $1.precip ?? 0) }
        let strongest = samples.max { ($0.windAvg ?? -1) < ($1.windAvg ?? -1) }

        return HourSlice(
            epoch: dayStart + hour * 3600,
            clock: WeatherInterpreter.clock(hour),
            temperature: mean { $0.airTemp },
            // It either rained in this hour or it didn't — there is no chance
            // left in a measurement. The lane draws bar height from this, so a
            // wet observed hour is a full bar filled by how much fell.
            precipProbability: rain > 0 ? 100 : 0,
            precip: rain,
            windAvg: mean { $0.windAvg },
            windGust: samples.compactMap(\.windGust).max(),
            windDirectionCardinal: strongest?.windDirection.map(cardinal),
            windDirection: strongest?.windDirection,
            pressure: mean { $0.seaLevelPressure },
            dewPoint: mean { $0.dewPoint },
            icon: "",
            conditions: "",
            isNight: isNight(hour, sunriseHour, sunsetHour),
            isObserved: true)
    }
}
