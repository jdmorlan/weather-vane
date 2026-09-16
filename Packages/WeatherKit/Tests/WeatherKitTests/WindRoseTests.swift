import XCTest
@testable import WeatherKit

final class WindRoseTests: XCTestCase {

    private func sample(_ timestamp: Int, speed: Double?, direction: Double?,
                        gust: Double? = nil, bucket: Int = 1) -> StationSample {
        var s = StationSample(timestamp: timestamp, bucketMinutes: bucket)
        s.windAvg = speed
        s.windDirection = direction
        s.windGust = gust
        return s
    }

    // MARK: The reason this type exists

    func testMeanDirectionAcrossNorthWouldBeWrongAndTheResultantIsNot() {
        // 350° and 10° average to 180° — due SOUTH, the exact opposite of the truth.
        // The vector sum is the only reduction that survives the wrap, and getting
        // this right is the whole argument for not storing a daily mean direction.
        let rose = WindRose.over([
            sample(0, speed: 10, direction: 350),
            sample(60, speed: 10, direction: 10),
        ])
        XCTAssertEqual(rose.resultantDegrees, 0, accuracy: 0.001)
        XCTAssertGreaterThan(rose.constancy, 0.98, "two readings 20° apart is a steady wind")
    }

    func testOpposedWindsCancelIntoLowConstancy() {
        // A valley that drains north at night and breathes south by day has a real
        // mode and no net direction at all. Reporting only the resultant would
        // invent a calm place; reporting only the mode would invent a steady one.
        let rose = WindRose.over([
            sample(0, speed: 10, direction: 0),
            sample(60, speed: 10, direction: 180),
        ])
        XCTAssertLessThan(rose.constancy, 0.01)
        XCTAssertGreaterThan(rose.sectors[0].minutes, 0)
        XCTAssertGreaterThan(rose.sectors[8].minutes, 0)
    }

    func testAStrongOpposedMinorityDragsTheResultantWithoutMakingTheWindSplit() {
        // Mostly south, with one hard northerly that cancels most of the resultant.
        // The place still clearly favours the south — only the NET motion is small.
        // An earlier `isSplit` compared the mode to the resultant and called this a
        // split, which is how the summary ended up denying a prevailing wind at a
        // station that plainly has one. Constancy is where this fact belongs.
        let rose = WindRose.over([
            sample(0, speed: 5, direction: 180),
            sample(60, speed: 5, direction: 180),
            sample(120, speed: 5, direction: 180),
            sample(180, speed: 30, direction: 0),
        ])
        XCTAssertEqual(rose.prevailing?.compass, "S")
        XCTAssertEqual(rose.dominantArc()?.compass, "S")
        XCTAssertFalse(rose.isSplit)
        XCTAssertLessThan(rose.constancy, 0.35, "the resultant really is nearly cancelled")
    }

    // MARK: Weighting

    func testMinutesNotRowsAreTheWeight() {
        // One 30-minute bucket from the original backfill outweighs a single
        // 1-minute reading thirty to one. Counting rows would let a densely
        // sampled week outvote a sparsely sampled year.
        let rose = WindRose.over([
            sample(0, speed: 10, direction: 0, bucket: 30),
            sample(1800, speed: 10, direction: 90, bucket: 1),
        ])
        XCTAssertEqual(rose.sectors[0].minutes, 30)
        XCTAssertEqual(rose.sectors[4].minutes, 1)
        XCTAssertEqual(rose.movingMinutes, 31)
    }

    func testFractionsAreOfMovingMinutesAndCalmIsReportedSeparately() {
        let rose = WindRose.over([
            sample(0, speed: 10, direction: 0),
            sample(60, speed: 0.2, direction: 0),   // calm: direction is noise
            sample(120, speed: 0, direction: 180),
        ])
        XCTAssertEqual(rose.sectors[0].fraction, 1.0, accuracy: 0.001,
                       "the one moving minute is all of the moving minutes")
        XCTAssertEqual(rose.calmMinutes, 2)
        XCTAssertEqual(rose.calmFraction, 2.0 / 3.0, accuracy: 0.001)
    }

    func testCalmReadingsDoNotStackASpikeOnNorth() {
        // A still station still reports a bearing, very often 0. Letting those in
        // manufactures a north wind out of an instrument's resting position.
        let calm = (0..<100).map { sample($0 * 60, speed: 0, direction: 0) }
        let rose = WindRose.over(calm + [sample(100_000, speed: 12, direction: 180)])
        XCTAssertEqual(rose.sectors[0].minutes, 0)
        XCTAssertEqual(rose.prevailing?.compass, "S")
    }

