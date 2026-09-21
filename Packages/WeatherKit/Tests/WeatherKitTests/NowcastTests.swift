//
//  NowcastTests.swift  (WeatherKit)
//
//  THE MOTION ESTIMATOR IS THE ONE PIECE HERE THAT CANNOT BE CHECKED BY LOOKING.
//  A forecast drawn from a wrong vector is a perfectly plausible picture of rain
//  arriving somewhere it will not — it does not glitch, it does not flicker, it
//  just quietly lies. So the whole of it is exercised against synthetic storms
//  whose true velocity is known by construction.
//

import XCTest
@testable import WeatherKit

final class NowcastTests: XCTestCase {

    // MARK: Fixtures

    /// A grid with a few soft blobs in it, shifted by a known amount.
    ///
    /// SOFT, NOT SHARP. A hard-edged square correlates beautifully at integer
    /// offsets and tells you nothing about the sub-cell fit, which is the part
    /// that matters over twelve forecast steps. A Gaussian blob has a real peak.
    private func storms(width: Int, height: Int,
                        shiftX: Double, shiftY: Double,
                        centres: [(Double, Double, Double)] = [(60, 70, 14), (150, 110, 20), (95, 40, 9)])
    -> IntensityGrid {
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var total = 0.0
                for (cx, cy, radius) in centres {
                    let dx = Double(x) - (cx + shiftX), dy = Double(y) - (cy + shiftY)
                    total += exp(-(dx * dx + dy * dy) / (2 * radius * radius))
                }
                values[y * width + x] = Float(min(1, total))
            }
        }
        return IntensityGrid(values: values, width: width, height: height, cellSize: 1000)
    }

    // MARK: What it must get right

    /// The headline case: storms crossing the screen, recovered to within a
    /// fraction of a cell. The tolerance is the point — a whole-cell answer would
    /// pass a looser test and still drift a cell per step across the hour.
    func testRecoversAKnownShift() {
        for (dx, dy) in [(6.0, -4.0), (-11.0, 3.0), (0.0, 9.0), (14.0, 14.0)] {
            let a = storms(width: 220, height: 160, shiftX: 0, shiftY: 0)
            let b = storms(width: 220, height: 160, shiftX: dx, shiftY: dy)

            let motion = MotionEstimator.estimate(from: a, to: b, over: 300, maxShift: 24)

            XCTAssertTrue(motion.isUsable, "gave up on a clean shift of (\(dx), \(dy))")
            XCTAssertEqual(motion.dx * 300, dx, accuracy: 0.6, "dx wrong for (\(dx), \(dy))")
            XCTAssertEqual(motion.dy * 300, dy, accuracy: 0.6, "dy wrong for (\(dx), \(dy))")
        }
    }

    /// Weather that has not moved must come back as not moving, rather than as a
    /// small confident drift. A spurious vector is worse than none: it is drawn as
    /// an hour of rain sliding somewhere it will never reach.
    func testStationaryWeatherReportsNoMotion() {
        let a = storms(width: 220, height: 160, shiftX: 0, shiftY: 0)
        let motion = MotionEstimator.estimate(from: a, to: a, over: 300, maxShift: 24)

        XCTAssertEqual(motion.dx, 0, accuracy: 1e-3)
        XCTAssertEqual(motion.dy, 0, accuracy: 1e-3)
    }

    /// A CLEAR SKY HAS NO MOTION TO FIND. Two grids of almost nothing correlate
    /// on their noise, and the answer would be confident and meaningless — so the
    /// estimator has to refuse rather than answer.
    func testClearSkyIsRefusedRatherThanGuessed() {
        var values = [Float](repeating: 0, count: 220 * 160)
        // A single speck, well under the wet-fraction floor.
        values[80 * 220 + 40] = 0.9
        let empty = IntensityGrid(values: values, width: 220, height: 160, cellSize: 1000)

        let motion = MotionEstimator.estimate(from: empty, to: empty, over: 300, maxShift: 24)
        XCTAssertFalse(motion.isUsable)
    }

    /// One isolated cell IS worth tracking, and is exactly the thing somebody is
    /// watching most closely. The clear-sky floor must not swallow it.
    func testASingleStormIsStillTracked() {
        let a = storms(width: 220, height: 160, shiftX: 0, shiftY: 0, centres: [(90, 80, 11)])
        let b = storms(width: 220, height: 160, shiftX: 7, shiftY: -5, centres: [(90, 80, 11)])

        let motion = MotionEstimator.estimate(from: a, to: b, over: 300, maxShift: 24)
        XCTAssertTrue(motion.isUsable, "refused a lone storm crossing the viewport")
        XCTAssertEqual(motion.dx * 300, 7, accuracy: 0.8)
        XCTAssertEqual(motion.dy * 300, -5, accuracy: 0.8)
    }

    /// A shift past the search window must not come back as a confident wrong
    /// answer pinned to the edge of the window. Better to refuse.
    func testMotionBeyondTheSearchWindowIsNotFaked() {
        let a = storms(width: 220, height: 160, shiftX: 0, shiftY: 0)
        let b = storms(width: 220, height: 160, shiftX: 60, shiftY: 0)

        let motion = MotionEstimator.estimate(from: a, to: b, over: 300, maxShift: 12)
        XCTAssertFalse(motion.isUsable,
                       "claimed a confident vector for a shift outside the search window")
    }

    // MARK: Which way up the grid is

    /// One tile's worth of alpha, with a blob at a known IMAGE position — where
    /// y counts DOWN from the top, the way every image does.
    private func tile(width: Int = 256, blobX: Double, blobY: Double,
                      radius: Double = 22) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * width)
        for y in 0..<width {
            for x in 0..<width {
                let dx = Double(x) - blobX, dy = Double(y) - blobY
                let v = exp(-(dx * dx + dy * dy) / (2 * radius * radius))
                bytes[y * width + x] = UInt8(min(255, v * 255))
            }
        }
        let context = CGContext(data: &bytes, width: width, height: width,
                                bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
        return context.makeImage()!
    }

    /// One z8 tile at the top-left of the world, and the patch that exactly covers it.
    private func onePlacement() -> (placements: [FieldTileGrid.Placement], span: Double) {
        let span = FieldTileGrid.tileSpan(z: 8)
        return ([FieldTileGrid.Placement(tile: .init(z: 8, x: 0, y: 0), mapX: 0, mapY: 0)], span)
    }

    /// THE BUG THAT SHIPPED, PINNED. A vertically mirrored grid correlates just as
    /// confidently as a correct one and produces a smooth, plausible forecast with
    /// its north-south component reversed — storms tracking northeast all
    /// afternoon turned around at the seam. Nothing but an explicit orientation
    /// check catches that.
    func testNorthInTheImageIsNorthInTheGrid() {
        let (placements, span) = onePlacement()
        // Blob in the image's TOP-LEFT quadrant: north-west.
        let image = tile(blobX: 64, blobY: 64)

        let grid = IntensityGrid.rasterise(placements: placements, rectX: 0, rectY: 0,
                                           width: span, height: span, cells: 64) { _ in image }
        guard let grid else { return XCTFail("no grid") }

        func mass(rows: Range<Int>, cols: Range<Int>) -> Double {
            rows.reduce(0.0) { total, r in
                total + cols.reduce(0.0) { $0 + Double(grid.values[r * grid.width + $1]) }
            }
        }
        let north = mass(rows: 0..<(grid.height / 2), cols: 0..<(grid.width / 2))
        let south = mass(rows: (grid.height / 2)..<grid.height, cols: 0..<(grid.width / 2))

        XCTAssertGreaterThan(north, south * 8,
                             "the grid is upside down: an image's top row must be its north row")
    }

    /// END TO END, THROUGH THE RASTERISER. The estimator's own tests build grids
    /// by hand, so they could never have caught a flip that happens on the way in.
    /// This one starts where the app starts: two tile images.
    func testAStormTrackingNortheastIsReportedAsTrackingNortheast() {
        let (placements, span) = onePlacement()
        // Image y counts DOWN, so a smaller y is further north. East and north.
        let older = tile(blobX: 100, blobY: 150)
        let newer = tile(blobX: 130, blobY: 120)

        func grid(_ image: CGImage) -> IntensityGrid {
            IntensityGrid.rasterise(placements: placements, rectX: 0, rectY: 0,
                                    width: span, height: span, cells: 128) { _ in image }!
        }

        let motion = MotionEstimator.estimate(from: grid(older), to: grid(newer),
                                              over: 300, maxShift: 24)

        XCTAssertTrue(motion.isUsable)
        XCTAssertGreaterThan(motion.dx, 0, "eastward travel must come out positive in x")
        XCTAssertLessThan(motion.dy, 0,
                          "northward travel must come out NEGATIVE in y — map space counts y south")

        // And it has to read out as a compass direction a person would recognise.
        let track = motion.groundTrack(atLatitude: 31.5)
        XCTAssertEqual(StormMotion.compass(track.bearing), "NE")
    }

    // MARK: Turning it into something a person reads

    /// MERCATOR STRETCH IS NOT A ROUNDING DETAIL. At Texas latitudes a map point
    /// is about 85% of the ground it is at the equator, so an unscaled speed reads
    /// ~18% fast — plausible enough that nobody would question it.
    func testGroundSpeedIsScaledForLatitude() {
        // One thousandth of the world per second, due east.
        let motion = StormMotion(dx: FieldTileGrid.worldSize / 1000, dy: 0, confidence: 1)

        let equator = motion.groundTrack(atLatitude: 0)
        let texas = motion.groundTrack(atLatitude: 31.5)

        XCTAssertEqual(equator.metresPerSecond, 40_075.016686, accuracy: 0.01)
        XCTAssertEqual(texas.metresPerSecond,
                       40_075.016686 * cos(31.5 * .pi / 180), accuracy: 0.01)
        XCTAssertLessThan(texas.metresPerSecond, equator.metresPerSecond)
    }

    /// Map space counts y DOWNWARD from the north edge, so a positive dy is
    /// travel SOUTH. Getting this backwards would label every storm with the
    /// opposite of where it is going.
    func testBearingReadsMapSpaceTheRightWayUp() {
        XCTAssertEqual(StormMotion(dx: 0, dy: -1, confidence: 1).groundTrack(atLatitude: 31).bearing,
                       0, accuracy: 0.01, "north")
        XCTAssertEqual(StormMotion(dx: 1, dy: 0, confidence: 1).groundTrack(atLatitude: 31).bearing,
                       90, accuracy: 0.01, "east")
        XCTAssertEqual(StormMotion(dx: 0, dy: 1, confidence: 1).groundTrack(atLatitude: 31).bearing,
                       180, accuracy: 0.01, "south")

        XCTAssertEqual(StormMotion.compass(45), "NE")
        XCTAssertEqual(StormMotion.compass(359), "N")
        XCTAssertEqual(StormMotion.compass(247.5), "WSW")
    }

    // MARK: The shape of the loop

    /// The loop must run observations then forecast, with the seam where the
    /// observations stop — and the forecast frames must all draw the NEWEST scan,
    /// because that is what makes them free.
    @MainActor
    func testTheLoopRunsPastThenFuture() {
        let model = RadarModel()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let scans = (0..<6).map { i in
            RadarFrame(time: base.addingTimeInterval(Double(i) * 300))
        }
        model.setFramesForTesting(scans)
        XCTAssertEqual(model.loop.count, 6, "no motion yet, so no future")
        XCTAssertEqual(model.nowIndex, 5)

        model.setMotionForTesting(StormMotion(dx: 100, dy: -50, confidence: 0.9))

        XCTAssertEqual(model.loop.count, 6 + 12, "an hour of five-minute steps")
        XCTAssertEqual(model.nowIndex, 5, "the seam does not move")
        XCTAssertFalse(model.loop[5].isForecast)
        XCTAssertTrue(model.loop[6].isForecast)

        // Every forecast frame is the newest scan, displaced.
        let newest = scans.last!.stamp
        for frame in model.loop where frame.isForecast {
            XCTAssertEqual(frame.stamp, newest)
            XCTAssertEqual(frame.offsetX, 100 * frame.lead, accuracy: 1e-6)
            XCTAssertEqual(frame.offsetY, -50 * frame.lead, accuracy: 1e-6)
        }

        // The last forecast lands an hour past the last observation.
        XCTAssertEqual(model.loop.last!.time.timeIntervalSince(scans.last!.time), 3600, accuracy: 1)
    }

    /// AN UNTRUSTWORTHY VECTOR BUYS NO FUTURE AT ALL. The loop goes back to being
    /// what the radar saw, rather than growing a confident-looking hour built on a
    /// correlation that never locked on.
    @MainActor
    func testAWeakEstimateLeavesTheLoopObservedOnly() {
        let model = RadarModel()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        model.setFramesForTesting((0..<4).map {
            RadarFrame(time: base.addingTimeInterval(Double($0) * 300))
        })
        model.setMotionForTesting(StormMotion(dx: 100, dy: -50, confidence: 0.9))
        XCTAssertGreaterThan(model.loop.count, 4)

        model.setMotion(StormMotion(dx: 100, dy: -50, confidence: 0.1))
        XCTAssertEqual(model.loop.count, 4, "kept a future off a correlation that failed")
        XCTAssertNil(model.motion)
    }

    /// The pause belongs on the newest OBSERVATION once the loop has a future —
    /// holding for an extra beat on an hour of extrapolation would give the
    /// longest look to the weakest claim.
    func testTheLoopPausesAtTheSeamNotAtTheEnd() {
        var clock = FieldLoopClock(frameCount: 18)
        clock.holdIndex = 5

        XCTAssertEqual(clock.duration(of: 5), clock.frameHold + clock.endHold)
        XCTAssertEqual(clock.duration(of: 17), clock.frameHold)

        // A reload puts the viewer back at the seam rather than an hour out — AND
        // at the seam's NEW position. The scan that just landed moved it right by
        // one; leaving the playhead at the old index would walk a viewer watching
        // now one frame into the past every five minutes.
        clock.jump(to: 5)
        clock.resize(to: 19, keepingEnd: true, holdIndex: 6)
        XCTAssertEqual(clock.index, 6)
    }

    /// A LAP IS A UNIT OF ATTENTION. Doubling the frame count must not double how
    /// long you wait to see the loop come round.
    func testALapStaysAboutTheSameLengthAsTheLoopGrows() {
        let short = FieldLoopClock.hold(forFrames: 10) * 10
        let long = FieldLoopClock.hold(forFrames: 22) * 22
        XCTAssertEqual(short, long, accuracy: 1.2)
        XCTAssertGreaterThan(FieldLoopClock.hold(forFrames: 3), FieldLoopClock.hold(forFrames: 22))
    }
}
