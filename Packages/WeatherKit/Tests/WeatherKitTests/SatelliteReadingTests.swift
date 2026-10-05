//
//  SatelliteReadingTests.swift
//
//  The home reading under the satellite map: the grey read from the middle of
//  a tiny picture, and the words for it lining up with the colour table.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import WeatherKit

final class SatelliteReadingTests: XCTestCase {

    /// A 3x3 grey PNG whose middle pixel differs from its edges.
    private func png(edge: UInt8, centre: UInt8, centreAlpha: UInt8 = 255) -> Data {
        var px = [UInt8](repeating: 0, count: 9 * 4)
        for i in 0..<9 {
            let v = i == 4 ? centre : edge
            let a = i == 4 ? centreAlpha : 255
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = a
        }
        let ctx = px.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testReadsTheMiddlePixel() {
        XCTAssertEqual(SatelliteFieldSource.centreGrey(png(edge: 200, centre: 30)), 30)
    }

    func testTransparentMiddleIsNoReading() {
        XCTAssertNil(SatelliteFieldSource.centreGrey(png(edge: 200, centre: 0, centreAlpha: 0)))
    }

    func testWaterVapourWords() {
        let band = SatelliteFieldSource.Band.waterVapor
        XCTAssertEqual(band.reading(grey: 10).name, "Very dry high up")
        XCTAssertEqual(band.reading(grey: 100).name, "Some moisture high up")
        XCTAssertEqual(band.reading(grey: 230).name, "Storm tops")
    }

    func testPointURLCentresOnHome() throws {
        let url = try XCTUnwrap(SatelliteFieldSource(band: .waterVapor)
            .pointURL(stamp: "2026-10-05T13:00:00.000Z", latitude: 0, longitude: 0))
        let bbox = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "bbox" }?.value
        XCTAssertEqual(bbox, "-3000.0,-3000.0,3000.0,3000.0")
    }
}
