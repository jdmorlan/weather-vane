import XCTest
@testable import WeatherKit

final class SeasonAndChillTests: XCTestCase {

    // MARK: Builders

    /// A record per day across an inclusive range, with min/max chosen per day.
    private func days(from start: String, to end: String,
                      low: (String) -> Double, high: (String) -> Double,
                      chillHours: ((String) -> Double?)? = nil,
                      coverage: Double = 1.0) -> [DailyRecord] {
        var result: [DailyRecord] = []
        var cursor = start
        while cursor <= end {
            var record = DailyRecord(day: cursor, sampleCount: Int(48 * coverage), expectedSamples: 48)
            record.tempMin = low(cursor)
            record.tempMax = high(cursor)
            record.schemaVersion = DailyRecord.currentSchemaVersion
            record.chillHours = chillHours?(cursor)
            result.append(record)
            guard let next = DayKey.next(cursor) else { break }
            cursor = next
        }
        return result
    }

    /// A mild year that dips to freezing on two named mornings and nowhere else.
    private func year(_ y: Int, springFrost: String, fallFrost: String) -> [DailyRecord] {
        days(from: "\(y)-01-01", to: "\(y)-12-31",
             low: { day in
                 let monthDay = DayKey.monthDay(of: day)
                 return monthDay == springFrost || monthDay == fallFrost ? 30 : 45
             },
             high: { _ in 70 })
    }

    private let fields = ["timestamp", "air_temp", "rh"]

    /// 2023-11-14 00:00 UTC. Fixtures must start at a local midnight or their
    /// samples straddle two calendar days and every per-day count comes out halved.
    private static let utcMidnight = 1_699_920_000

    private func observations(_ temps: [Double], startingAt epoch: Int, every seconds: Int) -> StationObservations {
        var obs: [[Double?]] = []
        for (i, t) in temps.enumerated() {
            // A BUCKET IS STAMPED AT ITS END, so the first reading of a day is
            // stamped one interval after midnight and the last is stamped at the
            // next midnight. Starting the series ON midnight would put that first
            // reading in the previous day, which is precisely what the rollup now
            // gets right — and would leave `.first` here a one-sample stub.
            obs.append([Double(epoch + (i + 1) * seconds), t, 50])
        }
        return StationObservations(stationID: 1, timezone: "UTC", obFields: fields, obs: obs)
    }

    // MARK: Counters at rollup

    /// The counters exist because a daily min/max cannot reconstruct them: these
    /// two days have identical extremes and very different chill.
    func testChillHoursCountTimeInBandNotJustTheDaysRange() {
        // 24 samples an hour apart. Day A sits at 40° for 12 hours; day B passes
        // through the band briefly on its way between the same two extremes.
        let sitting = Array(repeating: 40.0, count: 12) + Array(repeating: 60.0, count: 12)
        let passing = [40.0, 50, 55, 58, 60, 60, 60, 60, 58, 55, 50, 44,
                       60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60]

        let a = DailyRollup.records(from: observations(sitting, startingAt: Self.utcMidnight, every: 3600),
                                    bucketMinutes: 60, timeZone: TimeZone(identifier: "UTC"))
        let b = DailyRollup.records(from: observations(passing, startingAt: Self.utcMidnight, every: 3600),
                                    bucketMinutes: 60, timeZone: TimeZone(identifier: "UTC"))

        // Same min and max on both days…
        XCTAssertEqual(a.first?.tempMin, 40)
        XCTAssertEqual(b.first?.tempMin, 40)
        XCTAssertEqual(a.first?.tempMax, 60)
        XCTAssertEqual(b.first?.tempMax, 60)
        // …and chill that differs by a factor of six.
        XCTAssertEqual(a.first?.chillHours, 12)
        XCTAssertEqual(b.first?.chillHours, 2)
    }

