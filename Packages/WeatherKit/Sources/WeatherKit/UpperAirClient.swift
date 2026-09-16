//
//  UpperAirClient.swift  (WeatherKit)
//
//  500 mb heights from the GFS, via Open-Meteo. No key, no account.
//
//  THREE KINDS OF POINT go into one fetch, in this order:
//
//    · the display grid         — what the chart and the table show
//    · a ring around each row    — every `ringStep`° of longitude, for the zonal mean
//    · the home point itself     — so "the height here" is the height here
//
//  THE RUN IS NAMED BY THE SERVICE, NOT GUESSED. The forecast response doesn't say
//  which GFS cycle it came from, but Open-Meteo publishes the model's metadata:
//  `last_run_initialisation_time` is the cycle, and `last_run_availability_time`
//  is when it landed. Measured on 2026-09-13, the 12Z run became available about
//  6¾ hours after initialisation — well past the "about 4 hours" rule of thumb for
//  NOMADS — so a clock-based guess would have labelled the previous run's numbers
//  with the new run's name for hours at a time.
//

import Foundation

public struct UpperAirClient: Sendable {
    public let grid: UpperAirGrid
    public let home: GeoPoint?
    private let session: URLSession

    /// Open-Meteo's own advice, and the prompt's: a couple of dozen coordinates
    /// per request, not hundreds in one URL.
    public static let chunkSize = 24

    public static let credit = "GFS · NOAA/NCEP via Open-Meteo"

    public init(grid: UpperAirGrid = .conus, home: GeoPoint?, session: URLSession = .shared) {
        self.grid = grid
        self.home = home
        self.session = session
    }

    public enum Failure: Error, LocalizedError {
        case badResponse(status: Int)
        case decoding(Error)
        case incomplete(String)

        public var errorDescription: String? {
            switch self {
            case .badResponse(let status):
                return "Open-Meteo returned HTTP \(status)."
            case .decoding(let error):
                return "Couldn't read the GFS response: \(error.localizedDescription)"
            case .incomplete(let why):
                return "The GFS response was incomplete: \(why)"
            }
        }
    }

    // MARK: Requests

    /// Pressure-level fields on `/v1/gfs` come from the 0.25° GFS.
    static let metaURL = URL(string: "https://api.open-meteo.com/data/ncep_gfs025/static/meta.json")!

    /// Every point, in the order `assemble` expects.
    public var points: [GeoPoint] {
        var all: [GeoPoint] = []
        for lat in grid.latitudes {
            for lon in grid.longitudes { all.append(GeoPoint(latitude: lat, longitude: lon)) }
        }
        for lat in grid.latitudes {
            for lon in grid.ringLongitudes { all.append(GeoPoint(latitude: lat, longitude: lon)) }
        }
        if let home { all.append(home) }
        return all
    }

    static func chunks(_ points: [GeoPoint], size: Int = chunkSize) -> [[GeoPoint]] {
        stride(from: 0, to: points.count, by: size).map {
            Array(points[$0..<min($0 + size, points.count)])
        }
    }

    static func forecastURL(_ points: [GeoPoint]) -> URL {
        func list(_ values: [Double]) -> String {
            values.map { String(format: "%.2f", $0) }.joined(separator: ",")
        }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/gfs")!
        components.queryItems = [
            .init(name: "latitude", value: list(points.map(\.latitude))),
            .init(name: "longitude", value: list(points.map(\.longitude))),
            .init(name: "hourly", value: "geopotential_height_500hPa"),
            .init(name: "forecast_days", value: "16"),
            .init(name: "timezone", value: "GMT"),
        ]
        return components.url!
    }

