import XCTest
@testable import WeatherKit

/// Setup rests entirely on this decode: the token is the only thing the user
/// types, and everything else the app needs — the station id it fetches by, the
/// coordinate radar centres on — is read out of this payload. A field that
/// silently comes back nil here is a setup screen that looks like it worked and
/// an app that can't fetch.
final class StationDiscoveryTests: XCTestCase {

    private func directory(_ json: String) throws -> [TempestStation] {
        try JSONDecoder()
            .decode(TempestClient.StationDirectory.self, from: Data(json.utf8))
            .stations.map(\.station)
    }

    func testAStationIsReadWithItsIdNameAndLocation() throws {
        let stations = try directory(#"""
        {"stations":[{"station_id":4242,"name":"Home","public_name":"Backyard",
          "latitude":44.058,"longitude":-121.315,"timezone":"America/Los_Angeles"}]}
        """#)
        XCTAssertEqual(stations.count, 1)
        XCTAssertEqual(stations[0].id, 4242)
        XCTAssertEqual(stations[0].latitude ?? 0, 44.058, accuracy: 0.0001)
        XCTAssertEqual(stations[0].longitude ?? 0, -121.315, accuracy: 0.0001)
        XCTAssertEqual(stations[0].timeZone, "America/Los_Angeles")
        XCTAssertTrue(stations[0].hasLocation)
    }

    /// `public_name` is what the station is called in the Tempest app, which is
    /// the name the user will recognise in a picker. `name` is the account-side
    /// label and often differs.
    func testThePublicNameWinsOverTheAccountName() throws {
        let stations = try directory(#"""
        {"stations":[{"station_id":1,"name":"Home","public_name":"Backyard"}]}
        """#)
        XCTAssertEqual(stations[0].name, "Backyard")
    }

    func testAnEmptyPublicNameFallsThroughRatherThanWinning() throws {
        let stations = try directory(#"""
        {"stations":[{"station_id":1,"name":"Home","public_name":"   "}]}
        """#)
        XCTAssertEqual(stations[0].name, "Home")
    }

    /// A nameless station still has to be pickable. Naming it after its id beats
    /// an empty row, which in a list of two is an unanswerable choice.
    func testANamelessStationIsLabelledByItsId() throws {
        let stations = try directory(#"{"stations":[{"station_id":77}]}"#)
        XCTAssertEqual(stations[0].name, "Station 77")
    }

    /// Registered but never placed. The coordinate must stay nil rather than
    /// defaulting to zero — a zeroed home is the Gulf of Guinea, and setup would
    /// hand it to radar as if it were a real answer.
    func testAStationWithNoCoordinateReportsNoLocation() throws {
        let stations = try directory(#"{"stations":[{"station_id":9,"name":"Shed"}]}"#)
        XCTAssertNil(stations[0].latitude)
        XCTAssertFalse(stations[0].hasLocation)
    }

    /// A valid token on an account with no registered station. Not an error —
    /// the setup sheet says so in its own words — so the decode must not throw.
    func testATokenWithNoStationsDecodesAsEmpty() throws {
        XCTAssertTrue(try directory(#"{"status":{"status_code":0}}"#).isEmpty)
    }

    func testEveryStationOnTheTokenComesBack() throws {
        let stations = try directory(#"""
        {"stations":[{"station_id":1,"public_name":"Backyard"},
                     {"station_id":2,"public_name":"Shop roof"}]}
        """#)
        XCTAssertEqual(stations.map(\.id), [1, 2])
        XCTAssertEqual(stations.map(\.name), ["Backyard", "Shop roof"])
    }
}
