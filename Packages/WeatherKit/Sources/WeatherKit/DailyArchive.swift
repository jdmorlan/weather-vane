//
//  DailyArchive.swift  (WeatherKit)
//
//  The durable local copy of this station's history. Right now that history lives
//  only on WeatherFlow's servers; after this, the local archive is the record and
//  the API is just the feed that keeps it current.
//
//  Storage is plain JSON on disk, one file per year, sorted by day and
//  pretty-printed — legible in any text editor without this app, and diffable.
//  Sharding by year keeps a single rewrite small as the record grows.
//
//  Merging is by day key, newest write wins, EXCEPT that a lower-coverage record
//  never overwrites a higher-coverage one: a coarse or partial re-fetch must not
//  degrade a day we already have in full.
//

import Foundation

public protocol DailyArchiveStore: Sendable {
    func allRecords() throws -> [DailyRecord]
    func records(inYear year: Int) throws -> [DailyRecord]
    /// Upsert by day key. Returns the days actually written.
    @discardableResult
    func merge(_ records: [DailyRecord]) throws -> [String]
}

/// Which of two versions of the same day the archive keeps.
public enum ArchiveMerge {
    /// Newest write wins, with two exceptions that protect the record:
    ///
    /// · A THINNER re-fetch never overwrites a fuller day. A coarse or
    ///   interrupted pull must not degrade a day we already hold whole.
    /// · A SCHEMA UPGRADE outranks that, because an older record physically
    ///   cannot contain the newer fields — no amount of extra samples makes a
    ///   v1 day able to answer a chill-hours question. It still has to have seen
    ///   most of the day, so a stub can't wipe a real one on a version bump.
    public static func shouldReplace(_ existing: DailyRecord, with incoming: DailyRecord) -> Bool {
        if incoming.version > existing.version {
            // A day may legitimately come back ONE SAMPLE lighter: the v3 boundary
            // hands the reading stamped at midnight to the day it measured, so a
            // day can lose its first bucket to the day before. On a thin day —
            // nine samples out of forty-eight — the 90% floor alone rounds that
            // one bucket into a refusal, and the day then stays stale forever,
            // re-fetched on every launch and never accepted.
            return Double(incoming.sampleCount) >= Double(existing.sampleCount) * 0.9
                || incoming.sampleCount + 1 >= existing.sampleCount
        }
        return incoming.sampleCount >= existing.sampleCount
    }
}

extension DailyArchiveStore {
    /// The most recent day we hold — where an incremental catch-up resumes from.
    public func lastArchivedDay() throws -> String? {
        try allRecords().map(\.day).max()
    }

    /// Days written by an older rollup, which a re-fetch would enrich.
    public func staleDays() throws -> [String] {
        try allRecords().filter(\.isStale).map(\.day).sorted()
    }

    public func firstArchivedDay() throws -> String? {
        try allRecords().map(\.day).min()
    }
}

/// File-backed archive: `<root>/2022.json`, `<root>/2023.json`, …
public final class FileDailyArchive: DailyArchiveStore, @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    /// Orders writes against the OTHER app sharing this archive; see `ArchiveFileLock`.
    private let fileLock: ArchiveFileLock

    public init(root: URL) {
        self.root = root
        self.fileLock = ArchiveFileLock(root: root)
    }

    private func url(forYear year: Int) -> URL {
        root.appendingPathComponent("\(year).json")
    }

    private func availableYears() throws -> [Int] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let contents = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return contents.compactMap { url -> Int? in
            guard url.pathExtension == "json" else { return nil }
            return Int(url.deletingPathExtension().lastPathComponent)
        }.sorted()
    }

    public func records(inYear year: Int) throws -> [DailyRecord] {
        lock.lock(); defer { lock.unlock() }
        return try readYear(year)
    }

    private func readYear(_ year: Int) throws -> [DailyRecord] {
        let url = url(forYear: year)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        return try JSONDecoder().decode([DailyRecord].self, from: data)
    }

    public func allRecords() throws -> [DailyRecord] {
        lock.lock(); defer { lock.unlock() }
        return try availableYears().flatMap { try readYear($0) }.sorted { $0.day < $1.day }
    }

    @discardableResult
    public func merge(_ records: [DailyRecord]) throws -> [String] {
        guard !records.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        return try fileLock.withLock {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            var written: [String] = []
            let byYear = Dictionary(grouping: records) { DayKey.year(of: $0.day) ?? 0 }

            for (year, incoming) in byYear where year > 0 {
                var existing = Dictionary(uniqueKeysWithValues: try readYear(year).map { ($0.day, $0) })
                for record in incoming {
                    if let old = existing[record.day],
                       !ArchiveMerge.shouldReplace(old, with: record) { continue }
                    existing[record.day] = record
                    written.append(record.day)
                }
                let sorted = existing.values.sorted { $0.day < $1.day }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(sorted)
                try data.write(to: url(forYear: year), options: .atomic)
            }
            return written
        }
    }
}

/// In-memory archive for tests and previews.
public final class MemoryDailyArchive: DailyArchiveStore, @unchecked Sendable {
    private var storage: [String: DailyRecord] = [:]
    private let lock = NSLock()

    public init(_ seed: [DailyRecord] = []) {
        for record in seed { storage[record.day] = record }
    }

    public func allRecords() throws -> [DailyRecord] {
        lock.lock(); defer { lock.unlock() }
        return storage.values.sorted { $0.day < $1.day }
    }

    public func records(inYear year: Int) throws -> [DailyRecord] {
        try allRecords().filter { DayKey.year(of: $0.day) == year }
    }

    @discardableResult
    public func merge(_ records: [DailyRecord]) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        var written: [String] = []
        for record in records {
            if let old = storage[record.day],
               !ArchiveMerge.shouldReplace(old, with: record) { continue }
            storage[record.day] = record
            written.append(record.day)
        }
        return written
    }
}
