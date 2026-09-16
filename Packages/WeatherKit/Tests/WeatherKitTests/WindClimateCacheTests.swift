import XCTest
@testable import WeatherKit

final class WindClimateCacheTests: XCTestCase {

    private final class MemoryArchive: SampleArchiveStore, @unchecked Sendable {
        var days: [String: [StationSample]] = [:]
        var reads: [String] = []
        func samples(onDay day: String) throws -> [StationSample] {
            reads.append(day)
            return days[day] ?? []
        }
        func archivedDays() throws -> [String] { days.keys.sorted() }
        func merge(_ samples: [StationSample], timeZone: TimeZone) throws -> [String] { [] }
    }

    private func day(direction: Double, speed: Double, gust: Double? = nil,
                     minutes: Int = 240) -> [StationSample] {
        (0..<minutes).map { m in
            var s = StationSample(timestamp: m * 60, bucketMinutes: 1)
            s.windAvg = speed; s.windDirection = direction; s.windGust = gust
            return s
        }
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wind-\(UUID().uuidString)")
            .appendingPathComponent("climate.json")
    }

    /// THE INVARIANT THE WHOLE DESIGN RESTS ON. If folding days in one at a time
    /// diverged from reading them all at once, the cache would be a fast way to be
    /// wrong — and the divergence would show up as a climatology that quietly drifts
    /// as days accumulate, which nobody would ever catch by looking at it.
    func testAnIncrementalFoldEqualsAFullBuild() throws {
        let store = MemoryArchive()
        for i in 1...20 {
            let key = String(format: "2024-%02d-%02d", (i % 12) + 1, (i % 28) + 1)
            store.days[key] = day(direction: Double(i * 37 % 360), speed: Double(i % 9) + 1,
                                  gust: Double(i % 13) + 4)
        }
        let cache = WindClimateCache(url: tempURL())

        // Warm the cache on half the record, then let the rest arrive.
        let all = try store.archivedDays()
        var partial = WindClimateAccumulator()
        for d in all.prefix(9) { partial.fold(day: d, samples: try store.samples(onDay: d)) }
        try cache.save(partial)

        let incremental = cache.refresh(from: store)
        let full = WindClimate.build(from: store)

        XCTAssertEqual(incremental.days, full.days)
        XCTAssertEqual(incremental.overall, full.overall)
        for month in full.byMonth.keys {
            XCTAssertEqual(incremental.byMonth[month], full.byMonth[month], "month \(month)")
        }
    }

    func testAWarmCacheOnlyReadsTheNewDays() throws {
        let store = MemoryArchive()
        store.days["2024-03-01"] = day(direction: 180, speed: 8)
        store.days["2024-03-02"] = day(direction: 180, speed: 8)
        let cache = WindClimateCache(url: tempURL())

        cache.refresh(from: store)
        store.reads.removeAll()

        store.days["2024-03-03"] = day(direction: 0, speed: 12)
        let climate = cache.refresh(from: store)

        XCTAssertEqual(store.reads, ["2024-03-03"],
                       "the two days already folded in must not be re-read")
        XCTAssertEqual(climate.days, 3)
    }

    func testNothingNewIsANoOpAndReadsNoDaysAtAll() throws {
        let store = MemoryArchive()
        store.days["2024-03-01"] = day(direction: 180, speed: 8)
        let cache = WindClimateCache(url: tempURL())
        cache.refresh(from: store)
        store.reads.removeAll()

        let climate = cache.refresh(from: store)
        XCTAssertTrue(store.reads.isEmpty)
        XCTAssertEqual(climate.days, 1)
    }

    /// A gap backfilled later is the case a day COUNT would get wrong: the count
    /// matches on both sides of the change while the contents don't.
    func testADayBackfilledIntoAGapIsFoldedInNotMissed() throws {
        let store = MemoryArchive()
        store.days["2024-03-01"] = day(direction: 180, speed: 8)
        store.days["2024-03-03"] = day(direction: 180, speed: 8)
        let cache = WindClimateCache(url: tempURL())
        let before = cache.refresh(from: store)
        XCTAssertEqual(before.days, 2)

        store.days["2024-03-02"] = day(direction: 0, speed: 20)
        let after = cache.refresh(from: store)
        XCTAssertEqual(after.days, 3)
        XCTAssertEqual(after.overall, WindClimate.build(from: store).overall)
    }

    func testADayIsNeverFoldedTwice() throws {
        let store = MemoryArchive()
        store.days["2024-03-01"] = day(direction: 180, speed: 8)
        let cache = WindClimateCache(url: tempURL())
        let once = cache.refresh(from: store)
        let again = cache.refresh(from: store)
        let third = cache.refresh(from: store)
        XCTAssertEqual(once.overall.movingMinutes, again.overall.movingMinutes)
        XCTAssertEqual(again.overall.movingMinutes, third.overall.movingMinutes)
    }

    func testACacheWrittenUnderOlderArithmeticIsDiscardedRatherThanExtended() throws {
        // Adding new days onto sums computed under a different band ladder or calm
        // threshold would blend two rule sets into one rose with no way to tell.
        let url = tempURL()
        let store = MemoryArchive()
        store.days["2024-03-01"] = day(direction: 180, speed: 8)

        var old = WindClimateAccumulator()
        old.fold(day: "2024-03-01", samples: try store.samples(onDay: "2024-03-01"))
        old.version = WindClimateAccumulator.currentVersion - 1
        try WindClimateCache(url: url).save(old)

        XCTAssertNil(WindClimateCache(url: url).load(), "a stale version must not load")
        store.reads.removeAll()
        let rebuilt = WindClimateCache(url: url).refresh(from: store)
        XCTAssertEqual(store.reads, ["2024-03-01"], "it rebuilds from the samples")
        XCTAssertEqual(rebuilt.days, 1)
    }

    func testAMissingOrCorruptCacheRebuildsRatherThanThrowing() throws {
        let url = tempURL()
        XCTAssertNil(WindClimateCache(url: url).load())

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(WindClimateCache(url: url).load())

        let store = MemoryArchive()
        store.days["2024-03-01"] = day(direction: 180, speed: 8)
        XCTAssertEqual(WindClimateCache(url: url).refresh(from: store).days, 1)
    }

    func testTheCacheRoundTripsThroughDiskUnchanged() throws {
        let store = MemoryArchive()
        for i in 1...12 {
            let key = String(format: "2024-%02d-15", i)
            store.days[key] = day(direction: Double(i) * 30, speed: Double(i), gust: Double(i) * 3)
        }
        let url = tempURL()
        let first = WindClimateCache(url: url).refresh(from: store)
        // A second cache object, reading only what the first left on disk.
        let reloaded = WindClimateCache(url: url).refresh(from: store)
        XCTAssertEqual(first.overall, reloaded.overall)
        XCTAssertEqual(first.byMonth, reloaded.byMonth)
    }

    func testMonthsAreKeyedLegiblyOnDisk() throws {
        let store = MemoryArchive()
        store.days["2024-03-01"] = day(direction: 180, speed: 8)
        let url = tempURL()
        WindClimateCache(url: url).refresh(from: store)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"03\""), "a person should be able to read the month keys")
    }

    func testProgressIsReportedForAColdBuild() throws {
        let store = MemoryArchive()
        for i in 1...5 { store.days[String(format: "2024-03-%02d", i)] = day(direction: 180, speed: 8) }
        var seen: [Int] = []
        WindClimateCache(url: tempURL()).refresh(from: store) { done, total in
            XCTAssertEqual(total, 5)
            seen.append(done)
        }
        XCTAssertEqual(seen, [1, 2, 3, 4, 5])
    }
}
