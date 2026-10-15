import XCTest
@testable import WeatherKit

final class FrontCluesTests: XCTestCase {
    /// A 5×5 grid, 1° apart, south row first.
    let grid = SurfaceGrid(latitudes: [28, 29, 30, 31, 32], longitudes: [-98, -97, -96, -95, -94])
    let t0 = Date(timeIntervalSince1970: 1_792_000_800)

    let gulf = SurfaceReading(temperature: 80, dewPoint: 72, windFrom: 150, windSpeed: 12,
                              gust: 18, pressure: 1012)
    let dry = SurfaceReading(temperature: 70, dewPoint: 55, windFrom: 0, windSpeed: 20,
                             gust: 32, pressure: 1016)

    /// Gulf air everywhere at the start; three hours later the top `rows` rows
    /// have dry air on a north wind.
    func run(frontRows: Int) -> SurfaceRun {
        let before = SurfaceHour(valid: t0, readings: Array(repeating: gulf, count: grid.count))
        let after = SurfaceHour(valid: t0.addingTimeInterval(3 * 3600), readings: (0..<grid.count).map { i in
            i / grid.cols >= grid.rows - frontRows ? dry : gulf
        })
        return SurfaceRun(grid: grid, hours: [before, after], run: nil)
    }

    func testFindsTheBandAndReadsEveryClue() throws {
        let home = GeoPoint(latitude: 28, longitude: -96)
        let reading = try XCTUnwrap(FrontReader.read(run(frontRows: 2), at: 1, home: home))
        XCTAssertEqual(reading.justPassed.filter { $0 }.count, 10)
        XCTAssertFalse(reading.passingHome)
        XCTAssertEqual(reading.lines.map(\.clue), FrontClue.allCases)
        XCTAssertEqual(reading.lines[0].statement, "From the north where it just passed, from the southeast ahead of it")
        XCTAssertEqual(reading.lines[1].statement, "Up 4 mb in 3 hours")
        XCTAssertEqual(reading.lines[2].statement, "32 mph behind it, 18 mph ahead")
        XCTAssertEqual(reading.lines[3].statement, "Down 10°F in 3 hours")
        XCTAssertEqual(reading.lines[4].statement, "Down 17°F in 3 hours · 55°F behind it, 72°F ahead")
        XCTAssertTrue(reading.lines.allSatisfy(\.agrees))
        // The band's nearest row is 31°N, three degrees north of home: ~207 miles.
        XCTAssertEqual(try XCTUnwrap(reading.milesFromHome), 207, accuracy: 2)
        XCTAssertEqual(reading.directionFromHome, "north")
    }

    func testAWindThatWasAlreadyNorthIsNotTheFront() throws {
        var r = run(frontRows: 2)
        // North wind three hours ago too: the front came through earlier.
        r.hours[0].readings = r.hours[1].readings
        let reading = try XCTUnwrap(FrontReader.read(r, at: 1, home: nil))
        XCTAssertFalse(reading.found)
    }

    /// Pottsville, 2026-10-15: the wind turned at 8 PM, the dewpoint held for
    /// five hours. The front is where the wind turned; the dewpoint disagrees.
    func testTheDewpointCanLag() throws {
        var r = run(frontRows: 2)
        r.hours[1].readings = r.hours[1].readings.map { reading in
            reading.map { var x = $0; x.dewPoint = 72; return x }
        }
        let reading = try XCTUnwrap(FrontReader.read(r, at: 1, home: nil))
        XCTAssertTrue(reading.found)
        let dew = try XCTUnwrap(reading.lines.first { $0.clue == .dewPoint })
        XCTAssertFalse(dew.agrees)
        XCTAssertEqual(dew.statement, "About the same, within 3°F in 3 hours · 72°F behind it, 72°F ahead")
    }

    func testTemperatureCanDisagree() throws {
        var r = run(frontRows: 2)
        r.hours[1].readings = r.hours[1].readings.map { reading in
            reading.map { var x = $0; x.temperature = 81; return x }
        }
        let reading = try XCTUnwrap(FrontReader.read(r, at: 1, home: nil))
        let temp = try XCTUnwrap(reading.lines.first { $0.clue == .temperature })
        XCTAssertFalse(temp.agrees)
        XCTAssertEqual(temp.statement, "About the same, within 3°F in 3 hours")
    }

    func testPassageWalksBackToTheWindShift() {
        // North wind at home an hour before the dewpoint drop shows.
        let home = GeoPoint(latitude: 32, longitude: -96)
        var r = run(frontRows: 1)
        let h = FrontReader.nearest(grid, to: home)!
        var early = r.hours[0]
        early.valid = t0.addingTimeInterval(2 * 3600)
        early.readings[h] = SurfaceReading(temperature: 80, dewPoint: 72, windFrom: 350, windSpeed: 10,
                                           gust: nil, pressure: 1012)
        r.hours.insert(early, at: 1)
        XCTAssertEqual(FrontReader.passage(r, home: home), t0.addingTimeInterval(2 * 3600))
    }

    func testThroughHomeOnceTheBandHasMovedOn() throws {
        // The front crossed the top row in the first three hours and the next
        // two in the three after; home, on the top row, is behind it.
        var r = run(frontRows: 1)
        r.hours.append(SurfaceHour(valid: t0.addingTimeInterval(6 * 3600), readings: (0..<grid.count).map { i in
            i / grid.cols >= grid.rows - 3 ? dry : gulf
        }))
        let reading = try XCTUnwrap(FrontReader.read(r, at: 2, home: GeoPoint(latitude: 32, longitude: -96)))
        XCTAssertFalse(reading.passingHome)
        XCTAssertTrue(reading.throughHome)
        XCTAssertEqual(reading.directionFromHome, "south")
    }