    static func homeURL(_ home: GeoPoint) -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/gfs")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", home.latitude)),
            .init(name: "longitude", value: String(format: "%.2f", home.longitude)),
            .init(name: "hourly", value: "geopotential_height_1000hPa,wind_speed_500hPa,wind_direction_500hPa"),
            .init(name: "wind_speed_unit", value: "mph"),
            .init(name: "forecast_days", value: "16"),
            .init(name: "timezone", value: "GMT"),
        ]
        return components.url!
    }

    /// The initialisation time of the newest GFS run Open-Meteo is serving.
    public func latestRun() async throws -> Date {
        let data = try await get(Self.metaURL)
        do {
            return try Self.decodeMeta(data)
        } catch {
            throw Failure.decoding(error)
        }
    }

    /// Every frame of the run currently being served. `initialized` comes from
    /// `latestRun()`; frames valid before it are dropped, so the first frame is the
    /// run's own analysis (f000) or its first 12Z after that.
    public func fetch(initialized: Date, now: Date = Date()) async throws -> UpperAirRun {
        var locations: [OpenMeteoLocation] = []
        // One after another rather than all at once: this is a free service, and
        // thirteen simultaneous requests for one screen is rude whether or not
        // anything stops it.
        for chunk in Self.chunks(points) {
            let data = try await get(Self.forecastURL(chunk))
            let decoded: [OpenMeteoLocation]
            do { decoded = try Self.decodeLocations(data) } catch { throw Failure.decoding(error) }
            guard decoded.count == chunk.count else {
                throw Failure.incomplete("asked for \(chunk.count) points, got \(decoded.count)")
            }
            locations += decoded
        }
        // The home point's extras: the 1000 mb height (for thickness) and the
        // model's 500 mb wind. Asked for one point only — the grid doesn't need them.
        var extra: OpenMeteoHomeLocation?
        if let home {
            let data = try await get(Self.homeURL(home))
            do { extra = try JSONDecoder().decode(OpenMeteoHomeLocation.self, from: data) } catch { throw Failure.decoding(error) }
        }
        return try Self.assemble(grid: grid, home: home, locations: locations, homeExtra: extra,
                                 initialized: initialized, fetched: now)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(status: http.statusCode)
        }
        return data
    }

    // MARK: Decoding

    struct Meta: Decodable {
        let last_run_initialisation_time: Double
    }

    static func decodeMeta(_ data: Data) throws -> Date {
        Date(timeIntervalSince1970: try JSONDecoder().decode(Meta.self, from: data).last_run_initialisation_time)
    }

    /// Several coordinates come back as an ARRAY in request order; one comes back
    /// as a bare object.
    static func decodeLocations(_ data: Data) throws -> [OpenMeteoLocation] {
        let decoder = JSONDecoder()
        if let many = try? decoder.decode([OpenMeteoLocation].self, from: data) { return many }
        return [try decoder.decode(OpenMeteoLocation.self, from: data)]
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    /// Locations (in `points` order) → frames, one per 12Z.
    ///
    /// A frame missing ANY value is dropped whole rather than drawn with a hole.
    /// The zonal mean over a ring with a missing sample is a different number, and
    /// a profile built on it would place the axes somewhere that no chart does.
    static func assemble(grid: UpperAirGrid, home: GeoPoint?, locations: [OpenMeteoLocation],
                         homeExtra: OpenMeteoHomeLocation? = nil,
                         initialized: Date, fetched: Date) throws -> UpperAirRun {
        let rows = grid.latitudes.count, cols = grid.longitudes.count
        let ring = grid.ringLongitudes.count
        let expected = rows * cols + rows * ring + (home == nil ? 0 : 1)
        guard locations.count == expected else {
            throw Failure.incomplete("expected \(expected) points, got \(locations.count)")
        }
        guard let times = locations.first?.hourly.time else { throw Failure.incomplete("no times") }
        for location in locations where location.hourly.time != times {
            throw Failure.incomplete("locations disagree about the forecast hours")
        }

        var frames: [UpperAirFrame] = []
        for (t, stamp) in times.enumerated() where stamp.hasSuffix("T12:00") {
            guard let valid = timeFormatter.date(from: stamp), valid >= initialized else { continue }
            func dam(_ index: Int) -> Double? {
                let series = locations[index].hourly.geopotential_height_500hPa
                return t < series.count ? series[t].map { $0 / 10 } : nil
            }

            var heights: [[Double]] = []
            var means: [Double] = []
            var complete = true
            for r in 0..<rows {
                let row = (0..<cols).compactMap { dam(r * cols + $0) }
                let circle = (0..<ring).compactMap { dam(rows * cols + r * ring + $0) }
                guard row.count == cols, circle.count == ring else { complete = false; break }
                heights.append(row)
                means.append(WavePattern.average(circle))
            }
            guard complete else { continue }
            let homeHeight = home == nil ? nil : dam(expected - 1)
            if home != nil && homeHeight == nil { continue }

            // The extras ride along only when they line up hour for hour with the
            // heights. A mismatch leaves them missing rather than misaligned.
            var thickness: Double?
            var wind: UpperWind?
            if let extra = homeExtra?.hourly, extra.time == times, let homeHeight {
                func at(_ series: [Double?]?) -> Double? {
                    guard let series, t < series.count else { return nil }
                    return series[t]
                }
                if let low = at(extra.geopotential_height_1000hPa) { thickness = homeHeight - low / 10 }
                if let speed = at(extra.wind_speed_500hPa), let from = at(extra.wind_direction_500hPa) {
                    wind = UpperWind(speedMPH: speed, fromDegrees: from)
                }
            }

            frames.append(UpperAirFrame(valid: valid,
                                        field: HeightField(heights: heights, zonalMeans: means,
                                                           home: homeHeight, homeThickness: thickness,
                                                           homeWind: wind)))
        }
        guard !frames.isEmpty else { throw Failure.incomplete("no complete 12Z frames") }
        return UpperAirRun(initialized: initialized, fetched: fetched, home: home, grid: grid,
                           frames: frames)
    }
}

