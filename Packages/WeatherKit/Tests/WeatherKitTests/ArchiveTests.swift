import XCTest
@testable import WeatherKit

final class ArchiveTests: XCTestCase {

    // A trimmed copy of a real `observations/stn` response, field order and all.
    private let fields = ["timestamp", "report_interval", "wind_lull", "wind_avg", "wind_gust",
                          "wind_dir", "station_pressure", "sea_level_pressure", "air_temp", "rh",
                          "illuminance", "uv", "solar_radiation", "precip_accumulation",
                          "local_day_precip_accumulation", "precip_type", "strike_count",
                          "strike_distance", "nc_precip_accumulation", "nc_local_day_precip_accumulation"]

    private func row(ts: Int, temp: Double, rh: Double, gust: Double = 10, precip: Double = 0) -> [Double?] {
        [Double(ts), 30, 1, 5, gust, 180, 28.5, 30.0, temp, rh,
         0, 0, 0, precip, 0, 0, 0, 0, precip, 0]
    }

    private var chicago: TimeZone { TimeZone(identifier: "America/Chicago")! }

    // MARK: Wire decoding

    func testDecodesRealResponseShape() throws {
        let json = """
        {"station_id":68737,"timezone":"America/Chicago","type":"obs_station",
         "ob_fields":["timestamp","air_temp","rh"],
         "obs":[[1696118400,87.8,34],[1696118460,null,35]]}
        """.data(using: .utf8)!
        let obs = try JSONDecoder().decode(StationObservations.self, from: json)
        XCTAssertEqual(obs.stationID, 68737)
        XCTAssertEqual(obs.timezone, "America/Chicago")
        XCTAssertEqual(obs.obs.count, 2)

        let map = ObservationFieldMap(fields: obs.obFields)
        XCTAssertEqual(map.value("air_temp", in: obs.obs[0]), 87.8)
        // A null column reads as "unknown", same as an absent one.
        XCTAssertNil(map.value("air_temp", in: obs.obs[1]))
        XCTAssertNil(map.value("wind_gust", in: obs.obs[0]))
    }

    func testErrorBodyDecodesAsEmptyRatherThanThrowing() throws {
        // The API answers an over-long range with a 200 and no `obs`.
        let json = #"{"status":{"status_code":3,"status_message":"Time range cannot exceed 1 day"}}"#
            .data(using: .utf8)!
        let obs = try JSONDecoder().decode(StationObservations.self, from: json)
        XCTAssertTrue(obs.isEmpty)
    }

    /// Columns are resolved by NAME, so a reordering upstream can't silently
    /// archive one measure as another.
    func testFieldOrderChangeDoesNotCorruptReads() {
        let a = ObservationFieldMap(fields: ["timestamp", "air_temp", "rh"])
        let b = ObservationFieldMap(fields: ["timestamp", "rh", "air_temp"])
        XCTAssertEqual(a.value("air_temp", in: [100, 72, 40]), 72)
        XCTAssertEqual(b.value("air_temp", in: [100, 72, 40]), 40)
    }

    // MARK: Rollup

    func testRollsUpMinMaxMeanForLocalDay() {
        // 1696118400 = 2023-10-01 00:00 UTC = 2023-09-30 19:00 in Chicago.
        let obs = StationObservations(timezone: "America/Chicago", obFields: fields, obs: [
            row(ts: 1696138200, temp: 60, rh: 50),   // Oct 1 00:30 local
            row(ts: 1696172400, temp: 90, rh: 30),   // Oct 1 10:00 local
            row(ts: 1696190400, temp: 75, rh: 40),   // Oct 1 15:00 local
        ])
        let records = DailyRollup.records(from: obs, bucketMinutes: 30)
        XCTAssertEqual(records.count, 1)
        let day = records[0]
        XCTAssertEqual(day.day, "2023-10-01")
        XCTAssertEqual(day.tempMin, 60)
        XCTAssertEqual(day.tempMax, 90)
        XCTAssertEqual(day.tempMean!, 75, accuracy: 0.001)
        XCTAssertEqual(day.sampleCount, 3)
        XCTAssertEqual(day.expectedSamples, 48)
    }