    func testHoursAtEachFreezeDepthAreCounted() {
        let temps = Array(repeating: 26.0, count: 4) + Array(repeating: 30.0, count: 4)
            + Array(repeating: 50.0, count: 16)
        let record = DailyRollup.records(from: observations(temps, startingAt: Self.utcMidnight, every: 3600),
                                         bucketMinutes: 60, timeZone: TimeZone(identifier: "UTC")).first
        XCTAssertEqual(record?.hoursBelow32, 8)
        XCTAssertEqual(record?.hoursBelow28, 4)
    }

    /// The Utah model's whole point: a warm afternoon takes chill back off.
    func testUtahUnitsSubtractForWarmAfternoons() {
        let cold = Array(repeating: 42.0, count: 12)        // 12 hours of full credit
        let warm = Array(repeating: 70.0, count: 12)        // 12 hours at -1
        let record = DailyRollup.records(from: observations(cold + warm, startingAt: Self.utcMidnight, every: 3600),
                                         bucketMinutes: 60, timeZone: TimeZone(identifier: "UTC")).first
        XCTAssertEqual(record?.chillHours, 12)              // the simple model sees only the cold
        XCTAssertEqual(record?.chillUnitsUtah, 0)           // the weighted one nets out
    }

    func testUtahWeightsFollowThePublishedBands() {
        XCTAssertEqual(ChillModel.utahUnit(forF: 30), 0)
        XCTAssertEqual(ChillModel.utahUnit(forF: 42), 1.0)
        XCTAssertEqual(ChillModel.utahUnit(forF: 52), 0.5)
        XCTAssertEqual(ChillModel.utahUnit(forF: 58), 0)
        XCTAssertEqual(ChillModel.utahUnit(forF: 62), -0.5)
        XCTAssertEqual(ChillModel.utahUnit(forF: 75), -1.0)
    }

    // MARK: Schema upgrade

    func testRollupStampsTheCurrentSchemaVersion() {
        let record = DailyRollup.records(from: observations([50, 51], startingAt: Self.utcMidnight, every: 1800),
                                         bucketMinutes: 30, timeZone: TimeZone(identifier: "UTC")).first
        XCTAssertEqual(record?.version, DailyRecord.currentSchemaVersion)
        XCTAssertFalse(record?.isStale ?? true)
    }

    func testRecordsWithoutAVersionReadAsTheOriginalRollupAndAreStale() throws {
        // Exactly what's already on disk: no version key at all.
        let json = #"[{"day":"2023-01-01","sampleCount":48,"expectedSamples":48,"tempMax":50}]"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([DailyRecord].self, from: json)
        XCTAssertEqual(decoded.first?.version, 1)
        XCTAssertTrue(decoded.first?.isStale ?? false)
    }

    func testStaleDaysAreUpgradedByARefetchOfEqualCoverage() throws {
        var old = DailyRecord(day: "2023-01-01", sampleCount: 48, expectedSamples: 48)
        old.tempMax = 50                                    // v1: no counters, no version
        let store = MemoryDailyArchive([old])
        XCTAssertEqual(try store.staleDays(), ["2023-01-01"])

        var fresh = DailyRecord(day: "2023-01-01", sampleCount: 48, expectedSamples: 48)
        fresh.tempMax = 50
        fresh.chillHours = 9
        fresh.schemaVersion = DailyRecord.currentSchemaVersion

        try store.merge([fresh])
        XCTAssertEqual(try store.allRecords().first?.chillHours, 9)
        XCTAssertTrue(try store.staleDays().isEmpty)
    }

    /// The upgrade must not become a way to overwrite a full day with a stub.
    func testASubstantiallyThinnerRefetchStillLosesToAFullerOldDay() throws {
        var old = DailyRecord(day: "2023-01-01", sampleCount: 48, expectedSamples: 48)
        old.tempMax = 50
        let store = MemoryDailyArchive([old])

        var thin = DailyRecord(day: "2023-01-01", sampleCount: 10, expectedSamples: 48)
        thin.tempMax = 33
        thin.schemaVersion = DailyRecord.currentSchemaVersion

        try store.merge([thin])
        XCTAssertEqual(try store.allRecords().first?.tempMax, 50)
    }

