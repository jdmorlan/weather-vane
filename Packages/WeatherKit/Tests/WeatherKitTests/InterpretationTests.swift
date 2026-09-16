import XCTest
@testable import WeatherKit

final class InterpretationTests: XCTestCase {

    // MARK: Dew point comfort language

    func testDewPointLabels() {
        XCTAssertEqual(WeatherInterpreter.dewPointLabel(45), "dry and comfortable")
        XCTAssertEqual(WeatherInterpreter.dewPointLabel(58), "comfortable")
        XCTAssertEqual(WeatherInterpreter.dewPointLabel(67), "humid and muggy")
        XCTAssertEqual(WeatherInterpreter.dewPointLabel(78), "tropical — heavy, sweaty air")
    }

    func testFeelsLikeCalledOutWhenItDiverges() {
        var cc = CurrentConditions()
        cc.dewPoint = 72
        cc.airTemperature = 88
        cc.feelsLike = 98
        let note = WeatherInterpreter.comfortNote(cc)
        XCTAssertTrue(note.text.contains("Feels warmer"), note.text)
        XCTAssertEqual(note.label, "oppressively humid")
    }

    // MARK: The 80% / 0.02" problem

    func testHighChanceTinyAmountIsCalledOut() {
        // Three hours: 80% chance but a trivial 0.02" total.
        let hours = (13...15).map { hour -> HourlyForecast in
            var h = HourlyForecast()
            h.localHour = hour
            h.precipProbability = 80
            h.precip = 0.0066   // ~0.02" total across 3 hours
            return h
        }
        let note = WeatherInterpreter.rainNote(hours)
        XCTAssertTrue(note.willRain)
        XCTAssertEqual(note.peakProbability, 80)
        XCTAssertLessThan(note.totalAccum, 0.03)
        // The insight: high odds, small amount, phrased as "but only about".
        XCTAssertTrue(note.text.contains("but only about"), note.text)
        XCTAssertTrue(note.text.contains("1pm–4pm"), note.text)
    }

    func testNoRainWhenDry() {
        let hours = (9...17).map { hour -> HourlyForecast in
            var h = HourlyForecast()
            h.localHour = hour
            h.precipProbability = 5
            h.precip = 0
            return h
        }
        let note = WeatherInterpreter.rainNote(hours)
        XCTAssertFalse(note.willRain)
        XCTAssertTrue(note.text.contains("No rain"), note.text)
    }

    func testTwoSeparateRainWindows() {
        var hours: [HourlyForecast] = []
        for hour in 6...20 {
            var h = HourlyForecast()
            h.localHour = hour
            // wet morning (7-9) and wet evening (17-19), dry midday
            let wet = (7...9).contains(hour) || (17...19).contains(hour)
            h.precipProbability = wet ? 70 : 5
            h.precip = wet ? 0.1 : 0
            hours.append(h)
        }
        let note = WeatherInterpreter.rainNote(hours)
        XCTAssertEqual(note.windows.count, 2)
        XCTAssertTrue(note.text.contains("A few rounds"), note.text)
    }

    // MARK: Wind

    func testCalmWind() {
        let hours = (9...17).map { hour -> HourlyForecast in
            var h = HourlyForecast(); h.localHour = hour; h.windAvg = 4; h.windGust = 7; return h
        }
        let note = WeatherInterpreter.windNote(hours, current: CurrentConditions())
        XCTAssertTrue(note.text.contains("light"), note.text)
    }

    func testGustyAfternoonNamesTheHour() {
        var hours: [HourlyForecast] = []
        for hour in 9...17 {
            var h = HourlyForecast(); h.localHour = hour
            h.windAvg = 12
            h.windGust = hour == 15 ? 28 : 15
            hours.append(h)
        }
        let note = WeatherInterpreter.windNote(hours, current: CurrentConditions())
        XCTAssertEqual(note.peakGustHour, 15)
        XCTAssertTrue(note.text.contains("3pm"), note.text)
        XCTAssertTrue(note.text.contains("gusting"), note.text)
    }

    // MARK: Pressure clue

