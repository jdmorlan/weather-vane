import XCTest
@testable import WeatherKit

/// The archive speaking first. The tests that matter here are the ones keeping
/// it honest and keeping it useful — two pressures that pull opposite ways.
final class NotableTests: XCTestCase {

    private func day(_ key: String, high: Double? = nil, low: Double? = nil,
                     rain: Double? = nil, samples: Int = 48) -> DailyRecord {
        var record = DailyRecord(day: key, sampleCount: samples, expectedSamples: 48)
        record.tempMax = high
        record.tempMin = low
        record.dewPointMean = (high ?? 70) - 25
        record.dewPointMax = (high ?? 70) - 20
        record.precipTotal = rain
        record.schemaVersion = DailyRecord.currentSchemaVersion
        return record
    }

    /// Four years where June–August is hot, plus a given year's own shape.
    private func summers(_ years: ClosedRange<Int>,
                         through end: String? = nil,
                         hot: @escaping (Int, Int) -> Bool = { month, _ in (6...8).contains(month) })
        -> [DailyRecord] {
        years.flatMap { year -> [DailyRecord] in
            var records: [DailyRecord] = []
            var cursor = "\(year)-01-01"
            let last = end.flatMap { $0.hasPrefix("\(year)") ? $0 : nil } ?? "\(year)-12-31"
            while cursor <= last {
                let month = Int(cursor.dropFirst(5).prefix(2)) ?? 1
                let isHot = hot(month, year)
                records.append(day(cursor, high: isHot ? 101 : 70, low: isHot ? 78 : 50))
                guard let next = DayKey.next(cursor) else { break }
                cursor = next
            }
            return records
        }
    }

    // MARK: Honesty

    /// THE bug real data found. Asked about a date past the end of the record,
    /// the pace probe reported "only 0 days of rain so far, usually 15" — the
    /// absence of DATA read as a fact about the weather. A closed laptop is
    /// enough to trigger it, so it has to be impossible by construction.
    func testAStaleArchiveInventsNothing() {
        let climate = Climatology(records: summers(2021...2024))
        // The record ends in 2024; ask as though it were well into 2026.
        let notices = climate.notable(asOf: "2026-06-15")

        for notice in notices {
            XCTAssertNotEqual(notice.kind, .pace,
                              "a pace claim past the end of the record is a claim about missing data")
            XCTAssertNotEqual(notice.kind, .overdue,
                              "nothing can be overdue in a year the archive has never seen")
        }
    }

    /// The same guard within a year the record only half-watched.
    func testAYearWithAGapMakesNoPaceClaim() {
        var records = summers(2021...2024)
        records.removeAll { $0.day >= "2024-02-01" && $0.day < "2024-06-01" }
        let notices = Climatology(records: records).notable(asOf: "2024-07-01")

        XCTAssertFalse(notices.contains { $0.kind == .pace },
                       "four missing months can't be read as a quiet season")
    }

    func testAThinArchiveSaysNothingAtAll() {
        let climate = Climatology(records: summers(2023...2023))
        XCTAssertTrue(climate.notable(asOf: "2023-07-15").isEmpty)
    }

    // MARK: Usefulness

    /// The opposite pressure. Checked against the real archive, an ordinary
    /// August week produced exactly ONE anomaly — about wind. A surface that's
    /// empty most weeks is a surface nobody opens, so seasonal position fills
    /// the quiet stretches.
    func testAnOrdinaryWeekStillHasSomethingToSay() {
        let notices = Climatology(records: summers(2021...2024)).notable(asOf: "2024-07-15")
        XCTAssertFalse(notices.isEmpty, "high summer should at least know it's high summer")
    }

    /// …but position never outranks news, and never fills the whole list.
    func testRealNewsOutranksSeasonalPosition() {
        // 2024's summer runs hot far longer than any before it.
        let records = summers(2021...2024, through: "2024-08-20") { month, year in
            year == 2024 ? (4...8).contains(month) : (6...8).contains(month)
        }
        let notices = Climatology(records: records).notable(asOf: "2024-08-21")

        guard let top = notices.first else { return XCTFail("expected something") }
        XCTAssertNotEqual(top.kind, .position, "an unusual year should lead over the calendar")
        XCTAssertLessThanOrEqual(notices.filter { $0.kind == .position }.count, 3)
    }

    /// A notice has to be openable, or it's a claim you can only take on faith.
    func testEveryQueryBackedNoticeCarriesARunnableQuery() {
        let climate = Climatology(records: summers(2021...2024))
        for notice in climate.notable(asOf: "2024-07-15", floor: 0) {
            guard let query = notice.query else { continue }
            XCTAssertFalse(climate.run(query).days.isEmpty,
                           "\(notice.headline) opens onto nothing")
        }
    }

    /// Ranking is only meaningful if the probes score on one scale.
    func testScoresShareOneScaleAndTheListIsRanked() {
        let notices = Climatology(records: summers(2021...2024)).notable(asOf: "2024-07-15", floor: 0)
        XCTAssertEqual(notices.map(\.score), notices.map(\.score).sorted(by: >))
        for notice in notices {
            XCTAssertTrue((0...1).contains(notice.score), "\(notice.headline) scored \(notice.score)")
        }
    }

    /// One question shouldn't get to say the same thing three ways.
    func testOneNoticePerQuestion() {
        let notices = Climatology(records: summers(2021...2024)).notable(asOf: "2024-07-15", floor: 0)
        let named = notices.compactMap { $0.query?.name }
        XCTAssertEqual(named.count, Set(named).count)
    }

    /// A name someone typed for a chip can't be relied on to decline as a noun.
    /// Folded into a sentence it produced "0 days of days it rained".
    func testHeadlinesReadAsEnglish() {
        let notices = Climatology(records: summers(2021...2024)).notable(asOf: "2024-07-15", floor: 0)
        for notice in notices {
            XCTAssertFalse(notice.headline.contains("days of days"), notice.headline)
            XCTAssertFalse(notice.headline.contains("1 days"), notice.headline)
            XCTAssertFalse(notice.headline.contains(" of the shop"), notice.headline)
        }
    }
}
