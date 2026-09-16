//
//  ArchiveSync.swift  (WeatherKit)
//
//  Fills the local archive from the station's history, in chunks.
//
//  There is deliberately no separate "initial backfill" and "nightly top-up" —
//  both are the same operation: *fill everything from the last archived day up to
//  yesterday*. The first run happens to find an empty archive and does ~47 chunks;
//  the nightly run finds one missing day and does one. That's what makes
//  correctness independent of whether the app was awake at the right moment: a
//  laptop closed for a week just does a slightly bigger catch-up on next launch,
//  rather than accumulating a hole nobody notices for months.
//
//  Two properties this leans on:
//    · EACH CHUNK COMMITS AS IT LANDS. Quit at chunk 5 of 47 and those 5 are
//      durably archived; the next run resumes after them. Progress reports work
//      KEPT, not work attempted.
//    · A FAILED CHUNK DOESN'T ABORT THE RUN. Partial success is the normal outcome
//      of a long chunked pull, so failures are collected and reported as
//      retryable ranges instead of discarding everything that did land.
//

import Foundation

/// What the UI renders while a fill is running.
public struct BackfillProgress: Equatable, Sendable {
    public var completedChunks: Int
    public var totalChunks: Int
    /// The window currently being fetched — showing real dates is what makes the
    /// bar read as something happening rather than a spinner.
    public var currentStart: Date?
    public var currentEnd: Date?
    public var daysArchived: Int
    public var failedChunks: Int
    public var isFinished: Bool

    public init(completedChunks: Int = 0, totalChunks: Int = 0,
                currentStart: Date? = nil, currentEnd: Date? = nil,
                daysArchived: Int = 0, failedChunks: Int = 0, isFinished: Bool = false) {
        self.completedChunks = completedChunks
        self.totalChunks = totalChunks
        self.currentStart = currentStart
        self.currentEnd = currentEnd
        self.daysArchived = daysArchived
        self.failedChunks = failedChunks
        self.isFinished = isFinished
    }

    public var fraction: Double {
        guard totalChunks > 0 else { return 0 }
        return min(1, Double(completedChunks) / Double(totalChunks))
    }

    /// True when this is a big first-run fill worth showing a banner for, as
    /// opposed to a routine one-chunk top-up that should stay silent.
    public var isSubstantial: Bool { totalChunks > 1 }
}

public struct BackfillSummary: Equatable, Sendable {
    public var daysArchived: Int
    public var chunksCompleted: Int
    public var chunksFailed: Int
    public var earliestDay: String?
    public var latestDay: String?
    /// Windows that failed, for a retry pass.
    public var failedRanges: [DateInterval]

    public init(daysArchived: Int = 0, chunksCompleted: Int = 0, chunksFailed: Int = 0,
                earliestDay: String? = nil, latestDay: String? = nil,
                failedRanges: [DateInterval] = []) {
        self.daysArchived = daysArchived
        self.chunksCompleted = chunksCompleted
        self.chunksFailed = chunksFailed
        self.earliestDay = earliestDay
        self.latestDay = latestDay
        self.failedRanges = failedRanges
    }

    public var isComplete: Bool { chunksFailed == 0 }
}

/// A window of time to fetch in one request.
public struct FetchChunk: Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public enum ArchiveSync {

    /// Minutes per sample. The API caps a request's span by this value, and the
    /// two move together: coarser sampling buys a longer window.
    ///
    /// We use 30 rather than the 180 that would minimise request count, because
    /// 3-hourly samples routinely miss the day's actual high — every record and
    /// percentile built on them would be quietly biased low. 30-minute sampling
    /// puts daily min/max within a half hour of truth, at ~47 requests for four
    /// years. That's a couple of minutes, once.
    public static let bucketMinutes = 30

    /// Max span per request at that bucket is 30 days; we step 29 so that a chunk
    /// spanning a DST "fall back" (25 hours in a local day) still can't tip over
    /// the cap and fail the window.
    public static let chunkDays = 29

