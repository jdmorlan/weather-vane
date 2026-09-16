import XCTest
@testable import WeatherKit

final class UpperAirTests: XCTestCase {

    private let grid = UpperAirGrid.conus
    /// Hamilton County, Texas.
    private let home = GeoPoint(latitude: 31.7, longitude: -98.1)

    /// A synthetic field with a KNOWN answer: a mean height that falls toward the
    /// pole, plus a cosine wave in longitude whose ridge axis is at `ridgeAt`.
    ///
    /// Wavelength 40° divides 360, so around the whole latitude circle the wave
    /// averages to exactly zero and the zonal mean is the base height — the ring
    /// is sampled from the same function rather than handed the answer.
    /// `usOffset` lifts only the display grid (not the ring), the way a hot
    /// summer lifts the whole country above the hemisphere.
    private func field(ridgeAt: Double, amplitude: Double = 10, wavelength: Double = 40,
                       usOffset: Double = 0) -> HeightField {
        func base(_ lat: Double) -> Double { 590 - 0.6 * (lat - 25) }
        func wave(_ lon: Double) -> Double { amplitude * cos(2 * .pi * (lon - ridgeAt) / wavelength) }
        let heights = grid.latitudes.map { lat in grid.longitudes.map { base(lat) + wave($0) + usOffset } }
        let means = grid.latitudes.map { lat in
            WavePattern.average(grid.ringLongitudes.map { base(lat) + wave($0) })
        }
        return HeightField(heights: heights, zonalMeans: means,
                           home: base(home.latitude) + wave(home.longitude) + usOffset)
    }

    private func kinds(_ features: [WaveFeature]) -> [WaveFeature.Kind] { features.map(\.kind) }

    // MARK: Detrending

    func testZonalDetrendingLeavesExactlyTheWave() {
        let f = field(ridgeAt: -110)
        let dev = WavePattern.deviations(f, reference: .zonal)
        for (r, _) in grid.latitudes.enumerated() {
            for (c, lon) in grid.longitudes.enumerated() {
                XCTAssertEqual(dev[r][c], 10 * cos(2 * .pi * (lon + 110) / 40), accuracy: 1e-9)
            }
        }
    }

    func testRegionalDetrendingZeroesEachRow() {
        let dev = WavePattern.deviations(field(ridgeAt: -110, usOffset: 8), reference: .regional)
        for row in dev { XCTAssertEqual(row.reduce(0, +), 0, accuracy: 1e-9) }
    }

    func testProfileAveragesOnlyTheMidLatitudeRows() {
        XCTAssertEqual(grid.midRows.map { grid.latitudes[$0] }, [45, 40, 35])
        var dev = Array(repeating: Array(repeating: 0.0, count: 12), count: 6)
        dev[0] = Array(repeating: 100, count: 12)      // 50°N — must be ignored
        dev[5] = Array(repeating: -100, count: 12)     // 25°N — must be ignored
        dev[1][3] = 3; dev[2][3] = 6; dev[3][3] = 9
        let p = WavePattern.profile(dev, rows: grid.midRows)
        XCTAssertEqual(p[3], 6, accuracy: 1e-9)
        XCTAssertEqual(p[0], 0, accuracy: 1e-9)
    }

    // MARK: Detection

    /// The headline test: ridge at 110°W, trough at 90°W. The ridge at 70°W sits on
    /// the window's edge and must NOT be named — the wave beyond it is unseen.
    func testSineWaveRidgeAndTroughLandWhereTheyShould() {
        let a = WavePattern.analyze(field(ridgeAt: -110), grid: grid, home: home)
        XCTAssertEqual(kinds(a.features), [.ridge, .trough])
        XCTAssertEqual(a.features[0].longitude, -110, accuracy: 1e-9)
        XCTAssertEqual(a.features[1].longitude, -90, accuracy: 1e-9)
        XCTAssertEqual(a.features[0].value, 10, accuracy: 1e-9)
        XCTAssertEqual(a.features[1].value, -10, accuracy: 1e-9)
        // Relief is measured to the SHALLOWER flank. East of the ridge the wave
        // falls to the trough (−10); west of it the window ends at 125°W, where the
        // wave has only fallen to 10·cos(−135°) = −7.07. The edge limits it.
        XCTAssertEqual(a.features[0].relief, 10 - 10 * cos(.pi * 3 / 4), accuracy: 1e-9)
    }

