//
//  FrontModel.swift  (Weather)
//
//  The Front view's data: the HRRR's surface fields on a grid around home, the
//  airport reports for the hours already past, and which hour and which clue
//  the map is showing.
//
//  REFETCHED BY RUN, NOT BY CLOCK. The HRRR runs hourly; Open-Meteo's metadata
//  says when a new one has landed, so the grid is fetched once per run and the
//  check between runs is one small file. See `SurfaceWeather` for what a grid
//  fetch costs.
//
//  AIRPORTS: NEWEST HOUR FIRST, then backwards. The newest hour is what you are
//  most likely looking at; the older ones fill in the past end of the slider
//  and the 3-hour changes behind it.
//

import Foundation
import SwiftUI
import WeatherKit

@MainActor
final class FrontModel: ObservableObject {
    @Published private(set) var run: SurfaceRun?
    @Published private(set) var airports: [AirportReport] = []
    @Published private(set) var failure: String?
    @Published private(set) var loading = false
    /// The hour on the map, by valid time — so a new run keeps you on the same
    /// hour rather than the same index.
    @Published var hour: Date?
    /// The metric the map colours. Temperature first: it's the map everyone
    /// already knows how to read. Remembered, as a view's settings are.
    @Published var clue: FrontClue = FrontClue(rawValue: UserDefaults.standard.string(forKey: "frontMetric") ?? "")
        ?? .temperature {
        didSet { UserDefaults.standard.set(clue.rawValue, forKey: "frontMetric") }
    }
    /// Numbers on the map as well as colours. Off to start: colours alone read
    /// at a glance, and numbers everywhere are a lot to take in.
    @Published var showsNumbers: Bool = UserDefaults.standard.bool(forKey: "frontNumbers") {
        didSet { UserDefaults.standard.set(showsNumbers, forKey: "frontNumbers") }
    }
    /// Where the map was clicked, for the spot card.
    @Published var spot: GeoPoint?
    @Published var isPlaying = false

    private var home: GeoPoint?
    private var readings: [Int: FrontReading] = [:]
    private var airportHours: Set<Date> = []
    private var passageCache: (key: String, date: Date?)?

    /// The first hour the slider offers: three hours into the run, the first
    /// with a 3-hour change behind it.
    var firstHour: Int { min(3, max(0, (run?.hours.count ?? 1) - 1)) }

    var hourIndex: Int? {
        guard let run, !run.hours.isEmpty else { return nil }
        guard let hour else { return nowIndex }
        let i = run.hours.firstIndex { abs($0.valid.timeIntervalSince(hour)) < 60 } ?? nowIndex ?? firstHour
        return max(firstHour, i)
    }

    /// The hour that has most recently begun.
    var nowIndex: Int? {
        guard let run, !run.hours.isEmpty else { return nil }
        let now = Date()
        let i = run.hours.lastIndex { $0.valid <= now } ?? 0
        return max(firstHour, i)
    }

    func select(_ index: Int) {
        guard let run, run.hours.indices.contains(index) else { return }
        hour = run.hours[max(firstHour, index)].valid
    }

    private var pictureCache: (key: String, picture: FrontPicture)?

    /// The map's picture for the hour and clue chosen. Cached, because the map's
    /// layers are rebuilt on every SwiftUI pass and the shading is a few
    /// thousand samples.
    func picture() -> FrontPicture? {
        guard let run, let index = hourIndex else { return nil }
        let past = run.hours[index].valid <= Date()
        let key = "\(index)|\(clue.rawValue)|\(showsNumbers)|\(run.run?.initialised.timeIntervalSince1970 ?? 0)|\(run.hours.count)|\(past ? airports.count : -1)"
        if let cached = pictureCache, cached.key == key { return cached.picture }
        let picture = FrontPicture.make(run: run, index: index, metric: clue, numbers: showsNumbers,
                                        airports: airports, home: home)
        pictureCache = (key, picture)
        return picture
    }

    /// The HRRR at a place, between grid points. Direction from the nearest
    /// point: averaging 350° and 10° the plain way gives 180°.
    func readingAt(_ p: GeoPoint, index: Int) -> (now: SurfaceReading, pressureChange: Double?)? {
        guard let run, run.hours.indices.contains(index) else { return nil }
        let grid = run.grid
        let hour = run.hours[index].readings
        func field(_ f: (SurfaceReading) -> Double?) -> Double? { grid.sample(hour.map { $0.flatMap(f) }, at: p) }
        guard let t = field({ $0.temperature }), let d = field({ $0.dewPoint }),
              let speed = field({ $0.windSpeed }) else { return nil }
        let nearest = hour.indices.min {
            FrontReader.miles(grid.point($0), p) < FrontReader.miles(grid.point($1), p)
        }.flatMap { hour[$0] }
        let pressure = field { $0.pressure }
        let change = run.index(index, minusHours: 3).flatMap { back -> Double? in
            guard let pressure, let then = grid.sample(run.hours[back].readings.map { $0?.pressure }, at: p)
            else { return nil }
            return pressure - then
        }
        return (SurfaceReading(temperature: t, dewPoint: d, windFrom: speed < 2 ? nil : nearest?.windFrom,
                               windSpeed: speed, gust: field { $0.gust }, pressure: pressure), change)
    }