    /// Split a range into fetchable windows, ALIGNED TO LOCAL MIDNIGHT.
    ///
    /// The alignment is load-bearing, not tidiness. A boundary that lands mid-day
    /// splits that day across two requests, and since each request only sees half
    /// of it, the day gets archived with half its samples — and a daily high drawn
    /// from only the morning is wrong in a way nothing downstream can detect. Days
    /// are the unit we store, so days are the unit we fetch on.
    ///
    /// Stepping by calendar days rather than 86,400-second multiples keeps the
    /// alignment through DST changes, which would otherwise re-introduce the split
    /// twice a year.
    public static func chunks(from start: Date, to end: Date,
                              chunkDays: Int = chunkDays,
                              timeZone: TimeZone = .current) -> [FetchChunk] {
        guard start < end else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var result: [FetchChunk] = []
        var cursor = calendar.startOfDay(for: start)
        while cursor < end {
            let stepped = calendar.date(byAdding: .day, value: chunkDays, to: cursor) ?? end
            let next = min(stepped, end)
            result.append(FetchChunk(start: cursor, end: next))
            guard next > cursor else { break }
            cursor = next
        }
        return result
    }
}

/// Drives a fill. The fetcher is injected so the chunking, commit, progress and
/// failure behaviour are all testable without touching the network.
public actor ArchiveFiller {
    public typealias Fetcher = @Sendable (_ start: Date, _ end: Date, _ bucketMinutes: Int) async throws -> StationObservations

    private let store: DailyArchiveStore
    private let fetch: Fetcher
    private let timeZone: TimeZone?
    /// Pause between requests — we're pulling a few dozen windows from someone
    /// else's server and they throttle bulk pulls.
    private let throttle: Duration

    public init(store: DailyArchiveStore,
                timeZone: TimeZone? = nil,
                throttle: Duration = .milliseconds(400),
                fetch: @escaping Fetcher) {
        self.store = store
        self.timeZone = timeZone
        self.throttle = throttle
        self.fetch = fetch
    }

    /// Fill `start`…`end`, reporting after every chunk.
    public func fill(from start: Date,
                     to end: Date,
                     onProgress: (@Sendable (BackfillProgress) -> Void)? = nil) async -> BackfillSummary {
        await run(chunks: ArchiveSync.chunks(from: start, to: end, timeZone: timeZone ?? .current),
                  onProgress: onProgress)
    }

    /// Fetch a prepared list of windows. Everything that fills the archive comes
    /// through here, so commit-as-you-go, partial-failure collection and progress
    /// reporting have exactly one implementation.
    private func run(chunks: [FetchChunk],
                     onProgress: (@Sendable (BackfillProgress) -> Void)? = nil) async -> BackfillSummary {
        var archived = Set<String>()
        var failed: [DateInterval] = []
        var completed = 0

        onProgress?(BackfillProgress(completedChunks: 0, totalChunks: chunks.count))

        for chunk in chunks {
            if Task.isCancelled { break }

            onProgress?(BackfillProgress(completedChunks: completed,
                                         totalChunks: chunks.count,
                                         currentStart: chunk.start,
                                         currentEnd: chunk.end,
                                         daysArchived: archived.count,
                                         failedChunks: failed.count))
            do {
                // ONE SECOND PAST THE END, and one second exactly.
                //
                // A bucket is stamped at its end, so the last day of a chunk is
                // finished by the row stamped at the following midnight — which is
                // the chunk's own `end` instant, and an exclusive range drops it.
                // Without this every chunk boundary leaves its last day a bucket
                // short, and the next chunk can't repair it: that row now rolls up
                // as a one-sample record for a day already held fuller, which
                // `ArchiveMerge` correctly refuses.
                //
                // A whole bucket further would reach the NEXT day's first reading
                // and write a one-sample record for a day the archive deliberately
                // doesn't hold yet — today, at the end of a catch-up.
                let end = chunk.end.addingTimeInterval(1)
                let observations = try await fetch(chunk.start, end, ArchiveSync.bucketMinutes)
                let records = DailyRollup.records(from: observations,
                                                  bucketMinutes: ArchiveSync.bucketMinutes,
                                                  timeZone: timeZone)
                // Commit this chunk before moving on, so an interruption keeps it.
                let written = try store.merge(records)
                archived.formUnion(written)
            } catch {
                failed.append(DateInterval(start: chunk.start, end: chunk.end))
            }
            completed += 1

            if chunk.start != chunks.last?.start, throttle > .zero {
                try? await Task.sleep(for: throttle)
            }
        }

        onProgress?(BackfillProgress(completedChunks: completed,
                                     totalChunks: chunks.count,
                                     daysArchived: archived.count,
                                     failedChunks: failed.count,
                                     isFinished: true))

        let days = archived.sorted()
        return BackfillSummary(daysArchived: archived.count,
                               chunksCompleted: completed - failed.count,
                               chunksFailed: failed.count,
                               earliestDay: days.first,
                               latestDay: days.last,
                               failedRanges: failed)
    }

    /// Re-fetch days written by an older rollup, so they gain the fields it now
    /// produces.
    ///
    /// This is what makes the archive's schema forward-movable at all. Counters
    /// like chill hours can only be computed while the individual samples are in
    /// hand — the day's min and max can't reconstruct them later — so a new
    /// measure means re-pulling the raw observations for the days that predate
    /// it. Once. The days come back with the same sample counts and merge in over
    /// their older selves.
    ///
    /// Only contiguous runs are fetched, so a scattered set of stale days doesn't
    /// become one request each.
    public func refillStale(onProgress: (@Sendable (BackfillProgress) -> Void)? = nil) async -> BackfillSummary {
        guard let stale = try? store.staleDays(), !stale.isEmpty else {
            onProgress?(BackfillProgress(totalChunks: 0, isFinished: true))
            return BackfillSummary()
        }

        let zone = timeZone ?? .current
        let chunks = DayKey.runs(of: stale).flatMap { run -> [FetchChunk] in
            guard let start = DayKey.date(from: run.first, timeZone: zone),
                  let lastDay = DayKey.next(run.last),
                  let end = DayKey.date(from: lastDay, timeZone: zone) else { return [] }
            return ArchiveSync.chunks(from: start, to: end, timeZone: zone)
        }
        return await run(chunks: chunks, onProgress: onProgress)
    }

    /// The everyday entry point: bring the archive up to yesterday, starting from
    /// whatever we already hold (or `stationStart` on a cold archive).
    ///
    /// Yesterday, not today, because today is still accumulating — a partial day
    /// archived as if complete would land a wrong min/max in the permanent record.
    /// Today always comes from the live forecast call instead.
    public func catchUp(stationStart: Date,
                        now: Date = Date(),
                        calendar: Calendar = .current,
                        onProgress: (@Sendable (BackfillProgress) -> Void)? = nil) async -> BackfillSummary {

        let zone = timeZone ?? calendar.timeZone
        var cal = calendar
        cal.timeZone = zone

        let startOfToday = cal.startOfDay(for: now)
        guard let lastKey = try? store.lastArchivedDay(),
              let last = DayKey.date(from: lastKey, timeZone: zone) else {
            return await fill(from: stationStart, to: startOfToday, onProgress: onProgress)
        }

        // Re-fetch the last archived day: it may have been captured mid-day, and
        // merge() keeps whichever version has more samples.
        let resume = max(stationStart, cal.startOfDay(for: last))
        guard resume < startOfToday else {
            onProgress?(BackfillProgress(totalChunks: 0, isFinished: true))
            return BackfillSummary(daysArchived: 0, chunksCompleted: 0, chunksFailed: 0,
                                   earliestDay: nil, latestDay: nil, failedRanges: [])
        }
        return await fill(from: resume, to: startOfToday, onProgress: onProgress)
    }
}