    /// An axis between grid columns is estimated between them, not snapped.
    func testAxisBetweenColumnsIsInterpolated() {
        let a = WavePattern.analyze(field(ridgeAt: -107.5, wavelength: 50), grid: grid, home: home)
        let ridge = try! XCTUnwrap(a.features.first { $0.kind == .ridge })
        XCTAssertEqual(ridge.longitude, -107.5, accuracy: 0.5)
        let trough = try! XCTUnwrap(a.features.first { $0.kind == .trough })
        XCTAssertEqual(trough.longitude, -82.5, accuracy: 0.5)
    }

    /// Why detection uses relief and not sign: the whole US sits 12 dam above the
    /// hemisphere, so the trough never goes negative — and is still a trough.
    func testTroughAboveZeroIsStillFoundByRelief() {
        let a = WavePattern.analyze(field(ridgeAt: -110, amplitude: 5, usOffset: 12),
                                    grid: grid, home: home)
        XCTAssertTrue(a.profile.allSatisfy { $0 > 0 })
        let trough = try! XCTUnwrap(a.features.first { $0.kind == .trough })
        XCTAssertEqual(trough.longitude, -90, accuracy: 1e-9)
        XCTAssertEqual(trough.value, 7, accuracy: 1e-9)
    }

    func testWavesBelowTheThresholdAreNotNamed() {
        let a = WavePattern.analyze(field(ridgeAt: -110, amplitude: 1), grid: grid, home: home)
        XCTAssertTrue(a.features.isEmpty)
        XCTAssertEqual(a.position?.side, .flat)
    }

    func testThresholdIsTunable() {
        let f = field(ridgeAt: -110, amplitude: 1)
        let a = WavePattern.analyze(f, grid: grid, home: home, threshold: 1)
        XCTAssertEqual(kinds(a.features), [.ridge, .trough])
    }

    /// A small wiggle on the flank of a big trough gets its own local relief, not
    /// the big trough's depth.
    func testShoulderBumpIsMeasuredByItsOwnRelief() {
        let p: [Double] = [0, -10, -20, -19, -21, -30, -20, -10, 0, 5, 0, -5]
        let found = WavePattern.features(profile: p, longitudes: grid.longitudes, threshold: 0.5)
        let bump = try! XCTUnwrap(found.first { $0.column == 3 })
        XCTAssertEqual(bump.kind, .ridge)
        XCTAssertEqual(bump.relief, 1, accuracy: 1e-9)
        XCTAssertNil(WavePattern.features(profile: p, longitudes: grid.longitudes)
            .first { $0.column == 3 })
    }

    // MARK: Position

    /// Ridge 110°W, trough 90°W, you at 98.1°W: the trough downstream is nearer —
    /// behind the trough, northwest flow.
    func testWestOfTrough() {
        let a = WavePattern.analyze(field(ridgeAt: -110), grid: grid, home: home)
        XCTAssertEqual(a.position?.side, .westOfTrough)
        XCTAssertEqual(a.position?.trough?.longitude ?? 0, -90, accuracy: 1e-9)
        XCTAssertEqual(a.position?.ridge?.longitude ?? 0, -110, accuracy: 1e-9)
    }

    /// Trough 105°W, ridge 85°W: you're downstream of the trough — southwest flow.
    func testEastOfTrough() {
        let a = WavePattern.analyze(field(ridgeAt: -85), grid: grid, home: home)
        XCTAssertEqual(a.position?.side, .eastOfTrough)
        XCTAssertEqual(a.position?.trough?.longitude ?? 0, -105, accuracy: 1e-9)
    }

    func testOnTheTroughAxis() {
        let a = WavePattern.analyze(field(ridgeAt: -80), grid: grid, home: home)
        XCTAssertEqual(a.position?.side, .troughAxis)
        XCTAssertEqual(a.position?.trough?.longitude ?? 0, -100, accuracy: 1e-9)
    }

    /// The nearest TROUGH is on the far side of a ridge right next to you. The
    /// bracketing rule has to follow the ridge, not the distant trough.
    func testBracketingFeaturesDecideNotTheNearestTrough() {
        let ridge = WaveFeature(kind: .ridge, column: 5, longitude: -93, value: 8, relief: 12)
        let trough = WaveFeature(kind: .trough, column: 8, longitude: -80, value: -6, relief: 12)
        let pos = WavePattern.position(of: -98.1, among: [ridge, trough])
        // Ridge immediately downstream → you're on its upstream side, ahead of the
        // trough that lies somewhere west of the window.
        XCTAssertEqual(pos.side, .eastOfTrough)
        XCTAssertNil(pos.trough)
        XCTAssertEqual(pos.ridge, ridge)
    }

