import XCTest
@testable import WeatherKit

final class DayWindowTests: XCTestCase {

    private let fields = ["timestamp", "wind_avg", "air_temp", "rh", "solar_radiation"]

    private var chicago: TimeZone { TimeZone(identifier: "America/Chicago")! }

    /// Half-hourly rows across `hours` local hours of one day.
    private func day(_ key: String, from startHour: Int, to endHour: Int,
                     temp: (Int) -> Double, rh: Double = 60,
                     every minutes: Int = 30) -> [[Double?]] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago
        let start = DayKey.date(from: key, timeZone: chicago)!
        var rows: [[Double?]] = []
        var minute = startHour * 60
        while minute < endHour * 60 {
            let ts = start.timeIntervalSince1970 + Double(minute * 60)
            rows.append([ts, 4, temp(minute), rh, 100])
            minute += minutes
        }
        return rows
    }

    private func observations(_ rows: [[Double?]]) -> StationObservations {
        StationObservations(stationID: 1, timezone: "America/Chicago", obFields: fields, obs: rows)
    }

    // MARK: Slicing

    func testKeepsOnlySamplesInsideTheWindow() {
        let obs = observations(day("2026-08-08", from: 0, to: 24, temp: { _ in 80 }))
        let sliced = DayWindows.slice(obs, window: .morning, timeZone: chicago)

        XCTAssertEqual(sliced.count, 1)
        // 6am–10am at 30-minute samples is 8 readings, not the day's 48.
        XCTAssertEqual(sliced[0].samples.count, 8)
        XCTAssertEqual(sliced[0].samples.first?.minuteOfDay, 6 * 60)
        XCTAssertEqual(sliced[0].samples.last?.minuteOfDay, 9 * 60 + 30)
        XCTAssertEqual(sliced[0].coverage, 1, accuracy: 0.001)
    }

    func testGroupsByStationDayAndSortsByClock() {
        var rows = day("2026-08-08", from: 6, to: 10, temp: { _ in 70 })
        rows.append(contentsOf: day("2026-08-09", from: 6, to: 10, temp: { _ in 75 }))
        let sliced = DayWindows.slice(observations(rows.shuffled()), timeZone: chicago)

        XCTAssertEqual(sliced.map(\.day), ["2026-08-08", "2026-08-09"])
        XCTAssertEqual(sliced[0].samples.map(\.minuteOfDay),
                       sliced[0].samples.map(\.minuteOfDay).sorted())
    }

    /// Expected count comes from the window and the bucket, never from the rows —
    /// counting the rows would make every window 100% covered by definition.
    func testPartialWindowReadsAsPartial() {
        // Station only reported 6:00–7:30: four of the eight readings.
        let obs = observations(day("2026-08-08", from: 6, to: 8, temp: { _ in 68 }))
        let sliced = DayWindows.slice(obs, window: .morning, timeZone: chicago)

        XCTAssertEqual(sliced[0].samples.count, 4)
        XCTAssertEqual(sliced[0].expectedSamples, 8)
        XCTAssertEqual(sliced[0].coverage, 0.5, accuracy: 0.001)
        XCTAssertFalse(sliced[0].isReliable)
    }

    func testDerivesDewPointFromTempAndHumidity() {
        let obs = observations(day("2026-08-08", from: 6, to: 10, temp: { _ in 80 }, rh: 50))
        let sliced = DayWindows.slice(obs, timeZone: chicago)
        let dew = try? XCTUnwrap(sliced[0].samples.first?.dewPoint)

        // ~60°F for 80°/50%; the point is that it's derived at all, not the digit.
        XCTAssertEqual(dew ?? 0, 60, accuracy: 1.5)
        XCTAssertEqual(sliced[0].mean(\.temp), 80)
    }

    /// The window is a parameter. Nothing in here knows morning is special.
    func testAfternoonWindowIsTheSameEngine() {
        let obs = observations(day("2026-08-08", from: 0, to: 24, temp: { minute in
            minute < 12 * 60 ? 70 : 95
        }))
        let morning = DayWindows.slice(obs, window: .morning, timeZone: chicago)
        let afternoon = DayWindows.slice(obs, window: .afternoon, timeZone: chicago)

        XCTAssertEqual(morning[0].mean(\.temp), 70)
        XCTAssertEqual(afternoon[0].mean(\.temp), 95)
    }

    func testRecentTakesTheLatestDays() {
        let rows = (8...17).flatMap { d in
            day(String(format: "2026-08-%02d", d), from: 6, to: 10, temp: { _ in 70 })
        }
        let sliced = DayWindows.slice(observations(rows), timeZone: chicago)
        let recent = DayWindows.recent(sliced, count: 3)

        XCTAssertEqual(recent.map(\.day), ["2026-08-15", "2026-08-16", "2026-08-17"])
    }

    // MARK: Standing apart

    func testStandoutFindsTheCoolMorning() {
        var rows: [[Double?]] = []
        for d in 8...14 { rows += day(String(format: "2026-08-%02d", d), from: 6, to: 10, temp: { _ in 78 }) }
        rows += day("2026-08-15", from: 6, to: 10, temp: { _ in 66 })
        let sliced = DayWindows.slice(observations(rows), timeZone: chicago)

        let s = DayWindows.standout(sliced, day: "2026-08-15", measure: \.temp, measureName: "temp")
        XCTAssertEqual(s?.value, 66)
        XCTAssertEqual(s?.othersMean, 78)
        XCTAssertEqual(s?.difference ?? 0, -12, accuracy: 0.001)
        XCTAssertEqual(s?.daysCompared, 7)
    }

    /// With every other morning identical the spread is zero, so "how many
    /// standard deviations out" has no answer — and we'd rather say nothing than
    /// divide by it.
    func testNoSpreadMeansNoZScore() {
        var rows: [[Double?]] = []
        for d in 8...14 { rows += day(String(format: "2026-08-%02d", d), from: 6, to: 10, temp: { _ in 78 }) }
        rows += day("2026-08-15", from: 6, to: 10, temp: { _ in 66 })
        let sliced = DayWindows.slice(observations(rows), timeZone: chicago)

        let s = DayWindows.standout(sliced, day: "2026-08-15", measure: \.temp, measureName: "temp")
        XCTAssertNil(s?.zScore)
        XCTAssertFalse(s?.isStandout ?? true)
    }

    /// The honest answer is usually "no". A day inside the ordinary spread must
    /// not be reported as standing apart.
    func testOrdinaryDayDoesNotStandOut() {
        var rows: [[Double?]] = []
        let temps: [Double] = [74, 78, 71, 80, 76, 73, 79]
        for (i, t) in temps.enumerated() {
            rows += day(String(format: "2026-08-%02d", 8 + i), from: 6, to: 10, temp: { _ in t })
        }
        rows += day("2026-08-15", from: 6, to: 10, temp: { _ in 76 })
        let sliced = DayWindows.slice(observations(rows), timeZone: chicago)

        let s = DayWindows.standout(sliced, day: "2026-08-15", measure: \.temp, measureName: "temp")
        XCTAssertNotNil(s?.zScore)
        XCTAssertFalse(s?.isStandout ?? true)
    }

    /// A half-seen morning's mean is whichever half-hours happened to record, so
    /// it can neither set the baseline nor be the subject.
    func testThinWindowsAreExcludedFromTheComparison() {
        var rows: [[Double?]] = []
        for d in 8...13 { rows += day(String(format: "2026-08-%02d", d), from: 6, to: 10, temp: { _ in 78 }) }
        // A morning the station only saw the first hour of — and only the cool part.
        rows += day("2026-08-14", from: 6, to: 7, temp: { _ in 55 })
        rows += day("2026-08-15", from: 6, to: 10, temp: { _ in 66 })
        let sliced = DayWindows.slice(observations(rows), timeZone: chicago)

        let s = DayWindows.standout(sliced, day: "2026-08-15", measure: \.temp, measureName: "temp")
        XCTAssertEqual(s?.othersMean, 78)     // the 55° fragment never enters the baseline
        XCTAssertEqual(s?.daysCompared, 6)

        XCTAssertNil(DayWindows.standout(sliced, day: "2026-08-14",
                                         measure: \.temp, measureName: "temp"))
    }
}
