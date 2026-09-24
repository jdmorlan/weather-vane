//
//  WeatherArchiveModel.swift  (macOS)
//
//  App-side owner of the local station archive: where it lives on disk, when it
//  catches up, and what the UI shows while it does.
//
//  The archive is the durable copy of a history that currently exists only on
//  WeatherFlow's servers — so it lives in the data directory as plain per-year
//  JSON, legible without this app, in line with the rest of the vault.
//
//  All the fill logic (chunking, commit-as-you-go, resume, partial failure) is in
//  WeatherKit. This type is glue: credentials in, progress out.
//

import Foundation
import Combine
import WeatherKit

@MainActor
final class WeatherArchiveModel: ObservableObject {
    /// Non-nil only while a fill is running — the view's cue to show a banner.
    @Published private(set) var progress: BackfillProgress?
    /// Set when a fill ends with failed chunks, so the UI can offer a retry
    /// instead of silently pretending the archive is complete.
    @Published private(set) var lastFailure: BackfillSummary?
    @Published private(set) var error: String?
    @Published private(set) var dayCount: Int = 0
    @Published private(set) var earliestDay: String?
    @Published private(set) var latestDay: String?

    /// The archive as something queryable — normals, rankings, streaks, records.
    /// Nil until the first load finishes; the forecast renders without it.
    @Published private(set) var climatology: Climatology?

    /// The archive is being parsed into `climatology` right now.
    ///
    /// Same omission as `WeatherSamplesModel.isPreparing`, with the same
    /// consequence: `reload` parses every year file on a detached task, and until
    /// it lands `climatology` is nil — so Rhythms, Rain and Explore all announced
    /// "Not enough record yet" about an archive holding four years. The message
    /// was not early, it was wrong.
    @Published private(set) var isLoadingClimatology = false

    /// True while re-fetching days that predate the current rollup. Distinct from
    /// a plain catch-up because the archive is already complete by day — it's the
    /// per-day detail that's being filled in — and the banner should say so
    /// rather than implying history is missing.
    @Published private(set) var isUpgrading = false

    /// `<data>/Weather/daily/2022.json`, `2023.json`, …
    let store: FileDailyArchive

    private var isRunning = false
    private var task: Task<Void, Never>?

    init(root: URL? = nil) {
        let dir = root ?? AppGroup.dataDirectory
            .appendingPathComponent("Weather", isDirectory: true)
            .appendingPathComponent("daily", isDirectory: true)
        store = FileDailyArchive(root: dir)
        reload()
    }

    /// Wait for a catch-up that is already running, if one is.
    ///
    /// EXISTS FOR THE SAMPLE ARCHIVE, which can only ask for the minutes behind
    /// days this archive already holds. Returns at once when nothing is running,
    /// which is the every-launch case on a warm machine.
    func waitForCatchUp() async {
        await task?.value
    }

    /// Bring the archive up to yesterday. Safe to call on every launch: an
    /// already-current archive does nothing, and a laptop closed for a week just
    /// does a slightly bigger catch-up.
    func catchUp(token: String, stationID: Int) {
        guard !token.isEmpty, stationID != 0, !isRunning else { return }
        isRunning = true
        error = nil
        lastFailure = nil

        task = Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isRunning = false } }

            let client = TempestClient(token: token, stationID: stationID)

            // Only needed on a cold archive; once we hold days, catchUp resumes
            // from the last one and never looks at this.
            var start = Self.fallbackStart
            if (try? store.lastArchivedDay()) == nil {
                if let created = try? await client.stationCreated() {
                    start = created
                }
            }

            let filler = ArchiveFiller(store: store, fetch: client.archiveFetcher())
            let summary = await filler.catchUp(stationStart: start) { [weak self] update in
                Task { @MainActor in self?.progress = update }
            }

            await MainActor.run {
                self.progress = nil
                self.lastFailure = summary.isComplete ? nil : summary
                self.reload()
            }

            // Then bring old days up to the current rollup. Second, not first:
            // catching up to yesterday is what the screen is waiting on, while
            // this only enriches days already on disk.
            await self.upgradeStaleDays(using: filler)
        }
    }

    /// Re-fetch days written before the current rollup so they gain its fields.
    ///
    /// Counters like chill hours can only be computed while the raw samples are
    /// in hand, so a new measure means re-pulling the observations for days that
    /// predate it — once, after which `staleDays` is empty and this costs a single
    /// disk read per launch.
    private func upgradeStaleDays(using filler: ArchiveFiller) async {
        guard let stale = try? store.staleDays(), !stale.isEmpty else { return }

        await MainActor.run { self.isUpgrading = true }
        let summary = await filler.refillStale { [weak self] update in
            Task { @MainActor in self?.progress = update }
        }
        await MainActor.run {
            self.isUpgrading = false
            self.progress = nil
            if !summary.isComplete { self.lastFailure = summary }
            self.reload()
        }
    }

    /// Re-run only the windows that failed, keeping everything that landed.
    func retryFailures(token: String, stationID: Int) {
        guard let failure = lastFailure, !failure.failedRanges.isEmpty,
              !token.isEmpty, stationID != 0, !isRunning else { return }
        isRunning = true
        lastFailure = nil

        task = Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isRunning = false } }

            let client = TempestClient(token: token, stationID: stationID)
            let filler = ArchiveFiller(store: store, fetch: client.archiveFetcher())
            var stillFailing: [DateInterval] = []
            let total = failure.failedRanges.count

            for (i, range) in failure.failedRanges.enumerated() {
                await MainActor.run {
                    self.progress = BackfillProgress(completedChunks: i, totalChunks: total,
                                                     currentStart: range.start, currentEnd: range.end)
                }
                let result = await filler.fill(from: range.start, to: range.end)
                stillFailing.append(contentsOf: result.failedRanges)
            }

            await MainActor.run {
                self.progress = nil
                self.lastFailure = stillFailing.isEmpty ? nil
                    : BackfillSummary(daysArchived: 0, chunksCompleted: 0,
                                      chunksFailed: stillFailing.count,
                                      earliestDay: nil, latestDay: nil,
                                      failedRanges: stillFailing)
                self.reload()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
        isRunning = false
    }

    /// Re-read the archive and rebuild the queryable view of it.
    ///
    /// Off the main actor: this parses every year file, which is milliseconds
    /// today and grows with the record — it has no business on the thread that
    /// draws. The published values land back on main in one hop, so the UI never
    /// sees a half-updated archive.
    private func reload() {
        let store = self.store
        isLoadingClimatology = true
        Task.detached(priority: .utility) {
            let records = try? store.allRecords()
            let climate = records.map(Climatology.init(records:))
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Cleared before the guard, so an unreadable archive settles into
                // its empty state rather than spinning forever.
                self.isLoadingClimatology = false
                guard let records, let climate else { return }
                self.dayCount = records.count
                self.earliestDay = records.first?.day
                self.latestDay = records.last?.day
                self.climatology = climate
            }
        }
    }

    /// Only used if the station-metadata lookup fails on a cold archive. Tempest
    /// stations didn't exist before this, so it can't miss data.
    private static let fallbackStart = Date(timeIntervalSince1970: 1_420_070_400)  // 2015-01-01
}
