import XCTest
@testable import WeatherKit

final class WindArcTests: XCTestCase {

    private func sample(_ t: Int, speed: Double, direction: Double, gust: Double? = nil) -> StationSample {
        var s = StationSample(timestamp: t, bucketMinutes: 1)
        s.windAvg = speed; s.windDirection = direction; s.windGust = gust
        return s
    }

    /// The bug this whole type exists to fix.
    ///
    /// A thoroughly southerly station spreads its wind over SSE, S and SSW. Read as
    /// bins, no one of them clears 15% and the top two look like a two-way split —
    /// so the summary said "there's no prevailing wind, it splits between the south
    /// and the south-southeast", which is nonsense: those are adjacent.
    func testAdjacentBinsAreOneBroadMaximumNotASplit() {
        var samples: [StationSample] = []
        for i in 0..<300 { samples.append(sample(i * 60, speed: 8, direction: 157.5)) }  // SSE
        for i in 300..<620 { samples.append(sample(i * 60, speed: 8, direction: 180)) }  // S
        for i in 620..<900 { samples.append(sample(i * 60, speed: 8, direction: 202.5)) } // SSW
        for i in 900..<1000 { samples.append(sample(i * 60, speed: 8, direction: 0)) }   // a little N

        let rose = WindRose.over(samples)
        XCTAssertFalse(rose.isSplit, "three adjacent southerly bins are one wind")
        let arc = rose.dominantArc()
        XCTAssertEqual(arc?.compass, "S")
        XCTAssertEqual(arc?.fraction ?? 0, 0.9, accuracy: 0.001)
        XCTAssertGreaterThan(arc?.fraction ?? 0, rose.prevailing?.fraction ?? 1,
                             "the arc must say more than the bin it's centred on")
    }

    func testAGenuineTwoWayAlternationIsSplit() {
        // Opposed quarters with a clear gap between them — a sea breeze by day and a
        // land breeze by night. This is the case the word "split" is reserved for.
        var samples: [StationSample] = []
        for i in 0..<500 { samples.append(sample(i * 60, speed: 8, direction: 180)) }
        for i in 500..<1000 { samples.append(sample(i * 60, speed: 8, direction: 0)) }
        XCTAssertTrue(WindRose.over(samples).isSplit)
    }

    func testAVariableWindIsNotASplitWind() {
        // Favours the south decisively, but with enough scatter everywhere else that
        // the resultant nearly cancels. Low constancy, one clear quarter — the
        // distinction the old mode-vs-resultant test got wrong.
        var samples: [StationSample] = []
        for i in 0..<600 { samples.append(sample(i * 60, speed: 8, direction: 180)) }
        for i in 0..<16 {
            for j in 0..<25 {
                samples.append(sample(100_000 + i * 100 + j, speed: 8, direction: Double(i) * 22.5))
            }
        }
        let rose = WindRose.over(samples)
        XCTAssertEqual(rose.dominantArc()?.compass, "S")
        XCTAssertFalse(rose.isSplit)
        XCTAssertLessThan(rose.constancy, 0.7)
    }

    func testAnArcWrapsPastNorth() {
        // NNW, N, NNE is a contiguous arc; an implementation that clamps at index 0
        // instead of wrapping would find a weaker arc somewhere else entirely.
        var samples: [StationSample] = []
        for i in 0..<100 { samples.append(sample(i, speed: 6, direction: 337.5)) }
        for i in 100..<200 { samples.append(sample(i, speed: 6, direction: 0)) }
        for i in 200..<300 { samples.append(sample(i, speed: 6, direction: 22.5)) }
        let arc = WindRose.over(samples).dominantArc()
        XCTAssertEqual(arc?.compass, "N")
        XCTAssertEqual(arc?.sectors, [15, 0, 1])
        XCTAssertEqual(arc?.fraction ?? 0, 1.0, accuracy: 0.001)
    }

    func testSecondaryArcMustBeSeparatedNotMerelyNextDoor() {
        // The shoulder of the main maximum is not a second regime, and an arc that
        // merely abuts the dominant one must be rejected even though it's disjoint.
        var samples: [StationSample] = []
        for i in 0..<900 { samples.append(sample(i, speed: 8, direction: 180)) }
        for i in 900..<1000 { samples.append(sample(i, speed: 8, direction: 247.5)) } // WSW
        let rose = WindRose.over(samples)
        let dominant = rose.dominantArc()!
        let secondary = rose.secondaryArc(to: dominant)
        XCTAssertFalse(secondary?.sectors.contains(where: { dominant.sectors.contains($0) }) ?? false)
        XCTAssertFalse(rose.isSplit)
    }
}

final class WindClimateTests: XCTestCase {

