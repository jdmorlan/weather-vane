//
//  ModelRuns.swift  (WeatherKit)
//
//  WHICH RUN OF EACH MODEL OPEN-METEO IS SERVING, and when the next one lands.
//
//  The forecast response never says which cycle its numbers came from, but
//  every model has a metadata file beside it — `/data/<model>/static/meta.json`
//  — with the run's start, when it became available, and how often the model
//  runs. `UpperAirClient` found this first for the GFS; this is the same file
//  for any model.
//
//  THE MODELS DO NOT KEEP TIME TOGETHER, which is the reason this is shown at
//  all. At 10:36 AM CDT on 30 September the rain card's eleven were: NBM from
//  9 AM and HRRR from 8 AM (both hourly), every 6-hourly global from 1 AM —
//  landing anywhere from 4:28 AM (ICON) to 10:32 AM (JMA). "4 of 11 say rain"
//  is a vote between forecasts that are up to nine hours apart in what they
//  knew.
//
//  THE METADATA CAN LIE, AND THEN IT IS NOT SHOWN. On the same day GEM's file
//  said its newest run was from 26 May while its data ran to 9 October. A date
//  that old cannot be the run behind a forecast that reaches next week, so a
//  run far older than its own cadence allows is reported as unpublished rather
//  than printed.
//

import Foundation

/// One model's newest run, as Open-Meteo describes it.
public struct ModelRun: Codable, Equatable, Sendable {
    /// The analysis time the run started from — "the 12Z run".
    public var initialised: Date
    /// When Open-Meteo finished taking it in.
    public var available: Date
    /// How often the model runs.
    public var interval: TimeInterval

    public init(initialised: Date, available: Date, interval: TimeInterval) {
        self.initialised = initialised; self.available = available; self.interval = interval
    }

    /// A run older than this cannot be what a model on this cadence is
    /// serving — the metadata is stale, not the model. A day's slack covers a
    /// global model that is running a cycle or two behind.
    public func isPlausible(now: Date = Date()) -> Bool {
        now.timeIntervalSince(initialised) <= max(4 * interval, 24 * 3600)
    }

    /// When the NEXT run should land: this one's arrival plus the cadence.
    /// Each model is late by about the same amount every cycle, so the last
    /// arrival is a better anchor than the start time.
    public var nextAvailable: Date { available.addingTimeInterval(interval) }

    public func stamp(source: String, now: Date = Date()) -> SourceStamp {
        guard isPlausible(now: now) else { return SourceStamp(source: source, made: .unpublished) }
        return SourceStamp(source: source, made: .run(initialised), next: nextAvailable)
    }
}

public struct ModelRunClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public static func metaURL(_ model: String) -> URL {
        URL(string: "https://api.open-meteo.com/data/\(model)/static/meta.json")!
    }

    public func run(_ model: String) async throws -> ModelRun {
        var request = URLRequest(url: Self.metaURL(model))
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try Self.decode(data)
    }

    /// Every model's run at once. One that fails is simply missing from the
    /// answer — a row without a run time is still a forecast.
    public func runs(_ models: [String]) async -> [String: ModelRun] {
        await withTaskGroup(of: (String, ModelRun?).self) { group in
            for model in models {
                group.addTask { (model, try? await run(model)) }
            }
            var out: [String: ModelRun] = [:]
            for await (model, run) in group { if let run { out[model] = run } }
            return out
        }
    }

    struct Meta: Decodable {
        let last_run_initialisation_time: Double
        let last_run_availability_time: Double
        let update_interval_seconds: Double
    }

    static func decode(_ data: Data) throws -> ModelRun {
        let meta = try JSONDecoder().decode(Meta.self, from: data)
        return ModelRun(initialised: Date(timeIntervalSince1970: meta.last_run_initialisation_time),
                        available: Date(timeIntervalSince1970: meta.last_run_availability_time),
                        interval: meta.update_interval_seconds)
    }
}

extension PrecipModel {
    /// The underlying model whose metadata describes this row.
    ///
    /// The "seamless" series stitch a region's models together, and outside
    /// their home regions they ARE the global model — checked 30 September at
    /// central Texas, where each seamless series matched its global value for
    /// value. So the global's run is the run behind the row.
    public var metaName: String {
        switch self {
        case .nbm:    return "ncep_nbm_conus"
        case .hrrr:   return "ncep_hrrr_conus"
        case .ecmwf:  return "ecmwf_ifs025"
        case .ukmo:   return "ukmo_global_deterministic_10km"
        case .gfs:    return "ncep_gfs013"
        case .icon:   return "dwd_icon"
        case .gem:    return "cmc_gem_gdps"
        case .arpege: return "meteofrance_arpege_world025"
        case .jma:    return "jma_gsm"
        case .cma:    return "cma_grapes_global"
        case .aifs:   return "ecmwf_aifs025_single"
        }
    }
}
