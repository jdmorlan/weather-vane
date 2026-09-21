import XCTest
@testable import WeatherKit

/// A probability alone cannot separate the two days people most need separated:
/// a 20% chance of a hundredth, and a 20% chance of an inch. The daily payload
/// carries no amount, so it is summed from that day's hours — and the edge that
/// matters is the far end of the ten-day, where there are no hours at all and
/// "nothing forecast" must not be reported as "no rain".
final class DailyPrecipTotalTests: XCTestCase {

    private func hour(_ localHour: Int, precip: Double?) -> HourlyForecast {
        var h = HourlyForecast()
        h.time = 1_757_000_000 + localHour * 3600
        h.localHour = localHour
        h.precip = precip
        return h
    }

    private func note(_ hours: [HourlyForecast], probability: Double = 20) -> DayNote {
        var day = DailyForecast()
        day.dayStartLocal = 1_757_000_000
        day.precipProbability = probability
        day.airTempHigh = 90
        day.airTempLow = 70
        return WeatherInterpreter.dayNote(day, hours: hours, calendar: Calendar(identifier: .gregorian))
    }

    func testTheDayTotalIsTheSumOfItsHours() {
        let day = note([hour(13, precip: 0.20), hour(14, precip: 0.45), hour(15, precip: 0.05)])
        XCTAssertEqual(day.precipTotal ?? 0, 0.70, accuracy: 0.0001)
    }

    /// The distinction the whole field exists for: identical probability, wildly
    /// different days.
    func testSameProbabilityCanCarryVeryDifferentAmounts() {
        let drizzle = note([hour(14, precip: 0.01)], probability: 20)
        let soaker  = note([hour(14, precip: 1.00)], probability: 20)
        XCTAssertEqual(drizzle.precipProbability, soaker.precipProbability)
        XCTAssertEqual(drizzle.precipTotal ?? 0, 0.01, accuracy: 0.0001)
        XCTAssertEqual(soaker.precipTotal ?? 0, 1.00, accuracy: 0.0001)
    }

    /// Hours that reach the day but report no precip are a real forecast of a
    /// dry day, and that IS zero.
    func testHoursWithNoPrecipGiveZeroNotNil() {
        let day = note([hour(13, precip: 0), hour(14, precip: nil)])
        XCTAssertEqual(day.precipTotal ?? -1, 0, accuracy: 0.0001)
    }

    /// The far end of the ten-day. No hours reach it, so there is nothing to
    /// sum — and reporting 0.00 there would promise a dry day the forecast never
    /// made.
    func testADayBeyondTheHourlyForecastHasNoTotal() {
        XCTAssertNil(note([]).precipTotal)
    }
}
