//
//  WindClimateCache.swift  (WeatherKit)
//
//  A WIND CLIMATOLOGY IS TOO EXPENSIVE TO COMPUTE WHEN ASKED, and this is the
//  measurement that settled it: 16.3 seconds, release build, to fold 1,429 days
//  into a rose. Almost all of it is JSON-decoding roughly two million samples.
//  Nothing about that gets better — the archive only grows — so a surface that
//  builds the climatology on open is a surface that never opens.
//
//  The fix is the one [[files-are-the-data]] already prescribes: the roses are a
//  CACHE, rebuildable from the samples at any time, and the samples stay the
//  record. Deleting this file costs 16 seconds, once, and nothing else.
//
//  WHAT IS CACHED IS THE ACCUMULATOR, NOT THE ANSWER, and that is the whole
//  design. A finished `WindRose` cannot absorb tomorrow — fractions and means
//  have already divided away the weights they were made from, so folding one new
//  day into a stored rose is impossible and the only option is to re-read the
//  record. `WindRoseBuilder` holds the un-normalised sums instead: minutes per
//  sector, speed·minutes, the vector components. Those ADD. So the daily
//  catch-up folds in one day at a cost proportional to ONE DAY, and the 16
//  seconds is paid exactly once in the life of the station.
//
//  KEYED BY THE DAYS THAT WENT IN, stored as a list rather than a count. A count
//  would say "1,429 days" about a cache built before a gap in 2023 was backfilled
//  and after, and silently double-count or silently miss. The list makes the
//  question "which days are new" a set difference, which is the only way an
//  incremental fold can be correct rather than merely fast.
//

import Foundation

/// The mergeable state behind a `WindClimate`, plus the days it was built from.
public struct WindClimateAccumulator: Codable, Sendable {
    /// Bumped when a change to the rose's arithmetic makes old sums wrong — a new
    /// band ladder, a different calm threshold. A stale version rebuilds from
    /// scratch rather than adding new days onto sums computed under other rules.
    public static let currentVersion = 1

    public var version: Int
    /// Every day folded in, ascending. Sorted and unique.
    public var days: [String]
    public var overall: WindRoseBuilder
    /// Keyed "01"…"12" rather than by `Int`, because Swift encodes an
    /// integer-keyed dictionary as a flat JSON ARRAY of alternating keys and
    /// values — legible to a decoder and to nobody else. The vault's files are
    /// meant to be readable without this app.
    public var months: [String: WindRoseBuilder]

    public init(bands: [WindBand] = WindBand.standard) {
        version = Self.currentVersion
        days = []
        overall = WindRoseBuilder(bands: bands)
        months = [:]
    }

    public static func monthKey(ofDay day: String) -> String? {
        let key = String(day.dropFirst(5).prefix(2))
        guard let month = Int(key), (1...12).contains(month) else { return nil }
        return key
    }

    /// Fold one day's samples in. The caller is responsible for not folding a day
    /// twice; `daysMissing(from:)` is how it finds out which ones to pass.
    public mutating func fold(day: String, samples: [StationSample],
                              bands: [WindBand] = WindBand.standard) {
        guard !samples.isEmpty else { return }
        overall.add(samples)
        if let key = Self.monthKey(ofDay: day) {
            var builder = months[key] ?? WindRoseBuilder(bands: bands)
            builder.add(samples)
            months[key] = builder
        }
        days.append(day)
    }

    /// Days the archive holds that this accumulator hasn't seen.
    public func daysMissing(from archived: [String]) -> [String] {
        let held = Set(days)
        return archived.filter { !held.contains($0) }
    }

    /// True when the sums were built under arithmetic this build no longer uses.
    public var isStale: Bool { version != Self.currentVersion }

    public func climate() -> WindClimate {
        var byMonth: [Int: WindRose] = [:]
        for (key, builder) in months {
            guard let month = Int(key) else { continue }
            byMonth[month] = builder.build()
        }
        let sorted = days.sorted()
        return WindClimate(overall: overall.build(),
                           byMonth: byMonth,
                           days: sorted.count,
                           firstDay: sorted.first,
                           lastDay: sorted.last)
    }
}

/// Reads and writes the accumulator beside the archive it summarises.
public struct WindClimateCache: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> WindClimateAccumulator? {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(WindClimateAccumulator.self, from: data),
              !stored.isStale else { return nil }
        return stored
    }

    public func save(_ accumulator: WindClimateAccumulator) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(accumulator).write(to: url, options: .atomic)
    }

    /// Bring the cache up to the archive and hand back the climatology.
    ///
    /// The one entry point worth calling: it is a full build on a cold cache, a
    /// one-day fold on a warm one, and a no-op when nothing has been archived
    /// since last time — and the caller cannot tell which, which is the point.
    /// `onProgress` reports days folded out of days to fold, so a first run can
    /// say something while it spends its 16 seconds.
    @discardableResult
    public func refresh(from store: SampleArchiveStore,
                        bands: [WindBand] = WindBand.standard,
                        onProgress: ((Int, Int) -> Void)? = nil) -> WindClimate {
        var accumulator = load() ?? WindClimateAccumulator(bands: bands)
        let archived = (try? store.archivedDays()) ?? []
        let pending = accumulator.daysMissing(from: archived)

        guard !pending.isEmpty else { return accumulator.climate() }

        for (i, day) in pending.enumerated() {
            if let samples = try? store.samples(onDay: day) {
                accumulator.fold(day: day, samples: samples, bands: bands)
            }
            onProgress?(i + 1, pending.count)
        }

        // A failed write costs the next launch its 16 seconds and nothing else,
        // so it must never fail the answer we already have in hand.
        try? save(accumulator)
        return accumulator.climate()
    }
}
