//
//  WeatherSamplesModel.swift  (macOS)
//
//  App-side owner of the SAMPLE archive — the station's minutes, as opposed to
//  `WeatherArchiveModel`'s copy of its days.
//
//  It is deliberately the same shape as its daily sibling: credentials in,
//  progress out, all the chunking and resume logic down in WeatherKit. What it
//  adds is a second stage. The daily archive IS the answer once it's filled; the
//  sample archive is only raw material, and the thing anyone actually looks at —
//  the wind climatology — costs 16 seconds to derive from it. So this model owns
//  a fill AND a cache refresh, in that order, and the view waits on the second.
//
//  CATCHING UP IS TWO DIFFERENT SIZES OF JOB wearing one button. On a cold
//  archive it's 1,429 requests and the better part of an hour; on a laptop opened
//  daily it's one day and one folded rose. `SampleFiller` already treats resume as
//  the default rather than a mode, so both are the same call — and the banner
//  distinguishes them only because a progress bar that says "1 of 1" every morning
//  is noise, while one that says nothing during a first run looks broken.
//
//  IT SPANS THE DAILY ARCHIVE, NOT THE STATION'S WHOLE LIFE. The daily archive
//  has already worked out where the record starts and which days the station was
//  actually reporting; asking the same questions again would mean a second cold
//  start against `stationCreated`, and re-deriving a span that's already on disk.
//

import Foundation
import Combine
import WeatherKit

@MainActor
final class WeatherSamplesModel: ObservableObject {
    /// The wind at this station, from the cache. Nil until the first refresh
    /// finishes — the Wind tab renders its own waiting state rather than an
    /// empty rose, because a rose of zeros is indistinguishable from a calm.
    @Published private(set) var climate: WindClimate?

    /// The shape of a day here, month by month. Comes out of the SAME fold as
    /// the rose — see `SampleClimateCache` — so it costs nothing extra and
    /// arrives at the same moment.
    @Published private(set) var dayShape: DiurnalClimate?

    /// Non-nil while days are being fetched.
    @Published private(set) var fillProgress: SampleFillProgress?
    /// Non-nil while the cache is folding days in. Separate from the fill because
    /// they are different waits: one is the network, one is the disk, and on a
    /// cold start the second is the one that takes the visible 16 seconds.
    @Published private(set) var foldProgress: (done: Int, total: Int)?

    @Published private(set) var lastFailure: SampleFillSummary?
    @Published private(set) var dayCount: Int = 0

    /// Work is in flight that WILL produce a `climate`, but hasn't yet.
    ///
    /// THE STATE THAT WAS MISSING, and its absence was a lie rather than a gap.
    /// `loadCached` reads the cache on a detached task and `fold` rebuilds it off
    /// the main actor, and during both `climate`, `fillProgress` and
    /// `foldProgress` are all nil — which is indistinguishable, to the view, from
    /// having no wind history at all. So Wind confidently said "No wind history
    /// yet" while the answer was three seconds away on a background queue. A
    /// reader who believes it goes looking for a bug that isn't there.
    ///
    /// Distinct from `foldProgress` because that one carries a FRACTION and only
    /// appears once the fold is big enough to be worth a bar (> 30 days). This is
    /// the honest "something is happening" for everything before and around that.
    @Published private(set) var isPreparing = false
    @Published private(set) var error: String?

    let store: FileSampleArchive
    private let cache: SampleClimateCache
    private var isRunning = false
    private var task: Task<Void, Never>?

    init(root: URL? = nil) {
        let weather = root ?? AppGroup.dataDirectory.appendingPathComponent("Weather", isDirectory: true)
        store = FileSampleArchive(root: weather.appendingPathComponent("samples", isDirectory: true))
        // Renamed with the cache itself: it stopped being only about wind when
        // the diurnal fold joined the pass. An old `wind-climate.json` left
        // beside it is simply ignored and can be deleted.
        cache = SampleClimateCache(url: weather.appendingPathComponent("sample-climate.json"))
    }

