//
//  SurfaceWeather.swift  (WeatherKit)
//
//  THE AIR AT GROUND LEVEL, OVER A REGION, HOUR BY HOUR — what a front changes.
//  Two sources, and they are kept apart on purpose:
//
//    · the HRRR on a grid of points, via Open-Meteo: the model's picture, every
//      hour from a few hours ago to a day or two ahead. Smooth and complete,
//      and a forecast — named by its run.
//    · airport reports (METARs), via aviationweather.gov: what was measured,
//      station by station, for the hours already past. Patchy, and true.
//
//  Where both exist — the hours behind us — the map draws the model's shading
//  with the airports' dots on top, so the two can be seen agreeing or not.
//
//  THE GRID IS COARSE ON PURPOSE. Open-Meteo counts every coordinate as a call
//  against a free daily allowance. Three-quarters of a degree (about 50 miles)
//  around home is ~320 points: enough to see a front's edge cross Texas, and
//  cheap enough to refetch whenever a new HRRR run lands, which is hourly.
//
//  AIRPORTS ARE ASKED FOR ONE HOUR AT A TIME. The service stops at 400 reports
//  per request (measured 2026-10-15: two hours over Texas was already 400, and
//  the second hour was cut short), so each past hour is its own window.
//

import Foundation

// MARK: - One reading

/// The five things a front changes, at one place and time. US units throughout,
/// converted on the way in, so nothing downstream ever wonders which it has.
public struct SurfaceReading: Codable, Equatable, Sendable {
    /// °F.
    public var temperature: Double
    /// °F.
    public var dewPoint: Double
    /// Degrees the wind blows FROM, as forecasters say it. Nil when calm or
    /// variable — a direction for a 2 mph drift is a coin toss.
    public var windFrom: Double?
    /// mph.
    public var windSpeed: Double
    /// mph. Nil when none was reported, which for an airport means no gusts.
    public var gust: Double?
    /// Sea-level pressure, mb.
    public var pressure: Double?

    public init(temperature: Double, dewPoint: Double, windFrom: Double?, windSpeed: Double,
                gust: Double?, pressure: Double?) {
        self.temperature = temperature; self.dewPoint = dewPoint
        self.windFrom = windFrom; self.windSpeed = windSpeed
        self.gust = gust; self.pressure = pressure
    }

    /// A wind with some north in it, strong enough to have a direction. The
    /// half of the compass from west-northwest round to east-northeast.
    public var isNortherly: Bool {
        guard let from = windFrom, windSpeed >= 5 else { return false }
        return from >= 290 || from <= 70
    }

    /// The other half: the Gulf's wind, from east-southeast round to west.
    public var isSoutherly: Bool {
        guard let from = windFrom, windSpeed >= 3 else { return false }
        return from >= 100 && from <= 260
    }
}

// MARK: - The grid

/// Points evenly spaced in latitude and longitude. Row-major, SOUTH row first.
public struct SurfaceGrid: Codable, Equatable, Sendable {
    public var latitudes: [Double]
    public var longitudes: [Double]

    public init(latitudes: [Double], longitudes: [Double]) {
        self.latitudes = latitudes; self.longitudes = longitudes
    }

    /// A box around `center`: by default about 400 miles each way north–south
    /// and 450 east–west, which from Houston reaches the Panhandle — far
    /// enough to see a front a day before it arrives.
    public static func around(_ center: GeoPoint, halfHeight: Double = 6, halfWidth: Double = 7,
                              step: Double = 0.75) -> SurfaceGrid {
        func axis(_ mid: Double, _ half: Double) -> [Double] {
            // An even number of steps, so `center` is itself a grid point.
            let n = 2 * Int((half / step).rounded())
            let start = mid - Double(n) * step / 2
            return (0...n).map { ((start + Double($0) * step) * 100).rounded() / 100 }
        }
        return SurfaceGrid(latitudes: axis(center.latitude, halfHeight).filter { $0 >= southEdge },
                           longitudes: axis(center.longitude, halfWidth))
    }

    /// WHERE OPEN-METEO'S HRRR STOPS, which is north of where the HRRR does.
    /// The model's own domain reaches 21°N, but Open-Meteo answers "no data"
    /// below about 24.4°N over the Gulf and Mexico (measured 2026-10-15; the edge
    /// wobbles with the projection) — and one such point fails the whole
    /// request. From Houston that trims the southernmost rows, which are open
    /// water a front reaches last anyway.
    public static let southEdge = 24.5