    func testStaleDaysAreFetchedAsContiguousRunsNotOneRequestEach() {
        let runs = DayKey.runs(of: ["2023-01-03", "2023-01-01", "2023-01-02", "2023-03-10", "2023-03-11"])
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].first, "2023-01-01")
        XCTAssertEqual(runs[0].last, "2023-01-03")
        XCTAssertEqual(runs[1].first, "2023-03-10")
    }

    func testRefillStaleFetchesOnlyTheStaleWindows() async throws {
        var stale = DailyRecord(day: "2023-05-10", sampleCount: 48, expectedSamples: 48)
        stale.tempMax = 70
        var current = DailyRecord(day: "2024-05-10", sampleCount: 48, expectedSamples: 48)
        current.tempMax = 70
        current.schemaVersion = DailyRecord.currentSchemaVersion

        let store = MemoryDailyArchive([stale, current])
        let requested = FetchRecorder()
        let filler = ArchiveFiller(store: store, timeZone: TimeZone(identifier: "UTC"),
                                   throttle: .zero) { start, end, _ in
            await requested.record(start: start, end: end)
            return StationObservations(stationID: 1, timezone: "UTC", obFields: [], obs: [])
        }

        _ = await filler.refillStale()
        let windows = await requested.windows
        XCTAssertEqual(windows.count, 1, "only the one stale day should be re-fetched")
    }

    // MARK: Frost dates

    func testFindsLastSpringAndFirstFallFrostPerYear() {
        let climate = Climatology(records: year(2023, springFrost: "04-12", fallFrost: "10-24")
                                  + year(2024, springFrost: "04-02", fallFrost: "11-08"))

        let spring = climate.lastSpringFrost()
        XCTAssertEqual(spring.events.first { $0.year == 2023 }?.day, "2023-04-12")
        XCTAssertEqual(spring.earliest, "04-02")
        XCTAssertEqual(spring.latest, "04-12")
        XCTAssertEqual(spring.yearsObserved, 2)

        let fall = climate.firstFallFrost()
        XCTAssertEqual(fall.events.first { $0.year == 2024 }?.day, "2024-11-08")
        XCTAssertEqual(fall.spreadDays, 15)
    }

    /// Without a midsummer pivot, one October morning would be both the last
    /// spring frost and the first fall frost of its year.
    func testTheYearIsSplitAtMidsummerSoOneFrostIsntCountedTwice() {
        let climate = Climatology(records: year(2023, springFrost: "10-24", fallFrost: "10-24"))
        XCTAssertNil(climate.lastSpringFrost().events.first?.day)
        XCTAssertEqual(climate.firstFallFrost().events.first?.day, "2023-10-24")
    }

    func testFrostLevelsAreReadIndependently() {
        var records = year(2023, springFrost: "04-12", fallFrost: "10-24")
        // A single hard freeze later in the fall.
        if let index = records.firstIndex(where: { $0.day == "2023-11-20" }) {
            records[index].tempMin = 26
        }
        let climate = Climatology(records: records)
        XCTAssertEqual(climate.firstFallFrost(.frost).events.first?.day, "2023-10-24")
        XCTAssertEqual(climate.firstFallFrost(.hardFreeze).events.first?.day, "2023-11-20")
        XCTAssertNil(climate.firstFallFrost(.killingFreeze).events.first?.day)
    }

    /// A frost seen on a half-reported day still happened. Absence is the claim
    /// that needs the whole season watched.
    func testAbsenceRequiresCoverageButAnObservationDoesNot() {
        // Only October exists in the archive — nothing to say about spring.
        let sparse = Climatology(records: days(from: "2023-10-01", to: "2023-10-31",
                                               low: { DayKey.monthDay(of: $0) == "10-24" ? 30 : 50 },
                                               high: { _ in 65 }))
        let spring = sparse.lastSpringFrost()
        XCTAssertNil(spring.events.first?.day)
        XCTAssertFalse(spring.events.first?.hasCoverage ?? true)
        XCTAssertEqual(spring.yearsWithout, 0, "an unwatched spring is unknown, not frost-free")

        // A partial day that recorded 30° is still proof it froze.
        var partial = days(from: "2023-01-01", to: "2023-12-31", low: { _ in 50 }, high: { _ in 70 })
        if let index = partial.firstIndex(where: { $0.day == "2023-10-24" }) {
            partial[index].tempMin = 30
            partial[index].sampleCount = 12          // only a quarter of the day seen
        }
        XCTAssertEqual(Climatology(records: partial).firstFallFrost().events.first?.day, "2023-10-24")
    }

    func testAWatchedYearWithNoFrostIsReportedAsSuch() {
        let mild = Climatology(records: days(from: "2023-01-01", to: "2023-12-31",
                                             low: { _ in 44 }, high: { _ in 70 }))
        let fall = mild.firstFallFrost()
        XCTAssertEqual(fall.yearsWithout, 1)
        XCTAssertEqual(fall.yearsObserved, 0)
        XCTAssertFalse(fall.isMeaningful)
    }

    // MARK: Heat break

    func testHeatBreakUsesATrailingWeekNotASingleCoolDay() {
        // Hot through Sept 10, then cool — with one cool blip in mid-August that
        // a single-day rule would wrongly call the end of summer.
        let climate = Climatology(records: days(
            from: "2023-07-01", to: "2023-12-31",
            low: { _ in 65 },
            high: { day in
                if DayKey.monthDay(of: day) == "08-15" { return 78 }
                return day <= "2023-09-10" ? 95 : 80
            }))

        let summary = climate.heatBreak(threshold: 90)
        let event = summary.events.first { $0.year == 2023 }
        XCTAssertEqual(event?.day, "2023-09-10", "the blip must not end summer")
    }

    /// A hole in the record must not average into a cool week and fake a break.
    func testSmoothedMeanSkipsWindowsThatSpanAGap() {
        var records = days(from: "2023-07-01", to: "2023-09-30", low: { _ in 65 }, high: { _ in 95 })
        records.removeAll { $0.day >= "2023-08-01" && $0.day <= "2023-08-20" }
        let series = Climatology(records: records)
            .smoothedMean(\.tempMax, from: "2023-07-01", through: "2023-09-30", window: 7)
        // A centered 7-day window needs three days either side, so the first day
        // that can be scored after the gap is the 24th — nothing before it.
        XCTAssertFalse(series.contains { $0.day >= "2023-08-21" && $0.day <= "2023-08-23" })
        XCTAssertTrue(series.contains { $0.day == "2023-08-24" })
    }

    /// The reason the engine is generic over the measure: a place can shed almost
    /// no afternoon heat between August and late September and still feel
    /// transformed, because the NIGHTS dropped. A highs-only reading calls summer
    /// over weeks after it stopped feeling like summer.
    func testNightsCanBreakLongBeforeAfternoonsDo() {
        let climate = Climatology(records: days(
            from: "2023-07-01", to: "2023-12-31",
            low: { day in day <= "2023-09-01" ? 74 : 64 },      // nights let go Sept 1
            high: { day in day <= "2023-10-15" ? 97 : 84 }))    // afternoons hold to mid-Oct

        let afternoons = climate.heatBreak(threshold: 90).events.first { $0.year == 2023 }
        let nights = climate.nightsCool(below: 70).events.first { $0.year == 2023 }

        // Each crossing is the day AFTER the last one still above the threshold.
        XCTAssertEqual(nights?.day, "2023-09-01")
        XCTAssertEqual(afternoons?.day, "2023-10-16")
        XCTAssertLessThan(nights?.day ?? "", afternoons?.day ?? "")
    }

    /// The note compares CROSSING DATES, not degree drops. Both curves can fall
    /// the same amount while only one lands somewhere that changes how a place
    /// feels — that gap is the thing worth saying.
    func testTheReliefNoteComparesCrossingDatesNotDegreeDrops() {
        // Nights cross 70° in early September; afternoons hold above 90° to mid-October.
        var records: [DailyRecord] = []
        for year in 2022...2024 {
            records += days(from: "\(year)-06-01", to: "\(year)-12-31",
                            low: { day in day <= "\(year)-08-31" ? 74 : 64 },
                            high: { day in day <= "\(year)-10-14" ? 97 : 84 })
        }
        let note = WeatherAlmanac.summerReliefNote(Climatology(records: records))
        XCTAssertTrue(note?.contains("Nights cool first") ?? false, note ?? "nil")
        XCTAssertTrue(note?.contains("45 days") ?? false, note ?? "nil")

        // The mirror image: afternoons ease long before the nights ever do.
        var flipped: [DailyRecord] = []
        for year in 2022...2024 {
            flipped += days(from: "\(year)-06-01", to: "\(year)-12-31",
                            low: { day in day <= "\(year)-10-14" ? 74 : 64 },
                            high: { day in day <= "\(year)-08-31" ? 97 : 84 })
        }
        XCTAssertTrue(WeatherAlmanac.summerReliefNote(Climatology(records: flipped))?
            .contains("Afternoons cool first") ?? false)
    }

    func testWarmNightsCountsNightsThatNeverLetGo() {
        var records = days(from: "2023-07-01", to: "2023-08-31", low: { _ in 68 }, high: { _ in 95 })
        for index in records.indices where records[index].day <= "2023-07-10" {
            records[index].tempMin = 78
        }
        XCTAssertEqual(Climatology(records: records).warmNights(inYear: 2023, atOrAbove: 75), 10)
    }

    // MARK: Growing season

    func testGrowingSeasonMeasuresBetweenTheFrostsAndNeedsBothEnds() {
        let climate = Climatology(records: year(2023, springFrost: "04-12", fallFrost: "10-24"))
        let season = climate.growingSeasons().first
        XCTAssertEqual(season?.days, 195)
        XCTAssertEqual(season?.lastSpringFrost, "2023-04-12")

        // A year watched only in autumn can't report a length.
        let partial = Climatology(records: days(from: "2023-08-01", to: "2023-12-31",
                                                low: { DayKey.monthDay(of: $0) == "10-24" ? 30 : 50 },
                                                high: { _ in 70 }))
        XCTAssertNil(partial.growingSeasons().first?.days)
    }

    // MARK: Chill

    func testChillSeasonSpansTheNewYearAndIsNamedForItsSpring() {
        // Oct 2023 → Feb 2024, a flat 8 chill hours a day.
        let records = days(from: "2023-10-01", to: "2024-02-29",
                           low: { _ in 35 }, high: { _ in 50 }, chillHours: { _ in 8 })
        let seasons = Climatology(records: records)
            .chillSeasons(now: Date(timeIntervalSince1970: 1_720_000_000),  // July 2024 — nothing accumulating
                          timeZone: TimeZone(identifier: "UTC")!)

        XCTAssertEqual(seasons.count, 1)
        let season = seasons[0]
        XCTAssertEqual(season.endingYear, 2024)
        XCTAssertEqual(season.label, "2023–24")
        XCTAssertFalse(season.isInProgress)
        // Oct 1 – Feb 29 inclusive = 152 days × 8.
        XCTAssertEqual(season.chillHours, 152 * 8)
        XCTAssertTrue(season.isTrustworthy)
    }

    func testMarchAndSeptemberDaysDoNotCountTowardChill() {
        let records = days(from: "2023-09-01", to: "2024-03-31",
                           low: { _ in 35 }, high: { _ in 50 }, chillHours: { _ in 10 })
        let season = Climatology(records: records)
            .chillSeasons(now: Date(timeIntervalSince1970: 1_720_000_000),
                          timeZone: TimeZone(identifier: "UTC")!).first
        XCTAssertEqual(season?.chillHours, 152 * 10)   // September and March excluded
    }

    /// Days written before the counters existed contribute no chill but still
    /// count their hours as unrecorded, so they widen the stated uncertainty
    /// instead of silently lowering the total.
    func testPreCounterDaysWidenUncertaintyRatherThanLowerTheTotal() {
        var records = days(from: "2023-10-01", to: "2024-02-29",
                           low: { _ in 35 }, high: { _ in 50 }, chillHours: { _ in 8 })
        for index in records.indices where records[index].day < "2023-11-01" {
            records[index].chillHours = nil
            records[index].schemaVersion = nil
            records[index].sampleCount = 0
        }
        let season = Climatology(records: records)
            .chillSeasons(now: Date(timeIntervalSince1970: 1_720_000_000),
                          timeZone: TimeZone(identifier: "UTC")!).first

        XCTAssertEqual(season?.chillHours, 121 * 8)          // only the counted days
        XCTAssertEqual(season?.unrecordedHours, 31 * 24)     // October is unaccounted for
        XCTAssertEqual(season?.coverage ?? 0, 121.0 / 152, accuracy: 0.01)
        // Still a valid FLOOR — the missing month can only add chill, never remove
        // it — so the season stays quotable. What the gap does is widen the
        // distance between the floor and the estimate, which is what gets shown.
        XCTAssertGreaterThan(season?.estimatedChillHours ?? 0, (season?.chillHours ?? 0) * 1.2)
    }

    /// A partial day contributes every in-band hour it DID see. Discarding it
    /// would throw away fact to avoid admitting uncertainty — and with a real
    /// station missing scattered hours all winter, discarding would reject every
    /// season it ever recorded.
    func testPartialDaysStillContributeTheHoursTheySaw() {
        var records = days(from: "2023-10-01", to: "2024-02-29",
                           low: { _ in 35 }, high: { _ in 50 }, chillHours: { _ in 8 })
        for index in records.indices where records[index].day < "2023-10-11" {
            records[index].sampleCount = 24      // half the day seen…
            records[index].chillHours = 4        // …so half its chill observed
        }
        let season = Climatology(records: records)
            .chillSeasons(now: Date(timeIntervalSince1970: 1_720_000_000),
                          timeZone: TimeZone(identifier: "UTC")!).first

        XCTAssertEqual(season?.chillHours, 142 * 8 + 10 * 4)
        XCTAssertEqual(season?.unrecordedHours, 10 * 12)
        // Still quotable: 97% of the winter's hours were recorded.
        XCTAssertTrue(season?.isTrustworthy ?? false)
        // The floor is a bound; the estimate scales it by what was missed.
        XCTAssertGreaterThan(season?.estimatedChillHours ?? 0, season?.chillHours ?? 0)
    }

    /// The threshold has to be reachable by a real station. This one recorded
    /// ~85% of the winter's hours — scattered outages, no whole month missing —
    /// which is a perfectly usable bound and must not be rejected.
    func testARealisticallyImperfectWinterStillCounts() {
        var records = days(from: "2023-10-01", to: "2024-02-29",
                           low: { _ in 35 }, high: { _ in 50 }, chillHours: { _ in 8 })
        for index in records.indices where index % 5 == 0 {
            records[index].sampleCount = 12      // a quarter of every fifth day
            records[index].chillHours = 2
        }
        let season = Climatology(records: records)
            .chillSeasons(now: Date(timeIntervalSince1970: 1_720_000_000),
                          timeZone: TimeZone(identifier: "UTC")!).first
        XCTAssertGreaterThan(season?.coverage ?? 0, 0.8)
        XCTAssertTrue(season?.isTrustworthy ?? false)
    }

    func testSummaryPlansAgainstTheMedianFloorNotTheMinimum() {
        var records: [DailyRecord] = []
        let perSeason = [2022: 5.0, 2023: 8.0, 2024: 11.0]      // hours/day → ~151× that
        for (endingYear, hours) in perSeason {
            records += days(from: "\(endingYear - 1)-10-01", to: "\(endingYear)-02-28",
                            low: { _ in 35 }, high: { _ in 50 }, chillHours: { _ in hours })
        }
        let summary = Climatology(records: records)
            .chillSummary(now: Date(timeIntervalSince1970: 1_720_000_000),
                          timeZone: TimeZone(identifier: "UTC")!)

        XCTAssertEqual(summary.seasonsCounted, 3)
        XCTAssertEqual(summary.typicalChillHours ?? 0, 151 * 8, accuracy: 20)
        // Each season's figure is ALREADY a lower bound, so taking the minimum of
        // lower bounds would stack two pessimisms and rule out fruit that grows here.
        XCTAssertEqual(summary.planningChillHours, summary.typicalChillHours)
        XCTAssertGreaterThan(summary.planningChillHours ?? 0, summary.lowestChillHours ?? 0)
        XCTAssertTrue(summary.isMeaningful)
    }

    func testFruitFitReadsAgainstCultivarRanges() {
        let peach = FruitChill.common.first { $0.name.hasPrefix("Peach") }!
        XCTAssertEqual(peach.fit(1100), .comfortable)   // clears even high-chill cultivars
        XCTAssertEqual(peach.fit(600), .marginal)       // only low-chill varieties
        XCTAssertEqual(peach.fit(200), .insufficient)

        let ranked = FruitChill.ranked(for: 450)
        XCTAssertEqual(ranked.first?.1, .comfortable)
        XCTAssertEqual(ranked.last?.1, .insufficient)
    }
}

