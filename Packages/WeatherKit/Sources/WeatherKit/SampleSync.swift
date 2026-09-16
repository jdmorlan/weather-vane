//
//  SampleSync.swift  (WeatherKit)
//
//  Filling the sample archive from WeatherFlow's history endpoint.
//
//  THE PROBE THAT SET THE PARAMETERS (2026-09-02, against station 68737):
//
//    bucket │ max span per request │ 1 day of samples
//    ───────┼──────────────────────┼──────────────────
//       1   │ 1 day                │ ~1,439
//       5   │ 5 days               │ ~288
//      30   │ 30 days              │ ~48
//     180   │ (long)               │ ~8
//
//  10 and 15 are rejected outright — the valid set is {1, 5, 30, 180}. The API
//  trades span for resolution exactly, so the request count for a full backfill
//  is the same order of magnitude however you slice it; what changes is only how
//  much you keep.
//
//  AND 1-MINUTE DATA GOES ALL THE WAY BACK. A day in November 2022 returns 1,435
//  samples, same as a day last week — there is no retention cliff. The entire
//  history has always been available at native resolution; the original backfill
//  chose `bucket=30` to keep daily min/max honest at ~47 requests, which was the
//  right call for a DAILY archive and is the wrong one for this store.
//
//  So this fetches at `bucket=1`: one request per day, 1,419 requests for the
//  record, ~1.4 s each — about 33 minutes serially, under 10 with a handful in
//  flight. A one-time cost, and the only alternative that avoids it is throwing
//  away the resolution again.
//

import Foundation

public enum SampleSync {
    /// Native resolution. The station reports every minute and the API will serve
    /// every minute; anything coarser is a reduction taken at INGEST, which is
    /// the mistake this whole store exists to undo.
    public static let bucketMinutes = 1

    /// The API's hard cap at that bucket. Not a tuning knob.
    public static let chunkDays = 1

    /// The fetch windows covering one local day.
    ///
    /// Usually one: local midnight to a minute before the next. But **the cap is
    /// 86,400 SECONDS while a local day is not always 24 hours** — the fall-back
    /// day is 25 — so on that one day a year the natural window is 89,940 seconds
    /// and the API rejects it outright with "time range cannot exceed 1 day".
    /// Clamping instead would silently drop the repeated hour, which is the
    /// quieter and worse failure. So a long day is split and fetched in two.
    ///
    /// `ArchiveSync.chunks` steps by calendar days for the same reason; at a
    /// 29-day chunk the extra hour had slack to absorb it, and at a 1-day chunk
    /// there is none.
    ///
    /// Public and here rather than on `SampleFiller` because the backfill isn't
    /// the only caller any more: anything wanting ONE day at full resolution —
    /// the rain card asking what fell this afternoon — needs the same windows,
    /// and must not re-derive a rule this subtle.
    public static func windows(ofDay day: String, timeZone: TimeZone) -> [(start: Date, end: Date)] {
        guard let start = DayKey.date(from: day, timeZone: timeZone) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

        let cap: TimeInterval = 86_400 - 60
        var windows: [(start: Date, end: Date)] = []
        var cursor = start
        while cursor < next {
            let end = min(cursor.addingTimeInterval(cap), next.addingTimeInterval(-60))
            windows.append((cursor, end))
            cursor = end.addingTimeInterval(60)
        }
        return windows
    }

    /// How many day-requests to keep in flight.
    ///
    /// This was four, on the reasoning that the fetch is latency-bound and four is
    /// polite. MEASURED, on the real 1,429-day backfill (2026-09-12): four is not
    /// polite. The run lost 821 of 1,429 days, and the failure rate ACCELERATED —
    /// 5 failures by day 400, 821 by the end — which is the signature of a
    /// server-side throttle tightening, not of a flaky network. Every one of those
    /// days fetched perfectly when asked for on its own moments later.
    ///
    /// Two completes the same backfill with a handful of losses. The remaining
    /// lesson is that a long run should expect to be re-run: the throttle resets
    /// between invocations, so resume — already the default — is what actually
    /// carries a cold archive over the line, in four passes rather than one.
    public static let defaultConcurrency = 2
}

public struct SampleFillProgress: Equatable, Sendable {
    public var completedDays: Int
    public var totalDays: Int
    public var skippedDays: Int
    public var failedDays: Int
    public var samplesWritten: Int
    public var currentDay: String?
    public var isFinished: Bool

    public init(completedDays: Int = 0, totalDays: Int = 0, skippedDays: Int = 0,
                failedDays: Int = 0, samplesWritten: Int = 0,
                currentDay: String? = nil, isFinished: Bool = false) {
        self.completedDays = completedDays
        self.totalDays = totalDays
        self.skippedDays = skippedDays
        self.failedDays = failedDays
        self.samplesWritten = samplesWritten
        self.currentDay = currentDay
        self.isFinished = isFinished
    }

    public var fraction: Double {
        guard totalDays > 0 else { return isFinished ? 1 : 0 }
        return min(1, Double(completedDays + skippedDays) / Double(totalDays))
    }
}