    public var rows: Int { latitudes.count }
    public var cols: Int { longitudes.count }
    public var count: Int { rows * cols }

    public func index(row: Int, col: Int) -> Int { row * cols + col }

    public func point(_ index: Int) -> GeoPoint {
        GeoPoint(latitude: latitudes[index / cols], longitude: longitudes[index % cols])
    }

    public var points: [GeoPoint] { (0..<count).map(point) }

    /// Bilinear between the four surrounding points. Nil outside the grid, or
    /// where any of the four is missing — a blend with a hole in it is a number
    /// nobody measured or forecast.
    public func sample(_ values: [Double?], at p: GeoPoint) -> Double? {
        guard rows > 1, cols > 1, values.count == count,
              let lat0 = latitudes.first, let lon0 = longitudes.first else { return nil }
        let dLat = latitudes[1] - lat0, dLon = longitudes[1] - lon0
        let fr = (p.latitude - lat0) / dLat, fc = (p.longitude - lon0) / dLon
        guard fr >= 0, fc >= 0, fr <= Double(rows - 1), fc <= Double(cols - 1) else { return nil }
        let r = min(Int(fr), rows - 2), c = min(Int(fc), cols - 2)
        let tr = fr - Double(r), tc = fc - Double(c)
        guard let a = values[index(row: r, col: c)], let b = values[index(row: r, col: c + 1)],
              let d = values[index(row: r + 1, col: c)], let e = values[index(row: r + 1, col: c + 1)]
        else { return nil }
        return (a * (1 - tc) + b * tc) * (1 - tr) + (d * (1 - tc) + e * tc) * tr
    }
}

// MARK: - The model's run

/// One valid hour: a reading per grid point, nil where the model had none.
public struct SurfaceHour: Codable, Equatable, Sendable {
    public var valid: Date
    public var readings: [SurfaceReading?]

    public init(valid: Date, readings: [SurfaceReading?]) {
        self.valid = valid; self.readings = readings
    }
}

public struct SurfaceRun: Codable, Equatable, Sendable {
    public var grid: SurfaceGrid
    /// Oldest first, one per hour.
    public var hours: [SurfaceHour]
    /// The HRRR cycle behind the forecast hours, from Open-Meteo's metadata.
    /// Nil when the metadata could not be read — the numbers are still the
    /// HRRR's, only unnamed.
    public var run: ModelRun?

    public init(grid: SurfaceGrid, hours: [SurfaceHour], run: ModelRun?) {
        self.grid = grid; self.hours = hours; self.run = run
    }

    public static let source = "HRRR"

    /// The hour `back` hours before `index`, if the run holds it.
    public func index(_ index: Int, minusHours back: Int) -> Int? {
        let target = hours[index].valid.addingTimeInterval(-Double(back) * 3600)
        return hours.firstIndex { abs($0.valid.timeIntervalSince(target)) < 60 }
    }
}

/// HRRR surface fields on a grid, from Open-Meteo. No key, no account.
public struct SurfaceForecastClient: Sendable {
    public let grid: SurfaceGrid
    private let session: URLSession

    /// See `UpperAirClient.chunkSize`.
    public static let chunkSize = 24
    public static let model = "ncep_hrrr_conus"
    public static let credit = "HRRR · NOAA/NCEP via Open-Meteo"

    /// Six hours back so the 3-hour changes exist from the first hour shown;
    /// 48 ahead because the 00, 06, 12 and 18Z runs reach that far (the others
    /// stop at 18, and their missing hours are trimmed rather than drawn).
    public static let pastHours = 6
    public static let forecastHours = 48

    public init(grid: SurfaceGrid, session: URLSession = .shared) {
        self.grid = grid
        self.session = session
    }

    public enum Failure: Error, LocalizedError {
        case badResponse(status: Int)
        case incomplete(String)

        /// HTTP 429: Open-Meteo's free allowance is spent for now. Every grid
        /// point counts as a call, so a ~300-point grid is ~300 calls, and a
        /// morning of relaunching and testing used the hour up (2026-10-15).
        public var isRateLimited: Bool {
            if case .badResponse(429) = self { return true }
            return false
        }