    func testALonePointIsNotAFront() throws {
        var r = run(frontRows: 0)
        r.hours[1].readings[12] = dry
        XCTAssertEqual(FrontReader.justPassed(r, at: 1)?.filter { $0 }.count, 0)
    }

    func testPassageAtHome() {
        let home = GeoPoint(latitude: 31.9, longitude: -96)
        XCTAssertEqual(FrontReader.passage(run(frontRows: 2), home: home), t0.addingTimeInterval(3 * 3600))
        XCTAssertNil(FrontReader.passage(run(frontRows: 2), home: GeoPoint(latitude: 28, longitude: -96)))
    }

    func testNoReadingWithoutThreeHoursBehind() {
        XCTAssertNil(FrontReader.read(run(frontRows: 2), at: 0, home: nil))
    }

    func testCircularMeanAcrossNorth() throws {
        XCTAssertEqual(try XCTUnwrap(FrontReader.circularMean([350, 10])), 0, accuracy: 0.001)
    }

    func testGridSamplesBilinear() throws {
        let values: [Double?] = (0..<grid.count).map { Double($0 / grid.cols) }   // = row
        XCTAssertEqual(try XCTUnwrap(grid.sample(values, at: GeoPoint(latitude: 29.5, longitude: -96.3))),
                       1.5, accuracy: 1e-9)
        XCTAssertNil(grid.sample(values, at: GeoPoint(latitude: 40, longitude: -96)))
    }

    func testGridAroundIsCentred() {
        let g = SurfaceGrid.around(GeoPoint(latitude: 32.8, longitude: -95.4))
        XCTAssertEqual(g.rows, 17)
        XCTAssertEqual(g.cols, 19)
        XCTAssertEqual(g.latitudes[8], 32.8, accuracy: 1e-9)
        // From Houston the rows over the Gulf, past Open-Meteo's HRRR, are trimmed.
        let houston = SurfaceGrid.around(GeoPoint(latitude: 29.8, longitude: -95.4))
        XCTAssertEqual(houston.latitudes.first ?? 0, 24.55, accuracy: 1e-9)
        XCTAssertEqual(g.longitudes[9], -95.4, accuracy: 1e-9)
    }

    // MARK: Decoding

    func testAirportReportDecodes() throws {
        let json = """
        [{"icaoId":"KIAH","name":"Houston/Intl, TX, US","obsTime":1792076460,"lat":29.98,"lon":-95.36,
          "temp":24.4,"dewp":21.7,"wdir":150,"wspd":10,"wgst":20,"slp":1012.3,"altim":1012.9},
         {"icaoId":"KMRF","obsTime":1792076460,"lat":30.37,"lon":-104.01,
          "temp":18.3,"dewp":15.6,"wdir":"VRB","wspd":3,"altim":1022.1},
         {"icaoId":"KXXX","obsTime":1792076460,"lat":30,"lon":-100,"wdir":0,"wspd":0}]
        """
        let reports = try AirportReportClient.decode(Data(json.utf8))
        XCTAssertEqual(reports.count, 2)
        let iah = reports[0].reading
        XCTAssertEqual(iah.temperature, 75.92, accuracy: 0.01)
        XCTAssertEqual(iah.windFrom, 150)
        XCTAssertEqual(try XCTUnwrap(iah.gust), 23.0, accuracy: 0.1)
        XCTAssertEqual(iah.pressure, 1012.3)
        XCTAssertNil(reports[1].reading.windFrom)
        XCTAssertEqual(reports[1].reading.pressure, 1022.1)
    }

    func testLatestReportPerStation() {
        let r = SurfaceReading(temperature: 70, dewPoint: 60, windFrom: nil, windSpeed: 0, gust: nil, pressure: nil)
        let p = GeoPoint(latitude: 30, longitude: -95)
        let reports = [
            AirportReport(station: "A", name: "A", point: p, time: t0, reading: r),
            AirportReport(station: "A", name: "A", point: p, time: t0.addingTimeInterval(1200), reading: r),
            AirportReport(station: "B", name: "B", point: p, time: t0.addingTimeInterval(-3 * 3600), reading: r),
        ]
        let latest = AirportReportClient.latest(reports, at: t0.addingTimeInterval(1800))
        XCTAssertEqual(latest.map(\.station), ["A"])
        XCTAssertEqual(latest.first?.time, t0.addingTimeInterval(1200))
    }

    func testHRRRAssembleDropsHoursPastTheRun() throws {
        let tiny = SurfaceGrid(latitudes: [30, 31], longitudes: [-96, -95])
        let json = """
        {"hourly":{"time":[1792000800,1792004400],
          "temperature_2m":[80,null],"dew_point_2m":[70,null],"wind_speed_10m":[10,null],
          "wind_direction_10m":[180,null],"wind_gusts_10m":[15,null],"pressure_msl":[1012,null]}}
        """
        let one = try SurfaceForecastClient.decode(Data(json.utf8))
        let run = try SurfaceForecastClient.assemble(grid: tiny, locations: Array(repeating: one[0], count: 4), run: nil)
        XCTAssertEqual(run.hours.count, 1)
        XCTAssertEqual(run.hours[0].readings[0]?.windFrom, 180)
    }

    func testRunCacheRoundTripsAndChecksTheGrid() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SurfaceRunCache(url: dir.appendingPathComponent("front.plist"))
        let r = run(frontRows: 2)
        try cache.save(r)
        XCTAssertEqual(cache.load(grid: grid), r)
        XCTAssertNil(cache.load(grid: SurfaceGrid(latitudes: [1, 2], longitudes: [3, 4])))
    }
}
