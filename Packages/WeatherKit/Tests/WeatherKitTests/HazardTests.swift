import XCTest
@testable import WeatherKit

final class HazardTests: XCTestCase {

    private let home = GeoPoint(latitude: 32.7767, longitude: -96.7970)

    /// A square around home, in GeoJSON order ([lon, lat]) so the fixtures
    /// exercise the axis swap rather than assuming it away.
    private func squareJSON(centerLat: Double, centerLon: Double, halfSide: Double) -> String {
        let (a, b) = (centerLat - halfSide, centerLat + halfSide)
        let (c, d) = (centerLon - halfSide, centerLon + halfSide)
        return "[[[\(c),\(a)],[\(d),\(a)],[\(d),\(b)],[\(c),\(b)],[\(c),\(a)]]]"
    }

    private func feed(_ features: String) -> NWSAlertFeed {
        let json = #"{"type":"FeatureCollection","features":[\#(features)]}"#
        return try! JSONDecoder().decode(NWSAlertFeed.self, from: Data(json.utf8))
    }

    private func alert(id: String = "a", event: String, severity: String = "Severe",
                       urgency: String = "Immediate", status: String = "Actual",
                       geometry: String? = nil, expires: String = "2026-08-26T22:00:00-05:00") -> String {
        let geom = geometry.map { #""geometry":{"type":"Polygon","coordinates":\#($0)},"# } ?? #""geometry":null,"#
        return """
        {"id":"\(id)",\(geom)"properties":{"id":"\(id)","event":"\(event)","severity":"\(severity)",
        "urgency":"\(urgency)","status":"\(status)","messageType":"Alert",
        "onset":"2026-08-26T15:10:00-05:00","expires":"\(expires)","ends":"\(expires)",
        "headline":"\(event) issued","instruction":"Take cover.","areaDesc":"Dallas, TX",
        "senderName":"NWS Fort Worth TX"}}
        """
    }

    // MARK: Geometry

    func testPointInsideAndOutsideAPolygon() {
        let inside = GeoShape.polygon([[
            GeoPoint(latitude: 32.0, longitude: -97.0),
            GeoPoint(latitude: 33.0, longitude: -97.0),
            GeoPoint(latitude: 33.0, longitude: -96.0),
            GeoPoint(latitude: 32.0, longitude: -96.0),
        ]])
        XCTAssertTrue(inside.contains(home))
        XCTAssertFalse(inside.contains(GeoPoint(latitude: 35.0, longitude: -96.5)))
        XCTAssertFalse(inside.contains(GeoPoint(latitude: 32.5, longitude: -90.0)))
    }

    func testHoleInAPolygonIsOutsideIt() {
        let shape = GeoShape.polygon([
            [GeoPoint(latitude: 32, longitude: -98), GeoPoint(latitude: 34, longitude: -98),
             GeoPoint(latitude: 34, longitude: -95), GeoPoint(latitude: 32, longitude: -95)],
            [GeoPoint(latitude: 32.5, longitude: -97.5), GeoPoint(latitude: 33.5, longitude: -97.5),
             GeoPoint(latitude: 33.5, longitude: -96.5), GeoPoint(latitude: 32.5, longitude: -96.5)],
        ])
        XCTAssertFalse(shape.contains(home), "home sits in the hole")
        XCTAssertTrue(shape.contains(GeoPoint(latitude: 32.2, longitude: -96.0)))
    }

    // MARK: The polygon test is the real test

    func testAPolygonWarningThatDoesNotCoverYouIsDropped() {
        // NWS returned it — the county matched — but the storm polygon is 200 miles east.
        let far = squareJSON(centerLat: 32.7, centerLon: -90.0, halfSide: 0.2)
        let hazards = HazardParser.hazards(
            from: feed(alert(event: "Tornado Warning", severity: "Extreme", geometry: far)), at: home)
        XCTAssertTrue(hazards.isEmpty)
    }

    func testAPolygonWarningCoveringYouReadsAsPolygonResolution() {
        let near = squareJSON(centerLat: home.latitude, centerLon: home.longitude, halfSide: 0.2)
        let hazards = HazardParser.hazards(
            from: feed(alert(event: "Tornado Warning", severity: "Extreme", geometry: near)), at: home)
        XCTAssertEqual(hazards.count, 1)
        XCTAssertEqual(hazards[0].resolution, .polygon)
        XCTAssertEqual(hazards[0].kind, .tornado)
        XCTAssertEqual(hazards[0].tier, .warning)
    }

    func testAZoneProductReadsAsZoneResolution() {
        let hazards = HazardParser.hazards(
            from: feed(alert(event: "Severe Thunderstorm Watch", urgency: "Future")), at: home)
        XCTAssertEqual(hazards[0].resolution, .zone)
        XCTAssertEqual(hazards[0].tier, .watch)
    }

    // MARK: Ranking

    func testTornadoWarningOutranksEverythingWithoutASpecialCase() {
        let near = squareJSON(centerLat: home.latitude, centerLon: home.longitude, halfSide: 0.5)
        let hazards = HazardParser.hazards(from: feed([
            alert(id: "heat", event: "Heat Advisory", severity: "Moderate", urgency: "Expected"),
            alert(id: "air", event: "Air Quality Alert", severity: "Unknown", urgency: "Unknown"),
            alert(id: "watch", event: "Severe Thunderstorm Watch", urgency: "Future"),
            alert(id: "torn", event: "Tornado Warning", severity: "Extreme", geometry: near),
        ].joined(separator: ",")), at: home)

        XCTAssertEqual(hazards.map(\.id), ["torn", "watch", "heat", "air"])
        XCTAssertEqual(hazards[0].level, 1.0, accuracy: 0.0001)
        XCTAssertEqual(hazards[1].level, 0.50, accuracy: 0.0001)
        XCTAssertEqual(hazards[3].level, 0.15, accuracy: 0.0001)
    }

    func testTestAndCancelMessagesAreNotConditions() {
        XCTAssertTrue(HazardParser.hazards(
            from: feed(alert(event: "Tornado Warning", status: "Test")), at: home).isEmpty)
    }

    // MARK: Absence needs coverage

    func testNothingActiveWithNoSuccessfulFetchIsUnknownNotClear() {
        let watch = HazardWatch(hazards: [], lastReached: nil,
                                lastAttempt: Date(), failure: "offline")
        guard case .unknown(let since, let reason) = watch.state() else {
            return XCTFail("silence must never read as clear")
        }
        XCTAssertNil(since)
        XCTAssertEqual(reason, "offline")
    }

    func testAStaleSuccessGoesUnknownAndRemembersWhenItLastKnew() {
        let heardAt = Date().addingTimeInterval(-3600)
        let watch = HazardWatch(hazards: [], lastReached: heardAt)
        guard case .unknown(let since, _) = watch.state() else {
            return XCTFail("an hour-old answer cannot claim the sky is quiet")
        }
        XCTAssertEqual(since, heardAt)
    }

    func testAFreshEmptyAnswerIsClear() {
        let now = Date()
        let watch = HazardWatch(hazards: [], lastReached: now.addingTimeInterval(-60))
        guard case .clear = watch.state(now: now) else { return XCTFail("expected clear") }
    }

    func testAnExpiredHazardStopsBeingActive() {
        let now = Date()
        let expired = Hazard(id: "x", event: "Severe Thunderstorm Warning", kind: .thunderstorm,
                             tier: .warning, resolution: .polygon, level: 0.85,
                             expires: now.addingTimeInterval(-60))
        let watch = HazardWatch(hazards: [expired], lastReached: now)
        guard case .clear = watch.state(now: now) else { return XCTFail("expected clear") }
        XCTAssertNil(watch.top(now: now))
    }

    func testDuplicateProductsAcrossZonesCollapseByID() {
        let hazards = HazardParser.hazards(from: feed([
            alert(id: "same", event: "Flood Watch", urgency: "Future"),
            alert(id: "same", event: "Flood Watch", urgency: "Future"),
        ].joined(separator: ",")), at: home)
        XCTAssertEqual(hazards.count, 1)
        XCTAssertEqual(hazards[0].kind, .flood)
    }

    // MARK: Decoding

    func testGeoJSONPositionsAreLongitudeFirst() {
        let json = #"{"type":"Polygon","coordinates":[[[-96.9,32.7],[-96.6,32.7],[-96.6,32.9],[-96.9,32.9]]]}"#
        let geometry = try! JSONDecoder().decode(NWSAlertFeed.Geometry.self, from: Data(json.utf8))
        guard case .polygon(let rings)? = geometry.shape() else { return XCTFail("no polygon") }
        XCTAssertEqual(rings[0][0].latitude, 32.7, accuracy: 0.0001)
        XCTAssertEqual(rings[0][0].longitude, -96.9, accuracy: 0.0001)
        XCTAssertTrue(geometry.shape()!.contains(home))
    }

    func testMultiPolygonDecodes() {
        let json = """
        {"type":"MultiPolygon","coordinates":[[[[-96.9,32.7],[-96.6,32.7],[-96.6,32.9],[-96.9,32.9]]],
        [[[-90.0,30.0],[-89.0,30.0],[-89.0,31.0],[-90.0,31.0]]]]}
        """
        let geometry = try! JSONDecoder().decode(NWSAlertFeed.Geometry.self, from: Data(json.utf8))
        guard case .multiPolygon(let polys)? = geometry.shape() else { return XCTFail("no multipolygon") }
        XCTAssertEqual(polys.count, 2)
        XCTAssertTrue(geometry.shape()!.contains(home))
    }

    func testKindClassificationDoesNotFallThroughOnCompoundNames() {
        XCTAssertEqual(HazardKind.classify(event: "Tornado Warning"), .tornado)
        XCTAssertEqual(HazardKind.classify(event: "Flash Flood Warning"), .flood)
        XCTAssertEqual(HazardKind.classify(event: "Red Flag Warning"), .fire)
        XCTAssertEqual(HazardKind.classify(event: "High Wind Warning"), .wind)
        XCTAssertEqual(HazardKind.classify(event: "Winter Storm Warning"), .winter)
        XCTAssertEqual(HazardKind.classify(event: "Excessive Heat Warning"), .heat)
    }
}