        public var errorDescription: String? {
            switch self {
            case .badResponse(429):        return "Open-Meteo's free limit is used up for the moment."
            case .badResponse(let status): return "Open-Meteo returned HTTP \(status)."
            case .incomplete(let why):     return "The HRRR response was incomplete: \(why)"
            }
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
            .init(name: "hourly", value: "temperature_2m,dew_point_2m,wind_speed_10m,wind_direction_10m,wind_gusts_10m,pressure_msl"),
            .init(name: "models", value: "gfs_hrrr"),
            .init(name: "temperature_unit", value: "fahrenheit"),
            .init(name: "wind_speed_unit", value: "mph"),
            .init(name: "past_hours", value: "\(pastHours)"),
            .init(name: "forecast_hours", value: "\(forecastHours)"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "GMT"),
        ]
        return components.url!
    }

    /// The newest run's metadata — asked first, so a caller can skip the grid
    /// fetch entirely when the run hasn't changed.
    public func latestRun() async -> ModelRun? {
        try? await ModelRunClient(session: session).run(Self.model)
    }

    public func fetch(run: ModelRun?) async throws -> SurfaceRun {
        var locations: [Location] = []
        // One after another, as for the 500 mb grid: a free service.
        for chunk in stride(from: 0, to: grid.count, by: Self.chunkSize).map({
            Array(grid.points[$0..<min($0 + Self.chunkSize, grid.count)])
        }) {
            var request = URLRequest(url: Self.forecastURL(chunk))
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw Failure.badResponse(status: http.statusCode)
            }
            let decoded = try Self.decode(data)
            guard decoded.count == chunk.count else {
                throw Failure.incomplete("asked for \(chunk.count) points, got \(decoded.count)")
            }
            locations += decoded
        }
        return try Self.assemble(grid: grid, locations: locations, run: run)
    }

    struct Location: Decodable {
        struct Hourly: Decodable {
            let time: [Double]
            let temperature_2m: [Double?]
            let dew_point_2m: [Double?]
            let wind_speed_10m: [Double?]
            let wind_direction_10m: [Double?]
            let wind_gusts_10m: [Double?]
            let pressure_msl: [Double?]
        }
        let hourly: Hourly
    }

    /// Several coordinates come back as an array; one as a bare object.
    static func decode(_ data: Data) throws -> [Location] {
        let decoder = JSONDecoder()
        if let many = try? decoder.decode([Location].self, from: data) { return many }
        return [try decoder.decode(Location.self, from: data)]
    }

    /// Locations in grid order → hours. An hour where most of the grid is empty
    /// is past the end of this run and is dropped; a point missing in an hour
    /// that is otherwise there is left as a hole.
    static func assemble(grid: SurfaceGrid, locations: [Location], run: ModelRun?) throws -> SurfaceRun {
        guard locations.count == grid.count else {
            throw Failure.incomplete("expected \(grid.count) points, got \(locations.count)")
        }
        guard let times = locations.first?.hourly.time else { throw Failure.incomplete("no times") }
        for location in locations where location.hourly.time != times {
            throw Failure.incomplete("points disagree about the forecast hours")
        }
        var hours: [SurfaceHour] = []
        for (t, time) in times.enumerated() {
            let readings: [SurfaceReading?] = locations.map { location in
                let h = location.hourly
                guard t < h.temperature_2m.count,
                      let temp = h.temperature_2m[t], let dew = h.dew_point_2m[t],
                      let speed = h.wind_speed_10m[t] else { return nil }
                return SurfaceReading(temperature: temp, dewPoint: dew,
                                      windFrom: speed < 2 ? nil : h.wind_direction_10m[t],
                                      windSpeed: speed, gust: h.wind_gusts_10m[t],
                                      pressure: h.pressure_msl[t])
            }
            let held = readings.filter { $0 != nil }.count
            guard held * 10 >= grid.count * 9 else { continue }
            hours.append(SurfaceHour(valid: Date(timeIntervalSince1970: time), readings: readings))
        }
        guard !hours.isEmpty else { throw Failure.incomplete("no hour had data") }
        return SurfaceRun(grid: grid, hours: hours, run: run)
    }
}

// MARK: - Keeping a run

