//
//  StationSample.swift  (WeatherKit)
//
//  ONE READING. The unit the station actually produces, and — from here on — the
//  unit the archive actually keeps.
//
//  Everything else in WeatherKit reads `DailyRecord`, which is a day reduced to
//  its min, max and means. That reduction is a LENS, and it was a mistake to make
//  it the storage. A mean over a day answers "what was the day like" and silently
//  refuses every question about the shape INSIDE it: a windy afternoon averaged
//  against a calm night reads as an ordinary day; pressure that sat flat all
//  morning and fell off a cliff at four reads as a mild dip. The measures that
//  suffer are exactly the `.central` ones — pressure, wind, humidity, dew point,
//  mean temp — because a mean is the reduction that discards WHEN.
//
//  `Reading` already taught this codebase that a day-level number can be wrong
//  when hours are MISSING. This is the sibling case nobody had modelled: a day
//  level number wrong because hours are PRESENT and diluting.
//
//  So: samples are the record. Day, hour, morning, evening, "the hours it was
//  actually storming" are all projections over the same series.
//
//  RESOLUTION TRAVELS WITH THE SAMPLE, and that is not bookkeeping. This archive
//  will hold 1-minute readings alongside 30-minute ones, because the original
//  backfill was taken at `bucket=30` and the UDP collector reports every minute.
//  A peak gust found in a 30-minute series and one found in a 1-minute series are
//  not the same measurement, and without `bucketMinutes` on the sample nothing
//  downstream could tell them apart — the same class of mistake as comparing a
//  half-watched year to a full one (`QueryYear.isComparable`), or drawing a
//  county-wide watch as if it were a warning polygon.
//

import Foundation

/// One observation from the station, at whatever resolution it was taken.
///
/// Every column the API reports is kept, including the ones `DailyRecord` has no
/// field for — `windDirection`, `precipType`, `strikeDistance`, `illuminance`,
/// `stationPressure`. Those aren't speculative: "which way was the wind blowing
/// when it stormed" is a question the daily archive cannot express at all, and
/// it's the one the facing work runs into. Discarding a column at ingest is a
/// decision that can only be undone by re-fetching the entire record.
public struct StationSample: Codable, Equatable, Sendable {
    /// Seconds since the epoch. The identity of a sample — a station cannot
    /// report two different readings for the same instant.
    public var timestamp: Int

    /// Minutes this sample stands for. 1 for native/UDP, 30 for the original
    /// REST backfill. Load-bearing for every duration derived from a count
    /// (chill hours, "hours above 20 mph") and for whether two extremes drawn
    /// from different eras can be compared at all.
    public var bucketMinutes: Int

    /// The station's own `report_interval`, when it sends one. Distinct from
    /// `bucketMinutes`: that is how the series was SAMPLED, this is how often the
    /// hardware claims to speak.
    public var reportInterval: Int?

    public var airTemp: Double?
    public var humidity: Double?
    public var stationPressure: Double?
    public var seaLevelPressure: Double?

    public var windLull: Double?
    public var windAvg: Double?
    public var windGust: Double?
    /// Degrees. Absent from `DailyRecord` entirely — a mean of a circular
    /// quantity is meaningless, which is why the daily rollup never had one, and
    /// why it belongs at sample resolution where it needs no reduction.
    public var windDirection: Double?

    public var uv: Double?
    public var solarRadiation: Double?
    public var illuminance: Double?

    /// Accumulation for this sample's interval, not a running day total.
    public var precip: Double?
    /// The near-cast-corrected series, preferred when present (as in the rollup).
    public var precipCorrected: Double?
    public var precipType: Double?

    public var strikeCount: Double?
    public var strikeDistance: Double?

    public init(timestamp: Int, bucketMinutes: Int) {
        self.timestamp = timestamp
        self.bucketMinutes = bucketMinutes
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

    /// Minutes since local midnight — the x-coordinate for laying samples from
    /// different days over one axis.
    public func minuteOfDay(timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Computed rather than stored, exactly as the daily rollup computes it: the
    /// station doesn't report dew point, and deriving it from a day's mean temp
    /// and mean humidity gives a different, wrong number.
    public var dewPoint: Double? {
        guard let t = airTemp, let rh = humidity else { return nil }
        return WeatherInterpreter.dewPointF(tempF: t, humidity: rh)
    }
}

// MARK: - Decoding a wire response into samples

extension StationSample {
    /// Read a `observations/stn` response into samples.
    ///
    /// Same posture as `DailyRecord.rollup`: names, never positions, resolved
    /// through `ObservationFieldMap` — a reordering on WeatherFlow's end must not
    /// silently archive humidity as pressure.
    public static func samples(from observations: StationObservations,
                               bucketMinutes: Int) -> [StationSample] {
        let map = ObservationFieldMap(fields: observations.obFields)
        return observations.obs.compactMap { row in
            guard let ts = map.value(ObservationField.timestamp, in: row) else { return nil }
            var sample = StationSample(timestamp: Int(ts), bucketMinutes: bucketMinutes)
            sample.reportInterval  = map.value("report_interval", in: row).map(Int.init)
            sample.airTemp         = map.value(ObservationField.airTemp, in: row)
            sample.humidity        = map.value(ObservationField.humidity, in: row)
            sample.stationPressure = map.value(ObservationField.stationPressure, in: row)
            sample.seaLevelPressure = map.value(ObservationField.seaLevelPressure, in: row)
            sample.windLull        = map.value("wind_lull", in: row)
            sample.windAvg         = map.value(ObservationField.windAvg, in: row)
            sample.windGust        = map.value(ObservationField.windGust, in: row)
            sample.windDirection   = map.value(ObservationField.windDirection, in: row)
            sample.uv              = map.value(ObservationField.uv, in: row)
            sample.solarRadiation  = map.value(ObservationField.solarRadiation, in: row)
            sample.illuminance     = map.value("illuminance", in: row)
            sample.precip          = map.value(ObservationField.precip, in: row)
            sample.precipCorrected = map.value(ObservationField.precipCorrected, in: row)
            sample.precipType      = map.value("precip_type", in: row)
            sample.strikeCount     = map.value(ObservationField.strikeCount, in: row)
            sample.strikeDistance  = map.value("strike_distance", in: row)
            return sample
        }
    }
}