    func testFallingPressureFastFlagsStorm() {
        var cc = CurrentConditions()
        cc.pressureTrend = "falling"
        cc.seaLevelPressure = 30.00
        var future: [HourlyForecast] = []
        for i in 0...4 {
            var h = HourlyForecast(); h.time = i * 3600
            h.seaLevelPressure = 30.00 - Double(i) * 0.02   // -0.06 over 3h
            future.append(h)
        }
        let note = WeatherInterpreter.pressureNote(cc, future: future)
        XCTAssertEqual(note.trend, "falling")
        XCTAssertTrue(note.stormWatch)
        XCTAssertTrue(note.text.contains("falling"), note.text)
        XCTAssertTrue(note.text.contains("storm"), note.text)
    }

    func testRisingPressureSettles() {
        var cc = CurrentConditions()
        cc.pressureTrend = "rising"
        cc.seaLevelPressure = 29.9
        let note = WeatherInterpreter.pressureNote(cc, future: [])
        XCTAssertFalse(note.stormWatch)
        XCTAssertTrue(note.text.contains("clear") || note.text.contains("settle"), note.text)
    }

    // MARK: Dew point estimation (Magnus)

    func testDewPointMatchesKnownValues() {
        // 90°F / 50% RH ≈ 69°F dew point; 95°F / 40% ≈ 67°F. Allow a small tolerance.
        XCTAssertEqual(WeatherInterpreter.dewPointF(tempF: 90, humidity: 50), 69, accuracy: 2)
        XCTAssertEqual(WeatherInterpreter.dewPointF(tempF: 95, humidity: 40), 67, accuracy: 2)
        // Saturated air: dew point ≈ the temperature.
        XCTAssertEqual(WeatherInterpreter.dewPointF(tempF: 75, humidity: 100), 75, accuracy: 1)
    }

    func testDewComfortTags() {
        XCTAssertEqual(WeatherInterpreter.dewComfortTag(50), "Dry")
        XCTAssertEqual(WeatherInterpreter.dewComfortTag(67), "Muggy")
        XCTAssertEqual(WeatherInterpreter.dewComfortTag(73), "Oppressive")
    }

    func testWeekComfortFlagsAnOppressiveStretch() {
        // Build 6 days all with high dew points via hourly temp+humidity.
        var forecast = BetterForecast()
        var daily: [DailyForecast] = []
        var hourly: [HourlyForecast] = []
        for day in 20...25 {
            var d = DailyForecast()
            d.dayNum = day
            d.dayStartLocal = 1_600_000_000 + day * 86_400
            daily.append(d)
            // A muggy afternoon hour: 92°F, 65% RH → dew point ~78°F.
            var h = HourlyForecast()
            h.localDay = day; h.localHour = 15; h.airTemperature = 92; h.relativeHumidity = 65
            hourly.append(h)
        }
        forecast.forecast = Forecast(daily: daily, hourly: hourly)
        let report = WeatherInterpreter.report(from: forecast)
        XCTAssertNotNil(report.weekComfort)
        XCTAssertTrue(report.weekComfort!.lowercased().contains("oppressive"), report.weekComfort ?? "")
        // Each day carries an estimated dew point + tag.
        XCTAssertTrue(report.days.allSatisfy { ($0.dewPoint ?? 0) > 70 })
        XCTAssertEqual(report.days.first?.comfortTag, "Oppressive")
    }

    // MARK: Day parts — the fidelity a single daily verdict throws away

    /// The day the whole feature exists for: sticky at dawn, oppressive by mid-morning,
    /// then the dew point falls out while the temperature peaks. One tag can't say that.
    private func muggyMorningDryAfternoon() -> [HourlyForecast] {
        // (hour, temp, RH) → morning dew ~73°, afternoon dew ~62°.
        let profile: [(Int, Double, Double)] = [
            (3, 74, 92), (5, 73, 95),
            (7, 78, 85), (9, 84, 70), (11, 89, 58),
            (13, 93, 40), (15, 95, 33), (17, 93, 36),
            (19, 86, 45), (21, 80, 55), (23, 76, 62),
        ]
        return profile.map { hour, temp, rh in
            var h = HourlyForecast()
            h.localDay = 20
            h.localHour = hour
            h.airTemperature = temp
            h.relativeHumidity = rh
            return h
        }
    }

    func testDayPartsSplitTheDayByComfort() {
        let parts = WeatherInterpreter.dayParts(muggyMorningDryAfternoon())
        XCTAssertEqual(parts.map(\.name), ["Overnight", "Morning", "Afternoon", "Evening"])

        let morning = parts.first { $0.name == "Morning" }!
        let afternoon = parts.first { $0.name == "Afternoon" }!
        // The morning is the muggy part; the afternoon is the HOT part but a drier one.
        XCTAssertGreaterThan(morning.dewPoint!, 70)
        XCTAssertLessThan(afternoon.dewPoint!, 68)
        XCTAssertGreaterThan(afternoon.high!, morning.high!)
        XCTAssertEqual(morning.comfortTag, "Oppressive")
        XCTAssertNotEqual(afternoon.comfortTag, "Oppressive")
    }