    /// UTC bucketing would smear each local day across two, corrupting min/max.
    func testDaysAreSplitOnLocalMidnightNotUTC() {
        let obs = StationObservations(timezone: "America/Chicago", obFields: fields, obs: [
            row(ts: 1696129200, temp: 70, rh: 50),   // Sep 30 23:00 local
            row(ts: 1696140000, temp: 50, rh: 50),   // Oct  1 01:00 local
        ])
        let records = DailyRollup.records(from: obs, bucketMinutes: 30)
        XCTAssertEqual(records.map(\.day), ["2023-09-30", "2023-10-01"])
        XCTAssertEqual(records[0].tempMax, 70)
        XCTAssertEqual(records[1].tempMax, 50)
    }

    /// A bucket is stamped at its END, so the row at local midnight measured the
    /// half hour BEFORE it and belongs to the day that just ended.
    ///
    /// Filing it forward gave every day the last bucket of the day before. For
    /// temperature that's an off-by-one-bucket; for precipitation — an
    /// accumulation, not a reading — it invented rain, and against the real
    /// station it moved 0.9″ from one day to the next.
    func testMidnightBucketBelongsToTheDayItMeasured() {
        let obs = StationObservations(timezone: "America/Chicago", obFields: fields, obs: [
            row(ts: 1696134600, temp: 60, rh: 90, precip: 0.90),  // Sep 30 23:30 local
            row(ts: 1696136400, temp: 61, rh: 90, precip: 0.60),  // Oct  1 00:00 local
            row(ts: 1696138200, temp: 62, rh: 90, precip: 0.05),  // Oct  1 00:30 local
        ])
        let records = DailyRollup.records(from: obs, bucketMinutes: 30)
        XCTAssertEqual(records.map(\.day), ["2023-09-30", "2023-10-01"])
        // The midnight row's rain fell on the 30th, in the half hour it covers.
        XCTAssertEqual(records[0].precipTotal!, 1.50, accuracy: 0.0001)
        XCTAssertEqual(records[1].precipTotal!, 0.05, accuracy: 0.0001)
    }

    /// The correction changes stored values rather than adding fields, so every
    /// day written by the old rollup has to come back — which is exactly what
    /// the stale-day refill already does.
    func testDaysFromTheOldBoundaryAreStale() {
        var old = DailyRecord(day: "2023-10-01", sampleCount: 48, expectedSamples: 48)
        old.schemaVersion = 2
        XCTAssertTrue(old.isStale)

        var corrected = DailyRecord(day: "2023-10-01", sampleCount: 47, expectedSamples: 48)
        corrected.schemaVersion = DailyRecord.currentSchemaVersion
        // A day loses at most a bucket to its neighbour, so the re-fetch is never
        // thin enough to be refused as a degraded pull.
        XCTAssertTrue(ArchiveMerge.shouldReplace(old, with: corrected))

        // Same one bucket off a day the station barely watched: 8 of 9 is under
        // the 90% floor, and refusing it would leave the day stale forever,
        // re-fetched on every launch and never accepted.
        var thin = DailyRecord(day: "2023-12-15", sampleCount: 9, expectedSamples: 48)
        thin.schemaVersion = 2
        var thinner = DailyRecord(day: "2023-12-15", sampleCount: 8, expectedSamples: 48)
        thinner.schemaVersion = DailyRecord.currentSchemaVersion
        XCTAssertTrue(ArchiveMerge.shouldReplace(thin, with: thinner))

        // But a genuine stub still can't wipe a day, version bump or not.
        var stub = DailyRecord(day: "2023-12-15", sampleCount: 1, expectedSamples: 48)
        stub.schemaVersion = DailyRecord.currentSchemaVersion
        XCTAssertFalse(ArchiveMerge.shouldReplace(thin, with: stub))
    }

