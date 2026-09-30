import XCTest
@testable import WeatherKit

final class StormRiskTests: XCTestCase {

    private let home = GeoPoint(latitude: 30.27, longitude: -97.74)

    private func square(_ lat: Double, _ lon: Double, half: Double) -> String {
        let (a, b, c, d) = (lat - half, lat + half, lon - half, lon + half)
        return "[[[\(c),\(a)],[\(d),\(a)],[\(d),\(b)],[\(c),\(b)],[\(c),\(a)]]]"
    }

    /// The property names SPC's `day1otlk_torn.lyr.geojson` uses.
    private func feature(_ label: String, _ coordinates: String?) -> String {
        let geometry = coordinates.map { #"{"type":"Polygon","coordinates":\#($0)}"# } ?? "null"
        return #"""
        {"type":"Feature","geometry":\#(geometry),
         "properties":{"DN":2,"VALID_ISO":"2026-09-29T20:00:00+00:00",
          "EXPIRE_ISO":"2026-09-30T12:00:00+00:00","ISSUE_ISO":"2026-09-29T19:30:00+00:00",
          "LABEL":"\#(label)","LABEL2":"x","fill":"#79BA7A"}}
        """#
    }

    private func parse(_ features: [String], hazard: SevereHazard = .tornado) throws -> SevereProbability {
        let json = #"{"type":"FeatureCollection","features":[\#(features.joined(separator: ","))]}"#
        return try OutlookParser.spcProbability(Data(json.utf8), hazard: hazard, day: 1)
    }

    // MARK: Parsing

    func testHomeTakesTheHighestProbabilityItIsInside() throws {
        let p = try parse([
            feature("0.02", square(30.27, -97.74, half: 4)),
            feature("0.10", square(30.27, -97.74, half: 1)),
            feature("0.05", square(30.27, -97.74, half: 2)),
        ])
        XCTAssertEqual(p.probability(at: home), 0.10, accuracy: 1e-9)
        XCTAssertNotNil(p.validUntil)
    }

    func testOutsideEveryAreaIsZeroNotUnknown() throws {
        let p = try parse([feature("0.05", square(40, -90, half: 1))])
        XCTAssertEqual(p.probability(at: home), 0)
    }

    /// How SPC writes a quiet day.
    func testLessThanFivePercentEverywhereIsNoAreas() throws {
        let p = try parse([feature("Less Than 5% All Areas", nil)], hazard: .hail)
        XCTAssertTrue(p.areas.isEmpty)
        XCTAssertEqual(p.probability(at: home), 0)
    }

    /// What SPC actually sends on a quiet day, found against the live file:
    /// not a null geometry but an empty collection, with no `coordinates` key.
    func testAnEmptyGeometryCollectionIsNoAreasNotAFailure() throws {
        let json = #"""
        {"type":"FeatureCollection","features":[{"type":"Feature",
         "geometry":{"type":"GeometryCollection","geometries":[]},
         "properties":{"DN":0,"LABEL":"Less Than 5% All Areas","LABEL2":"",
          "VALID_ISO":"2026-09-29T20:00:00+00:00","EXPIRE_ISO":"2026-09-30T12:00:00+00:00"}}]}
        """#
        let p = try OutlookParser.spcProbability(Data(json.utf8), hazard: .hail, day: 1)
        XCTAssertTrue(p.areas.isEmpty)
        XCTAssertEqual(p.probability(at: home), 0)
    }

    // MARK: Levels

    /// The same 5% is a different day per hazard — that is the whole reason
    /// each is rated on its own scale.
    func testTheSameProbabilityIsADifferentLevelPerHazard() {
        XCTAssertEqual(SevereHazard.tornado.level(for: 0.05), 2)
        XCTAssertEqual(SevereHazard.hail.level(for: 0.05), 1)
        XCTAssertEqual(SevereHazard.wind.level(for: 0.05), 1)
    }

    func testLevelsFollowSPCsTable() {
        XCTAssertEqual(SevereHazard.tornado.level(for: 0), 0)
        XCTAssertEqual(SevereHazard.tornado.level(for: 0.02), 1)
        XCTAssertEqual(SevereHazard.tornado.level(for: 0.15), 3)
        XCTAssertEqual(SevereHazard.tornado.level(for: 0.30), 4)
        XCTAssertEqual(SevereHazard.tornado.level(for: 0.60), 5)
        XCTAssertEqual(SevereHazard.hail.level(for: 0.02), 0)
        XCTAssertEqual(SevereHazard.hail.level(for: 0.15), 2)
        XCTAssertEqual(SevereHazard.hail.level(for: 0.45), 3)
        XCTAssertEqual(SevereHazard.hail.level(for: 0.60), 4)
    }

    /// Decoded from a string, 0.15 can land a hair under 0.15.
    func testAThresholdAHairUnderStillCounts() {
        XCTAssertEqual(SevereHazard.hail.level(for: 0.1499999999), 2)
    }

    func testNoActionBelowTheLowestContour() {
        XCTAssertNil(StormRisk.Hazard(hazard: .hail, probability: 0.02).action)
        XCTAssertNotNil(StormRisk.Hazard(hazard: .hail, probability: 0.05).action)
    }

    func testHazardsStrongestFirst() {
        let risk = StormRisk(category: nil, hazards: [
            .init(hazard: .wind, probability: 0.05),
            .init(hazard: .tornado, probability: 0.05),
            .init(hazard: .hail, probability: 0.0),
        ], flood: nil)
        XCTAssertEqual(risk.hazards.map(\.hazard), [.tornado, .wind, .hail])
        XCTAssertEqual(risk.notable.map(\.hazard), [.tornado, .wind])
        XCTAssertFalse(risk.isQuiet)
    }

    func testGeneralThunderAloneIsQuiet() {
        let tstm = OutlookCategory.spc.first { $0.code == "TSTM" }
        XCTAssertTrue(StormRisk(category: tstm, hazards: [], flood: nil).isQuiet)
    }

    // MARK: Which day

    private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testAnOutlookBelongsToTheDayItsWindowCovers() {
        let central = TimeZone(identifier: "America/Chicago")!
        // Day 1 issued in the afternoon: 20Z the 29th to 12Z the 30th.
        XCTAssertEqual(OutlookDay.key(validUntil: utc("2026-09-30T12:00:00Z"), timeZone: central),
                       "2026-09-29")
        // Pacific: 12Z is 5 AM, and twelve hours before is still the 29th.
        let pacific = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(OutlookDay.key(validUntil: utc("2026-09-30T12:00:00Z"), timeZone: pacific),
                       "2026-09-29")
        // Eastern: 12Z is 8 AM.
        let eastern = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(OutlookDay.key(validUntil: utc("2026-09-30T12:00:00Z"), timeZone: eastern),
                       "2026-09-29")
        XCTAssertNil(OutlookDay.key(validUntil: nil, timeZone: central))
    }
}
