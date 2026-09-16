import XCTest
@testable import WeatherKit

final class UpperAirFlowTests: XCTestCase {

    private let grid = UpperAirGrid.conus

    // MARK: Contours

    func testLevelsAreMultiplesOfSix() {
        XCTAssertEqual(HeightContours.levels([[570, 580], [585, 592]]), [570, 576, 582, 588])
    }

    /// Heights rising 2 dam per column eastward: the 576 line is straight down
    /// column 3, crossing every row gap.
    func testStraightContourSitsWhereTheLevelIs() {
        let heights = (0..<6).map { _ in (0..<12).map { 570 + 2 * Double($0) } }
        let segments = HeightContours.segments(heights, level: 576)
        XCTAssertEqual(segments.count, 5)
        for s in segments {
            XCTAssertEqual(s.a.column, 3, accuracy: 1e-9)
            XCTAssertEqual(s.b.column, 3, accuracy: 1e-9)
        }
    }

    /// Crossing is interpolated: 580→590 crosses 582 a fifth of the way along.
    func testCrossingIsInterpolatedNotMidpoint() {
        let s = HeightContours.segments([[580, 590], [580, 590]], level: 582)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].a.column, 0.2, accuracy: 1e-9)
    }

    /// A single high point closes into a loop: every endpoint is shared by exactly
    /// two segments.
    func testContourAroundAPeakCloses() {
        let s = HeightContours.segments([[0, 0, 0], [0, 10, 0], [0, 0, 0]], level: 5)
        XCTAssertEqual(s.count, 4)
        let ends = s.flatMap { [$0.a, $0.b] }
        for p in ends {
            XCTAssertEqual(ends.filter { abs($0.column - p.column) < 1e-9 && abs($0.row - p.row) < 1e-9 }.count, 2)
        }
    }

    func testSaddleYieldsTwoSegments() {
        XCTAssertEqual(HeightContours.segments([[10, 0], [0, 10]], level: 5).count, 2)
        XCTAssertEqual(HeightContours.segments([[0, 10], [10, 0]], level: 5).count, 2)
    }

    // MARK: Flow

    /// Heights falling 6 dam per 5° toward the pole — the ordinary state — give a
    /// wind FROM the west, at a speed the textbook formula predicts.
    func testFallingTowardThePoleGivesAWesterly() {
        let heights = grid.latitudes.map { lat in grid.longitudes.map { _ in 600 - 6 * (50 - lat) / 5 * -1 } }
        let flows = GeostrophicFlow.corners(heights, grid: grid)
        XCTAssertEqual(flows.count, 5 * 11)
        let at425 = flows[0]   // between 50°N and 45°N
        XCTAssertEqual(at425.fromDegrees, 270, accuracy: 1e-6)
        let f = 2 * 7.2921e-5 * sin(47.5 * .pi / 180)
        let expected = 9.80665 / f * (60 / (5 * 111_195.0)) * 2.23694
        XCTAssertEqual(at425.speedMPH, expected, accuracy: 1e-6)
        XCTAssertTrue((15...40).contains(at425.speedMPH), "a plausible jet-level speed, got \(at425.speedMPH)")
    }

    /// Heights rising toward the east: lower heights on the left means the wind
    /// comes from the south.
    func testRisingEastwardGivesASoutherly() {
        let heights = grid.latitudes.map { _ in grid.longitudes.map { 570 + ($0 + 125) / 5 } }
        let flows = GeostrophicFlow.corners(heights, grid: grid)
        XCTAssertEqual(flows[0].fromDegrees, 180, accuracy: 1e-6)
    }

    func testCompass() {
        XCTAssertEqual(FlowVector.compass(0), "N")
        XCTAssertEqual(FlowVector.compass(225), "SW")
        XCTAssertEqual(FlowVector.compass(290), "WNW")
        XCTAssertEqual(FlowVector.compass(359), "N")
    }

    // MARK: Tracks

    private func feature(_ kind: WaveFeature.Kind, _ lon: Double) -> WaveFeature {
        WaveFeature(kind: kind, column: 0, longitude: lon, value: 0, relief: 5)
    }

    func testAProgressiveTroughIsOneTrackMovingEast() {
        let days = (0..<5).map { [feature(.trough, -120 + 8 * Double($0))] }
        let tracks = FeatureTracks.build(days)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].points.count, 5)
        XCTAssertEqual(tracks[0].degreesPerDay ?? .nan, 8, accuracy: 1e-9)
    }

    func testStalledAndRetrogressingFeaturesKeepTheirOwnTracks() {
        let days = (0..<4).map { d in
            [feature(.ridge, -105 - 3 * Double(d)),   // backing west
             feature(.trough, -85)]                    // stalled
        }
        let tracks = FeatureTracks.build(days)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks.first { $0.kind == .ridge }?.degreesPerDay ?? .nan, -3, accuracy: 1e-9)
        XCTAssertEqual(tracks.first { $0.kind == .trough }?.degreesPerDay ?? .nan, 0, accuracy: 1e-9)
    }

    /// A trough leaving the east edge while a new one enters the west is two
    /// features, not one that jumped 40° overnight.
    func testAJumpTooFarStartsANewTrack() {
        let tracks = FeatureTracks.build([[feature(.trough, -75)], [feature(.trough, -115)]])
        XCTAssertEqual(tracks.count, 2)
        XCTAssertNil(tracks[0].degreesPerDay)
    }

    // MARK: Temperature

    /// The forecaster's 540 line: 5,400 m of thickness is a layer averaging about −7 °C.
    func testThe540LineIsAboutMinusSevenCelsius() {
        XCTAssertEqual(LayerTemperature.kelvin(thicknessDam: 540) - 273.15, -7, accuracy: 0.5)
        XCTAssertEqual(LayerTemperature.fahrenheitPerDam * 10, 8.9, accuracy: 0.1)
    }

    // MARK: Client extras

    func testAssembleCarriesHomeThicknessAndWind() throws {
        let tiny = UpperAirGrid(west: -100, east: -95, north: 40, south: 35, step: 5,
                                midLatitudes: 35...40, ringStep: 180)
        let times = ["2026-09-13T12:00"]
        let loc = { (m: Double) in OpenMeteoLocation(hourly: .init(time: times, geopotential_height_500hPa: [m])) }
        let locations = (0..<8).map { _ in loc(5850) } + [loc(5923)]
        let extra = OpenMeteoHomeLocation(hourly: .init(time: times, geopotential_height_1000hPa: [118],
                                                        wind_speed_500hPa: [8.2], wind_direction_500hPa: [90]))
        let run = try UpperAirClient.assemble(
            grid: tiny, home: GeoPoint(latitude: 31.7, longitude: -98.1), locations: locations,
            homeExtra: extra, initialized: UpperAirClient.timeFormatter.date(from: "2026-09-13T12:00")!,
            fetched: Date())
        XCTAssertEqual(run.frames[0].field.homeThickness ?? .nan, 580.5, accuracy: 1e-9)
        XCTAssertEqual(run.frames[0].field.homeWind, UpperWind(speedMPH: 8.2, fromDegrees: 90))
        XCTAssertEqual(run.version, UpperAirRun.currentVersion)
    }

    /// A run stored before the extras existed must not be served as current.
    func testUnversionedRunDoesNotCover() {
        var run = UpperAirRun(initialized: Date(), fetched: Date(), home: nil, grid: grid, frames: [])
        XCTAssertTrue(run.covers(grid: grid, home: nil))
        run.version = nil
        XCTAssertFalse(run.covers(grid: grid, home: nil))
    }
}
