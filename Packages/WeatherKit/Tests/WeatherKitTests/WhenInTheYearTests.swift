import XCTest
@testable import WeatherKit

/// The question as a place in the year. Mostly about which kind of answer a
/// question gets, and that the dates read off the curve land where the weather
/// put them.
final class WhenInTheYearTests: XCTestCase {

    // MARK: Fixtures

    private func day(_ key: String, high: Double? = nil, low: Double? = nil,
                     rain: Double? = nil, samples: Int = 48) -> DailyRecord {
        var record = DailyRecord(day: key, sampleCount: samples, expectedSamples: 48)
        record.tempMax = high
        record.tempMin = low
        record.precipTotal = rain
        record.schemaVersion = DailyRecord.currentSchemaVersion
        return record
    }

    /// Every day from `start` through `end`, shaped by `make`.
    private func span(_ start: String, _ end: String,
                      _ make: (String, Int) -> DailyRecord) -> [DailyRecord] {
        var out: [DailyRecord] = []
        var cursor: String? = start
        var index = 0
        while let key = cursor, key <= end {
            out.append(make(key, index))
            cursor = DayKey.next(key)
            index += 1
        }
        return out
    }

    /// A summer peaking in late July: highs reach 95° and fall to 55° in late January.
    private func summer(_ key: String) -> Double {
        let slot = YearAxis.day(of: DayKey.monthDay(of: key)) ?? 0
        return 75 + 20 * cos(2 * .pi * Double(slot - 205) / 366)
    }

    private var hot: DayQuery { DayQuery(conditions: [Condition(.high, .atOrAbove(90))]) }

    // MARK: Which answer

    /// Something with a real off season is answered with dates: where it's the
    /// norm, and where it's possible at all.
    func testASeasonIsAnsweredWithItsDates() throws {
        // And a spike ahead of a front every May 10: possible, long before it's usual.
        let climate = Climatology(records: span("2022-10-08", "2026-10-15") { key, _ in
            self.day(key, high: key.hasSuffix("05-10") ? 93 : self.summer(key))
        })
        let shape = try XCTUnwrap(climate.whenInTheYear(hot))
        XCTAssertEqual(shape.kind, .season)
        let inner = try XCTUnwrap(shape.inner)
        let outer = try XCTUnwrap(shape.outer)
        // Highs reach 90° about 60 days either side of the July 24 peak.
        let peak = try XCTUnwrap((0..<shape.slotCount).first { shape.monthDay($0) == "07-24" })
        XCTAssertTrue(inner.contains(peak))
        XCTAssertLessThan(outer.lowerBound, inner.lowerBound, "possible long before it's usual")
        XCTAssertLessThanOrEqual(abs(outer.upperBound - inner.upperBound), 2,
                                 "no spikes at the far end, so the two close together")
        XCTAssertEqual(shape.monthDay(outer.lowerBound), "05-10")
        XCTAssertTrue(inner.contains(shape.peak))
        // The axis is cropped to the season, not the whole year.
        XCTAssertLessThan(shape.slotCount, 366)
        XCTAssertTrue(shape.records.contains { $0.label == "Hottest day" })
        XCTAssertTrue(shape.records.contains { $0.label == "Earliest on record" })
    }

    /// Something that can happen any day is answered with when it's likeliest,
    /// never with a "season" carved out of a low winter rate.
    func testRainAllYearIsAnsweredWithWhenItsLikeliest() throws {
        let climate = Climatology(records: span("2022-01-01", "2025-12-31") { key, index in
            let month = Int(key.dropFirst(5).prefix(2)) ?? 1
            // Every fourth day, and every third in May.
            let wet = month == 5 ? index % 3 == 0 : index % 4 == 0
            return self.day(key, rain: wet ? 0.6 : 0)
        })
        let shape = try XCTUnwrap(climate.whenInTheYear(DayQuery(conditions: [Condition(.rain, .atOrAbove(0.5))])))
        XCTAssertEqual(shape.kind, .yearRound)
        XCTAssertNil(shape.inner)
        XCTAssertEqual(shape.slotCount, 366)
        XCTAssertEqual(shape.monthDay(shape.peak).prefix(2), "05")
        XCTAssertTrue(shape.records.contains { $0.label == "Wettest week" })
        XCTAssertNil(shape.readings?.mean.first ?? nil, "rain is never averaged")
    }