    /// Read whatever the cache already holds, without touching the network.
    ///
    /// Called on appear so an app opened for the tenth time shows the rose
    /// immediately and catches up behind it. On a warm cache this is a single
    /// small file read; it is deliberately NOT a `refresh`, because folding in
    /// days would put a 16-second disk job on the path to first paint.
    func loadCached() {
        guard climate == nil else { return }
        let cache = self.cache
        isPreparing = true
        Task.detached(priority: .userInitiated) {
            let stored = cache.load()
            let climate = stored?.climate()
            let shape = stored?.dayShape()
            await MainActor.run {
                // Cleared on EVERY path, including the one where there is no
                // cache to read. An early return that skipped this is how a
                // spinner becomes permanent.
                self.isPreparing = false
                guard let climate, let shape else { return }
                self.climate = climate
                self.dayShape = shape
            }
        }
        refreshCount()
    }

    /// Fetch any days the daily archive holds that the sample archive doesn't,
    /// then fold whatever landed into the sample cache.
    ///
    /// Safe on every launch: a current archive fetches nothing and folds nothing.
    func catchUp(token: String, stationID: Int, daily: FileDailyArchive) {
        guard !token.isEmpty, stationID != 0, !isRunning else { return }
        isRunning = true
        error = nil
        lastFailure = nil

        task = Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isRunning = false } }

            let client = TempestClient(token: token, stationID: stationID)
            let filler = SampleFiller(store: store, fetch: client.archiveFetcher())
            let summary = await filler.fillMatchingDailyArchive(daily) { [weak self] update in
                Task { @MainActor in self?.fillProgress = update }
            }

            await MainActor.run {
                self.fillProgress = nil
                // A long fill WILL lose days to the throttle (see
                // `SampleSync.defaultConcurrency`). Naming them is what makes the
                // retry cheap; hiding them is what makes a climatology quietly short.
                self.lastFailure = summary.isComplete ? nil : summary
                self.refreshCount()
            }

            await self.fold()
        }
    }

    /// Retry only the days that failed. The whole point of `failedDays` being a
    /// list rather than a count — and the throttle resets between runs, so this
    /// usually lands what the previous pass couldn't.
    func retryFailures(token: String, stationID: Int) {
        guard let failure = lastFailure, !failure.failedDays.isEmpty,
              !token.isEmpty, stationID != 0, !isRunning else { return }
        isRunning = true
        lastFailure = nil

        task = Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isRunning = false } }

            let client = TempestClient(token: token, stationID: stationID)
            let filler = SampleFiller(store: store, fetch: client.archiveFetcher())
            let summary = await filler.fill(days: failure.failedDays) { [weak self] update in
                Task { @MainActor in self?.fillProgress = update }
            }
            await MainActor.run {
                self.fillProgress = nil
                self.lastFailure = summary.isComplete ? nil : summary
                self.refreshCount()
            }
            await self.fold()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        fillProgress = nil
        foldProgress = nil
    }

    /// Bring the sample cache up to the archive, off the main actor.
    ///
    /// Detached rather than merely async: on a cold cache this is sixteen seconds
    /// of JSON decoding, and run anywhere near the main actor it would stop the
    /// window dead — the exact failure this cache exists to prevent.
    private func fold() async {
        let cache = self.cache
        let store = self.store
        isPreparing = true
        let built = await Task.detached(priority: .userInitiated) { () -> (wind: WindClimate, day: DiurnalClimate) in
            cache.refresh(from: store) { done, total in
                Task { @MainActor in
                    // Only worth showing while there's a real wait. A daily fold of
                    // one day would otherwise flash a progress bar on every launch.
                    self.foldProgress = total > 30 ? (done, total) : nil
                }
            }
        }.value

        await MainActor.run {
            self.isPreparing = false
            self.foldProgress = nil
            self.climate = built.wind
            self.dayShape = built.day
        }
    }

    private func refreshCount() {
        dayCount = ((try? store.archivedDays()) ?? []).count
    }
}