/// The newest run, kept on disk so a relaunch doesn't spend another few
/// hundred of Open-Meteo's calls on the run it already has. One file, replaced
/// when a newer run arrives: unlike the 500 mb runs, nothing compares these
/// afterwards.
public struct SurfaceRunCache: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func save(_ run: SurfaceRun) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try PropertyListEncoder().encode(run).write(to: url, options: .atomic)
    }

    /// The kept run, if it was fetched for this grid.
    public func load(grid: SurfaceGrid) -> SurfaceRun? {
        guard let data = try? Data(contentsOf: url),
              let run = try? PropertyListDecoder().decode(SurfaceRun.self, from: data),
              run.grid == grid else { return nil }
        return run
    }
}

// MARK: - Airports

/// One airport's report.
public struct AirportReport: Equatable, Sendable, Identifiable {
    public var station: String
    public var name: String
    public var point: GeoPoint
    public var time: Date
    public var reading: SurfaceReading

    public var id: String { "\(station)@\(Int(time.timeIntervalSince1970))" }

    public init(station: String, name: String, point: GeoPoint, time: Date, reading: SurfaceReading) {
        self.station = station; self.name = name; self.point = point
        self.time = time; self.reading = reading
    }
}

/// Airport reports from the Aviation Weather Center's data API. No key.
public struct AirportReportClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public static let credit = "Airport reports · NOAA Aviation Weather Center"

    /// Every report in the box during the hour ending at `end`.
    public func hour(ending end: Date, south: Double, west: Double,
                     north: Double, east: Double) async throws -> [AirportReport] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var components = URLComponents(string: "https://aviationweather.gov/api/data/metar")!
        components.queryItems = [
            .init(name: "bbox", value: String(format: "%.2f,%.2f,%.2f,%.2f", south, west, north, east)),
            .init(name: "format", value: "json"),
            .init(name: "hours", value: "1"),
            .init(name: "date", value: iso.string(from: end)),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Vane weather app", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(status: http.statusCode)
        }
        return try Self.decode(data)
    }

    public enum Failure: Error, LocalizedError {
        case badResponse(status: Int)
        public var errorDescription: String? {
            switch self {
            case .badResponse(let status): return "The Aviation Weather Center returned HTTP \(status)."
            }
        }
    }

    struct Report: Decodable {
        let icaoId: String
        let name: String?
        let obsTime: Double
        let lat: Double
        let lon: Double
        let temp: Double?
        let dewp: Double?
        let wdir: Direction?
        let wspd: Double?
        let wgst: Double?
        let slp: Double?
        let altim: Double?

        /// Degrees, or "VRB" for variable.
        enum Direction: Decodable {
            case degrees(Double), variable
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let d = try? c.decode(Double.self) { self = .degrees(d) } else { self = .variable }
            }
        }
    }

    /// Reports missing a temperature or dewpoint are dropped: they are the two
    /// numbers every clue but the wind leans on.
    static func decode(_ data: Data) throws -> [AirportReport] {
        let reports = try JSONDecoder().decode([Report].self, from: data)
        return reports.compactMap { r in
            guard let t = r.temp, let d = r.dewp else { return nil }
            let knots = 1.15078
            let speed = (r.wspd ?? 0) * knots
            var from: Double?
            if case .degrees(let deg) = r.wdir, speed > 0 { from = deg == 0 ? 360 : deg }
            return AirportReport(
                station: r.icaoId, name: r.name ?? r.icaoId,
                point: GeoPoint(latitude: r.lat, longitude: r.lon),
                time: Date(timeIntervalSince1970: r.obsTime),
                reading: SurfaceReading(temperature: t * 9 / 5 + 32, dewPoint: d * 9 / 5 + 32,
                                        windFrom: from, windSpeed: speed,
                                        gust: r.wgst.map { $0 * knots },
                                        // Sea-level pressure where the station sends
                                        // it; the altimeter setting is close enough
                                        // for a 3-hour CHANGE, which is all it's for.
                                        pressure: r.slp ?? r.altim))
        }
    }

    /// Each station's newest report at or before `time`, no older than an hour
    /// and a quarter — an hourly report plus a little lateness.
    public static func latest(_ reports: [AirportReport], at time: Date,
                              within: TimeInterval = 75 * 60) -> [AirportReport] {
        var best: [String: AirportReport] = [:]
        for r in reports where r.time <= time && time.timeIntervalSince(r.time) <= within {
            if let held = best[r.station], held.time >= r.time { continue }
            best[r.station] = r
        }
        return best.values.sorted { $0.station < $1.station }
    }
}
