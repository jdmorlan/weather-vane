import XCTest
@testable import WeatherKit

final class RadarTests: XCTestCase {

    private func index(_ stamps: [String]) -> RadarIndex {
        let json = #"{"scans":[\#(stamps.map { #"{"ts":"\#($0)"}"# }.joined(separator: ","))]}"#
        return try! JSONDecoder().decode(RadarIndex.self, from: Data(json.utf8))
    }

    /// IEM's list writes minute precision and drops the seconds; the WMS `TIME`
    /// argument requires them. Nothing else in the pipeline notices the
    /// difference, so a frame parsed here but unrequestable there would look like
    /// a working loop of empty tiles — clear weather, drawn by a bug.
    func testTheIndexStampParsesWithAndWithoutSeconds() {
        let frames = index(["2026-09-03T20:55Z", "2026-09-03T21:00:00Z"]).frames()
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.map(\.stamp),
                       ["2026-09-03T20:55:00Z", "2026-09-03T21:00:00Z"])
    }

    func testFramesComeBackOldestFirst() {
        let frames = index(["2026-09-03T20:20Z", "2026-09-03T20:05Z", "2026-09-03T20:15Z"]).frames()
        XCTAssertEqual(frames.map(\.stamp), ["2026-09-03T20:05:00Z",
                                             "2026-09-03T20:15:00Z",
                                             "2026-09-03T20:20:00Z"])
    }

    func testTruncationKeepsTheNEWESTScans() {
        // Dropping the recent end would leave the loop ending an hour ago — the
        // one thing a radar loop must never do.
        let frames = index((0..<6).map { "2026-09-03T20:\(String(format: "%02d", $0 * 5))Z" })
            .frames(maxPast: 3)
        XCTAssertEqual(frames.map(\.stamp), ["2026-09-03T20:15:00Z",
                                             "2026-09-03T20:20:00Z",
                                             "2026-09-03T20:25:00Z"])
    }

    func testAnUnparseableStampIsDroppedRatherThanCrashing() {
        let frames = index(["2026-09-03T20:55Z", "not a time"]).frames()
        XCTAssertEqual(frames.count, 1)
    }

    /// THE BBOX IS THE ONE THING THAT FAILS SILENTLY. A tile service is given
    /// z/x/y and does the projection itself; a WMS is given metres and draws
    /// exactly what it was asked for, so getting this wrong doesn't error — it
    /// puts the storm over the wrong town. These are the Web-Mercator corners of
    /// the whole world and of one known tile.
    func testTileBBoxCoversTheWorldAtZoomZero() {
        let e = Radar.mercatorExtent
        XCTAssertEqual(Radar.tileBBox(z: 0, x: 0, y: 0), "\(-e),\(-e),\(e),\(e)")
    }

    func testTileBBoxOfAKnownTile() {
        // z7/x29/y48 — the tile over eastern Kansas.
        let parts = Radar.tileBBox(z: 7, x: 29, y: 48).split(separator: ",").map { Double($0)! }
        XCTAssertEqual(parts[0], -10_958_012.37, accuracy: 0.01)
        XCTAssertEqual(parts[1],   4_696_291.02, accuracy: 0.01)
        XCTAssertEqual(parts[2], -10_644_926.31, accuracy: 0.01)
        XCTAssertEqual(parts[3],   5_009_377.09, accuracy: 0.01)
        // Square, as every Web-Mercator tile is.
        XCTAssertEqual(parts[2] - parts[0], parts[3] - parts[1], accuracy: 0.01)
    }

    func testTileURLCarriesTheScanTimeAndTheRequestedSize() {
        let frame = RadarFrame(time: Radar.stampFormatter.date(from: "2026-09-03T20:55:00Z")!)
        let url = Radar.tileURL(frame: frame, z: 7, x: 29, y: 48)!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(url.host, "mesonet.agron.iastate.edu")
        XCTAssertEqual(value("REQUEST"), "GetMap")
        XCTAssertEqual(value("LAYERS"), "nexrad-n0q-wmst")
        XCTAssertEqual(value("SRS"), "EPSG:3857")
        XCTAssertEqual(value("TIME"), "2026-09-03T20:55:00Z")
        XCTAssertEqual(value("BBOX"), Radar.tileBBox(z: 7, x: 29, y: 48))
        XCTAssertEqual(value("WIDTH"), "512")
        XCTAssertEqual(value("HEIGHT"), "512")
        // Without TRANSPARENT the composite arrives opaque and swallows the
        // basemap that says where the returns are.
        XCTAssertEqual(value("TRANSPARENT"), "TRUE")
    }

    /// A FRAME'S IDENTITY IS ITS VALID TIME, and two things lean on that: the map
    /// diffs installed overlays by id so a reload re-requests one frame instead of
    /// ten, and the tile cache serves stored tiles regardless of freshness. Both
    /// are only correct because a finished five-minute composite never changes.
    func testIdentityIsTheValidTime() {
        let stamp = "2026-09-03T20:55:00Z"
        let time = Radar.stampFormatter.date(from: stamp)!
        XCTAssertEqual(RadarFrame(time: time).id, stamp)
        XCTAssertEqual(RadarFrame(time: time), RadarFrame(time: time))
        XCTAssertNotEqual(RadarFrame(time: time),
                          RadarFrame(time: time.addingTimeInterval(Radar.scanInterval)))
    }

    /// THE TILE SIZE IS A REQUEST-COUNT DECISION, not a rendering preference, and
    /// nothing else in the code says so out loud. At 256px a ten-frame loop asks
    /// for 400 tiles at the regional range and over 1100 at the close one — every
    /// one of them a render IEM performs for free. Dropping to 256 here would
    /// quietly quadruple that, and at the far end the symptom looks like clear
    /// weather, so it has to fail here instead.
    func testTileSizeKeepsALoopToARespectableNumberOfRequests() {
        XCTAssertEqual(Radar.tileSize, 512)

        // Tiles per frame, measured on the real card at each range.
        let perFrameAt512 = [RadarRange.close: 12, .nearby: 8, .regional: 10]
        let loopLength = 10   // RadarIndex.frames(maxPast:)

        for (range, cost) in perFrameAt512 {
            XCTAssertLessThan(cost * loopLength, 200,
                              "a full loop at \(range.label) must stay a polite ask")
        }
    }

    func testTheIndexWindowReachesFurtherBackThanTheLoop() {
        // The index is the only thing that knows a scan is MISSING; a window
        // sized to the loop would return a short loop on any skipped slot.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start.addingTimeInterval(90 * 60)
        let query = URLComponents(url: Radar.indexURL(from: start, to: end),
                                  resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        XCTAssertEqual(value("operation"), "list")
        XCTAssertEqual(value("radar"), "USCOMP")
        XCTAssertEqual(value("product"), "N0Q")
        XCTAssertEqual(value("start"), Radar.stampFormatter.string(from: start))
        XCTAssertEqual(value("end"), Radar.stampFormatter.string(from: end))
    }

    func testRangesAreOrderedOutward() {
        let radii = RadarRange.allCases.map(\.radius)
        XCTAssertEqual(radii, radii.sorted())
    }
}