struct OpenMeteoHomeLocation: Decodable {
    struct Hourly: Decodable {
        let time: [String]
        let geopotential_height_1000hPa: [Double?]?
        let wind_speed_500hPa: [Double?]?
        let wind_direction_500hPa: [Double?]?
    }
    let hourly: Hourly
}

struct OpenMeteoLocation: Decodable {
    struct Hourly: Decodable {
        let time: [String]
        let geopotential_height_500hPa: [Double?]
    }
    let hourly: Hourly
}

// MARK: - Run

/// One valid time.
public struct UpperAirFrame: Codable, Equatable, Sendable, Identifiable {
    public var valid: Date
    public var field: HeightField
    public var id: Date { valid }

    public init(valid: Date, field: HeightField) {
        self.valid = valid
        self.field = field
    }
}

/// One GFS cycle's worth of frames — the unit that is fetched, cached and kept.
public struct UpperAirRun: Codable, Equatable, Sendable {
    /// Bumped when a run starts carrying something older files lack. A stored run
    /// below it doesn't `cover` anything, so it's refetched rather than drawn
    /// with pieces missing. 2 = home thickness and wind.
    public static let currentVersion = 2
    /// Optional so files written before versioning still decode (as 1).
    public var version: Int?
    public var model: String
    /// The cycle: 00, 06, 12 or 18Z on some date.
    public var initialized: Date
    public var fetched: Date
    public var home: GeoPoint?
    public var grid: UpperAirGrid
    public var frames: [UpperAirFrame]

    public init(model: String = "GFS", initialized: Date, fetched: Date, home: GeoPoint?,
                grid: UpperAirGrid, frames: [UpperAirFrame]) {
        self.version = Self.currentVersion
        self.model = model
        self.initialized = initialized
        self.fetched = fetched
        self.home = home
        self.grid = grid
        self.frames = frames
    }

    /// Hours from initialisation — `f048` on a chart.
    public func forecastHour(_ frame: UpperAirFrame) -> Int {
        Int((frame.valid.timeIntervalSince(initialized) / 3600).rounded())
    }

    /// Whether this run answers for `grid` and `home` — a run fetched for another
    /// home point holds the wrong "height here".
    public func covers(grid: UpperAirGrid, home: GeoPoint?) -> Bool {
        guard (version ?? 1) >= Self.currentVersion, self.grid == grid else { return false }
        switch (self.home, home) {
        case (nil, nil): return true
        case let (a?, b?):
            return abs(a.latitude - b.latitude) < 0.01 && abs(a.longitude - b.longitude) < 0.01
        default: return false
        }
    }

    /// The earliest a NEWER cycle could plausibly be served: the next cycle plus
    /// four hours. Before this there is no point asking; after it, `latestRun()`
    /// says whether one actually has.
    public var nextRunPossible: Date {
        initialized.addingTimeInterval(6 * 3600 + 4 * 3600)
    }
}

// MARK: - Store

/// Every run kept, one file each: `<root>/gfs-2026-09-13T12Z.json`. A forecast
/// is only observable when it's issued — nobody serves last Monday's GFS — so
/// keeping them is what later lets a pattern forecast be compared with the
/// pattern that happened. A few tens of KB a run.
public struct UpperAirStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH'Z'"
        return f
    }()

    public func url(for run: UpperAirRun) -> URL {
        root.appendingPathComponent("\(run.model.lowercased())-\(Self.nameFormatter.string(from: run.initialized)).json")
    }

    public func save(_ run: UpperAirRun) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(run).write(to: url(for: run), options: .atomic)
    }

    /// The newest stored run that covers `grid` and `home`. Names sort by cycle.
    public func latest(covering grid: UpperAirGrid, home: GeoPoint?) -> UpperAirRun? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for name in names.filter({ $0.hasSuffix(".json") }).sorted(by: >) {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name)),
                  let run = try? decoder.decode(UpperAirRun.self, from: data),
                  run.covers(grid: grid, home: home) else { continue }
            return run
        }
        return nil
    }
}
