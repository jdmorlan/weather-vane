//
//  Forecast.swift  (WeatherKit)
//
//  The raw shape of WeatherFlow's `better_forecast` response, decoded straight
//  from JSON. These types are deliberately dumb: optionals everywhere the API
//  can omit a field, no interpretation. All the "what does it mean" work happens
//  in Interpretation.swift so this file stays a faithful mirror of the wire format.
//
//  Numbers arrive already in the units we ask for (°F, mph, inHg, inches) via the
//  units_* query params, so there is no conversion math here — see TempestClient.
//

import Foundation

/// Top-level `better_forecast` payload.
public struct BetterForecast: Codable, Equatable, Sendable {
    public var latitude: Double?
    public var longitude: Double?
    public var timezone: String?
    public var currentConditions: CurrentConditions?
    public var forecast: Forecast?

    enum CodingKeys: String, CodingKey {
        case latitude, longitude, timezone
        case currentConditions = "current_conditions"
        case forecast
    }
}

public struct Forecast: Codable, Equatable, Sendable {
    public var daily: [DailyForecast]
    public var hourly: [HourlyForecast]

    public init(daily: [DailyForecast] = [], hourly: [HourlyForecast] = []) {
        self.daily = daily
        self.hourly = hourly
    }
}

/// Right-now snapshot the station/network reports.
public struct CurrentConditions: Codable, Equatable, Sendable {
    /// Epoch seconds.
    public var time: Int?
    public var conditions: String?
    public var icon: String?

    public var airTemperature: Double?
    public var feelsLike: Double?
    public var dewPoint: Double?
    public var wetBulbTemperature: Double?
    public var relativeHumidity: Double?

    public var seaLevelPressure: Double?
    public var stationPressure: Double?
    /// "falling" | "steady" | "rising"
    public var pressureTrend: String?

    public var windAvg: Double?
    public var windGust: Double?
    public var windDirection: Double?
    public var windDirectionCardinal: String?

    public var uv: Double?
    public var solarRadiation: Double?
    public var brightness: Double?

    public var precipProbability: Double?
    public var precipAccumLocalDay: Double?

    public var lightningStrikeCountLast1hr: Int?
    public var lightningStrikeCountLast3hr: Int?
    public var lightningStrikeLastDistance: Double?

    enum CodingKeys: String, CodingKey {
        case time, conditions, icon, uv, brightness
        case airTemperature = "air_temperature"
        case feelsLike = "feels_like"
        case dewPoint = "dew_point"
        case wetBulbTemperature = "wet_bulb_temperature"
        case relativeHumidity = "relative_humidity"
        case seaLevelPressure = "sea_level_pressure"
        case stationPressure = "station_pressure"
        case pressureTrend = "pressure_trend"
        case windAvg = "wind_avg"
        case windGust = "wind_gust"
        case windDirection = "wind_direction"
        case windDirectionCardinal = "wind_direction_cardinal"
        case solarRadiation = "solar_radiation"
        case precipProbability = "precip_probability"
        case precipAccumLocalDay = "precip_accum_local_day"
        case lightningStrikeCountLast1hr = "lightning_strike_count_last_1hr"
        case lightningStrikeCountLast3hr = "lightning_strike_count_last_3hr"
        case lightningStrikeLastDistance = "lightning_strike_last_distance"
    }
}

/// One day in the 10-day summary.
public struct DailyForecast: Codable, Equatable, Sendable, Identifiable {
    /// Epoch seconds for local midnight.
    public var dayStartLocal: Int?
    /// Day-of-month; matches HourlyForecast.localDay for grouping.
    public var dayNum: Int?
    public var monthNum: Int?

    public var conditions: String?
    public var icon: String?
    public var sunrise: Int?
    public var sunset: Int?

    public var airTempHigh: Double?
    public var airTempLow: Double?

    public var precipProbability: Double?
    public var precipIcon: String?
    public var precipType: String?

    public var id: Int { dayStartLocal ?? (dayNum ?? 0) }

    enum CodingKeys: String, CodingKey {
        case conditions, icon, sunrise, sunset
        case dayStartLocal = "day_start_local"
        case dayNum = "day_num"
        case monthNum = "month_num"
        case airTempHigh = "air_temp_high"
        case airTempLow = "air_temp_low"
        case precipProbability = "precip_probability"
        case precipIcon = "precip_icon"
        case precipType = "precip_type"
    }
}

/// One hour in the time-series.
public struct HourlyForecast: Codable, Equatable, Sendable, Identifiable {
    /// Epoch seconds.
    public var time: Int?
    public var conditions: String?
    public var icon: String?

    public var airTemperature: Double?
    public var feelsLike: Double?
    public var relativeHumidity: Double?
    public var seaLevelPressure: Double?

    /// Accumulation THIS hour, in the requested precip unit (inches).
    public var precip: Double?
    public var precipType: String?
    public var precipProbability: Double?
    public var precipIcon: String?

    public var windAvg: Double?
    public var windGust: Double?
    public var windDirection: Double?
    public var windDirectionCardinal: String?

    public var uv: Double?
    /// Local clock hour 0–23 (the API pre-computes this in station time).
    public var localHour: Int?
    /// Local day-of-month; matches DailyForecast.dayNum.
    public var localDay: Int?

    public var id: Int { time ?? 0 }

    enum CodingKeys: String, CodingKey {
        case time, conditions, icon, precip, uv
        case airTemperature = "air_temperature"
        case feelsLike = "feels_like"
        case relativeHumidity = "relative_humidity"
        case seaLevelPressure = "sea_level_pressure"
        case precipType = "precip_type"
        case precipProbability = "precip_probability"
        case precipIcon = "precip_icon"
        case windAvg = "wind_avg"
        case windGust = "wind_gust"
        case windDirection = "wind_direction"
        case windDirectionCardinal = "wind_direction_cardinal"
        case localHour = "local_hour"
        case localDay = "local_day"
    }
}