    /// An in-memory archive, so a climatology is testable without the network or a
    /// gzip file on disk.
    private final class MemoryArchive: SampleArchiveStore, @unchecked Sendable {
        var days: [String: [StationSample]] = [:]
        func samples(onDay day: String) throws -> [StationSample] { days[day] ?? [] }
        func archivedDays() throws -> [String] { days.keys.sorted() }
        func merge(_ samples: [StationSample], timeZone: TimeZone) throws -> [String] { [] }
    }

    private func day(_ key: String, direction: Double, speed: Double,
                     gust: Double? = nil) -> [StationSample] {
        (0..<(24 * 60)).map { minute in
            var s = StationSample(timestamp: minute * 60, bucketMinutes: 1)
            s.windAvg = speed; s.windDirection = direction; s.windGust = gust
            return s
        }
    }

    private func archive(_ build: (MemoryArchive) -> Void) -> MemoryArchive {
        let a = MemoryArchive(); build(a); return a
    }

    func testEachDayIsReadOnceIntoBothTheOverallRoseAndItsMonth() {
        let store = archive { a in
            a.days["2024-03-01"] = day("2024-03-01", direction: 180, speed: 10)
            a.days["2024-08-01"] = day("2024-08-01", direction: 0, speed: 4)
        }
        let climate = WindClimate.build(from: store)
        XCTAssertEqual(climate.days, 2)
        XCTAssertEqual(climate.byMonth[3]?.prevailing?.compass, "S")
        XCTAssertEqual(climate.byMonth[8]?.prevailing?.compass, "N")
        XCTAssertEqual(climate.overall.movingMinutes, 2 * 24 * 60)
        XCTAssertEqual(climate.byMonth.count, 2, "a month with no days is absent, not a rose of zeros")
    }

    func testWindiestAndCalmestMonthsAreByMeanSpeed() {
        let store = archive { a in
            a.days["2024-03-01"] = day("2024-03-01", direction: 180, speed: 12)
            a.days["2024-07-01"] = day("2024-07-01", direction: 180, speed: 3)
            a.days["2024-11-01"] = day("2024-11-01", direction: 180, speed: 7)
        }
        let climate = WindClimate.build(from: store)
        XCTAssertEqual(climate.windiestMonth?.month, 3)
        XCTAssertEqual(climate.calmestMonth?.month, 7)
    }

    func testTheGustiestMonthIsTrackedSeparatelyFromTheWindiest() {
        // The real record: March blows hardest on average, November holds the biggest
        // gust. Collapsing the two would lose the more surprising half.
        let store = archive { a in
            a.days["2024-03-01"] = day("2024-03-01", direction: 180, speed: 12, gust: 30)
            a.days["2024-11-01"] = day("2024-11-01", direction: 180, speed: 5, gust: 68)
        }
        let climate = WindClimate.build(from: store)
        XCTAssertEqual(climate.windiestMonth?.month, 3)
        XCTAssertEqual(climate.gustiestMonth?.month, 11)
    }

    func testAMonthThatSlipsOneBinHasNotTurned() {
        // S in the record, SSE in July: the same southerly wind at a resolution finer
        // than the claim. Comparing bins would report a turn that didn't happen.
        let store = archive { a in
            for m in 1...12 {
                let key = String(format: "2024-%02d-01", m)
                a.days[key] = day(key, direction: m == 7 ? 157.5 : 180, speed: 6)
            }
        }
        XCTAssertEqual(WindClimate.build(from: store).monthsAgainstTheGrain(), [])
    }

    func testAMonthInAGenuinelyDifferentQuarterIsFlagged() {
        let store = archive { a in
            for m in 1...12 {
                let key = String(format: "2024-%02d-01", m)
                a.days[key] = day(key, direction: m == 1 ? 0 : 180, speed: 6)
            }
        }
        XCTAssertEqual(WindClimate.build(from: store).monthsAgainstTheGrain(), [1])
    }

    func testAThinArchiveSaysNothingRatherThanSomethingThin() {
        let store = archive { a in a.days["2024-03-01"] = day("2024-03-01", direction: 180, speed: 8) }
        XCTAssertTrue(WeatherInterpreter.windSummary(WindClimate.build(from: store)).isEmpty)
    }

    func testASteadyWindIsNotDescribedAsSplit() {
        let store = archive { a in
            for m in 1...12 {
                for d in 1...28 {
                    let key = String(format: "2024-%02d-%02d", m, d)
                    a.days[key] = day(key, direction: 180, speed: 8)
                }
            }
        }
        let lines = WeatherInterpreter.windSummary(WindClimate.build(from: store))
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines[0].contains("comes out of the south"), lines[0])
        XCTAssertFalse(lines.contains { $0.contains("no single prevailing wind") })
    }
}
