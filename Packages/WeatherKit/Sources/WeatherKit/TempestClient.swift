//
//  TempestClient.swift  (WeatherKit)
//
//  Fetches WeatherFlow's `better_forecast` endpoint for a given station, asking
//  for US-common units up front so nothing downstream has to convert. This is the
//  "works anywhere" source (phone on cellular, laptop at a café). The on-network
//  UDP broadcast source is a separate, later layer that only augments "right now".
//

import Foundation

public struct TempestClient: Sendable {
    /// A WeatherFlow personal access token (Settings → "Data Authorizations").
    public let token: String
    /// The numeric station id (not the device id).
    public let stationID: Int

    private let session: URLSession

    public init(token: String, stationID: Int, session: URLSession = .shared) {
        self.token = token
        self.stationID = stationID
        self.session = session
    }

    public enum Failure: Error, LocalizedError {
        case notConfigured
        case badResponse(status: Int)
        case decoding(Error)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Add your Tempest API token and station ID in Settings."
            case .badResponse(let status):
                return "Weather service returned HTTP \(status). Check the token and station ID."
            case .decoding(let error):
                return "Couldn't read the weather response: \(error.localizedDescription)"
            }
        }
    }

    /// Build the request URL with US-common units baked in.
    var requestURL: URL {
        var components = URLComponents(string: "https://swd.weatherflow.com/swd/rest/better_forecast")!
        components.queryItems = [
            URLQueryItem(name: "station_id", value: String(stationID)),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "units_temp", value: "f"),
            URLQueryItem(name: "units_wind", value: "mph"),
            URLQueryItem(name: "units_pressure", value: "inhg"),
            URLQueryItem(name: "units_precip", value: "in"),
            URLQueryItem(name: "units_distance", value: "mi"),
        ]
        return components.url!
    }

    /// A decoder that maps the endpoint's snake_case keys onto our camelCase
    /// properties. (Our CodingKeys spell the exact keys, but this makes any field
    /// we haven't hand-mapped fall through cleanly too.)
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }

    public func fetch() async throws -> BetterForecast {
        guard !token.isEmpty, stationID != 0 else { throw Failure.notConfigured }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(status: http.statusCode)
        }
        do {
            return try Self.makeDecoder().decode(BetterForecast.self, from: data)
        } catch {
            throw Failure.decoding(error)
        }
    }

    /// Fetch and interpret in one call — the app-facing entry point.
    public func report(now: Date = Date(), calendar: Calendar = .current) async throws -> WeatherReport {
        let forecast = try await fetch()
        return WeatherInterpreter.report(from: forecast, now: now, calendar: calendar)
    }

    // MARK: - History

    /// URL for a window of past observations. Same units as the forecast call, so
    /// archived history and live conditions are directly comparable with no
    /// conversion anywhere downstream.
    func observationsURL(start: Date, end: Date, bucketMinutes: Int) -> URL {
        var components = URLComponents(string: "https://swd.weatherflow.com/swd/rest/observations/stn/\(stationID)")!
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "time_start", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "time_end", value: String(Int(end.timeIntervalSince1970))),
            URLQueryItem(name: "bucket", value: String(bucketMinutes)),
            URLQueryItem(name: "units_temp", value: "f"),
            URLQueryItem(name: "units_wind", value: "mph"),
            URLQueryItem(name: "units_pressure", value: "inhg"),
            URLQueryItem(name: "units_precip", value: "in"),
            URLQueryItem(name: "units_distance", value: "mi"),
        ]
        return components.url!
    }

    /// Fetch one window of history. The API caps the span by `bucketMinutes` —
    /// exceeding it returns a 200 with an error body, not an HTTP error, which is
    /// why the decode below tolerates a missing `obs` rather than trusting status.
    public func observations(start: Date, end: Date,
                             bucketMinutes: Int = ArchiveSync.bucketMinutes) async throws -> StationObservations {
        guard !token.isEmpty, stationID != 0 else { throw Failure.notConfigured }

        var request = URLRequest(url: observationsURL(start: start, end: end, bucketMinutes: bucketMinutes))
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(status: http.statusCode)
        }
        do {
            return try Self.makeDecoder().decode(StationObservations.self, from: data)
        } catch {
            throw Failure.decoding(error)
        }
    }

    /// When the station was registered. This is a FLOOR for a cold-archive fill,
    /// not the first day of data — a station can be registered months before it
    /// starts reporting, or moved. Empty windows before the real first observation
    /// simply archive nothing, so erring early is cheap and self-configuring.
    public func stationCreated() async throws -> Date? {
        guard !token.isEmpty, stationID != 0 else { throw Failure.notConfigured }

        var components = URLComponents(string: "https://swd.weatherflow.com/swd/rest/stations/\(stationID)")!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(status: http.statusCode)
        }
        let payload = try Self.makeDecoder().decode(StationList.self, from: data)
        guard let epoch = payload.stations.compactMap(\.createdEpoch).min() else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    struct StationList: Decodable {
        var stations: [Station]
        struct Station: Decodable {
            var createdEpoch: Double?
            enum CodingKeys: String, CodingKey { case createdEpoch = "created_epoch" }
        }
        enum CodingKeys: String, CodingKey { case stations }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stations = try c.decodeIfPresent([Station].self, forKey: .stations) ?? []
        }
    }

    /// An `ArchiveFiller` fetcher bound to this station.
    public func archiveFetcher() -> ArchiveFiller.Fetcher {
        { start, end, bucket in
            try await observations(start: start, end: end, bucketMinutes: bucket)
        }
    }
}