    /// A question that names its dates is answered per instance of them, on an
    /// axis centred on them.
    func testAScopedQuestionCountsItsOwnDates() throws {
        let climate = Climatology(records: span("2022-10-08", "2026-10-15") { key, index in
            self.day(key, rain: index % 5 == 0 ? 0.3 : 0)
        })
        let september = WeatherPeriod.months[8]
        let shape = try XCTUnwrap(climate.whenInTheYear(
            DayQuery(conditions: [Condition(.rain, .atOrAbove(0.01))], scope: september)))
        XCTAssertEqual(shape.kind, .scoped)
        XCTAssertEqual(shape.startMonth, 3, "September sits mid-axis")
        XCTAssertEqual(shape.counts.map(\.label), ["2023", "2024", "2025", "2026"])
        XCTAssertTrue(shape.counts.allSatisfy(\.isComplete))
        XCTAssertTrue(shape.matchedDays.allSatisfy { $0.dropFirst(5).hasPrefix("09") })
        let scope = try XCTUnwrap(shape.scope)
        XCTAssertEqual(shape.monthDay(scope.lowerBound), "09-01")
        XCTAssertEqual(shape.monthDay(scope.upperBound), "09-30")
        XCTAssertTrue(shape.records.contains { $0.label == "Wettest September" })
    }

    // MARK: The honesty rule

    /// A day with no high recorded can't say whether it reached 90°, so it is in
    /// neither count — not a "no".
    func testADayThatCantAnswerIsLeftOutOfBothCounts() throws {
        var records = span("2022-01-01", "2025-12-31") { key, _ in self.day(key, high: self.summer(key)) }
        let index = try XCTUnwrap(records.firstIndex { $0.day == "2024-07-24" })
        records[index] = day("2024-07-24", high: nil, samples: 10)
        let shape = try XCTUnwrap(Climatology(records: records).whenInTheYear(hot))
        let season = try XCTUnwrap(shape.counts.first { $0.label == "2024" })
        XCTAssertEqual(season.answerable, season.span - 1)
        XCTAssertFalse(shape.matchedDays.contains("2024-07-24"))
    }

    // MARK: Words

    func testAQuestionAboutLowsCountsNights() throws {
        let climate = Climatology(records: span("2022-10-08", "2026-10-15") { key, _ in
            self.day(key, low: self.summer(key) - 25)
        })
        let shape = try XCTUnwrap(climate.whenInTheYear(DayQuery(conditions: [Condition(.low, .below(40))])))
        XCTAssertEqual(shape.noun, "nights")
        XCTAssertEqual(shape.kind, .season)
        // A cold season wraps New Year, and the axis starts in summer so it's drawn whole.
        XCTAssertTrue((4...10).contains(shape.startMonth))
        XCTAssertTrue(shape.records.contains { $0.label == "Coldest night" })
    }

    // MARK: Against the real archive

