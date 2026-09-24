import XCTest
import CoreGraphics
@testable import WeatherKit
@testable import RadarKernel

final class Level2Tests: XCTestCase {

    /// The header and first two LDM records of KFWS's 12:22Z volume on
    /// 2026-09-24 — metadata, then the first 120 radials of the 0.5° tilt. Cut
    /// at a record boundary, so it is exactly what a short ranged read returns.
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/KFWS20260924_122217_V06",
                                                  withExtension: "head"))
        return try Data(contentsOf: url)
    }

    func testDecodesSiteAndTimeFromARealVolume() throws {
        let volume = try Level2.decode(fixture(), moments: ["REF"], throughElevation: 1)
        XCTAssertEqual(volume.icao, "KFWS")
        // Where the NWS says KFWS is, to the third decimal.
        XCTAssertEqual(volume.latitude, 32.573, accuracy: 0.001)
        XCTAssertEqual(volume.longitude, -97.303, accuracy: 0.001)
        // The file name is to the second; the header carries milliseconds.
        XCTAssertEqual(volume.time.timeIntervalSince1970,
                       Level2Scan(name: "KFWS20260924_122217_V06")!.time.timeIntervalSince1970, accuracy: 1)
    }

    func testAShortReadIsAPartialSweepNotAnError() throws {
        let sweep = try XCTUnwrap(Level2.decode(fixture(), moments: ["REF"], throughElevation: 1).lowest("REF"))
        XCTAssertEqual(sweep.elevationNumber, 1)
        XCTAssertEqual(sweep.elevationAngle, 0.5, accuracy: 0.1)
        XCTAssertEqual(sweep.rowCount, 720, "super-resolution: 0.5° radials")
        XCTAssertEqual(sweep.gateSpacing, 250)
        XCTAssertEqual(sweep.radialCount, 120)
        XCTAssertFalse(sweep.isComplete)
        let real = sweep.values.filter { !$0.isNaN }
        XCTAssertFalse(real.isEmpty)
        // 8-bit REF spans -32...94.5 dBZ; anything outside is a scaling bug.
        XCTAssertGreaterThanOrEqual(real.min()!, -32)
        XCTAssertLessThanOrEqual(real.max()!, 94.5)
    }

    func testOnlyAskedForMomentsAreKept() throws {
        let volume = try Level2.decode(fixture(), moments: ["RHO"], throughElevation: 1)
        XCTAssertNil(volume.lowest("REF"))
        let rho = try XCTUnwrap(volume.lowest("RHO"))
        let real = rho.values.filter { !$0.isNaN }
        XCTAssertGreaterThan(real.count, 0)
        XCTAssertLessThanOrEqual(real.max()!, 1.06, "ρhv is a correlation, never much above 1")
    }

    func testMetadataOnlyIsNoRadials() throws {
        let head = try fixture().prefix(2359)   // header + the metadata record
        XCTAssertThrowsError(try Level2.decode(head)) { error in
            XCTAssertEqual(error as? Level2.Failure, .noRadials)
        }
    }

    func testNotLevel2IsRefused() {
        XCTAssertThrowsError(try Level2.decode(Data(repeating: 7, count: 64)))
    }

    // MARK: Names and listings

    func testScanNameRoundTripsToItsKey() throws {
        let scan = try XCTUnwrap(Level2Scan(name: "KFWS20260924_122217_V06"))
        XCTAssertEqual(scan.site, "KFWS")
        XCTAssertEqual(scan.key, "2026/09/24/KFWS/KFWS20260924_122217_V06")
        XCTAssertEqual(scan.time, ISO8601DateFormatter().date(from: "2026-09-24T12:22:17Z"))
        XCTAssertNil(Level2Scan(name: "KFWS20260924_122217_V06_MDM"), "metadata files are not scans")
    }

    func testListingKeysAreRead() {
        let xml = Data("""
        <ListBucketResult><Contents><Key>2026/09/24/KFWS/KFWS20260924_120816_V06</Key></Contents>\
        <Contents><Key>2026/09/24/KFWS/KFWS20260924_121513_V06</Key></Contents></ListBucketResult>
        """.utf8)
        XCTAssertEqual(Level2Client.keys(inListing: xml).count, 2)
    }

    // MARK: Geometry

    func testBeamClimbsAndSlantRangeExceedsGround() {
        // The textbook number: at 0.5° the beam centre is about 1.5 km up by
        // 100 km, and about 6 km up by 230 km, under the 4/3-Earth model.
        let r100 = RadarGeometry.slantRange(ground: 100_000, elevation: 0.5)
        XCTAssertGreaterThan(r100, 100_000)
        XCTAssertEqual(RadarGeometry.beamHeight(slantRange: r100, elevation: 0.5), 1_460, accuracy: 100)
        let r230 = RadarGeometry.slantRange(ground: 230_000, elevation: 0.5)
        XCTAssertEqual(RadarGeometry.beamHeight(slantRange: r230, elevation: 0.5), 5_120, accuracy: 300)
    }

    func testBearingIsFromNorth() {
        let east = RadarGeometry.groundPath(fromLatitude: 32, longitude: -97, toLatitude: 32, longitude: -96)
        XCTAssertEqual(east.bearing, 90, accuracy: 0.5)
        XCTAssertEqual(east.distance, 94_400, accuracy: 500)
        let south = RadarGeometry.groundPath(fromLatitude: 32, longitude: -97, toLatitude: 31, longitude: -97)
        XCTAssertEqual(south.bearing, 180, accuracy: 0.01)
    }

    func testNearestSiteToFortWorthIsKFWS() {
        XCTAssertEqual(RadarSites.nearest(latitude: 32.75, longitude: -97.33).first?.id, "KFWS")
    }

    // MARK: Drawing

    func testPaletteHidesClearAirAndShowsCores() {
        let p = ReflectivityPalette.standard
        XCTAssertEqual(p.color(at: 0).a, 0)
        XCTAssertGreaterThan(p.color(at: 55).a, 0.9)
        XCTAssertGreaterThan(p.color(at: 35).a, p.color(at: 15).a, "opacity rises with intensity")
    }

    func testClutterFilterSparesStrongLowCorrelationReturns() {
        XCTAssertTrue(Level2TileRenderer.isClutter(dBZ: 12, rho: 0.5), "birds and bugs")
        XCTAssertFalse(Level2TileRenderer.isClutter(dBZ: 12, rho: 0.98), "light rain")
        XCTAssertFalse(Level2TileRenderer.isClutter(dBZ: 55, rho: 0.6), "hail or debris — never filtered")
    }

    func testPinholeFillClosesHolesButNotEdges() {
        // 4 rows × 5 gates. A lone hole in the middle row is surrounded; the
        // empty last gate column is an echo edge.
        var v = [Float](repeating: 30, count: 20)
        for r in 0..<4 { v[r * 5 + 4] = .nan }
        v[1 * 5 + 2] = .nan
        let sweep = Level2Sweep(moment: "REF", elevationNumber: 1, elevationAngle: 0.5,
                                time: Date(), firstGate: 2125, gateSpacing: 250, gateCount: 5,
                                rowCount: 4, values: v, radialCount: 4, isComplete: true)
        let filled = sweep.pinholesFilled()
        XCTAssertEqual(filled.values[1 * 5 + 2], 30)
        XCTAssertTrue(filled.values[1 * 5 + 4].isNaN)
    }

    func testTileBeyondRangeIsClearNotNil() throws {
        let volume = try Level2.decode(fixture(), throughElevation: 1)
        let sweep = try XCTUnwrap(volume.lowest("REF"))
        // z8 tile over Denver — a thousand km from Fort Worth.
        let image = Level2TileRenderer.render(sweep: sweep, siteLatitude: volume.latitude,
                                              siteLongitude: volume.longitude,
                                              z: 8, x: 53, y: 97, size: 256)
        XCTAssertEqual(image?.width, 1)
    }

    func testTileOverTheSiteIsDrawn() throws {
        let volume = try Level2.decode(fixture(), throughElevation: 1)
        let sweep = try XCTUnwrap(volume.lowest("REF"))
        let n = pow(2.0, 8.0)
        let x = Int((volume.longitude + 180) / 360 * n)
        let y = Int((1 - log(tan(.pi / 4 + volume.latitude * .pi / 360)) / .pi) / 2 * n)
        let image = try XCTUnwrap(Level2TileRenderer.render(sweep: sweep, siteLatitude: volume.latitude,
                                                            siteLongitude: volume.longitude,
                                                            z: 8, x: x, y: y, size: 256))
        XCTAssertEqual(image.width, 256)
    }
}

