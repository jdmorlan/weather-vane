import XCTest
@testable import WeatherKit

final class DiurnalClimateTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    /// A day of 1-minute samples whose temperature is a sine peaking at a named
    /// minute — the shape the whole chart exists to recover.
    private func day(_ key: String, peakMinute: Int, amplitude: Double = 20,
                     mean: Double = 70, humidity: Double = 50,
                     bucketMinutes: Int = 1, zone: TimeZone? = nil) -> [StationSample] {
        let zone = zone ?? utc
        guard let midnight = DayKey.date(from: key, timeZone: zone) else { return [] }
        let base = Int(midnight.timeIntervalSince1970)
        return stride(from: 0, to: 1440, by: bucketMinutes).map { minute in
            var sample = StationSample(timestamp: base + minute * 60,
                                       bucketMinutes: bucketMinutes)
            let phase = Double(minute - peakMinute) / 1440 * 2 * .pi
            sample.airTemp = mean + amplitude * cos(phase)
            sample.humidity = humidity
            sample.windAvg = 5
            return sample
        }
    }

    private func accumulator(_ days: [String: [StationSample]],
                             zone: TimeZone? = nil) -> DiurnalAccumulator {
        var accumulator = DiurnalAccumulator()
        for key in days.keys.sorted() {
            accumulator.fold(day: key, samples: days[key]!, timeZone: zone ?? utc)
        }
        return accumulator
    }

    // MARK: The slot grid

    func testASlotIsFifteenMinutesAndTheDayIsCoveredExactly() {
        XCTAssertEqual(DiurnalClimate.slotCount, 96)
        XCTAssertEqual(DiurnalClimate.slotMinutes, 15)
        XCTAssertEqual(DiurnalClimate.slotCount * DiurnalClimate.slotMinutes, 24 * 60)
        XCTAssertEqual(DiurnalClimate.slot(ofMinute: 0), 0)
        XCTAssertEqual(DiurnalClimate.slot(ofMinute: 14), 0)
        XCTAssertEqual(DiurnalClimate.slot(ofMinute: 15), 1)
        XCTAssertEqual(DiurnalClimate.slot(ofMinute: 1439), 95)
        XCTAssertEqual(DiurnalClimate.minuteOfDay(ofSlot: 60), 900)   // 3pm
    }

    /// Out-of-range minutes clamp rather than crashing a fold that is walking
    /// two million samples and cannot afford a precondition.
    func testMinutesOutsideTheDayClamp() {
        XCTAssertEqual(DiurnalClimate.slot(ofMinute: -5), 0)
        XCTAssertEqual(DiurnalClimate.slot(ofMinute: 5000), 95)
    }

    // MARK: Recovering the shape

    /// The headline claim: the fold can say WHEN the day peaks, which is the one
    /// thing a daily min/max can never answer.
    func testTheFoldRecoversTheHourTheDayPeaks() {
        // 3:30pm.
        let samples = accumulator(["2024-07-15": day("2024-07-15", peakMinute: 15 * 60 + 30)])
        let climate = samples.climate(days: ["2024-07-15"])
        let extremes = climate.overall.extremes(.temperature)
        XCTAssertEqual(extremes?.peak, DiurnalClimate.slot(ofMinute: 15 * 60 + 30))
    }

    /// The other half of the same fact, and the more surprising one: the day's
    /// low is not midnight.
    func testTheTroughLandsOppositeThePeakNotAtMidnight() {
        let samples = accumulator(["2024-07-15": day("2024-07-15", peakMinute: 15 * 60)])
        let climate = samples.climate(days: ["2024-07-15"])
        let extremes = climate.overall.extremes(.temperature)
        XCTAssertEqual(extremes?.trough, DiurnalClimate.slot(ofMinute: 3 * 60))
        XCTAssertNotEqual(extremes?.trough, 0)
    }

    func testTheSwingIsTheDistanceBetweenTroughAndPeak() {
        let samples = accumulator(["2024-07-15": day("2024-07-15", peakMinute: 900, amplitude: 12)])
        let swing = samples.climate(days: ["2024-07-15"]).overall.swing(.temperature)
        // Two amplitudes across, less whatever the 15-minute mean rounds off.
        XCTAssertEqual(swing ?? 0, 24, accuracy: 0.2)
    }

    /// THE REGRESSION THIS EXISTS FOR, taken from real data. A mean daily curve
    /// is flat across its top; a dip of a few tenths inside that flat stretch is
    /// noise, and an argmax will happily hand back whichever side of the dip
    /// happens to sit a hair higher. This station's July did exactly that — the
    /// peak was reported an hour and a half late off a 0.4° wobble.
    func testAWobbleInsideTheFlatTopDoesNotMoveThePeak() {
        guard let midnight = DayKey.date(from: "2024-07-15", timeZone: utc) else { return XCTFail() }
        let base = Int(midnight.timeIntervalSince1970)
        let truePeak = 17 * 60
        let noiseAt = 18 * 60 + 30
        let samples = (0..<1440).map { minute -> StationSample in
            var sample = StationSample(timestamp: base + minute * 60, bucketMinutes: 1)
            // A genuinely flat-topped afternoon centred on 5pm...
            var temp = 91.5 - 0.00002 * pow(Double(minute - truePeak), 2)
            // ...and a third of a degree of wobble in one quarter-hour, which is
            // all it takes for a raw argmax to call 6:30pm the peak.
            if minute >= noiseAt, minute < noiseAt + 15 { temp += 0.35 }
            sample.airTemp = temp
            sample.humidity = 50
            return sample
        }
        let climate = accumulator(["2024-07-15": samples]).climate(days: ["2024-07-15"])

        // The bug, stated: unsmoothed, the wobble wins.
        let raw = climate.overall.temperature.enumerated()
            .compactMap { index, value in value.map { (index, $0) } }
            .max(by: { $0.1 < $1.1 })?.0
        XCTAssertEqual(raw, DiurnalClimate.slot(ofMinute: noiseAt))

        // The fix: the peak lands on the curve, not on the wobble.
        let peak = climate.overall.extremes(.temperature)?.peak ?? -1
        XCTAssertLessThan(abs(peak - DiurnalClimate.slot(ofMinute: truePeak)), 3)
        XCTAssertNotEqual(peak, DiurnalClimate.slot(ofMinute: noiseAt))
    }

    /// The smoothing window wraps, because a day is a cycle. Without it the
    /// slots either side of midnight are averaged against nothing and the
    /// overnight trough — which sits nearest that seam — is drawn toward it.
    func testTheSmoothingWindowWrapsAtMidnight() {
        var series = [Double?](repeating: 10, count: DiurnalClimate.slotCount)
        series[0] = 0
        series[DiurnalClimate.slotCount - 1] = 0
        let smoothed = DiurnalProfile.smoothed(series, window: DiurnalProfile.smoothingSlots)
        // Midnight sees both zeros; a non-wrapping window would only see one.
        XCTAssertEqual(smoothed[0] ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(smoothed[DiurnalClimate.slotCount - 1] ?? 0, 6, accuracy: 0.001)
    }

    /// A window mostly made of holes is not an answer.
    func testSmoothingRefusesAWindowItCannotFill() {
        var series = [Double?](repeating: nil, count: DiurnalClimate.slotCount)
        series[40] = 50
        let smoothed = DiurnalProfile.smoothed(series, window: 5)
        XCTAssertNil(smoothed[40], "one reading in five is not a mean")
        series[41] = 50
        series[42] = 50
        XCTAssertNotNil(DiurnalProfile.smoothed(series, window: 5)[41])
    }

    // MARK: Around the year

    /// The chart's real subject: the peak moves later in summer, and the matrix
    /// has to keep the months apart to show it.
    func testMonthsAreFoldedSeparatelySoTheSeasonalLagIsVisible() {
        var days: [String: [StationSample]] = [:]
        for d in 1...5 { days[String(format: "2024-01-%02d", d)] = day(String(format: "2024-01-%02d", d), peakMinute: 14 * 60) }
        for d in 1...5 { days[String(format: "2024-07-%02d", d)] = day(String(format: "2024-07-%02d", d), peakMinute: 16 * 60) }

        let climate = accumulator(days).climate(days: days.keys.sorted())
        XCTAssertEqual(climate.byMonth[1]?.extremes(.temperature)?.peak,
                       DiurnalClimate.slot(ofMinute: 14 * 60))
        XCTAssertEqual(climate.byMonth[7]?.extremes(.temperature)?.peak,
                       DiurnalClimate.slot(ofMinute: 16 * 60))
        XCTAssertNil(climate.byMonth[3], "a month with no days is absent, not flat")
    }

    /// `peakSpread` is what the lead sentence is written from.
    func testPeakSpreadNamesTheEarliestAndLatestMonths() {
        var days: [String: [StationSample]] = [:]
        // Ten days a month clears `isMeaningful`.
        for d in 1...11 { days[String(format: "2024-01-%02d", d)] = day(String(format: "2024-01-%02d", d), peakMinute: 13 * 60) }
        for d in 1...11 { days[String(format: "2024-07-%02d", d)] = day(String(format: "2024-07-%02d", d), peakMinute: 17 * 60) }

        let spread = accumulator(days).climate(days: days.keys.sorted()).peakSpread(.temperature)
        XCTAssertEqual(spread?.earliest.month, 1)
        XCTAssertEqual(spread?.latest.month, 7)
        XCTAssertEqual(spread?.earliest.slot, DiurnalClimate.slot(ofMinute: 13 * 60))
        XCTAssertEqual(spread?.latest.slot, DiurnalClimate.slot(ofMinute: 17 * 60))
    }

    /// One ramp across every month, or every afternoon reads the same shade of
    /// hot and the comparison the chart exists for is destroyed.
    func testTheRangeSpansEveryMonthAtOnce() {
        var days: [String: [StationSample]] = [:]
        for d in 1...5 { days[String(format: "2024-01-%02d", d)] = day(String(format: "2024-01-%02d", d), peakMinute: 840, mean: 40) }
        for d in 1...5 { days[String(format: "2024-07-%02d", d)] = day(String(format: "2024-07-%02d", d), peakMinute: 960, mean: 85) }

        let range = accumulator(days).climate(days: days.keys.sorted()).range(.temperature)
        XCTAssertEqual(range?.low ?? 0, 20, accuracy: 1)    // January's trough
        XCTAssertEqual(range?.high ?? 0, 105, accuracy: 1)  // July's peak
    }

    // MARK: Honesty

    /// A slot nothing was ever recorded in has to stay empty. Zero would draw as
    /// a cold snap at 3am for a station that came online at noon.
    func testUnwatchedSlotsStayNil() {
        guard let midnight = DayKey.date(from: "2024-03-01", timeZone: utc) else { return XCTFail() }
        let base = Int(midnight.timeIntervalSince1970)
        // Noon to 6pm only.
        let partial = stride(from: 720, to: 1080, by: 1).map { minute -> StationSample in
            var sample = StationSample(timestamp: base + minute * 60, bucketMinutes: 1)
            sample.airTemp = 70
            sample.humidity = 50
            return sample
        }
        let climate = accumulator(["2024-03-01": partial]).climate(days: ["2024-03-01"])
        XCTAssertNil(climate.overall.temperature[DiurnalClimate.slot(ofMinute: 3 * 60)])
        XCTAssertNotNil(climate.overall.temperature[DiurnalClimate.slot(ofMinute: 13 * 60)])
        // And a measure the station never reported stays empty all the way across.
        XCTAssertTrue(climate.overall.wind.allSatisfy { $0 == nil })
    }

    /// A reading that stands for half an hour cannot say what a quarter past
    /// three was like — see the file header.
    func testSamplesCoarserThanASlotAreRefused() {
        let coarse = day("2024-03-01", peakMinute: 900, bucketMinutes: 30)
        let climate = accumulator(["2024-03-01": coarse]).climate(days: ["2024-03-01"])
        XCTAssertTrue(climate.overall.temperature.allSatisfy { $0 == nil })
        XCTAssertEqual(climate.overall.minutes, 0)

        // A 15-minute sample is exactly a slot, so it is admitted.
        let exact = day("2024-03-01", peakMinute: 900, bucketMinutes: 15)
        let fine = accumulator(["2024-03-01": exact]).climate(days: ["2024-03-01"])
        XCTAssertTrue(fine.overall.temperature.contains { $0 != nil })
    }

    /// Minute-of-day is meaningless without a clock, and it is the STATION's
    /// clock — the same reading folded under two zones belongs in two slots.
    func testTheSlotFollowsTheTimeZoneItWasFoldedUnder() {
        let key = "2024-07-15"
        let samples = day(key, peakMinute: 15 * 60)
        let asUTC = accumulator([key: samples]).climate(days: [key])

        let chicago = TimeZone(identifier: "America/Chicago")!
        var shifted = DiurnalAccumulator()
        shifted.fold(day: key, samples: samples, timeZone: chicago)
        let asLocal = shifted.climate(days: [key])

        let utcPeak = asUTC.overall.extremes(.temperature)?.peak ?? -1
        let localPeak = asLocal.overall.extremes(.temperature)?.peak ?? -1
        // Five hours behind in July, and the slot grid wraps.
        XCTAssertEqual((utcPeak - localPeak + 96) % 96, 5 * 4)
    }

    /// Dew point isn't reported by the station; it is derived per sample, which
    /// is the only place it can be derived correctly.
    func testDewPointIsDerivedPerSampleRatherThanFromDailyMeans() {
        let climate = accumulator(["2024-07-15": day("2024-07-15", peakMinute: 900,
                                                     amplitude: 0, mean: 80, humidity: 60)])
            .climate(days: ["2024-07-15"])
        let dew = climate.overall.dewPoint.compactMap { $0 }
        XCTAssertFalse(dew.isEmpty)
        // 80° at 60% RH is in the mid-60s.
        XCTAssertEqual(dew[0], WeatherInterpreter.dewPointF(tempF: 80, humidity: 60), accuracy: 0.01)
    }

    // MARK: Merging

    /// The sums have to ADD, or a warm cache can't fold one new day in and the
    /// whole point of the accumulator is lost.
    func testFoldingTwoHalvesMatchesFoldingTheWhole() {
        let a = day("2024-07-15", peakMinute: 900, mean: 70)
        let b = day("2024-07-16", peakMinute: 900, mean: 90)

        let together = accumulator(["2024-07-15": a, "2024-07-16": b])
            .climate(days: ["2024-07-15", "2024-07-16"])

        var incremental = DiurnalAccumulator()
        incremental.fold(day: "2024-07-15", samples: a, timeZone: utc)
        incremental.fold(day: "2024-07-16", samples: b, timeZone: utc)
        let stepwise = incremental.climate(days: ["2024-07-15", "2024-07-16"])

        XCTAssertEqual(together, stepwise)
        // And the mean of the two is what landed, not the last one written.
        let peak = together.overall.extremes(.temperature)?.peak ?? 0
        XCTAssertEqual(together.overall.temperature[peak] ?? 0, 100, accuracy: 0.5)
    }

    func testTheAccumulatorSurvivesADiskRoundTrip() throws {
        let built = accumulator(["2024-07-15": day("2024-07-15", peakMinute: 900)])
        let data = try JSONEncoder().encode(built)
        let back = try JSONDecoder().decode(DiurnalAccumulator.self, from: data)
        XCTAssertEqual(built, back)
    }

    /// Months are keyed as strings so the stored file is readable without this
    /// app — the same rule the wind accumulator keeps, and for the same reason.
    func testMonthsAreKeyedLegiblyOnDisk() throws {
        let built = accumulator(["2024-07-15": day("2024-07-15", peakMinute: 900)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let text = String(decoding: try encoder.encode(built), as: UTF8.self)
        XCTAssertTrue(text.contains("\"07\""), "months read as \"07\", not as an array of pairs")
    }
}

// MARK: - The shape rides along with the wind

final class SampleClimateDiurnalTests: XCTestCase {

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

    /// The whole reason the diurnal fold lives in the wind's accumulator: one
    /// read of the day, both answers.
    func testOneReadOfTheArchiveProducesBothClimatologies() throws {
        let store = MemoryArchive()
        guard let midnight = DayKey.date(from: "2024-07-15", timeZone: .current) else { return XCTFail() }
        let base = Int(midnight.timeIntervalSince1970)
        store.days["2024-07-15"] = (0..<1440).map { minute in
            var sample = StationSample(timestamp: base + minute * 60, bucketMinutes: 1)
            sample.airTemp = 70 + 15 * cos(Double(minute - 900) / 1440 * 2 * .pi)
            sample.humidity = 50
            sample.windAvg = 9
            sample.windDirection = 180
            return sample
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)/sample-climate.json")
        let built = SampleClimateCache(url: url).refresh(from: store)

        XCTAssertEqual(store.reads, ["2024-07-15"], "the day is read once, not twice")
        XCTAssertEqual(built.wind.days, 1)
        XCTAssertEqual(built.day.days, 1)
        XCTAssertEqual(built.day.overall.extremes(.temperature)?.peak,
                       DiurnalClimate.slot(ofMinute: 900))
    }

    /// Sums indexed by wall-clock time can only be extended under the clock they
    /// were folded against.
    func testACacheFoldedUnderAnotherClockIsNotLoaded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)/sample-climate.json")
        let cache = SampleClimateCache(url: url)
        var accumulator = SampleClimateAccumulator(timeZone: TimeZone(identifier: "UTC")!)
        accumulator.days = ["2024-07-15"]
        try cache.save(accumulator)

        XCTAssertNotNil(cache.load(timeZone: TimeZone(identifier: "UTC")!))
        XCTAssertNil(cache.load(timeZone: TimeZone(identifier: "America/Chicago")!),
                     "a moved station rebuilds rather than folding afternoons onto mornings")
    }

    /// An old wind-only cache has no day-shapes in it and none can be derived
    /// from a finished rose, so the only honest migration is to read again.
    func testAPreDiurnalCacheIsTreatedAsStale() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)/sample-climate.json")
        let cache = SampleClimateCache(url: url)
        var accumulator = SampleClimateAccumulator()
        accumulator.version = 1
        try cache.save(accumulator)
        XCTAssertNil(cache.load())
    }
}
