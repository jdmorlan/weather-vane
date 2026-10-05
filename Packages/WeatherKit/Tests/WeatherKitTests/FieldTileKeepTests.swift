//
//  FieldTileKeepTests.swift
//
//  The loop on screen must survive the cache being emptied. On 2026-10-03
//  memory pressure made NSCache drop every radar tile as it landed, and the
//  map played a loop of nothing over its range rings.
//

import XCTest
import CoreGraphics
@testable import WeatherKit

final class FieldTileKeepTests: XCTestCase {

    /// Draws a small solid tile for any address, instantly.
    struct SolidSource: RenderedFieldTileSource {
        var id: String { "test-solid" }
        var tileSize: Int { 8 }
        func render(stamp: String, z: Int, x: Int, y: Int) async -> CGImage? {
            let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            ctx?.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return ctx?.makeImage()
        }
    }

    private func waitUntilHeld(_ store: FieldTileStore, stamps: [String],
                               tiles: [FieldTileGrid.Tile], source: FieldTileSource) async {
        for _ in 0..<200 where !store.progress(stamps: stamps, tiles: tiles, from: source).isComplete {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testKeptTilesSurviveAPurgeAndOthersDoNot() async {
        let store = FieldTileStore()
        let source = SolidSource()
        let stamps = ["A", "B"]
        let onScreen = [FieldTileGrid.Tile(z: 6, x: 1, y: 1), FieldTileGrid.Tile(z: 6, x: 2, y: 1)]
        let elsewhere = [FieldTileGrid.Tile(z: 6, x: 9, y: 9)]

        store.keep(stamps: stamps, passes: [onScreen], from: source)
        store.prefetch(stamps: stamps, tiles: onScreen + elsewhere, from: source)
        await waitUntilHeld(store, stamps: stamps, tiles: onScreen + elsewhere, source: source)
        XCTAssertTrue(store.progress(stamps: stamps, tiles: onScreen + elsewhere, from: source).isComplete)

        store.purgeCache()

        XCTAssertTrue(store.progress(stamps: stamps, tiles: onScreen, from: source).isComplete,
                      "the loop in view must outlive a purge")
        XCTAssertEqual(store.progress(stamps: stamps, tiles: elsewhere, from: source).held, 0,
                       "tiles not in view are still only cached")
    }

    /// A tile cached BEFORE it was wanted is kept from the moment it is.
    func testAlreadyCachedTilesAreKeptWhenWanted() async {
        let store = FieldTileStore()
        let source = SolidSource()
        let tiles = [FieldTileGrid.Tile(z: 6, x: 3, y: 3)]
        store.prefetch(stamps: ["A"], tiles: tiles, from: source)
        await waitUntilHeld(store, stamps: ["A"], tiles: tiles, source: source)

        store.keep(stamps: ["A"], passes: [tiles], from: source)
        store.purgeCache()
        XCTAssertEqual(store.progress(stamps: ["A"], tiles: tiles, from: source).held, 1)
    }

    /// Released tiles go back to being merely cached — the map closing must
    /// hand the memory back.
    func testKeepNothingReleases() async {
        let store = FieldTileStore()
        let source = SolidSource()
        let tiles = [FieldTileGrid.Tile(z: 6, x: 4, y: 4)]
        store.keep(stamps: ["A"], passes: [tiles], from: source)
        store.prefetch(stamps: ["A"], tiles: tiles, from: source)
        await waitUntilHeld(store, stamps: ["A"], tiles: tiles, source: source)

        store.keepNothing()
        store.purgeCache()
        XCTAssertEqual(store.progress(stamps: ["A"], tiles: tiles, from: source).held, 0)
    }
}