final class RadarCoverageTests: XCTestCase {
    private let kfws = RadarCoverage(site: "KFWS", latitude: 32.573, longitude: -97.303,
                                     elevation: 0.5, reach: 459_000)

    func testGroundAndSlantRangeAreInverses() {
        let slant = RadarGeometry.slantRange(ground: 200_000, elevation: 0.5)
        XCTAssertEqual(RadarGeometry.groundRange(slant: slant, elevation: 0.5), 200_000, accuracy: 1)
    }

    func testHeightRingsClimbOutwardAndEndAtTheEdge() {
        let rings = kfws.rings
        XCTAssertEqual(rings.map(\.kind), [.beamHeight, .beamHeight, .beamHeight, .reach])
        XCTAssertEqual(rings.map(\.radius), rings.map(\.radius).sorted())
        XCTAssertEqual(rings.last?.radius, 459_000)
        // Checked against the small-angle form h ≈ r·sin e + r²/2kR: at 166 km
        // that is 1,449 + 1,622 = 3,071 m, just over 10,000 ft — 103 mi.
        XCTAssertEqual(Double(rings[1].miles), 103, accuracy: 2)
        XCTAssertEqual(kfws.beamFeet(atGround: rings[1].radius), 10_000, accuracy: 1)
    }

    func testAShortReachDropsTheRingsBeyondIt() {
        let short = RadarCoverage(site: "X", latitude: 0, longitude: 0, elevation: 0.5, reach: 150_000)
        XCTAssertEqual(short.rings.filter { $0.kind == .beamHeight }.count, 1)
    }

