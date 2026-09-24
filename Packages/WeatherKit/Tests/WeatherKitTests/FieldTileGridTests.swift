//
//  FieldTileGridTests.swift
//
//  The tile arithmetic, checked against values that can be worked out by hand.
//
//  WHY THIS FILE EXISTS AT ALL. An error in here does not throw and does not draw
//  a blank — it slides the radar off the town it is actually over, by an amount
//  that looks plausible. That is the one failure the card cannot survive and the
//  one a human eye is worst at catching, so it is pinned to arithmetic rather
//  than to a screenshot.
//

import XCTest
@testable import WeatherKit

final class FieldTileGridTests: XCTestCase {

    // MARK: Zoom selection

    /// At zoom scale 1 — one screen point per map point, fully zoomed in — the
    /// world is 2^28 points across. Cut into 256 px tiles that is 2^20 of them,
    /// so zoom 20; into 512 px tiles it is 2^19, so zoom 19. The 512 tile covers
    /// four times the ground, which is the entire reason `Radar.tileSize` is 512.
    func testZoomAtUnitScaleFollowsTileSize() {
        XCTAssertEqual(FieldTileGrid.zoom(forZoomScale: 1, tileSize: 256, clampedTo: 0...24), 20)
        XCTAssertEqual(FieldTileGrid.zoom(forZoomScale: 1, tileSize: 512, clampedTo: 0...24), 19)
    }

    /// Halving the zoom scale is zooming out one level, exactly.
    func testZoomHalvesWithZoomScale() {
        let range = 0...24
        XCTAssertEqual(FieldTileGrid.zoom(forZoomScale: 0.5, tileSize: 512, clampedTo: range), 18)
        XCTAssertEqual(FieldTileGrid.zoom(forZoomScale: 0.25, tileSize: 512, clampedTo: range), 17)
    }

    /// A retina backing asks for one level sharper, because there are twice as
    /// many pixels to fill per point.
    func testScaleFactorBuysOneLevel() {
        let plain = FieldTileGrid.zoom(forZoomScale: 0.01, tileSize: 512, scale: 1, clampedTo: 0...24)
        let retina = FieldTileGrid.zoom(forZoomScale: 0.01, tileSize: 512, scale: 2, clampedTo: 0...24)
        XCTAssertEqual(retina, plain + 1)
    }

    /// THE CLAMP MUST CLAMP, NOT BLANK. This is the whole difference from
    /// `MKTileOverlay`'s minimumZ/maximumZ, which renders "Zoom level not
    /// supported" outside its range — a constraint that blanked the map instead
    /// of limiting it. Past the range the nearest level is drawn scaled.
    func testZoomClampsRatherThanEscaping() {
        XCTAssertEqual(FieldTileGrid.zoom(forZoomScale: 1, tileSize: 512, clampedTo: 3...10), 10)
        XCTAssertEqual(FieldTileGrid.zoom(forZoomScale: 0.000001, tileSize: 512, clampedTo: 3...10), 3)
    }

    func testDegenerateZoomScaleFallsToLowerBound() {
        XCTAssertEqual(FieldTileGrid.zoom(forZoomScale: 0, tileSize: 512, clampedTo: 3...10), 3)
        XCTAssertEqual(FieldTileGrid.zoom(forZoomScale: -1, tileSize: 512, clampedTo: 3...10), 3)
    }

    // MARK: Tile spans and origins

    func testTileSpanHalvesEachLevel() {
        XCTAssertEqual(FieldTileGrid.tileSpan(z: 0), FieldTileGrid.worldSize, accuracy: 0.0001)
        XCTAssertEqual(FieldTileGrid.tileSpan(z: 1), FieldTileGrid.worldSize / 2, accuracy: 0.0001)
        XCTAssertEqual(FieldTileGrid.tileSpan(z: 10), FieldTileGrid.worldSize / 1024, accuracy: 0.0001)
    }

