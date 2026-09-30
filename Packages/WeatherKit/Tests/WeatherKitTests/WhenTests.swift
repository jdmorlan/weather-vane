import XCTest
@testable import WeatherKit

final class WhenTests: XCTestCase {

    private var central: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// 2026-09-30 01:00 CDT — the "reading it at 1 AM" case.
    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: Days

    func testLastEveningReadAtOneInTheMorningSaysYesterday() {
        let now = date("2026-09-30T06:00:00Z")          // 1 AM CDT
        let sixPM = date("2026-09-29T23:00:00Z")        // 6 PM CDT the day before
        XCTAssertEqual(When.moment(sixPM, now: now, calendar: central), "yesterday 6 PM")
    }

    func testTodayTomorrowAndTheComingWeek() {
        let now = date("2026-09-30T15:00:00Z")          // Wed 10 AM CDT
        XCTAssertEqual(When.moment(date("2026-09-30T20:30:00Z"), now: now, calendar: central), "today 3:30 PM")
        XCTAssertEqual(When.moment(date("2026-10-01T12:00:00Z"), now: now, calendar: central), "tomorrow 7 AM")
        XCTAssertEqual(When.moment(date("2026-10-02T12:00:00Z"), now: now, calendar: central), "Fri 7 AM")
    }

    /// Backwards, a weekday is ambiguous — this Monday or last? — so it's a date.
    func testOlderPastIsADateNotAWeekday() {
        let now = date("2026-09-30T15:00:00Z")
        XCTAssertEqual(When.moment(date("2026-09-27T23:00:00Z"), now: now, calendar: central), "Sep 27, 6 PM")
    }

    // MARK: The flood watch

    /// The bug that prompted all this: a watch running into the next day must
    /// never print as a same-day window.
    func testMultiDayWatchNamesBothDays() {
        let now = date("2026-09-30T15:00:00Z")          // 10 AM CDT
        let watch = Hazard(id: "w", event: "Flood Watch", kind: .classify(event: "Flood Watch"),
                           tier: .watch, resolution: .zone, level: 0.5,
                           onset: date("2026-09-30T18:00:00Z"),       // 1 PM today
                           expires: date("2026-10-01T12:00:00Z"))     // 7 AM tomorrow
        XCTAssertEqual(watch.timing(now: now, calendar: central), "today 1 PM – tomorrow 7 AM")
    }

    func testUnderwayWatchSaysUntilWithItsDay() {
        let now = date("2026-09-30T15:00:00Z")
        let watch = Hazard(id: "w", event: "Flood Watch", kind: .classify(event: "Flood Watch"),
                           tier: .watch, resolution: .zone, level: 0.5,
                           onset: date("2026-09-30T13:00:00Z"),
                           expires: date("2026-10-02T06:00:00Z"))     // 1 AM Fri
        XCTAssertEqual(watch.timing(now: now, calendar: central), "until Fri 1 AM")
    }

    /// NWS's `expires` on a long watch is the next statement, not the end.
    func testStatementExpiryIsKeptApartFromTheEnd() throws {
        let json = """
        {"features":[{"id":"x","properties":{"id":"x","event":"Flood Watch","status":"Actual",
          "messageType":"Update","sent":"2026-09-30T08:23:00-05:00","onset":"2026-09-30T13:00:00-05:00",
          "expires":"2026-09-30T16:30:00-05:00","ends":"2026-10-01T07:00:00-05:00",
          "senderName":"NWS Midland/Odessa TX"}}]}
        """
        let feed = try JSONDecoder().decode(NWSAlertFeed.self, from: Data(json.utf8))
        let hazard = try XCTUnwrap(HazardParser.hazards(from: feed, at: GeoPoint(latitude: 31, longitude: -102)).first)
        XCTAssertEqual(hazard.expires, date("2026-10-01T12:00:00Z"))
        XCTAssertEqual(hazard.nextStatement, date("2026-09-30T21:30:00Z"))
        XCTAssertEqual(hazard.sent, date("2026-09-30T13:23:00Z"))
    }

    // MARK: Schedules

    func testSPCDayOneNextIssuance() {
        let issued = date("2026-09-30T12:55:00Z")       // the 1300Z outlook, a touch early
        XCTAssertEqual(IssueSchedule.spc(day: 1).next(afterIssue: issued), date("2026-09-30T16:30:00Z"))
    }

    /// Day 2's early issuance is fixed at 1 AM CENTRAL, so it moves in UTC
    /// with daylight saving.
    func testSPCDayTwoFollowsCentralTime() {
        XCTAssertEqual(IssueSchedule.spc(day: 2).next(after: date("2026-09-30T00:00:00Z")),
                       date("2026-09-30T06:00:00Z"))    // CDT
        XCTAssertEqual(IssueSchedule.spc(day: 2).next(after: date("2026-12-01T00:00:00Z")),
                       date("2026-12-01T07:00:00Z"))    // CST
    }

    /// WPC stamped its 0830Z outlook 0756Z; that copy must not announce
    /// itself as still to come.
    func testEarlyIssueCountsAsItsSlot() {
        XCTAssertEqual(IssueSchedule.wpcExcessiveRain(day: 1).next(afterIssue: date("2026-09-30T07:56:00Z")),
                       date("2026-09-30T16:00:00Z"))
    }

    // MARK: Model runs

    func testModelRunNextIsArrivalPlusCadence() {
        let run = ModelRun(initialised: date("2026-09-30T13:00:00Z"),
                           available: date("2026-09-30T14:45:00Z"), interval: 3600)
        let stamp = run.stamp(source: "HRRR", now: date("2026-09-30T15:30:00Z"))
        XCTAssertEqual(stamp.made, .run(date("2026-09-30T13:00:00Z")))
        XCTAssertEqual(stamp.next, date("2026-09-30T15:45:00Z"))
    }

    /// GEM's metadata said 26 May on 30 September; that is not the run behind
    /// a forecast reaching into October, so no date is printed.
    func testImplausiblyOldRunIsNotPublished() {
        let run = ModelRun(initialised: date("2026-05-26T00:00:00Z"),
                           available: date("2026-07-01T10:46:00Z"), interval: 12 * 3600)
        XCTAssertEqual(run.stamp(source: "GEM", now: date("2026-09-30T15:30:00Z")).made, .unpublished)
    }

    func testDecodesOpenMeteoMeta() throws {
        let json = #"{"last_run_initialisation_time":1790744400,"last_run_availability_time":1790750700,"update_interval_seconds":3600,"crs_wkt":"x\ny"}"#
        let run = try ModelRunClient.decode(Data(json.utf8))
        XCTAssertEqual(run.interval, 3600)
        XCTAssertEqual(run.available.timeIntervalSince(run.initialised), 6300)
    }
}
