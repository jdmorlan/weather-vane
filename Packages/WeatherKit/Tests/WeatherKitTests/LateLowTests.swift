//
//  LateLowTests.swift
//
//  A day box marks its low with a moon and the hour only when the cold comes
//  after the morning — a front in the evening — and stays quiet on the usual
//  day, whose low is the dawn.
//

import XCTest
@testable import WeatherKit

final class LateLowTests: XCTestCase {

    private func day(wake: Double?, temps: [Int: Double]) -> DayNote {
        DayNote(epoch: 0, weekday: "Thu", high: temps.values.max(), low: temps.values.min(),
                wakeTemp: wake, conditions: "", icon: "", precipProbability: nil,
                precipTotal: nil, sunrise: nil, sunset: nil, dewPoint: nil, comfortTag: "",
                dewPointHigh: nil, dewPointLow: nil, parts: [], shape: "", headline: "",
                hours: temps.map { DayHour(hour: $0.key, temperature: $0.value,
                                           precipProbability: nil, precip: nil) }
                    .sorted { $0.hour < $1.hour })
    }

    func testDawnLowIsNotLate() {
        let d = day(wake: 58, temps: [6: 58, 7: 58, 15: 80, 23: 63])
        XCTAssertNil(d.lateLowHour)
    }

    func testFrontAfterDarkIsLate() {
        let d = day(wake: 61, temps: [7: 61, 15: 76, 20: 58, 23: 52])
        XCTAssertEqual(d.lateLowHour, 23)
    }

    func testSmallEveningDipIsNotLate() {
        let d = day(wake: 61, temps: [7: 61, 15: 76, 23: 59])
        XCTAssertNil(d.lateLowHour)
    }

    func testNoMorningReadingSaysNothing() {
        let d = day(wake: nil, temps: [15: 76, 23: 52])
        XCTAssertNil(d.lateLowHour)
    }
}