    /// Tile (0,0) is the top-left of the world at every zoom, and the last tile
    /// on a row starts exactly one span short of the far edge.
    func testOriginsSitOnTheGrid() {
        XCTAssertEqual(FieldTileGrid.origin(of: .init(z: 4, x: 0, y: 0)).x, 0)
        XCTAssertEqual(FieldTileGrid.origin(of: .init(z: 4, x: 0, y: 0)).y, 0)

        let span = FieldTileGrid.tileSpan(z: 4)
        let last = FieldTileGrid.origin(of: .init(z: 4, x: 15, y: 15))
        XCTAssertEqual(last.x, FieldTileGrid.worldSize - span, accuracy: 0.0001)
        XCTAssertEqual(last.y, FieldTileGrid.worldSize - span, accuracy: 0.0001)
    }

    // MARK: Covering a rect

    /// A rect exactly one tile wide and aligned to the grid needs exactly one
    /// tile — NOT four. The epsilon in `tiles(inRectX:...)` is what makes the
    /// far edge exclusive; without it every aligned viewport fetches a wasted row
    /// and column it never draws a pixel of.
    func testAlignedSingleTileRectNeedsOneTile() {
        let span = FieldTileGrid.tileSpan(z: 5)
        let tiles = FieldTileGrid.tiles(inRectX: span * 3, y: span * 7,
                                        width: span, height: span, z: 5)
        XCTAssertEqual(tiles, [FieldTileGrid.Tile(z: 5, x: 3, y: 7)])
    }

    /// Straddling a boundary by any amount needs both.
    func testStraddlingRectNeedsBothTiles() {
        let span = FieldTileGrid.tileSpan(z: 5)
        let tiles = FieldTileGrid.tiles(inRectX: span * 3 - 1, y: span * 7,
                                        width: span, height: span, z: 5)
        XCTAssertEqual(Set(tiles), [FieldTileGrid.Tile(z: 5, x: 2, y: 7),
                                    FieldTileGrid.Tile(z: 5, x: 3, y: 7)])
    }

    /// The whole world at zoom 2 is sixteen tiles, each exactly once.
    func testWholeWorldIsCoveredExactlyOnce() {
        let tiles = FieldTileGrid.tiles(inRectX: 0, y: 0,
                                        width: FieldTileGrid.worldSize,
                                        height: FieldTileGrid.worldSize, z: 2)
        XCTAssertEqual(tiles.count, 16)
        XCTAssertEqual(Set(tiles).count, 16)
    }

    /// THE WORLD WRAPS SIDEWAYS AND NOT VERTICALLY, and MapKit really does hand
    /// out rects past the antimeridian once you pan there. Wrapping x is what
    /// stops the field tearing at the date line; NOT wrapping y is what stops a
    /// pan off the top of the world fetching tiles from the south pole.
    func testHorizontalWrapAndVerticalClip() {
        let span = FieldTileGrid.tileSpan(z: 3)   // eight tiles across
        let past = FieldTileGrid.tiles(inRectX: FieldTileGrid.worldSize + span * 0.5,
                                       y: span, width: span, height: span, z: 3)
        XCTAssertEqual(Set(past.map(\.x)), [0, 1], "east of the antimeridian is the west edge")

        let above = FieldTileGrid.tiles(inRectX: 0, y: -span * 2,
                                        width: span, height: span, z: 3)
        XCTAssertTrue(above.isEmpty, "off the top of the world is nothing, not the far pole")
    }

    func testEmptyRectNeedsNoTiles() {
        XCTAssertTrue(FieldTileGrid.tiles(inRectX: 0, y: 0, width: 0, height: 10, z: 5).isEmpty)
        XCTAssertTrue(FieldTileGrid.tiles(inRectX: 0, y: 0, width: 10, height: -1, z: 5).isEmpty)
    }

    // MARK: Agreement with the WMS bounding box