/// Records which windows a fake fetcher was asked for.
private actor FetchRecorder {
    private(set) var windows: [(Date, Date)] = []
    func record(start: Date, end: Date) { windows.append((start, end)) }
}

// MARK: - The year axis

final class YearAxisTests: XCTestCase {

    func testTheAxisRunsJanuaryFirstToDecemberThirtyFirst() {
        XCTAssertEqual(YearAxis.day(of: "01-01"), 0)
        XCTAssertEqual(YearAxis.day(of: "12-31"), YearAxis.dayCount - 1)
        XCTAssertEqual(YearAxis.monthDay(of: 0), "01-01")
        XCTAssertEqual(YearAxis.monthDay(of: YearAxis.dayCount - 1), "12-31")
        XCTAssertEqual(YearAxis.monthMarks.count, 12)
        XCTAssertEqual(YearAxis.monthMarks.map(\.start), YearAxis.monthStart)
    }

    /// The axis is leap-shaped, so a leap day is a day like any other rather
    /// than something folded onto the 28th.
    func testFebruaryTwentyNinthIsItsOwnSlot() {
        XCTAssertEqual(YearAxis.day(of: "02-29"), 59)
        XCTAssertEqual(YearAxis.day(of: "02-28").map { $0 + 1 }, YearAxis.day(of: "02-29"))
        XCTAssertEqual(YearAxis.monthDay(of: 59), "02-29")
    }

    /// A date rolls to next year once it's passed, so nothing reads as overdue.
    func testDaysUntilRollsIntoNextYear() {
        XCTAssertEqual(Climatology.daysUntil(monthDay: "09-01", from: "2025-08-06"), 26)
        XCTAssertEqual(Climatology.daysUntil(monthDay: "01-15", from: "2025-12-31"), 15)
    }
}
