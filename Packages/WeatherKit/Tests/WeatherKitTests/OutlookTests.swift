import XCTest
@testable import WeatherKit

final class OutlookTests: XCTestCase {

    private let home = GeoPoint(latitude: 30.27, longitude: -97.74)

    /// A square in GeoJSON order ([lon, lat]).
    private func square(_ lat: Double, _ lon: Double, half: Double) -> String {
        let (a, b, c, d) = (lat - half, lat + half, lon - half, lon + half)
        return "[[[\(c),\(a)],[\(d),\(a)],[\(d),\(b)],[\(c),\(b)],[\(c),\(a)]]]"
    }

    // MARK: SPC

    /// The property names and formats of SPC's `day1otlk_cat.lyr.geojson`.
    private func spcFeature(_ label: String, _ coordinates: String, fill: String = "#FFE066") -> String {
        #"""
        {"type":"Feature","geometry":{"type":"Polygon","coordinates":\#(coordinates)},
         "properties":{"DN":4,"VALID":"202609291200","EXPIRE":"202609301200","ISSUE":"202609291300",
          "VALID_ISO":"2026-09-29T12:00:00+00:00","EXPIRE_ISO":"2026-09-30T12:00:00+00:00",
          "ISSUE_ISO":"2026-09-29T13:00:00+00:00","FORECASTER":"Test","LABEL":"\#(label)",
          "LABEL2":"x","stroke":"#DDAA00","fill":"\#(fill)"}}
        """#
    }

    private func spc(_ features: [String]) throws -> Outlook {
        let json = #"{"type":"FeatureCollection","features":[\#(features.joined(separator: ","))]}"#
        return try OutlookParser.spc(Data(json.utf8), period: 1)
    }

    func testSPCHomeTakesTheHighestCategoryItIsInside() throws {
        let outlook = try spc([
            spcFeature("SLGT", square(30.27, -97.74, half: 1)),
            spcFeature("TSTM", square(30.27, -97.74, half: 5)),
            spcFeature("MRGL", square(30.27, -97.74, half: 3)),
        ])
        XCTAssertEqual(outlook.category(at: home)?.code, "SLGT")
        // Painted lowest first, whatever order the file lists them in.
        XCTAssertEqual(outlook.areas.map(\.category.code), ["TSTM", "MRGL", "SLGT"])
        XCTAssertEqual(outlook.present.map(\.code), ["TSTM", "MRGL", "SLGT"])
    }

    func testSPCOutsideEveryAreaIsNoCategory() throws {
        let outlook = try spc([spcFeature("MRGL", square(40, -90, half: 1))])
        XCTAssertNil(outlook.category(at: home))
    }

    func testSPCReadsItsWindowAndColoursFromTheFile() throws {
        let outlook = try spc([spcFeature("SLGT", square(30, -97, half: 1), fill: "#123456")])
        XCTAssertEqual(outlook.validFrom, HazardParser.iso.date(from: "2026-09-29T12:00:00Z"))
        XCTAssertEqual(outlook.validUntil, HazardParser.iso.date(from: "2026-09-30T12:00:00Z"))
        XCTAssertEqual(outlook.areas.first?.fill, OutlookColor(0x123456))
        XCTAssertEqual(outlook.areas.first?.stroke, OutlookColor(0xDDAA00))
    }

    func testSPCUnknownLabelIsNotDrawn() throws {
        let outlook = try spc([spcFeature("SIGN", square(30.27, -97.74, half: 1))])
        XCTAssertTrue(outlook.areas.isEmpty)
    }

    /// No thunder anywhere is a real, decodable answer — an empty outlook, not
    /// a failure. See the file header on absence.
    func testSPCWithNoAreasDecodesAsEmpty() throws {
        let outlook = try spc([])
        XCTAssertTrue(outlook.areas.isEmpty)
        XCTAssertNil(outlook.category(at: home))
    }

    // MARK: WPC

    /// The shape NOAA's ArcGIS service returns for `query?f=geojson`.
    private func wpcFeature(dn: Int, _ coordinates: String) -> String {
        #"""
        {"type":"Feature","id":\#(dn),"geometry":{"type":"Polygon","coordinates":\#(coordinates)},
         "properties":{"dn":\#(dn),"issue_time":"2026-09-29 15:30:00",
          "start_time":"2026-09-29 16:00:00","end_time":"2026-09-30 12:00:00"}}
        """#
    }

    private func wpc(_ features: [String]) throws -> Outlook {
        let json = #"{"type":"FeatureCollection","features":[\#(features.joined(separator: ","))]}"#
        return try OutlookParser.wpc(Data(json.utf8), period: 1)
    }

    func testWPCCategoriesComeFromTheLevelField() throws {
        let outlook = try wpc([
            wpcFeature(dn: 3, square(30.27, -97.74, half: 0.5)),
            wpcFeature(dn: 1, square(30.27, -97.74, half: 4)),
        ])
        XCTAssertEqual(outlook.category(at: home)?.name, "Moderate")
        XCTAssertEqual(outlook.category(at: home)?.threshold, "40%")
        XCTAssertEqual(outlook.areas.map(\.category.level), [1, 3])
    }

    /// WPC's Slight can carry a hole where the Moderate inside it is drawn. A
    /// point in the hole but outside the Moderate is in neither — it falls to
    /// whatever lies beneath.
    func testWPCHoleIsOutsideThatCategory() throws {
        let withHole = "[[[-99,29],[-96,29],[-96,32],[-99,32],[-99,29]],[[-98,30],[-97,30],[-97,31],[-98,31],[-98,30]]]"
        let outlook = try wpc([
            wpcFeature(dn: 2, withHole),
            wpcFeature(dn: 1, square(30.5, -97.5, half: 5)),
        ])
        XCTAssertEqual(outlook.category(at: GeoPoint(latitude: 30.5, longitude: -97.5))?.name, "Marginal")
        XCTAssertEqual(outlook.category(at: GeoPoint(latitude: 29.5, longitude: -98.5))?.name, "Slight")
    }

    func testWPCTimesAreUTC() throws {
        let outlook = try wpc([wpcFeature(dn: 1, square(30, -97, half: 1))])
        XCTAssertEqual(outlook.issued, HazardParser.iso.date(from: "2026-09-29T15:30:00Z"))
        XCTAssertEqual(outlook.validUntil, HazardParser.iso.date(from: "2026-09-30T12:00:00Z"))
    }

    /// An ArcGIS error comes back as HTTP 200. It must fail, not read as a
    /// quiet map with nothing drawn.
    func testWPCServiceErrorIsAFailureNotAnEmptyMap() {
        let json = #"{"error":{"code":400,"message":"Invalid query parameters.","details":[]}}"#
        XCTAssertThrowsError(try OutlookParser.wpc(Data(json.utf8), period: 1))
    }

    // MARK: Around the edges

    func testExpiryIsTheEndOfTheWindow() throws {
        let outlook = try wpc([wpcFeature(dn: 1, square(30, -97, half: 1))])
        let end = HazardParser.iso.date(from: "2026-09-30T12:00:00Z")!
        XCTAssertFalse(outlook.isExpired(at: end.addingTimeInterval(-1)))
        XCTAssertTrue(outlook.isExpired(at: end))
    }

    func testScaleNamesTheLevelOutOfTheProductsOwnTop() {
        XCTAssertEqual(OutlookCategory.spc[2].scale(of: .severeStorms), "Slight · level 2 of 5")
        XCTAssertEqual(OutlookCategory.wpc[1].scale(of: .excessiveRain), "Slight · level 2 of 4")
        XCTAssertEqual(OutlookCategory.spc[0].scale(of: .severeStorms), "Thunderstorms")
    }

    // MARK: Rain totals

    /// The shape of the `wpc_qpf` layers: one feature per band, `qpf` its floor.
    private func rainBand(_ inches: Double, _ coordinates: String) -> String {
        #"""
        {"type":"Feature","geometry":{"type":"Polygon","coordinates":\#(coordinates)},
         "properties":{"qpf":\#(inches),"issue_time":"2026-09-29 10:30:12",
          "start_time":"2026-09-29 12:00:00","end_time":"2026-10-06 12:00:00"}}
        """#
    }

    private func rainTotals(_ features: [String]) throws -> Outlook {
        let json = #"{"type":"FeatureCollection","features":[\#(features.joined(separator: ","))]}"#
        return try OutlookParser.wpcRainTotals(Data(json.utf8), period: 7)
    }

    /// The bands do not nest: the inch band has a hole where the two-inch band
    /// sits. Home in the hole is in the two-inch band and nothing else.
    func testRainTotalsReadTheBandYouAreIn() throws {
        let inchWithHole = "[[[-100,28],[-95,28],[-95,33],[-100,33],[-100,28]],[[-98,30],[-97,30],[-97,31],[-98,31],[-98,30]]]"
        let outlook = try rainTotals([
            rainBand(2, square(30.5, -97.5, half: 0.5)),
            rainBand(1, inchWithHole),
        ])
        XCTAssertEqual(outlook.category(at: GeoPoint(latitude: 30.5, longitude: -97.5))?.name, "2–2.5 in")
        XCTAssertEqual(outlook.category(at: GeoPoint(latitude: 29, longitude: -99))?.name, "1–1.25 in")
        XCTAssertNil(outlook.category(at: GeoPoint(latitude: 40, longitude: -90)))
        XCTAssertEqual(outlook.validUntil, HazardParser.iso.date(from: "2026-10-06T12:00:00Z"))
    }

    /// A band value we have no colour for is left off rather than painted as
    /// its neighbour — a wrong colour on a rain map is a wrong amount.
    func testRainTotalsUnknownBandIsNotDrawn() throws {
        let outlook = try rainTotals([rainBand(0.3, square(30, -97, half: 1))])
        XCTAssertTrue(outlook.areas.isEmpty)
    }

    func testRainTotalBandsAreNamedByTheirRange() {
        let names = OutlookCategory.rainTotals.map(\.name)
        XCTAssertEqual(names.first, "0.01–0.1 in")
        XCTAssertEqual(names.last, "20+ in")
        XCTAssertTrue(names.contains("0.25–0.5 in"))
        XCTAssertEqual(OutlookCategory.rainTotals[5].scale(of: .rainTotals), "1–1.25 in")
    }

    func testPeriodsAndTheirNames() {
        XCTAssertEqual(OutlookProduct.severeStorms.periods, [1, 2, 3])
        XCTAssertEqual(OutlookProduct.rainTotals.periods, [1, 2, 3, 5, 7])
        XCTAssertEqual(OutlookProduct.rainTotals.periodName(5), "Days 1–5")
        XCTAssertEqual(OutlookProduct.rainTotals.periodName(1), "Day 1")
        XCTAssertEqual(OutlookProduct.excessiveRain.periodName(2), "Day 2")
    }

    /// Each running total is its own layer, and they are not in order.
    func testRainTotalURLsPickTheCumulativeLayer() {
        XCTAssertTrue(OutlookClient.url(.rainTotals, period: 1).path.hasSuffix("/wpc_qpf/MapServer/1/query"))
        XCTAssertTrue(OutlookClient.url(.rainTotals, period: 3).path.hasSuffix("/wpc_qpf/MapServer/9/query"))
        XCTAssertTrue(OutlookClient.url(.rainTotals, period: 7).path.hasSuffix("/wpc_qpf/MapServer/11/query"))
        XCTAssertTrue(OutlookClient.url(.rainTotals, period: 7).query?.contains("maxAllowableOffset=0.02") ?? false)
    }

    func testURLsNameTheDay() {
        XCTAssertEqual(OutlookClient.url(.severeStorms, period: 2).absoluteString,
                       "https://www.spc.noaa.gov/products/outlook/day2otlk_cat.lyr.geojson")
        XCTAssertTrue(OutlookClient.url(.excessiveRain, period: 3).path.hasSuffix("/MapServer/2/query"))
    }
}

final class CountyBoundaryTests: XCTestCase {

    /// The bundled file itself: every county present, and the point test lands
    /// on the right one. Travis County holds Austin; Williamson is directly
    /// north of it, which makes a wrong axis swap or ring order show up here.
    func testBundledCountiesLoadAndLocateAustin() throws {
        let counties = try CountyBoundaries.load()
        XCTAssertGreaterThan(counties.count, 3100)
        let austin = CountyBoundaries.county(containing: GeoPoint(latitude: 30.2672, longitude: -97.7431),
                                             in: counties)
        XCTAssertEqual(austin?.name, "Travis")
        XCTAssertEqual(austin?.state, "TX")
        let georgetown = CountyBoundaries.county(containing: GeoPoint(latitude: 30.6333, longitude: -97.6770),
                                                 in: counties)
        XCTAssertEqual(georgetown?.name, "Williamson")
        XCTAssertNil(CountyBoundaries.county(containing: GeoPoint(latitude: 25, longitude: -90),
                                             in: counties))
    }
}