    /// THE TWO HALVES OF THE SAME ADDRESS MUST AGREE. `FieldTileGrid` decides
    /// WHERE a tile is drawn, in MapKit's map space; `bbox3857` decides
    /// WHAT a WMS renders, in EPSG:3857 metres. They are separate pieces of
    /// arithmetic over the same slippy-tile scheme, and if they ever disagree the
    /// picture is drawn accurately in the wrong place. Both are linear in the
    /// tile index over their own world size, so the fractional position of a
    /// tile's origin has to match exactly.
    func testGridAndBoundingBoxDescribeTheSameTile() {
        for (z, x, y) in [(3, 1, 2), (6, 14, 25), (10, 233, 419)] {
            let origin = FieldTileGrid.origin(of: .init(z: z, x: x, y: y))
            let fractionX = origin.x / FieldTileGrid.worldSize
            // Map space counts y DOWNWARD from the north edge.
            let fractionY = origin.y / FieldTileGrid.worldSize

            let parts = FieldTileGrid.bbox3857(z: z, x: x, y: y).split(separator: ",").map { Double($0)! }
            let extent = FieldTileGrid.mercatorExtent
            let bboxFractionX = (parts[0] + extent) / (2 * extent)
            let bboxFractionY = (extent - parts[3]) / (2 * extent)

            XCTAssertEqual(fractionX, bboxFractionX, accuracy: 1e-12,
                           "x disagreed at z\(z) \(x)/\(y)")
            XCTAssertEqual(fractionY, bboxFractionY, accuracy: 1e-12,
                           "y disagreed at z\(z) \(x)/\(y)")
        }
    }

    // MARK: The coarse first pass

    /// THE POINT OF `parents` IS THE COLLAPSE, so that is what is checked. A
    /// viewport's worth of tiles has to come back as a HANDFUL three levels up —
    /// if it did not, the coarse pass would cost the same as the sharp one and
    /// buy nothing.
    func testAViewportCollapsesToAFewCoarseTiles() {
        let viewport = FieldTileGrid.tiles(inRectX: 0.31 * FieldTileGrid.worldSize,
                                           y: 0.39 * FieldTileGrid.worldSize,
                                           width: 0.02 * FieldTileGrid.worldSize,
                                           height: 0.015 * FieldTileGrid.worldSize,
                                           z: 9)
        XCTAssertGreaterThan(viewport.count, 8, "the fixture should be a real viewport")

        let coarse = FieldTileGrid.parents(of: viewport, levelsUp: 3, notBelow: 3)
        // An order of magnitude, which is what turns two hundred requests into a
        // single pass of the connection pool.
        XCTAssertLessThan(coarse.count * 8, viewport.count)
        XCTAssertTrue(coarse.allSatisfy { $0.z == 6 })

        // Every sharp tile must actually be COVERED by one of them, or the
        // renderer's parent fallback has nothing to draw and the loop still waits.
        for tile in viewport {
            let ancestor = FieldTileGrid.Tile(z: tile.z - 3, x: tile.x >> 3, y: tile.y >> 3)
            XCTAssertTrue(coarse.contains(ancestor), "\(tile) had no coarse stand-in")
        }
    }

    /// A tile already at the floor of its source's range has no coarser version to
    /// stand in for it, and inventing one would address a zoom the service was
    /// never asked about.
    func testTilesAtTheFloorHaveNoCoarserStandIn() {
        let atFloor = [FieldTileGrid.Tile(z: 3, x: 1, y: 3)]
        XCTAssertTrue(FieldTileGrid.parents(of: atFloor, levelsUp: 3, notBelow: 3).isEmpty)

        // Within one level of the floor it clamps rather than refusing — one level
        // of magnification is still worth having.
        let justAbove = [FieldTileGrid.Tile(z: 4, x: 3, y: 6)]
        XCTAssertEqual(FieldTileGrid.parents(of: justAbove, levelsUp: 3, notBelow: 3),
                       [FieldTileGrid.Tile(z: 3, x: 1, y: 3)])
    }

    /// THE RADAR CEILING, STATED AS THE THING THAT ACTUALLY MATTERS: the
    /// relationship between the finest tile drawn and the 250 m gate a Level II
    /// sweep is made of. A few pixels per gate so the interpolation reads
    /// smooth; not so many that each level quadruples the tiles to draw the
    /// same measurement larger.
    func testTheRadarCeilingResolvesAGateWithoutOversamplingIt() {
        let source = Level2FieldSource(site: "KFWS")
        let metresPerPixel = 40_075_017.0
            / (pow(2, Double(source.zoomRange.upperBound)) * Double(source.tileSize))
        let pixelsPerGate = 250.0 / metresPerPixel

        XCTAssertGreaterThan(pixelsPerGate, 2, "the finest tile can no longer resolve a gate")
        XCTAssertLessThan(pixelsPerGate, 16, "drawing four times the tiles to upscale the same gate")
    }
}