    /// Prints what the page will show from this machine's own archive, beside
    /// the numbers the design mock computed from it. Opt in with
    /// `VANE_REAL_ARCHIVE=1`; it reads the app group container.
    func testPrintTheRealArchive() throws {
        guard ProcessInfo.processInfo.environment["VANE_REAL_ARCHIVE"] == "1" else { throw XCTSkip("opt-in") }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/CG68B3UD28.group.jdm-solutions.vane/Weather/daily")
        let climate = Climatology(records: try FileDailyArchive(root: root).allRecords())
        let questions: [(String, DayQuery)] = [
            ("hot", hot),
            ("warm", DayQuery(conditions: [Condition(.low, .atOrAbove(65))])),
            ("cool", DayQuery(conditions: [Condition(.low, .below(50))])),
            ("muggy", DayQuery(conditions: [Condition(.dewPoint, .atOrAbove(65))])),
            ("freeze", DayQuery(conditions: [Condition(.low, .atOrBelow(32))])),
            ("heavy", DayQuery(conditions: [Condition(.rain, .atOrAbove(0.5))])),
            ("storms", DayQuery(conditions: [Condition(.lightning, .atOrAbove(1)), Condition(.rain, .atOrAbove(0.1))])),
            ("seprain", DayQuery(conditions: [Condition(.rain, .atOrAbove(0.01))], scope: WeatherPeriod.months[8])),
        ]
        for (name, query) in questions {
            let s = try XCTUnwrap(climate.whenInTheYear(query))
            let pair = { (r: ClosedRange<Int>?) in r.map { "\(s.monthDay($0.lowerBound))…\(s.monthDay($0.upperBound))" } ?? "-" }
            print("\(name): \(s.kind) start \(s.startMonth) slots \(s.slotCount) inner \(pair(s.inner)) outer \(pair(s.outer)) peak \(s.monthDay(s.peak)) matched \(s.matchedDays.count) last \(s.lastEver ?? "-")")
            print("   counts", s.counts.map { "\($0.label):\($0.matched)/\($0.byToday.map(String.init) ?? "-")" }.joined(separator: " "))
            print("   records", s.records.map { "\($0.label)=\($0.value ?? $0.day ?? "") \($0.day ?? "") \($0.note ?? "")" }.joined(separator: " | "))
            print("   longest", s.longest.map { "\($0.length) \($0.firstDay)…\($0.lastDay)" } ?? "-", "runs3", s.runsOfThree)
        }
    }
}

/// The report pictures, on this machine's archive. Opt in with `VANE_REAL_ARCHIVE=1`.
final class ReportPictureRealArchiveTests: XCTestCase {
    func testPrintTheRealArchive() throws {
        guard ProcessInfo.processInfo.environment["VANE_REAL_ARCHIVE"] == "1" else { throw XCTSkip("opt-in") }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/CG68B3UD28.group.jdm-solutions.vane/Weather/daily")
        let climate = Climatology(records: try FileDailyArchive(root: root).allRecords())
        for query in DayQuery.reportQuestions {
            let p = try XCTUnwrap(climate.reportPicture(query))
            print("\(query.name): \(p.kind)")
            switch p.kind {
            case .yearToDate:
                print("  ", p.running.map { "\($0.year):\(String(format: "%.2f", $0.total)) complete \($0.isComplete)" },
                      "usual end", p.usualRunning.last ?? -1, "usual by today", p.usualRunning[ReportPicture.dayOfYear(p.recordEnd)])
            case .departureGrid:
                print("  ", p.years.map { "\($0.year):\(String(format: "%.1f", $0.value ?? .nan)) cov \(String(format: "%.2f", $0.coverage))" })
            case .monthGrid, .monthOfYear:
                let top = p.months.filter(\.isWhole).sorted { ($0.value ?? 0) > ($1.value ?? 0) }.prefix(3)
                print("   top", top.map { "\($0.year)-\($0.month): \($0.value ?? 0) \($0.day ?? "")" })
                print("   usual", p.usualByMonth.map { $0.map { String(format: "%.2f", $0) } ?? "-" })
            case .extremes:
                print("   window month \(p.windowMonth) length \(p.windowLength) line \(p.line ?? -1)")
                for s in p.seasons { print("   ", s.label, s.day ?? "-", s.value ?? -1, s.firstPast ?? "-", s.lastPast ?? "-", s.pastCount, "seen", s.isSeen, "running", s.isRunning) }
            case .single: print("  ", p.single ?? -1)
            }
        }
    }
}
