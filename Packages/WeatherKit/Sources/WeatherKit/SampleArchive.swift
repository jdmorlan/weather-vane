//
//  SampleArchive.swift  (WeatherKit)
//
//  The durable local copy of the station's OBSERVATIONS, as opposed to
//  `DailyArchive`'s copy of its days.
//
//  It runs alongside the daily archive rather than replacing it. That is
//  deliberate and temporary: a derived `DailyRecord` has to reproduce the stored
//  one, and having both on disk at once is what lets you diff them day by day
//  instead of trusting the rollup. When they agree, the daily archive becomes a
//  cache rebuilt from here and the storage stops being truth — which is
//  [[files-are-the-data]] applied to the one place in this codebase that was
//  still violating it.
//
//  ONE FILE PER DAY, and the query pattern is the reason. A day query hands back
//  a SCATTERED set of days — storm days across four years — and then wants their
//  samples. Month or year shards would mean decompressing months to read a
//  handful of days; at worst the whole 840 MB record to answer one question. A
//  day is ~24 KB compressed and is exactly the unit that gets asked for, so
//  random access costs one small read. 1,419 files is nothing; a directory per
//  year keeps listings sane.
//
//  NDJSON, append-shaped, gzipped: one sample per line, greppable through
//  `zgrep`, no schema to migrate, and re-interpretable forever because nothing
//  was reduced on the way in. Same reasoning the UDP collector already settled
//  on, now on the app side of the seam.
//

import Foundation

public protocol SampleArchiveStore: Sendable {
    /// Samples for one `yyyy-MM-dd` key, ascending by timestamp. Empty when the
    /// day isn't held — never an error, since "we have no samples" is an answer.
    func samples(onDay day: String) throws -> [StationSample]
    /// Which days this archive holds, ascending.
    func archivedDays() throws -> [String]
    /// Upsert. Returns the day keys actually written.
    @discardableResult
    func merge(_ samples: [StationSample], timeZone: TimeZone) throws -> [String]
}

extension SampleArchiveStore {
    /// Samples across a set of days, in day order — the shape a day query's
    /// result asks for.
    public func samples(onDays days: [String]) throws -> [String: [StationSample]] {
        var result: [String: [StationSample]] = [:]
        for day in days {
            let found = try samples(onDay: day)
            if !found.isEmpty { result[day] = found }
        }
        return result
    }

    public func firstArchivedDay() throws -> String? { try archivedDays().first }
    public func lastArchivedDay() throws -> String? { try archivedDays().last }
}

/// How two versions of the same instant are arbitrated.
public enum SampleMerge {
    /// FINER RESOLUTION WINS, and that is the whole rule.
    ///
    /// The day-level archive arbitrates on coverage (`sampleCount`), because two
    /// versions of a day differ in how MUCH of it was seen. Two versions of one
    /// INSTANT can't differ that way — they differ in how sharply it was
    /// measured. A 1-minute reading and the 30-minute bucket that contains it are
    /// both true; the minute is just less averaged, so it supersedes.
    ///
    /// Ties go to the incoming sample, matching the daily archive's newest-wins
    /// default: a re-fetch at the same resolution is a correction.
    public static func shouldReplace(_ existing: StationSample, with incoming: StationSample) -> Bool {
        incoming.bucketMinutes <= existing.bucketMinutes
    }
}

public final class FileSampleArchive: SampleArchiveStore, @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()

    public init(root: URL) {
        self.root = root
    }

    /// `<root>/2026/2026-06-15.ndjson.gz`
    private func url(forDay day: String) -> URL {
        let year = day.prefix(4)
        return root.appendingPathComponent(String(year))
            .appendingPathComponent("\(day).ndjson.gz")
    }

    public func samples(onDay day: String) throws -> [StationSample] {
        lock.lock(); defer { lock.unlock() }
        return try read(day: day)
    }

    private func read(day: String) throws -> [StationSample] {
        let url = url(forDay: day)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let raw = try Data(contentsOf: url)
        guard !raw.isEmpty else { return [] }
        let lines = try Gzip.decompress(raw).split(separator: UInt8(ascii: "\n"))
        let decoder = JSONDecoder()
        return try lines.compactMap { line in
            line.isEmpty ? nil : try decoder.decode(StationSample.self, from: Data(line))
        }
    }

    public func archivedDays() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        var days: [String] = []
        for yearDir in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard Int(yearDir.lastPathComponent) != nil else { continue }
            let files = (try? fm.contentsOfDirectory(at: yearDir, includingPropertiesForKeys: nil)) ?? []
            days += files.compactMap { file in
                let name = file.lastPathComponent
                guard name.hasSuffix(".ndjson.gz") else { return nil }
                return String(name.dropLast(".ndjson.gz".count))
            }
        }
        return days.sorted()
    }

    @discardableResult
    public func merge(_ samples: [StationSample], timeZone: TimeZone) throws -> [String] {
        guard !samples.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }

        let formatter = DayKey.formatter(timeZone: timeZone)
        let byDay = Dictionary(grouping: samples) { formatter.string(from: $0.date) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var written: [String] = []
        for (day, incoming) in byDay {
            // Keyed by instant: a station cannot report two readings for the same
            // second, so the timestamp IS the identity.
            var existing = Dictionary(uniqueKeysWithValues: try read(day: day).map { ($0.timestamp, $0) })
            var changed = false
            for sample in incoming {
                if let old = existing[sample.timestamp],
                   !SampleMerge.shouldReplace(old, with: sample) { continue }
                existing[sample.timestamp] = sample
                changed = true
            }
            guard changed else { continue }

            var body = Data()
            for sample in existing.values.sorted(by: { $0.timestamp < $1.timestamp }) {
                body.append(try encoder.encode(sample))
                body.append(UInt8(ascii: "\n"))
            }
            let url = url(forDay: day)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Gzip.compress(body).write(to: url, options: .atomic)
            written.append(day)
        }
        return written.sorted()
    }
}

/// In-memory archive for tests and previews.
public final class MemorySampleArchive: SampleArchiveStore, @unchecked Sendable {
    private var storage: [String: [Int: StationSample]] = [:]
    private let lock = NSLock()

    public init() {}

    public func samples(onDay day: String) throws -> [StationSample] {
        lock.lock(); defer { lock.unlock() }
        return (storage[day]?.values ?? [:].values).sorted { $0.timestamp < $1.timestamp }
    }

    public func archivedDays() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storage.keys.sorted()
    }

    @discardableResult
    public func merge(_ samples: [StationSample], timeZone: TimeZone) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let formatter = DayKey.formatter(timeZone: timeZone)
        var written: Set<String> = []
        for sample in samples {
            let day = formatter.string(from: sample.date)
            var bucket = storage[day] ?? [:]
            if let old = bucket[sample.timestamp],
               !SampleMerge.shouldReplace(old, with: sample) { continue }
            bucket[sample.timestamp] = sample
            storage[day] = bucket
            written.insert(day)
        }
        return written.sorted()
    }
}