    func testEmptyStretchesAreDroppedSoTodayShrinks() {
        // Only evening hours left → only an evening part.
        let evening = muggyMorningDryAfternoon().filter { ($0.localHour ?? 0) >= 18 }
        XCTAssertEqual(WeatherInterpreter.dayParts(evening).map(\.name), ["Evening"])
    }

    func testDayShapeNamesTheMuggyPartAndTheHotPart() {
        let shape = WeatherInterpreter.dayShape(WeatherInterpreter.dayParts(muggyMorningDryAfternoon()))
        XCTAssertTrue(shape.contains("morning"), shape)
        XCTAssertTrue(shape.contains("easing to"), shape)
        XCTAssertTrue(shape.lowercased().contains("afternoon is the hot one"), shape)
    }

    func testFlatDayHasNoShapeSentence() {
        // Same dew point all day — claiming it changes would be a lie.
        let hours = [2, 8, 14, 20].map { hour -> HourlyForecast in
            var h = HourlyForecast()
            h.localDay = 20; h.localHour = hour
            h.airTemperature = 85; h.relativeHumidity = 65
            return h
        }
        XCTAssertEqual(WeatherInterpreter.dayShape(WeatherInterpreter.dayParts(hours)), "")
    }

    func testWeekSummarySaysWhenAHumidWeekBreaks() {
        var forecast = BetterForecast()
        var daily: [DailyForecast] = []
        var hourly: [HourlyForecast] = []
        for day in 20...25 {
            var d = DailyForecast()
            d.dayNum = day
            d.dayStartLocal = 1_600_000_000 + day * 86_400
            daily.append(d)
            for var h in muggyMorningDryAfternoon() {
                h.localDay = day
                hourly.append(h)
            }
        }
        forecast.forecast = Forecast(daily: daily, hourly: hourly)
        let report = WeatherInterpreter.report(from: forecast)

        // Still an oppressive-peaking week, but reported as one that lets go — not as
        // six identical "Oppressive" days.
        XCTAssertNotNil(report.weekComfort)
        XCTAssertTrue(report.weekComfort!.contains("lets go"), report.weekComfort!)
        let today = report.days.first!
        XCTAssertGreaterThan(today.dewPointHigh! - today.dewPointLow!, 8)
        XCTAssertEqual(today.parts.count, 4)
        XCTAssertFalse(today.shape.isEmpty)
    }

    // MARK: Clock formatting

    func testClockLabels() {
        XCTAssertEqual(WeatherInterpreter.clock(0), "12am")
        XCTAssertEqual(WeatherInterpreter.clock(12), "noon")
        XCTAssertEqual(WeatherInterpreter.clock(9), "9am")
        XCTAssertEqual(WeatherInterpreter.clock(15), "3pm")
        XCTAssertEqual(WeatherInterpreter.clock(23), "11pm")
    }

    // MARK: End-to-end assembly

    func testReportHeadlinePrefersRain() {
        var forecast = BetterForecast()
        var cc = CurrentConditions()
        cc.airTemperature = 60; cc.dewPoint = 55; cc.conditions = "Rain Likely"
        cc.pressureTrend = "falling"; cc.seaLevelPressure = 29.9
        forecast.currentConditions = cc

        var hours: [HourlyForecast] = []
        let base = 1_600_000_000
        for i in 0...6 {
            var h = HourlyForecast()
            h.time = base + i * 3600
            h.localDay = 1
            h.localHour = 13 + i
            h.precipProbability = 80
            h.precip = 0.1      // real accumulation → jacket headline
            h.airTemperature = 60
            hours.append(h)
        }
        forecast.forecast = Forecast(daily: [], hourly: hours)

        let report = WeatherInterpreter.report(from: forecast,
                                               now: Date(timeIntervalSince1970: TimeInterval(base)))
        XCTAssertTrue(report.rain.willRain)
        XCTAssertTrue(report.headline.contains("jacket"), report.headline)
        XCTAssertFalse(report.hours.isEmpty)
    }
}