    func testLabelsSayHeightAndDistance() {
        XCTAssertTrue(kfws.rings[0].label.hasPrefix("beam 5,000 ft up"))
        XCTAssertTrue(kfws.rings.last!.label.hasPrefix("edge of coverage"))
    }
}

final class RadarPathTests: XCTestCase {
    func testAScanKeepsItsRadialPath() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/KFWS20260924_122217_V06", withExtension: "head"))
        let sweep = try XCTUnwrap(Level2.decode(Data(contentsOf: url), throughElevation: 1).lowest("REF"))
        XCTAssertEqual(sweep.path.count, 120)
        XCTAssertEqual(sweep.path.first?.seconds, 0)
        XCTAssertGreaterThan(sweep.duration, 0)
        // Clockwise, a half-degree a radial.
        let first = try XCTUnwrap(sweep.path.first), second = sweep.path[1]
        XCTAssertEqual(Double((second.azimuth - first.azimuth + 360).truncatingRemainder(dividingBy: 360)), 0.5, accuracy: 0.1)
    }

    func testDestinationRoundTripsGroundPath() {
        let p = RadarGeometry.destination(fromLatitude: 32.573, longitude: -97.303, bearing: 213, distance: 120_000)
        let back = RadarGeometry.groundPath(fromLatitude: 32.573, longitude: -97.303,
                                            toLatitude: p.latitude, longitude: p.longitude)
        XCTAssertEqual(back.distance, 120_000, accuracy: 1)
        XCTAssertEqual(back.bearing, 213, accuracy: 0.01)
    }
}