    func testSectorBinningRoundsToTheNearestOfSixteenPoints() {
        // 11.24° is still N; 11.26° tips into NNE. The boundary is half a bin.
        XCTAssertEqual(WindRose.over([sample(0, speed: 5, direction: 11.2)]).prevailing?.compass, "N")
        XCTAssertEqual(WindRose.over([sample(0, speed: 5, direction: 11.3)]).prevailing?.compass, "NNE")
        XCTAssertEqual(WindRose.over([sample(0, speed: 5, direction: 359)]).prevailing?.compass, "N")
        XCTAssertEqual(WindRose.over([sample(0, speed: 5, direction: -90)]).prevailing?.compass, "W")
    }

    // MARK: Speed, bands and peaks

    func testARareSectorCanOwnTheStrongestWind() {
        // The point of banding: the south is the everyday breeze, the north is what
        // takes the fence down. A rose that only showed time would hide that.
        var samples = (0..<60).map { sample($0 * 60, speed: 5, direction: 180, gust: 9) }
        samples.append(sample(999_999, speed: 30, direction: 0, gust: 55))
        let rose = WindRose.over(samples)
        XCTAssertEqual(rose.prevailing?.compass, "S")
        XCTAssertEqual(rose.strongest?.compass, "N")
        XCTAssertEqual(rose.peakGust?.speed, 55)
        XCTAssertEqual(rose.peakGust?.timestamp, 999_999)
    }

    func testBandMinutesSplitASectorBySpeed() {
        let rose = WindRose.over([
            sample(0, speed: 2, direction: 90),     // light
            sample(60, speed: 10, direction: 90),   // moderate
            sample(120, speed: 40, direction: 90),  // gale
        ])
        let east = rose.sectors[4]
        XCTAssertEqual(east.bandMinutes[0], 1)
        XCTAssertEqual(east.bandMinutes[2], 1)
        XCTAssertEqual(east.bandMinutes[5], 1)
        XCTAssertEqual(east.meanSpeed, (2 + 10 + 40) / 3, accuracy: 0.001)
    }

    func testPeakGustSurvivesTheCalmCut() {
        // A gust of 40 in an otherwise still minute is the single most interesting
        // thing that happened. Dropping it with the calm reading would be a bug.
        let rose = WindRose.over([sample(0, speed: 0, direction: nil, gust: 40)])
        XCTAssertEqual(rose.peakGust?.speed, 40)
        XCTAssertEqual(rose.movingMinutes, 0)
    }

    func testAVaneThatStopsReportingIsCountedNotSilentlyDropped() {
        let rose = WindRose.over([
            sample(0, speed: 10, direction: nil),
            sample(60, speed: 10, direction: 180),
        ])
        XCTAssertEqual(rose.undirectedMinutes, 1)
        XCTAssertEqual(rose.movingMinutes, 1)
        XCTAssertEqual(rose.totalMinutes, 2)
    }

    // MARK: Shape and honesty

    func testAlwaysSixteenSectorsIncludingEmptyOnes() {
        let rose = WindRose.over([sample(0, speed: 5, direction: 180)])
        XCTAssertEqual(rose.sectors.count, 16)
        XCTAssertEqual(rose.sectors.map(\.compass).prefix(4), ["N", "NNE", "NE", "ENE"])
        XCTAssertEqual(rose.sectors.filter { $0.minutes == 0 }.count, 15)
    }

    func testAnEmptyRoseIsWellFormedRatherThanNaN() {
        let rose = WindRose.over([])
        XCTAssertEqual(rose.sectors.count, 16)
        XCTAssertEqual(rose.meanSpeed, 0)
        XCTAssertEqual(rose.constancy, 0)
        XCTAssertEqual(rose.calmFraction, 0)
        XCTAssertNil(rose.peakGust)
        XCTAssertFalse(rose.isSplit)
    }

    func testAWeekIsNotAClimatology() {
        var week = WindRoseBuilder()
        for i in 0..<(7 * 24 * 60) { week.add(sample(i * 60, speed: 6, direction: 200)) }
        XCTAssertFalse(week.build().isRepresentative())

        var year = WindRoseBuilder()
        for i in 0..<(365 * 24 * 60) { year.add(sample(i * 60, speed: 6, direction: 200)) }
        XCTAssertTrue(year.build().isRepresentative())
    }

    func testStreamingMatchesReducingItAllAtOnce() {
        let samples = (0..<500).map {
            sample($0 * 60, speed: Double($0 % 17) + 1, direction: Double(($0 * 37) % 360),
                   gust: Double($0 % 23) + 5)
        }
        var streamed = WindRoseBuilder()
        for chunk in stride(from: 0, to: samples.count, by: 37) {
            streamed.add(Array(samples[chunk..<min(chunk + 37, samples.count)]))
        }
        XCTAssertEqual(streamed.build(), WindRose.over(samples))
    }
}