    /// An airport within 15 miles of `p` that reported in the hour, if any.
    func airportNear(_ p: GeoPoint, at time: Date) -> AirportReport? {
        guard time <= Date() else { return nil }
        return AirportReportClient.latest(airports, at: time.addingTimeInterval(30 * 60))
            .map { ($0, FrontReader.miles($0.point, p)) }
            .filter { $0.1 <= 15 }
            .min { $0.1 < $1.1 }?.0
    }

    func reading(at index: Int) -> FrontReading? {
        guard let run else { return nil }
        if let cached = readings[index] { return cached }
        let r = FrontReader.read(run, at: index, home: home)
        readings[index] = r
        return r
    }

    /// When the front reaches home in this run.
    var passage: Date? {
        guard let run, let home else { return nil }
        let key = "\(run.run?.initialised.timeIntervalSince1970 ?? 0)|\(run.hours.count)"
        if let cached = passageCache, cached.key == key { return cached.date }
        let date = FrontReader.passage(run, home: home)
        passageCache = (key, date)
        return date
    }

    var stamp: SourceStamp? {
        guard let run else { return nil }
        if let model = run.run { return model.stamp(source: SurfaceRun.source) }
        return SourceStamp(source: SurfaceRun.source, made: .unpublished)
    }

    // MARK: Loading

    /// Runs while the Front view is on screen.
    func keepCurrent(home: GeoPoint) async {
        if self.home != home {
            self.home = home
            run = nil; airports = []; airportHours = []; readings = [:]; passageCache = nil
        }
        async let models: Void = keepRunCurrent(home: home)
        async let reports: Void = keepAirportsCurrent(home: home)
        _ = await (models, reports)
    }

    /// The kept run: in Caches, because it is only ever a shortcut — losing it
    /// costs one fetch.
    private static let cache = SurfaceRunCache(url:
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("front-hrrr.plist"))

    private func keepRunCurrent(home: GeoPoint) async {
        let grid = SurfaceGrid.around(home)
        let client = SurfaceForecastClient(grid: grid)
        // A relaunch starts from the run already on disk, if it's for here.
        if run == nil, let kept = await Task.detached(priority: .utility, operation: {
            Self.cache.load(grid: grid)
        }).value {
            run = kept
            readings = [:]
        }
        while !Task.isCancelled {
            let latest = await client.latestRun()
            let held = run?.run?.initialised
            // FETCH ONLY FOR A NEWER RUN. With no answer from the metadata, a run
            // already held is kept: refetching blind every few minutes is what
            // spends the free allowance.
            var wait: Double = 300
            if run == nil || (latest != nil && latest?.initialised != held) {
                loading = true
                do {
                    let fetched = try await client.fetch(run: latest)
                    run = fetched
                    readings = [:]
                    failure = nil
                    Task.detached(priority: .utility) { try? Self.cache.save(fetched) }
                } catch is CancellationError {
                    loading = false
                    return
                } catch {
                    if (error as? URLError)?.code == .cancelled { loading = false; return }
                    failure = error.localizedDescription
                    // Over the limit: asking again soon only keeps it tripped.
                    let limited = (error as? SurfaceForecastClient.Failure)?.isRateLimited ?? false
                    wait = limited ? 900 : 120
                    if limited { failure = (failure ?? "") + " Trying again in 15 minutes." }
                }
                loading = false
            }
            // A new run lands about an hour after the last; looking every five
            // minutes catches it within a few, for the cost of one small file.
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    private func keepAirportsCurrent(home: GeoPoint) async {
        let client = AirportReportClient()
        let grid = SurfaceGrid.around(home)
        let south = grid.latitudes.first ?? home.latitude - 6
        let north = grid.latitudes.last ?? home.latitude + 6
        let west = grid.longitudes.first ?? home.longitude - 7
        let east = grid.longitudes.last ?? home.longitude + 7
        while !Task.isCancelled {
            let now = Date()
            // The hour just ended is always re-asked: reports keep arriving
            // for it. Older hours, once held, are final.
            let hours = (0..<(SurfaceForecastClient.pastHours + 4)).map { now.addingTimeInterval(-Double($0) * 3600) }
            for (n, end) in hours.enumerated() {
                let bucket = Date(timeIntervalSince1970: (end.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
                if n > 0, airportHours.contains(bucket) { continue }
                guard let got = try? await client.hour(ending: end, south: south, west: west,
                                                       north: north, east: east) else { continue }
                if Task.isCancelled { return }
                var byID = Dictionary(airports.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for report in got { byID[report.id] = report }
                // Twelve hours is all the slider's past end can reach.
                airports = byID.values.filter { now.timeIntervalSince($0.time) < 12 * 3600 }
                if n > 0 { airportHours.insert(bucket) }
            }
            try? await Task.sleep(for: .seconds(600))
        }
    }

    // MARK: Playing

    /// Steps an hour every 0.7 s while `isPlaying`, wrapping at the end.
    func play() async {
        while !Task.isCancelled, isPlaying {
            try? await Task.sleep(for: .milliseconds(700))
            guard isPlaying, let run, let i = hourIndex else { continue }
            select(i + 1 < run.hours.count ? i + 1 : firstHour)
        }
    }
}