    func testPrecipTotalsAcrossBucketsAndStrikesSum() {
        let obs = StationObservations(timezone: "America/Chicago", obFields: fields, obs: [
            row(ts: 1696138200, temp: 60, rh: 90, precip: 0.02),
            row(ts: 1696140000, temp: 61, rh: 92, precip: 0.05),
        ])
        let day = DailyRollup.records(from: obs, bucketMinutes: 30)[0]
        XCTAssertEqual(day.precipTotal!, 0.07, accuracy: 0.0001)
    }

    /// Dew point must be computed per observation then rolled up — averaging temp
    /// and humidity first gives a different, wrong number.
    func testDewPointComputedPerObservation() {
        let obs = StationObservations(timezone: "America/Chicago", obFields: fields, obs: [
            row(ts: 1696138200, temp: 95, rh: 20),
            row(ts: 1696140000, temp: 60, rh: 95),
        ])
        let day = DailyRollup.records(from: obs, bucketMinutes: 30)[0]
        let expected = [WeatherInterpreter.dewPointF(tempF: 95, humidity: 20),
                        WeatherInterpreter.dewPointF(tempF: 60, humidity: 95)]
        XCTAssertEqual(day.dewPointMean!, expected.reduce(0, +) / 2, accuracy: 0.001)
        let naive = WeatherInterpreter.dewPointF(tempF: 77.5, humidity: 57.5)
        XCTAssertNotEqual(day.dewPointMean!, naive, accuracy: 0.5)
    }

    // MARK: Coverage — "no data" is not "zero"

    func testCoverageMarksThinDaysUnreliable() {
        var thin = DailyRecord(day: "2022-10-08", sampleCount: 6, expectedSamples: 48)
        XCTAssertEqual(thin.coverage, 0.125, accuracy: 0.001)
        XCTAssertFalse(thin.isReliable)

        thin.sampleCount = 46
        XCTAssertTrue(thin.isReliable)
    }

    func testMissingMeasuresStayNilRatherThanZero() {
        let obs = StationObservations(timezone: "America/Chicago",
                                      obFields: ["timestamp", "air_temp"],
                                      obs: [[1696136400, 70]])
        let day = DailyRollup.records(from: obs, bucketMinutes: 30)[0]
        XCTAssertEqual(day.tempMax, 70)
        // No humidity column → no dew point, and crucially not 0.
        XCTAssertNil(day.dewPointMean)
        XCTAssertNil(day.precipTotal)
        XCTAssertNil(day.windGustMax)
    }

    // MARK: Store

    func testMergeUpsertsByDayAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("weather-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileDailyArchive(root: root)

        var a = DailyRecord(day: "2023-10-01", sampleCount: 48, expectedSamples: 48)
        a.tempMax = 90
        var b = DailyRecord(day: "2024-05-02", sampleCount: 48, expectedSamples: 48)
        b.tempMax = 70
        try store.merge([a, b])

        XCTAssertEqual(try store.allRecords().map(\.day), ["2023-10-01", "2024-05-02"])
        XCTAssertEqual(try store.records(inYear: 2023).count, 1)
        XCTAssertEqual(try store.lastArchivedDay(), "2024-05-02")
        XCTAssertEqual(try store.firstArchivedDay(), "2023-10-01")
        XCTAssertEqual(try store.allRecords().first?.tempMax, 90)
    }

    /// A partial re-fetch must not degrade a day already archived in full.
    func testThinnerRefetchDoesNotOverwriteFullerDay() throws {
        let store = MemoryDailyArchive()
        var full = DailyRecord(day: "2023-10-01", sampleCount: 48, expectedSamples: 48)
        full.tempMax = 90
        try store.merge([full])

        var partial = DailyRecord(day: "2023-10-01", sampleCount: 4, expectedSamples: 48)
        partial.tempMax = 61
        let written = try store.merge([partial])

        XCTAssertTrue(written.isEmpty)
        XCTAssertEqual(try store.allRecords().first?.tempMax, 90)
    }

    // MARK: Chunking