public struct SampleFillSummary: Equatable, Sendable {
    public var daysWritten: Int
    public var daysSkipped: Int
    public var samplesWritten: Int
    /// Days the fetch failed on. A backfill this long WILL lose some to the
    /// network; naming them is what makes a second pass cheap instead of a
    /// full re-run.
    public var failedDays: [String]

    public init(daysWritten: Int = 0, daysSkipped: Int = 0,
                samplesWritten: Int = 0, failedDays: [String] = []) {
        self.daysWritten = daysWritten
        self.daysSkipped = daysSkipped
        self.samplesWritten = samplesWritten
        self.failedDays = failedDays
    }

    public var isComplete: Bool { failedDays.isEmpty }
}

/// Drives a sample backfill. The fetcher is injected so chunking, resume,
/// progress and failure behaviour are testable without touching the network —
/// same posture as `ArchiveFiller`.
public actor SampleFiller {
    public typealias Fetcher = @Sendable (_ start: Date, _ end: Date, _ bucketMinutes: Int) async throws -> StationObservations

    private let store: SampleArchiveStore
    private let fetch: Fetcher
    private let timeZone: TimeZone
    private let concurrency: Int

    public init(store: SampleArchiveStore,
                timeZone: TimeZone = .current,
                concurrency: Int = SampleSync.defaultConcurrency,
                fetch: @escaping Fetcher) {
        self.store = store
        self.fetch = fetch
        self.timeZone = timeZone
        self.concurrency = max(1, concurrency)
    }

    /// Fill every day in `days` that isn't already held.
    ///
    /// RESUME IS THE DEFAULT, not a mode. A 1,419-request run will be interrupted
    /// — by a lid, a network blip, a quit — and the only tolerable behaviour is
    /// that starting it again picks up where it stopped. Days already on disk are
    /// skipped, so "resume" and "run it again" are the same command. Pass
    /// `refetch: true` only to deliberately re-pull days at a finer bucket than
    /// they were first taken at; `SampleMerge` will still refuse to coarsen one.
    public func fill(days: [String],
                     refetch: Bool = false,
                     onProgress: (@Sendable (SampleFillProgress) -> Void)? = nil) async -> SampleFillSummary {
        let held = refetch ? [] : Set((try? store.archivedDays()) ?? [])
        let pending = days.filter { !held.contains($0) }
        let skipped = days.count - pending.count

        var summary = SampleFillSummary(daysSkipped: skipped)
        guard !pending.isEmpty else {
            onProgress?(SampleFillProgress(totalDays: days.count, skippedDays: skipped, isFinished: true))
            return summary
        }

        var completed = 0
        var cursor = 0

        await withTaskGroup(of: (String, [StationSample]?).self) { group in
            func schedule() {
                guard cursor < pending.count else { return }
                let day = pending[cursor]
                cursor += 1
                group.addTask { [fetch, timeZone] in
                    let windows = SampleSync.windows(ofDay: day, timeZone: timeZone)
                    guard !windows.isEmpty else { return (day, nil) }
                    do {
                        var samples: [StationSample] = []
                        for window in windows {
                            let response = try await fetch(window.start, window.end, SampleSync.bucketMinutes)
                            samples += StationSample.samples(from: response,
                                                             bucketMinutes: SampleSync.bucketMinutes)
                        }
                        return (day, samples)
                    } catch {
                        // Any window failing fails the day. A day half-fetched and
                        // recorded as done would be skipped by every later resume
                        // with no record that it's short.
                        return (day, nil)
                    }
                }
            }

            for _ in 0..<min(concurrency, pending.count) { schedule() }

            while let (day, samples) = await group.next() {
                if let samples, !samples.isEmpty {
                    // A day that fetched but wrote nothing is not a failure — the
                    // station was off. Recording it as one would send every future
                    // resume back to re-fetch genuine downtime forever.
                    if (try? store.merge(samples, timeZone: timeZone)) != nil {
                        summary.daysWritten += 1
                        summary.samplesWritten += samples.count
                    } else {
                        summary.failedDays.append(day)
                    }
                } else if samples == nil {
                    summary.failedDays.append(day)
                }
                completed += 1
                onProgress?(SampleFillProgress(completedDays: completed,
                                               totalDays: days.count,
                                               skippedDays: skipped,
                                               failedDays: summary.failedDays.count,
                                               samplesWritten: summary.samplesWritten,
                                               currentDay: day,
                                               isFinished: false))
                schedule()
            }
        }

        summary.failedDays.sort()
        onProgress?(SampleFillProgress(completedDays: completed,
                                       totalDays: days.count,
                                       skippedDays: skipped,
                                       failedDays: summary.failedDays.count,
                                       samplesWritten: summary.samplesWritten,
                                       isFinished: true))
        return summary
    }

    /// Fill the span the daily archive already covers — the usual entry point,
    /// since that span is exactly the history worth having at full resolution.
    public func fillMatchingDailyArchive(_ daily: DailyArchiveStore,
                                         onProgress: (@Sendable (SampleFillProgress) -> Void)? = nil) async -> SampleFillSummary {
        let days = ((try? daily.allRecords()) ?? []).map(\.day)
        return await fill(days: days, onProgress: onProgress)
    }

}
