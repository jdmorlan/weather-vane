import XCTest
@testable import WeatherKit

/// The forecast half of the query language: can a forecast question be SAID, read back strictly, and
/// answered off a real report? The archive side proved the shape (`QueryLanguageTests`); this is the
/// same contract for the live forecast, which had no value type at all until now.
final class ForecastQueryTests: XCTestCase {

    // MARK: Saying it

    func testRoundTripsEveryHorizonAndFocus() throws {
        for horizon in ForecastQuery.Horizon.allCases {
            for focus in ForecastQuery.Focus.allCases {
                let query = ForecastQuery(horizon: horizon, focus: focus)
                let back = try ForecastQuery(json: query.jsonObject)
                XCTAssertEqual(back, query)
            }
        }
    }

    func testFocusDefaultsToEverything() throws {
        let query = try ForecastQuery(json: ["horizon": "today"])
        XCTAssertEqual(query.focus, .everything)
        XCTAssertEqual(query.describe, "The forecast for today")
    }

    /// STRICT, for the reason the archive is strict: a horizon quietly defaulted still returns a
    /// plausible forecast, and nothing downstream can tell it answered a different day.
    func testUnknownHorizonThrows() {
        XCTAssertThrowsError(try ForecastQuery(json: ["horizon": "next_month"]))
        XCTAssertThrowsError(try ForecastQuery(json: [:]))
        XCTAssertThrowsError(try ForecastQuery(json: ["horizon": "today", "focus": "vibes"]))
    }

    func testSchemaEnumeratesFromTheTypes() {
        let schema = ForecastQuery.jsonSchema
        let properties = schema["properties"] as? [String: Any]
        let horizon = properties?["horizon"] as? [String: Any]
        XCTAssertEqual(horizon?["enum"] as? [String], ForecastQuery.Horizon.allCases.map(\.rawValue))
        XCTAssertEqual(schema["required"] as? [String], ["horizon"])
    }

    func testDescribesItselfInEnglish() {
        XCTAssertEqual(ForecastQuery(horizon: .tomorrow, focus: .rain).describe, "Rain tomorrow")
        XCTAssertEqual(ForecastQuery(horizon: .week).describe, "The forecast for the next ten days")
    }

    // MARK: Answering it

    /// A muggy summer afternoon: 92°, dew point 74, rain arriving late in the day, ten days ahead.
    private func report(now: Date = Date(timeIntervalSince1970: 1_723_820_400)) -> WeatherReport {
        var cc = CurrentConditions()
        cc.time = Int(now.timeIntervalSince1970)
        cc.conditions = "Partly Cloudy"
        cc.airTemperature = 92
        cc.feelsLike = 101
        cc.dewPoint = 74
        cc.relativeHumidity = 58
        cc.windAvg = 8
        cc.windGust = 17
        cc.windDirectionCardinal = "SSE"
        cc.pressureTrend = "falling"
        cc.seaLevelPressure = 29.92

        let calendar = Calendar(identifier: .gregorian)
        let startOfHour = Int(now.timeIntervalSince1970) - Int(now.timeIntervalSince1970) % 3600

        var hourly: [HourlyForecast] = []
        for step in 0..<48 {
            var h = HourlyForecast()
            let epoch = startOfHour + step * 3600
            h.time = epoch
            h.localHour = calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(epoch)))
            h.localDay = calendar.component(.day, from: Date(timeIntervalSince1970: TimeInterval(epoch)))
            h.airTemperature = 78 + Double((h.localHour ?? 0) % 12)
            h.relativeHumidity = 70
            h.precipProbability = (h.localHour ?? 0) >= 18 ? 60 : 5
            h.precip = (h.localHour ?? 0) >= 18 ? 0.08 : 0
            h.conditions = "Partly Cloudy"
            hourly.append(h)
        }

        var daily: [DailyForecast] = []
        for step in 0..<10 {
            var d = DailyForecast()
            let epoch = startOfHour + step * 86_400
            d.dayStartLocal = epoch
            d.dayNum = calendar.component(.day, from: Date(timeIntervalSince1970: TimeInterval(epoch)))
            d.airTempHigh = 92 + Double(step % 3)
            d.airTempLow = 74
            d.conditions = "Partly Cloudy"
            d.precipProbability = step == 1 ? 70 : 10
            daily.append(d)
        }

        let forecast = BetterForecast(latitude: 30, longitude: -97, timezone: "UTC",
                                      currentConditions: cc,
                                      forecast: Forecast(daily: daily, hourly: hourly))
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!
        return WeatherInterpreter.report(from: forecast, now: now, calendar: utc)
    }

    func testNowLeadsWithTheNumberAndSaysHowItFeels() {
        let text = report().answer(ForecastQuery(horizon: .now))
        XCTAssertTrue(text.contains("92°"), text)
        XCTAssertTrue(text.contains("feels like 101°"), text)   // only because it DISAGREES with the reading
        XCTAssertTrue(text.contains("74°"), text)               // the dew point, which is what decides the day
    }

    func testFocusAnswersOnlyWhatWasAsked() {
        let text = report().answer(ForecastQuery(horizon: .now, focus: .comfort))
        XCTAssertTrue(text.contains("Dew point"), text)
        XCTAssertFalse(text.contains("mph"), text)
    }

    func testTomorrowIsTomorrowNotToday() {
        let text = report().answer(ForecastQuery(horizon: .tomorrow, focus: .rain))
        XCTAssertTrue(text.contains("70%"), text)   // day index 1 carries the 70% chance, today has 10%
    }

    func testWeekIsAListBecauseTheShapeIsTheQuestion() {
        let card = report()
        let lines = card.answer(ForecastQuery(horizon: .week)).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.prefix(10).filter { $0.contains("—") }.count, 10)
        XCTAssertTrue(lines[0].hasPrefix(card.days[0].weekday), lines[0])
    }

    /// SAY WHAT ISN'T THERE. Asked past the end of what was decoded, the answer must be that the
    /// forecast doesn't reach — never today's weather wearing tomorrow's label.
    func testAnswersBeyondTheForecastSaySo() {
        var cc = CurrentConditions()
        cc.airTemperature = 60
        let bare = BetterForecast(currentConditions: cc, forecast: Forecast(daily: [], hourly: []))
        let text = WeatherInterpreter.report(from: bare).answer(ForecastQuery(horizon: .tomorrow))
        XCTAssertTrue(text.contains("doesn't reach"), text)
    }
}
