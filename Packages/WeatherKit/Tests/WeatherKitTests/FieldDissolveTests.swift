//
//  FieldDissolveTests.swift
//
//  The satellite loop flashed the map through at every frame change: two
//  see-through layers faded plainly cover less than one. The dissolve must
//  hold the field's coverage steady from start to finish.
//

import XCTest
@testable import WeatherKit

final class FieldDissolveTests: XCTestCase {

    private func coverage(_ a: (out: Double, in: Double), _ o: Double) -> Double {
        1 - (1 - a.out * o) * (1 - a.in * o)
    }

    func testCoverageHoldsThroughTheDissolve() {
        for opacity in [1.0, 0.7] {
            for step in 0...20 {
                let b = Double(step) / 20
                let a = FieldDissolve.alphas(blend: b, opacity: opacity, fieldAlpha: 0.85)
                XCTAssertEqual(coverage(a, 0.85), opacity * 0.85, accuracy: 1e-9, "blend \(b)")
            }
        }
    }

    func testEndsAreTheTwoFramesAlone() {
        let start = FieldDissolve.alphas(blend: 0, opacity: 1, fieldAlpha: 0.85)
        let end = FieldDissolve.alphas(blend: 1, opacity: 1, fieldAlpha: 0.85)
        XCTAssertEqual(start.out, 1, accuracy: 1e-9); XCTAssertEqual(start.in, 0)
        XCTAssertEqual(end.out, 0, accuracy: 1e-9); XCTAssertEqual(end.in, 1)
    }

    func testPlainFadeWithoutAFieldAlpha() {
        let a = FieldDissolve.alphas(blend: 0.25, opacity: 1, fieldAlpha: nil)
        XCTAssertEqual(a.out, 0.75); XCTAssertEqual(a.in, 0.25)
    }
}
