import XCTest
@testable import WeatherKit

final class GzipTests: XCTestCase {
    func testRoundTrip() throws {
        let text = String(repeating: #"{"timestamp":1781529600,"air_temp":71.2}"#, count: 500)
        let data = Data(text.utf8)
        let zipped = try Gzip.compress(data)
        XCTAssertLessThan(zipped.count, data.count / 10, "repetitive NDJSON should compress hard")
        XCTAssertEqual(try Gzip.decompress(zipped), data)
    }

    func testWritesARealGzipContainer() throws {
        // The 18 bytes of container are the entire reason the vault stays readable
        // without this app. If this drifts to raw DEFLATE, `zcat` stops working
        // and the file becomes a blob.
        let zipped = try Gzip.compress(Data("hello".utf8))
        XCTAssertEqual(Array(zipped.prefix(3)), [0x1F, 0x8B, 0x08])
        XCTAssertEqual(Gzip.crc32(Data("hello".utf8)), 0x3610_A686)
    }

    func testEmptyInput() throws {
        XCTAssertEqual(try Gzip.decompress(try Gzip.compress(Data())), Data())
    }

    func testRejectsNonGzip() {
        XCTAssertThrowsError(try Gzip.decompress(Data(repeating: 0, count: 40)))
    }

    func testDetectsCorruption() throws {
        var zipped = try Gzip.compress(Data(String(repeating: "a", count: 400).utf8))
        zipped[zipped.count - 6] ^= 0xFF          // scribble on the CRC
        XCTAssertThrowsError(try Gzip.decompress(zipped))
    }
}

final class SampleArchiveTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/Chicago")!

    private func sample(_ iso: String, bucket: Int = 1, temp: Double? = nil) -> StationSample {
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        f.formatOptions = [.withInternetDateTime]
        var s = StationSample(timestamp: Int(f.date(from: iso)!.timeIntervalSince1970),
                              bucketMinutes: bucket)
        s.airTemp = temp
        return s
    }

    private func makeStore() -> (FileSampleArchive, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("samples-\(UUID().uuidString)")
        return (FileSampleArchive(root: root), root)
    }

    /// The installed Vane and Vane Dev share one archive on a Mac. Two stores on
    /// one root stand in for the two apps: each has its own `NSLock`, so only the
    /// file lock stands between them — and without it, a read-merge-write racing
    /// another one drops whichever minutes only the loser had.
    func testTwoStoresOnOneRootLoseNothing() throws {
        let (first, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let second = FileSampleArchive(root: root)

        let base = sample("2026-06-15T08:00:00-05:00").timestamp
        func minutes(_ range: StrideTo<Int>) -> [[StationSample]] {
            range.map { [StationSample(timestamp: base + $0 * 60, bucketMinutes: 1)] }
        }
        let evens = minutes(stride(from: 0, to: 400, by: 2))
        let odds = minutes(stride(from: 1, to: 400, by: 2))

        DispatchQueue.concurrentPerform(iterations: 2) { i in
            let (store, batches) = i == 0 ? (first, evens) : (second, odds)
            for batch in batches { _ = try? store.merge(batch, timeZone: zone) }
        }

        XCTAssertEqual(try first.samples(onDay: "2026-06-15").count, 400)
    }

    func testRoundTripsThroughDisk() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.merge([sample("2026-06-15T08:00:00-05:00", temp: 71.2),
                         sample("2026-06-15T08:01:00-05:00", temp: 71.4)], timeZone: zone)

        let back = try store.samples(onDay: "2026-06-15")
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].airTemp, 71.2)
        XCTAssertEqual(back[1].airTemp, 71.4)
        XCTAssertEqual(try store.archivedDays(), ["2026-06-15"])
    }

    func testShardsByDayUnderAYearDirectory() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.merge([sample("2026-06-15T08:00:00-05:00")], timeZone: zone)
        let expected = root.appendingPathComponent("2026/2026-06-15.ndjson.gz")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func testDaysAreAssignedInTheStationsZoneNotUTC() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        // 23:30 local on the 15th is already the 16th in UTC. Sharding on the
        // wrong zone would file every evening under tomorrow.
        try store.merge([sample("2026-06-15T23:30:00-05:00")], timeZone: zone)
        XCTAssertEqual(try store.archivedDays(), ["2026-06-15"])
    }

    func testFinerResolutionSupersedesCoarser() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.merge([sample("2026-06-15T08:00:00-05:00", bucket: 30, temp: 70.0)], timeZone: zone)
        try store.merge([sample("2026-06-15T08:00:00-05:00", bucket: 1, temp: 71.2)], timeZone: zone)

        let back = try store.samples(onDay: "2026-06-15")
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].bucketMinutes, 1)
        XCTAssertEqual(back[0].airTemp, 71.2)
    }

    func testCoarserResolutionNeverOverwritesFiner() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.merge([sample("2026-06-15T08:00:00-05:00", bucket: 1, temp: 71.2)], timeZone: zone)
        let written = try store.merge([sample("2026-06-15T08:00:00-05:00", bucket: 30, temp: 70.0)],
                                      timeZone: zone)

        XCTAssertTrue(written.isEmpty, "a no-op merge shouldn't rewrite the file")
        XCTAssertEqual(try store.samples(onDay: "2026-06-15").first?.airTemp, 71.2)
    }

    func testMergePreservesExistingSamplesOnTheSameDay() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.merge([sample("2026-06-15T08:00:00-05:00", temp: 71.2)], timeZone: zone)
        try store.merge([sample("2026-06-15T09:00:00-05:00", temp: 75.0)], timeZone: zone)

        XCTAssertEqual(try store.samples(onDay: "2026-06-15").count, 2)
    }

    func testMissingDayIsEmptyNotAnError() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try store.samples(onDay: "2019-01-01"), [])
        XCTAssertEqual(try store.archivedDays(), [])
    }
}

