import XCTest
@testable import WeatherKit

/// The two claims this file makes that nothing else in the app can check:
/// how often it rains in a given month, and how long the dry runs get. Both are
/// easy to get quietly wrong in the direction of "more impressive", which is
/// exactly the direction a weather app must not drift.
final class RainHabitsTests: XCTestCase {

    /// `coverage` is derived from the sample counts, so a "half-watched" day is
    /// made by short-changing the samples rather than by setting a percentage.
    private func record(_ day: String, precip: Double?, seen: Int = 288) -> DailyRecord {
        var r = DailyRecord(day: day, sampleCount: seen, expectedSamples: 288)
        r.precipTotal = precip
        return r
    }

    private func climate(_ records: [DailyRecord]) -> Climatology {
        Climatology(records: records.sorted { $0.day < $1.day })
    }

    // MARK: How often

    func testWetShareCountsOnlyDaysAtOrAboveMeasurable() {
        // 10 days: 3 wet, 1 trace (does not count), 6 dry.
        var days: [DailyRecord] = []
        for i in 1...10 {
            let d = String(format: "2025-10-%02d", i)
            days.append(record(d, precip: i <= 3 ? 0.5 : (i == 4 ? 0.005 : 0.0)))
        }
        let habits = climate(days).rainHabits(asOf: "2025-10-31")
        let october = habits.months.first { $0.month == 10 }
        XCTAssertEqual(october?.wetShare ?? 0, 0.3, accuracy: 0.001)
    }

    /// The share is scaled to the month's real length, because "9 days in
    /// October" is the sentence a person wants and the sample is several
    /// Octobers deep.
    func testWetDaysScalesToTheLengthOfTheMonth() {
        var days: [DailyRecord] = []
        for i in 1...10 {
            days.append(record(String(format: "2025-10-%02d", i), precip: i <= 3 ? 0.5 : 0))
        }
        let october = climate(days).rainHabits(asOf: "2025-10-31").months.first { $0.month == 10 }
        XCTAssertEqual(october?.wetDays ?? 0, 0.3 * 31, accuracy: 0.01)
    }

    /// The whole reason this type exists: the mean over WET days, not over all
    /// days. A month's total spread across its length is a number no day ever
    /// looked like.
    func testMeanOnWetDaysIgnoresTheDryOnes() {
        let days = [record("2025-06-01", precip: 1.0), record("2025-06-02", precip: 2.0),
                    record("2025-06-03", precip: 0.0), record("2025-06-04", precip: 0.0)]
        let june = climate(days).rainHabits(asOf: "2025-06-30").months.first { $0.month == 6 }
        XCTAssertEqual(june?.meanOnWetDays ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(june?.wettestDay ?? 0, 2.0, accuracy: 0.001)
    }

    /// A day the station only half-watched reports a FLOOR. A floor of 0.00 is
    /// indistinguishable from a dry day, so counting it would drag the wet share
    /// down and inflate every dry spell in the record.
    func testUnreliableDaysAreExcludedEntirely() {
        let days = [record("2025-06-01", precip: 0.5),
                    record("2025-06-02", precip: 0.0, seen: 58),
                    record("2025-06-03", precip: 0.5)]
        let june = climate(days).rainHabits(asOf: "2025-06-30").months.first { $0.month == 6 }
        XCTAssertEqual(june?.daysSampled, 2)
        XCTAssertEqual(june?.wetShare ?? 0, 1.0, accuracy: 0.001)
    }

    // MARK: Dry spells

    func testTheLongestDrySpellIsFound() {
        var days: [DailyRecord] = []
        for i in 1...20 {
            let d = String(format: "2025-07-%02d", i)
            days.append(record(d, precip: (i == 5 || i == 18) ? 0.4 : 0.0))
        }
        let habits = climate(days).rainHabits(asOf: "2025-07-31")
        // Days 6–17 is the longest run: 12 days.
        XCTAssertEqual(habits.longestDrySpells.first?.days, 12)
        XCTAssertEqual(habits.longestDrySpells.first?.startDay, "2025-07-06")
        XCTAssertEqual(habits.longestDrySpells.first?.endDay, "2025-07-17")
    }

    /// The one that matters most. Days the station missed are absent from the
    /// record entirely, and treating "no data" as "no rain" is how you end up
    /// reporting a 60-day drought that was two dry weeks either side of an
    /// outage.
    func testAGapInTheArchiveEndsASpellRatherThanExtendingIt() {
        let days = [record("2025-07-01", precip: 0), record("2025-07-02", precip: 0),
                    record("2025-07-03", precip: 0),
                    // 4th–20th missing entirely.
                    record("2025-07-21", precip: 0), record("2025-07-22", precip: 0),
                    record("2025-07-23", precip: 0.5)]
        let spells = climate(days).rainHabits(asOf: "2025-07-31").longestDrySpells
        XCTAssertEqual(spells.first?.days, 3)
        XCTAssertFalse(spells.contains { $0.days > 3 })
    }

    /// A run still going when the record ends is marked open rather than
    /// reported as a finished spell of that length.
    func testARunThatReachesTheEndOfTheRecordIsOpen() {
        let days = [record("2025-07-01", precip: 0.4), record("2025-07-02", precip: 0),
                    record("2025-07-03", precip: 0), record("2025-07-04", precip: 0)]
        let spells = climate(days).rainHabits(asOf: "2025-07-04").longestDrySpells
        XCTAssertEqual(spells.first?.days, 3)
        XCTAssertTrue(spells.first?.isOpen ?? false)
    }

    func testASingleDryDayIsNotASpell() {
        let days = [record("2025-07-01", precip: 0.4), record("2025-07-02", precip: 0),
                    record("2025-07-03", precip: 0.4)]
        XCTAssertTrue(climate(days).rainHabits(asOf: "2025-07-03").longestDrySpells.isEmpty)
    }

    // MARK: Now, and the record

    func testLastRainAndCurrentDryRunAreReported() {
        let days = [record("2025-07-01", precip: 0.8), record("2025-07-02", precip: 0),
                    record("2025-07-03", precip: 0), record("2025-07-04", precip: 0)]
        let habits = climate(days).rainHabits(asOf: "2025-07-04")
        XCTAssertEqual(habits.lastRain?.day, "2025-07-01")
        XCTAssertEqual(habits.lastRain?.amount ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(habits.currentDryDays, 3)
    }

    func testBiggestDaysComeBackWettestFirstAndCapped() {
        let amounts = [0.2, 3.1, 0.9, 2.4, 1.7]
        let days = amounts.enumerated().map {
            record(String(format: "2025-05-%02d", $0.offset + 1), precip: $0.element)
        }
        let biggest = climate(days).rainHabits(asOf: "2025-05-31", topN: 3).biggestDays
        XCTAssertEqual(biggest.count, 3)
        XCTAssertEqual(biggest.map { ($0.amount * 10).rounded() / 10 }, [3.1, 2.4, 1.7])
    }

    func testAThinRecordDoesNotClaimToBeMeaningful() {
        let days = (1...5).map { record(String(format: "2025-05-%02d", $0), precip: 0.1) }
        XCTAssertFalse(climate(days).rainHabits(asOf: "2025-05-31").isMeaningful)
    }
}