    func testChunkingCoversRangeAndClampsToEnd() {
        let start = DayKey.date(from: "2022-10-08", timeZone: chicago)!
        let end = start.addingTimeInterval(70 * 86_400)
        let chunks = ArchiveSync.chunks(from: start, to: end, timeZone: chicago)

        XCTAssertEqual(chunks.count, 3)                          // 29 + 29 + 12
        XCTAssertEqual(chunks.first?.start, start)
        XCTAssertEqual(chunks.last?.end, end)                    // never past `end`
        for chunk in chunks {
            // Stays under the API's 30-day cap even across a DST change.
            XCTAssertLessThanOrEqual(chunk.end.timeIntervalSince(chunk.start), 30 * 86_400)
        }
        // Contiguous, no gaps.
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(a.end, b.start)
        }
    }

    /// Regression: a boundary landing mid-day splits that day across two requests,
    /// so each request sees only part of it and the day is archived with half its
    /// samples — a daily high drawn from only the morning, wrong in a way nothing
    /// downstream can detect. Every boundary must sit on local midnight.
    func testChunkBoundariesLandOnLocalMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago

        // A start at 14:32 local — the shape a station-created timestamp has.
        let ragged = DayKey.date(from: "2022-01-28", timeZone: chicago)!
            .addingTimeInterval(14 * 3_600 + 32 * 60)
        let end = DayKey.date(from: "2023-06-01", timeZone: chicago)!
        let chunks = ArchiveSync.chunks(from: ragged, to: end, timeZone: chicago)

        XCTAssertGreaterThan(chunks.count, 10)
        for chunk in chunks {
            XCTAssertEqual(chunk.start, calendar.startOfDay(for: chunk.start),
                           "chunk start \(chunk.start) is not local midnight")
        }
        // Interior boundaries too — the last one is clamped to `end`.
        for chunk in chunks.dropLast() {
            XCTAssertEqual(chunk.end, calendar.startOfDay(for: chunk.end))
        }
    }

    /// The same, across both DST transitions: stepping by fixed 86,400-second
    /// multiples would drift an hour off midnight and re-split days twice a year.
    func testAlignmentSurvivesDaylightSavingTransitions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago
        let start = DayKey.date(from: "2023-01-01", timeZone: chicago)!
        let end = DayKey.date(from: "2024-01-01", timeZone: chicago)!

        let chunks = ArchiveSync.chunks(from: start, to: end, timeZone: chicago)
        for chunk in chunks {
            XCTAssertEqual(chunk.start, calendar.startOfDay(for: chunk.start))
            XCTAssertLessThanOrEqual(chunk.end.timeIntervalSince(chunk.start), 30 * 86_400)
        }
    }

    /// End-to-end shape of the bug: fetch two adjacent chunks of a synthetic
    /// station reporting every 30 minutes, and assert no day lands short.
    func testNoDayIsSplitAcrossAdjacentChunks() async {
        let store = MemoryDailyArchive()
        let start = DayKey.date(from: "2023-03-01", timeZone: chicago)!
            .addingTimeInterval(9 * 3_600)               // ragged start
        let end = DayKey.date(from: "2023-05-15", timeZone: chicago)!

        // A station that reports every 30 minutes, always.
        let filler = ArchiveFiller(store: store, timeZone: chicago, throttle: .zero) { s, e, _ in
            var rows: [[Double?]] = []
            var t = s.timeIntervalSince1970
            while t < e.timeIntervalSince1970 {
                rows.append(self.row(ts: Int(t), temp: 70, rh: 50))
                t += 1_800
            }
            return StationObservations(timezone: "America/Chicago", obFields: self.fields, obs: rows)
        }
        _ = await filler.fill(from: start, to: end)

        let records = (try? store.allRecords()) ?? []
        XCTAssertGreaterThan(records.count, 60)
        // Drop the first and last day, which are legitimately partial at the edges.
        // Compared against each day's OWN expected count, since the range spans the
        // spring-forward transition where a local day is only 23 hours long.
        for record in records.dropFirst().dropLast() {
            XCTAssertEqual(record.sampleCount, record.expectedSamples,
                           "\(record.day) archived short — a chunk boundary split it")
            XCTAssertTrue(record.isReliable, record.day)
        }
        // And that short day is present and correctly accounted for, not penalised.
        if let dst = records.first(where: { $0.day == "2023-03-12" }) {
            XCTAssertEqual(dst.expectedSamples, 46)   // 23-hour day
            XCTAssertEqual(dst.coverage, 1, accuracy: 0.001)
        }
    }

    func testDaylightSavingDaysGetTheirTrueExpectedSampleCount() {
        // Spring forward: 23 hours. Fall back: 25.
        let spring = DayKey.date(from: "2023-03-12", timeZone: chicago)!
        let fall = DayKey.date(from: "2023-11-05", timeZone: chicago)!

        func record(for day: Date) -> DailyRecord {
            let obs = StationObservations(timezone: "America/Chicago", obFields: fields,
                                          obs: [row(ts: Int(day.timeIntervalSince1970) + 3_600,
                                                    temp: 60, rh: 50)])
            return DailyRollup.records(from: obs, bucketMinutes: 30, timeZone: chicago)[0]
        }
        XCTAssertEqual(record(for: spring).expectedSamples, 46)
        XCTAssertEqual(record(for: fall).expectedSamples, 50)
    }

    func testEmptyRangeProducesNoChunks() {
        let now = Date(timeIntervalSince1970: 1_665_187_200)
        XCTAssertTrue(ArchiveSync.chunks(from: now, to: now).isEmpty)
        XCTAssertTrue(ArchiveSync.chunks(from: now, to: now.addingTimeInterval(-86_400)).isEmpty)
    }

    // MARK: Filling — progress, commit-as-you-go, partial failure

    func testFillReportsDeterminateProgressAndArchivesEachChunk() async {
        let store = MemoryDailyArchive()
        let start = DayKey.date(from: "2022-10-08", timeZone: chicago)!
        let end = start.addingTimeInterval(58 * 86_400)
        let expectedChunks = ArchiveSync.chunks(from: start, to: end, timeZone: chicago).count

        let filler = ArchiveFiller(store: store, timeZone: chicago, throttle: .zero) { s, _, _ in
            StationObservations(timezone: "America/Chicago", obFields: self.fields,
                                obs: [self.row(ts: Int(s.timeIntervalSince1970) + 43_200, temp: 70, rh: 50)])
        }

        let box = ProgressBox()
        let summary = await filler.fill(from: start, to: end) { box.append($0) }

        XCTAssertEqual(expectedChunks, 2)
        XCTAssertEqual(summary.chunksCompleted, expectedChunks)
        XCTAssertEqual(summary.chunksFailed, 0)
        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(summary.daysArchived, expectedChunks)

        let updates = box.values
        XCTAssertEqual(updates.first?.totalChunks, expectedChunks)   // determinate from the start
        XCTAssertEqual(updates.last?.isFinished, true)
        XCTAssertEqual(updates.last?.completedChunks, expectedChunks)
        XCTAssertEqual(updates.last?.fraction, 1)
        // The window being fetched is reported, so the UI can name real dates.
        XCTAssertNotNil(updates.dropFirst().first?.currentStart)
    }

    func testOneFailedChunkDoesNotDiscardTheRest() async {
        let store = MemoryDailyArchive()
        let start = DayKey.date(from: "2022-10-08", timeZone: chicago)!
        let end = start.addingTimeInterval(87 * 86_400)
        let planned = ArchiveSync.chunks(from: start, to: end, timeZone: chicago)
        let failAfter = planned[1].start          // fail the middle chunk

        struct Boom: Error {}
        let filler = ArchiveFiller(store: store, timeZone: chicago, throttle: .zero) { s, _, _ in
            if s == failAfter { throw Boom() }
            return StationObservations(timezone: "America/Chicago", obFields: self.fields,
                                       obs: [self.row(ts: Int(s.timeIntervalSince1970) + 43_200, temp: 70, rh: 50)])
        }

        let summary = await filler.fill(from: start, to: end)

        XCTAssertEqual(summary.chunksFailed, 1)
        XCTAssertEqual(summary.chunksCompleted, planned.count - 1)
        XCTAssertFalse(summary.isComplete)
        XCTAssertEqual(summary.failedRanges.count, 1)
        XCTAssertEqual(summary.failedRanges.first?.start, failAfter)
        // The chunks that did land are durably archived, not rolled back.
        XCTAssertEqual(try? store.allRecords().count, planned.count - 1)
    }

    func testCatchUpResumesFromLastArchivedDayAndStopsAtYesterday() async {
        var seed = DailyRecord(day: "2026-08-01", sampleCount: 48, expectedSamples: 48)
        seed.tempMax = 99
        let store = MemoryDailyArchive([seed])

        let requested = RangeBox()
        let filler = ArchiveFiller(store: store, timeZone: chicago, throttle: .zero) { s, e, _ in
            requested.append((s, e))
            return StationObservations(timezone: "America/Chicago", obFields: self.fields, obs: [])
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = chicago
        let now = DayKey.date(from: "2026-08-06", timeZone: chicago)!
            .addingTimeInterval(15 * 3_600)

        _ = await filler.catchUp(stationStart: DayKey.date(from: "2022-10-08", timeZone: chicago)!,
                                 now: now, calendar: cal)

        // Starts at the last day we hold (re-fetched in case it was partial),
        // not at the station's install date.
        XCTAssertEqual(requested.values.count, 1)
        XCTAssertEqual(DayKey.string(for: requested.values[0].0, timeZone: chicago), "2026-08-01")
        // Stops at the start of today — today is still accumulating.
        XCTAssertEqual(DayKey.string(for: requested.values[0].1, timeZone: chicago), "2026-08-06")
    }

    func testCatchUpOnColdArchiveStartsAtStationInstallDate() async {
        let store = MemoryDailyArchive()
        let requested = RangeBox()
        let filler = ArchiveFiller(store: store, timeZone: chicago, throttle: .zero) { s, e, _ in
            requested.append((s, e))
            return StationObservations(timezone: "America/Chicago", obFields: self.fields, obs: [])
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = chicago
        let stationStart = DayKey.date(from: "2022-10-08", timeZone: chicago)!

        _ = await filler.catchUp(stationStart: stationStart,
                                 now: DayKey.date(from: "2022-12-08", timeZone: chicago)!,
                                 calendar: cal)

        XCTAssertEqual(requested.values.first?.0, stationStart)
        XCTAssertGreaterThan(requested.values.count, 1)   // chunked, not one giant request
    }

    /// An already-current archive does no work and reports nothing substantial —
    /// the nightly no-op case that must stay silent in the UI.
    func testCatchUpIsANoOpWhenAlreadyCurrent() async {
        let seed = DailyRecord(day: "2026-08-05", sampleCount: 48, expectedSamples: 48)
        let store = MemoryDailyArchive([seed])
        let filler = ArchiveFiller(store: store, timeZone: chicago, throttle: .zero) { _, _, _ in
            XCTFail("should not fetch when already current")
            return StationObservations()
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = chicago
        let now = DayKey.date(from: "2026-08-05", timeZone: chicago)!.addingTimeInterval(20 * 3_600)

        let box = ProgressBox()
        let summary = await filler.catchUp(stationStart: DayKey.date(from: "2022-10-08", timeZone: chicago)!,
                                           now: now, calendar: cal) { box.append($0) }

        XCTAssertEqual(summary.daysArchived, 0)
        XCTAssertEqual(box.values.last?.isSubstantial, false)
    }

    func testSubstantialOnlyForMultiChunkFills() {
        XCTAssertFalse(BackfillProgress(totalChunks: 1).isSubstantial)
        XCTAssertTrue(BackfillProgress(totalChunks: 47).isSubstantial)
    }
}

/// Small thread-safe collectors — the progress callback is `@Sendable`.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BackfillProgress] = []
    func append(_ p: BackfillProgress) { lock.lock(); storage.append(p); lock.unlock() }
    var values: [BackfillProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class RangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(Date, Date)] = []
    func append(_ r: (Date, Date)) { lock.lock(); storage.append(r); lock.unlock() }
    var values: [(Date, Date)] { lock.lock(); defer { lock.unlock() }; return storage }
}
