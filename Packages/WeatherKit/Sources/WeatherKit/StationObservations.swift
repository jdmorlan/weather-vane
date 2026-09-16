//
//  StationObservations.swift  (WeatherKit)
//
//  The raw shape of WeatherFlow's `observations/stn/{id}` response — the HISTORY
//  endpoint, as opposed to better_forecast's "what's coming". Same posture as
//  Forecast.swift: dumb mirror of the wire format, no interpretation.
//
//  The one wrinkle worth knowing: observations arrive as ARRAYS OF NUMBERS, not
//  objects. The response ships an `ob_fields` list naming the columns in order,
//  so we build a name→index map per response rather than hardcoding positions.
//  Hardcoding would mean a reordering on their end silently archives humidity as
//  pressure — a corruption you wouldn't notice for months, in a store whose whole
//  point is that it's the durable copy.
//

import Foundation

/// Top-level `observations/stn` payload.
public struct StationObservations: Decodable, Equatable, Sendable {
    public var stationID: Int?
    public var timezone: String?
    public var obFields: [String]
    /// Rows of raw values, positionally matching `obFields`. Any column can be null.
    public var obs: [[Double?]]

    enum CodingKeys: String, CodingKey {
        case stationID = "station_id"
        case timezone
        case obFields = "ob_fields"
        case obs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stationID = try c.decodeIfPresent(Int.self, forKey: .stationID)
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone)
        obFields = try c.decodeIfPresent([String].self, forKey: .obFields) ?? []
        // `obs` is absent (not empty) when a window has no data at all.
        obs = try c.decodeIfPresent([[Double?]].self, forKey: .obs) ?? []
    }

    public init(stationID: Int? = nil, timezone: String? = nil,
                obFields: [String] = [], obs: [[Double?]] = []) {
        self.stationID = stationID
        self.timezone = timezone
        self.obFields = obFields
        self.obs = obs
    }

    /// The API reports failures as a 200 with a `status` body and no `obs`; callers
    /// use this to tell "the window is genuinely empty" from "we got data".
    public var isEmpty: Bool { obs.isEmpty }
}

/// Resolves a column name to its position for one response, so readers ask for
/// `"air_temp"` instead of `row[8]`.
public struct ObservationFieldMap: Equatable, Sendable {
    private let indexByName: [String: Int]

    public init(fields: [String]) {
        var map: [String: Int] = [:]
        for (i, name) in fields.enumerated() { map[name] = i }
        indexByName = map
    }

    public func has(_ field: String) -> Bool { indexByName[field] != nil }

    /// Nil when the field is absent from this response OR null in this row —
    /// deliberately the same answer, because both mean "we don't know".
    public func value(_ field: String, in row: [Double?]) -> Double? {
        guard let i = indexByName[field], i < row.count else { return nil }
        return row[i]
    }
}

/// The column names we read. Anything not listed here is still fetched and simply
/// not aggregated — cheap to start using later without re-pulling history.
public enum ObservationField {
    public static let timestamp = "timestamp"
    public static let airTemp = "air_temp"
    public static let humidity = "rh"
    public static let seaLevelPressure = "sea_level_pressure"
    public static let stationPressure = "station_pressure"
    public static let windAvg = "wind_avg"
    public static let windGust = "wind_gust"
    public static let windDirection = "wind_dir"
    public static let uv = "uv"
    public static let solarRadiation = "solar_radiation"
    public static let strikeCount = "strike_count"
    /// Per-bucket precipitation. The `nc_` ("nearcast-corrected") variant is the
    /// one WeatherFlow considers final; we prefer it and fall back to the raw.
    public static let precip = "precip_accumulation"
    public static let precipCorrected = "nc_precip_accumulation"
}
