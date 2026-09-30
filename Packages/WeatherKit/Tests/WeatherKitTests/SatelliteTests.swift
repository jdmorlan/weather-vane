import XCTest
@testable import WeatherKit

final class SatelliteTests: XCTestCase {

    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    /// The shape of nowCOAST's capabilities, trimmed: the water-vapour layer
    /// between two others, each with its own time list.
    private let capabilities = """
    <Layer queryable="1"><Name>goes_longwave_imagery</Name>
      <Dimension name="time" default="2026-09-30T22:28:00Z" units="ISO8601" nearestValue="1">2026-09-30T22:23:00.000Z,2026-09-30T22:28:00.000Z</Dimension>
    </Layer>
    <Layer queryable="1"><Name>goes_water_vapor_imagery</Name>
      <Title>GOES East &amp; West Satellite Water Vapor Imagery</Title>
      <Dimension name="time" default="2026-09-30T22:28:00Z" units="ISO8601" nearestValue="1">2026-09-30T22:18:00.000Z,2026-09-30T22:23:00.000Z,2026-09-30T22:28:00.000Z</Dimension>
    </Layer>
    <Layer queryable="1"><Name>goes_visible_imagery</Name></Layer>
    """

    func testReadsOnlyTheNamedLayersTimes() {
        let times = SatelliteScans.times(in: capabilities, layer: "goes_water_vapor_imagery")
        XCTAssertEqual(times, [date("2026-09-30T22:18:00Z"), date("2026-09-30T22:23:00Z"),
                               date("2026-09-30T22:28:00Z")])
        XCTAssertEqual(SatelliteScans.times(in: capabilities, layer: "goes_longwave_imagery").count, 2)
    }

    func testALayerWithNoTimeDimensionHasNoScans() {
        // Not the next layer's list.
        XCTAssertEqual(SatelliteScans.times(in: capabilities, layer: "goes_visible_imagery"), [])
        XCTAssertEqual(SatelliteScans.times(in: capabilities, layer: "no_such_layer"), [])
    }

    func testReadsAStartEndPeriodDimension() {
        let doc = #"<Name>x</Name><Dimension name="time" units="ISO8601">2026-09-30T22:00:00Z/2026-09-30T22:20:00Z/PT5M</Dimension></Layer>"#
        XCTAssertEqual(SatelliteScans.times(in: doc, layer: "x").count, 5)
    }

    func testStampIsTheTimeAsTheCapabilitiesWriteIt() {
        XCTAssertEqual(SatelliteScans.stamp(date("2026-09-30T22:28:00Z")), "2026-09-30T22:28:00.000Z")
    }

    func testFramesAreTenMinutesApartOverThreeHoursEndingOnTheNewest() {
        // Seven and a half hours of five-minute scans, as the service keeps.
        let newest = date("2026-09-30T22:28:00Z")
        let times = (0..<90).reversed().map { newest.addingTimeInterval(Double(-$0 * 300)) }
        let frames = SatelliteScans.frames(from: times)
        XCTAssertEqual(frames.last, newest)
        XCTAssertEqual(frames.count, 19)                     // 0, 10, … 180 minutes back
        XCTAssertEqual(frames.first, newest.addingTimeInterval(-3 * 3600))
        XCTAssertTrue(zip(frames, frames.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 600 })
    }

    func testAMissedScanDoesNotBreakTheSpacing() {
        let newest = date("2026-09-30T22:28:00Z")
        // 22:18 is missing: the next frame back is the first at least ten minutes on.
        let times = [-25, -20, -15, -5, 0].map { newest.addingTimeInterval(Double($0 * 60)) }
        XCTAssertEqual(SatelliteScans.frames(from: times),
                       [-25, -15, 0].map { newest.addingTimeInterval(Double($0 * 60)) })
    }

    // MARK: Colour

    func testWaterVapourPaintsDryBrownAndMoistPale() throws {
        let table = SatelliteFieldSource.table(for: .waterVapor)
        let dry = try XCTUnwrap(table[20]), moist = try XCTUnwrap(table[125])
        XCTAssertGreaterThan(dry.0, dry.2, "dry air is warm-coloured")
        XCTAssertGreaterThan(moist.0, 220, "the moist plume is near white")
        XCTAssertTrue(table.allSatisfy { $0 != nil }, "a field, not a mask: every level is drawn")
    }

    func testInfraredDropsWarmGroundAndColoursTheColdestTops() throws {
        let table = SatelliteFieldSource.table(for: .infrared)
        XCTAssertNil(table[83], "clear ground")
        let core = try XCTUnwrap(table[242])
        XCTAssertGreaterThan(core.0, core.1, "the coldest tops are red")
    }
}