final class SampleFillTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/Chicago")!

    /// A fetcher that reports one sample per requested day and records what it was asked for.
    private func fetcher(fail: Set<String> = [],
                         seen: @escaping @Sendable (String) -> Void = { _ in }) -> SampleFiller.Fetcher {
        let zone = self.zone
        return { start, _, bucket in
            let day = DayKey.string(for: start, timeZone: zone)
            seen(day)
            if fail.contains(day) { throw URLError(.timedOut) }
            return StationObservations(obFields: ["timestamp", "air_temp"],
                                       obs: [[start.timeIntervalSince1970, 70]])
        }
    }

    func testFillsRequestedDays() async throws {
        let store = MemorySampleArchive()
        let filler = SampleFiller(store: store, timeZone: zone, concurrency: 2, fetch: fetcher())
        let summary = await filler.fill(days: ["2026-06-15", "2026-06-16", "2026-06-17"])

        XCTAssertEqual(summary.daysWritten, 3)
        XCTAssertEqual(summary.samplesWritten, 3)
        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(try store.archivedDays(), ["2026-06-15", "2026-06-16", "2026-06-17"])
    }

    func testFetchesAtNativeResolution() async throws {
        let store = MemorySampleArchive()
        let buckets = Locked<[Int]>([])
        let filler = SampleFiller(store: store, timeZone: zone) { _, _, bucket in
            buckets.mutate { $0.append(bucket) }
            return StationObservations(obFields: [], obs: [])
        }
        _ = await filler.fill(days: ["2026-06-15"])
        XCTAssertEqual(buckets.value, [1])
    }

    func testResumeSkipsDaysAlreadyHeld() async throws {
        let store = MemorySampleArchive()
        let requested = Locked<[String]>([])
        let filler = SampleFiller(store: store, timeZone: zone, concurrency: 1,
                                  fetch: fetcher(seen: { day in requested.mutate { $0.append(day) } }))

        _ = await filler.fill(days: ["2026-06-15", "2026-06-16"])
        requested.mutate { $0.removeAll() }
        let second = await filler.fill(days: ["2026-06-15", "2026-06-16", "2026-06-17"])

        XCTAssertEqual(requested.value, ["2026-06-17"], "a resume must not re-pull held days")
        XCTAssertEqual(second.daysSkipped, 2)
        XCTAssertEqual(second.daysWritten, 1)
    }

    func testFailuresAreNamedAndDoNotStopTheRun() async throws {
        let store = MemorySampleArchive()
        let filler = SampleFiller(store: store, timeZone: zone, concurrency: 2,
                                  fetch: fetcher(fail: ["2026-06-16"]))
        let summary = await filler.fill(days: ["2026-06-15", "2026-06-16", "2026-06-17"])

        XCTAssertEqual(summary.failedDays, ["2026-06-16"])
        XCTAssertEqual(summary.daysWritten, 2)
        XCTAssertFalse(summary.isComplete)
    }

    func testAnEmptyDayIsNotAFailure() async throws {
        // The station was off. Counting that as a failure would send every future
        // resume back to re-fetch genuine downtime forever.
        let store = MemorySampleArchive()
        let filler = SampleFiller(store: store, timeZone: zone) { _, _, _ in
            StationObservations(obFields: ["timestamp"], obs: [])
        }
        let summary = await filler.fill(days: ["2026-06-15"])
        XCTAssertTrue(summary.failedDays.isEmpty)
        XCTAssertEqual(summary.daysWritten, 0)
    }

    func testEveryFetchWindowFitsTheApisOneDayCap() throws {
        // The spring-forward day is 23 hours and the fall-back day is 25. A single
        // 89,940-second window is rejected outright with "time range cannot exceed
        // 1 day", which would fail that one day every November.
        for day in ["2026-03-08", "2026-11-01", "2026-06-15"] {
            let windows = SampleSync.windows(ofDay: day, timeZone: zone)
            XCTAssertFalse(windows.isEmpty, day)
            for window in windows {
                XCTAssertLessThanOrEqual(window.end.timeIntervalSince(window.start), 86_400, day)
            }
        }
    }

    func testTheFallBackDayIsSplitRatherThanClipped() throws {
        // Clipping to 24 hours would silently drop the repeated hour — the quieter
        // failure, and the one nothing downstream could detect.
        let windows = SampleSync.windows(ofDay: "2026-11-01", timeZone: zone)
        XCTAssertEqual(windows.count, 2)
        let start = DayKey.date(from: "2026-11-01", timeZone: zone)!
        XCTAssertEqual(windows.first?.start, start)
        XCTAssertEqual(windows.last?.end.timeIntervalSince(start) ?? 0, 25 * 3600 - 60, accuracy: 1)
    }

    func testAllOfALongDaysWindowsAreFetched() async throws {
        let store = MemorySampleArchive()
        let calls = Locked<Int>(0)
        let filler = SampleFiller(store: store, timeZone: zone) { start, _, _ in
            calls.mutate { $0 += 1 }
            return StationObservations(obFields: ["timestamp"], obs: [[start.timeIntervalSince1970]])
        }
        let summary = await filler.fill(days: ["2026-11-01"])
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(summary.samplesWritten, 2)
    }
}

/// Minimal box so a `@Sendable` fetcher can record what it saw.
private final class Locked<T>: @unchecked Sendable {
    private var storage: T
    private let lock = NSLock()
    init(_ value: T) { storage = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return storage }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&storage) }
}
