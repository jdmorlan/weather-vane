import XCTest
@testable import WeatherKit

/// History's story: what one stretch did, named by mechanism.
final class StretchStoryTests: XCTestCase {

    private func day(_ key: String, high: Double = 85, low: Double = 70, dew: Double = 68,
                     pressure: Double = 30.0, rain: Double = 0, strikes: Int = 0,
                     coverage: Double = 1) -> DailyRecord {
        var r = DailyRecord(day: key, sampleCount: Int(48 * coverage), expectedSamples: 48)
        r.tempMax = high; r.tempMin = low
        r.dewPointMean = dew; r.pressureMean = pressure
        r.precipTotal = rain; r.strikeCount = strikes
        return r
    }

    private func october(_ edits: [Int: DailyRecord] = [:]) -> [DailyRecord] {
        (1...31).map { d in edits[d] ?? day(String(format: "2023-10-%02d", d)) }
    }

    private let october2023 = WeatherPeriod.month(containing: "2023-10-15")

    /// Oct 28–30, 2023 in miniature: the drop spread over two days, the middle
    /// one barely watched. It's still one front.
    func testAFrontAcrossPartlyWatchedDaysIsOneFront() {
        let climate = Climatology(records: october([
            28: day("2023-10-28", high: 66, dew: 61, pressure: 30.06, coverage: 0.9),
            29: day("2023-10-29", high: 43, dew: 41, pressure: 30.14, coverage: 0.21),
            30: day("2023-10-30", high: 47, dew: 30, pressure: 30.33, coverage: 0.58),
            31: day("2023-10-31", high: 57, dew: 30, pressure: 30.40),
        ]))
        let story = climate.story(october2023, year: 2023, title: "October 2023")!
        XCTAssertEqual(story.fronts.count, 1)
        XCTAssertEqual(story.fronts.first?.day, "2023-10-28")
        XCTAssertEqual(story.fronts.first?.end, "2023-10-30")
        XCTAssertEqual(story.fronts.first?.detail.hasPrefix("Dew point fell 68° → 30° and pressure rose 0.33 inHg"), true,
                       story.fronts.first?.detail ?? "nil")
    }

    /// Dew point falling on its own — an afternoon mixing dry — isn't a front.
    func testADewDropWithoutAPressureRiseIsNotAFront() {
        let climate = Climatology(records: october([
            10: day("2023-10-10", dew: 56, pressure: 29.98),
        ]))
        XCTAssertTrue(climate.story(october2023, year: 2023, title: "October 2023")!.fronts.isEmpty)
    }

    /// The impostor: highs crash under a storm, the dew point holds.
    func testAStormCooledDayIsCalledRainCooledNotAFront() {
        let climate = Climatology(records: october([
            12: day("2023-10-12", high: 95),
            13: day("2023-10-13", high: 83, dew: 69, rain: 1.61, strikes: 1878),
        ]))
        let story = climate.story(october2023, year: 2023, title: "October 2023")!
        XCTAssertTrue(story.fronts.isEmpty)
        let rain = story.events.first { $0.kind == .rain }
        XCTAssertEqual(rain?.title, "1.61″ of rain")
        XCTAssertEqual(rain?.detail.contains("rain-cooled air, not a front"), true, rain?.detail ?? "nil")
        XCTAssertEqual(rain?.detail.contains("1,878 lightning strikes"), true)
    }

    func testTheSentenceNamesFrontsAndWhereTheRainWent() {
        let climate = Climatology(records: october([
            5: day("2023-10-05", dew: 50, pressure: 30.2),
            18: day("2023-10-18", rain: 1.2),
            19: day("2023-10-19", rain: 0.8),
            25: day("2023-10-25", rain: 0.3),
        ]))
        let text = climate.story(october2023, year: 2023, title: "October 2023")!.sentence()
        XCTAssertEqual(text, "October 2023 ran about normal. One front came through, on Oct 5. 2.30″ of rain fell, most of it Oct 18–19.")
    }

    func testThreeWarmDaysMakeASpell() {
        // Normals come from the record itself, so warm days are warm against
        // the rest of the month.
        var edits: [Int: DailyRecord] = [:]
        for d in 10...13 { edits[d] = day(String(format: "2023-10-%02d", d), high: 97) }
        let story = Climatology(records: october(edits)).story(october2023, year: 2023, title: "October 2023")!
        let spell = story.events.first { $0.kind == .warmSpell }
        XCTAssertEqual(spell?.day, "2023-10-10")
        XCTAssertEqual(spell?.title, "4 days warm in a row")
    }

    /// A warm month's ordinary warm days aren't a spell — September 2026 was
    /// above normal nearly every day, and "4 days warm in a row" said nothing.
    func testAWarmMonthHasNoWarmSpellUnlessItStandsOutFromTheMonth() {
        // Normals come from the record, so build two Octobers: 2022 at 85°,
        // 2023 warm throughout (91°) with a 4-day run at 93°.
        let base = (1...31).map { day(String(format: "2022-10-%02d", $0), high: 85) }
        var warm = (1...31).map { day(String(format: "2023-10-%02d", $0), high: 91) }
        for d in 10...13 { warm[d - 1] = day(String(format: "2023-10-%02d", d), high: 93) }
        let story = Climatology(records: base + warm).story(october2023, year: 2023, title: "October 2023")!
        XCTAssertFalse(story.events.contains { $0.kind == .warmSpell })
    }

    func testSpansReadAsPeopleWriteThem() {
        XCTAssertEqual(StretchStory.span("2023-10-27", "2023-10-28"), "Oct 27–28")
        XCTAssertEqual(StretchStory.span("2023-09-30", "2023-10-02"), "Sep 30–Oct 2")
        XCTAssertEqual(StretchStory.span("2023-10-05", nil), "Oct 5")
    }
}