    func testHomeDeviationUsesTheMeanAtHomeLatitude() {
        let f = field(ridgeAt: -110)
        let a = WavePattern.analyze(f, grid: grid, home: home)
        XCTAssertEqual(a.homeDeviation ?? .nan, 10 * cos(2 * .pi * (-98.1 + 110) / 40), accuracy: 1e-9)
    }

    // MARK: Client

    func testChunksPreserveOrderAndSize() {
        let client = UpperAirClient(grid: grid, home: home)
        XCTAssertEqual(client.points.count, 72 + 216 + 1)
        let chunks = UpperAirClient.chunks(client.points)
        XCTAssertEqual(chunks.count, 13)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 24 })
        XCTAssertEqual(chunks.flatMap { $0 }, client.points)
    }

    func testDecodesBothAnArrayAndABareObject() throws {
        let one = #"{"hourly":{"time":["2026-09-13T12:00"],"geopotential_height_500hPa":[5880.0]}}"#
        XCTAssertEqual(try UpperAirClient.decodeLocations(Data(one.utf8)).count, 1)
        let many = "[\(one),\(one)]"
        XCTAssertEqual(try UpperAirClient.decodeLocations(Data(many.utf8)).count, 2)
    }

    func testAssembleKeeps12ZFromTheRunOnwardInDecameters() throws {
        let tiny = UpperAirGrid(west: -100, east: -90, north: 40, south: 35, step: 5,
                                midLatitudes: 35...40, ringStep: 120)
        let times = ["2026-09-13T00:00", "2026-09-13T12:00", "2026-09-14T00:00",
                     "2026-09-14T12:00", "2026-09-15T12:00"]
        func location(_ meters: Double, missingLast: Bool = false) -> OpenMeteoLocation {
            var values: [Double?] = times.map { _ in meters }
            if missingLast { values[4] = nil }
            return OpenMeteoLocation(hourly: .init(time: times, geopotential_height_500hPa: values))
        }
        // 2 rows × 3 cols, 2 rows × 3 ring, 1 home = 13; one ring value missing on the last day.
        var locations = (0..<6).map { location(5800 + Double($0) * 10) }
        locations += (0..<6).map { location(5700, missingLast: $0 == 4) }
        locations.append(location(5850))

        let run = try UpperAirClient.assemble(
            grid: tiny, home: home, locations: locations,
            initialized: UpperAirClient.timeFormatter.date(from: "2026-09-13T12:00")!,
            fetched: Date())
        XCTAssertEqual(run.frames.count, 2, "13th 12Z kept, 00Z skipped, incomplete 15th dropped")
        XCTAssertEqual(run.frames[0].field.heights, [[580, 581, 582], [583, 584, 585]])
        XCTAssertEqual(run.frames[0].field.zonalMeans, [570, 570])
        XCTAssertEqual(run.frames[0].field.home, 585)
        XCTAssertEqual(run.forecastHour(run.frames[1]), 24)
    }

    func testMetaNamesTheRun() throws {
        let json = #"{"last_run_initialisation_time":1789300800,"last_run_availability_time":1789325117}"#
        let run = try UpperAirClient.decodeMeta(Data(json.utf8))
        XCTAssertEqual(UpperAirStore.nameFormatter.string(from: run), "2026-09-13T12Z")
    }

    func testStoreRoundTripsAndPicksTheNewestCoveringRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpperAirStore(root: root)
        let frame = UpperAirFrame(valid: Date(timeIntervalSince1970: 1789300800), field: field(ridgeAt: -110))
        let older = UpperAirRun(initialized: Date(timeIntervalSince1970: 1789279200), fetched: Date(),
                                home: home, grid: grid, frames: [frame])
        var newer = older
        newer.initialized = Date(timeIntervalSince1970: 1789300800)
        var elsewhere = newer
        elsewhere.initialized = Date(timeIntervalSince1970: 1789322400)
        elsewhere.home = GeoPoint(latitude: 40, longitude: -100)
        try store.save(older); try store.save(newer); try store.save(elsewhere)

        let found = try XCTUnwrap(store.latest(covering: grid, home: home))
        XCTAssertEqual(found.initialized, newer.initialized)
        XCTAssertEqual(found.frames[0].field.heights.count, 6)
    }
}
