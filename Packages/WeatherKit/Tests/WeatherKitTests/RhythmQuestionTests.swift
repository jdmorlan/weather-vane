import XCTest
@testable import WeatherKit

final class RhythmQuestionTests: XCTestCase {

    /// A climate with a known shape in both directions, and frost dates that
    /// drift so the windows have width.
    private func station(years: ClosedRange<Int> = 2021...2024) -> Climatology {
        var records: [DailyRecord] = []
        for year in years {
            let drift = year - years.lowerBound
            var cursor = "\(year)-01-01"
            while cursor <= "\(year)-12-31" {
                let monthDay = DayKey.monthDay(of: cursor)
                var record = DailyRecord(day: cursor, sampleCount: 48, expectedSamples: 48)
                let warm = monthDay >= "04-10" && monthDay < "09-10"
                record.tempMin = warm ? 70 : 50
                record.tempMax = (monthDay >= "05-10" && monthDay < "10-10") ? 92 : 78
                record.dewPointMean = warm ? 68 : 55
                if let spring = DayKey.step("\(year)-03-05", by: drift),
                   let fall = DayKey.step("\(year)-11-12", by: drift),
                   cursor == spring || cursor == fall {
                    record.tempMin = 30
                }
                record.schemaVersion = DailyRecord.currentSchemaVersion
                records.append(record)
                guard let next = DayKey.next(cursor) else { break }
                cursor = next
            }
        }
        return Climatology(records: records)
    }

    // MARK: The catalogue

    /// The question this page was asked for comes first. A reader standing in a
    /// hot September wants one thing, and it should not be the fourth card.
    func testTheHeatBreakingIsTheFirstQuestion() {
        let questions = station().rhythmQuestions()
        XCTAssertEqual(questions.first?.question, "When does it stop being hot?")
        XCTAssertEqual(questions.first?.measure, .afternoons)
        XCTAssertEqual(questions.first?.direction, .easing)
    }

    /// Every question carries the definition of its own words. A date for "when
    /// fall starts" is unusable without knowing what the app calls fall.
    func testEveryQuestionStatesItsOwnParameters() {
        for question in station().rhythmQuestions() {
            XCTAssertFalse(question.basis.isEmpty, question.question)
            XCTAssertTrue(question.basis.contains("°"),
                          "\(question.question) must name its threshold")
            XCTAssertTrue(question.question.hasSuffix("?"))
        }
    }

    /// One threshold is the answer; the rest are an aside. The chart this
    /// replaced drew three per row, which is three answers to one question.
    func testOneThresholdAnswersAndTheOthersSupport() {
        let heat = station().rhythmQuestions().first { $0.id == "afternoons·easing" }
        XCTAssertEqual(heat?.answer.threshold, 90)
        XCTAssertFalse(heat?.alternates.contains { $0.threshold == 90 } ?? true)
        // Alternates stay in calendar order so a line of them reads forward.
        let days = heat?.alternates.map(\.dayOfYear) ?? []
        XCTAssertEqual(days, days.sorted())
        XCTAssertTrue(heat?.alternates.allSatisfy { $0.direction == .easing } ?? false)
    }

    /// Both halves of the year are asked about, which is the thing the countdown
    /// could never do.
    func testQuestionsRunInBothDirections() {
        let questions = station().rhythmQuestions()
        XCTAssertTrue(questions.contains { $0.direction == .easing })
        XCTAssertTrue(questions.contains { $0.direction == .arriving })
        XCTAssertTrue(questions.contains { $0.id == "freeze·easing" })
        XCTAssertTrue(questions.contains { $0.id == "freeze·arriving" })
    }

    /// The answer must arrive with its window, never as a bare date.
    func testTheAnswerCarriesTheWindowTheRecordHasSeen() {
        let freeze = station().rhythmQuestions().first { $0.id == "freeze·easing" }
        XCTAssertNotNil(freeze?.answer.earliestMonthDay)
        XCTAssertNotNil(freeze?.answer.latestMonthDay)
        XCTAssertEqual(freeze?.answer.spreadDays, 3)
    }

    /// The same answer whenever it is asked — that is what separates this page
    /// from the countdown it replaced.
    func testTheQuestionsReadTheSameWheneverTheyAreAsked() {
        let climate = station()
        XCTAssertEqual(climate.rhythmQuestions(), climate.rhythmQuestions())
    }

    /// A station that has never seen the threshold simply has no card for it.
    /// Inventing a first-freeze date is worse than a shorter page.
    func testAQuestionThisRecordCannotAnswerIsAbsent() {
        var records: [DailyRecord] = []
        for year in 2021...2024 {
            var cursor = "\(year)-01-01"
            while cursor <= "\(year)-12-31" {
                var record = DailyRecord(day: cursor, sampleCount: 48, expectedSamples: 48)
                record.tempMin = 55          // never freezes
                record.tempMax = 75          // never hot
                record.schemaVersion = DailyRecord.currentSchemaVersion
                records.append(record)
                guard let next = DayKey.next(cursor) else { break }
                cursor = next
            }
        }
        let questions = Climatology(records: records).rhythmQuestions()
        XCTAssertFalse(questions.contains { $0.measure == .freeze })
        XCTAssertFalse(questions.contains { $0.measure == .afternoons })
    }

    // MARK: What this year is doing

    /// The live line comes from the countdown, which is the only instrument that
    /// can tell a late crossing from one that already happened.
    func testThisYearSpeaksOnlyForTheDirectionTheSeasonIsTravelling() {
        let climate = station()
        let questions = climate.rhythmQuestions()
        let autumn = climate.seasonalTracks(asOf: "2025-09-01", horizonDays: 75)

        let cooling = questions.first { $0.id == "nights·easing" }
        let warming = questions.first { $0.id == "nights·arriving" }
        XCTAssertNotNil(cooling?.thisYear(autumn), "September has news about the nights letting go")
        XCTAssertNil(warming?.thisYear(autumn), "and none about them coming back")
    }

    /// A question with nothing near is silent rather than reaching for filler.
    func testAQuestionMonthsAwaySaysNothingAboutThisYear() {
        let climate = station()
        let questions = climate.rhythmQuestions()
        let tracks = climate.seasonalTracks(asOf: "2025-09-01", horizonDays: 75)
        let freeze = questions.first { $0.id == "freeze·easing" }
        // Mid-November frost, asked on September 1 — over two months out.
        XCTAssertNil(freeze?.thisYear(tracks))
    }

    /// A different threshold on the same measure running late is still news
    /// about this question, and this card is the only place it can land.
    ///
    /// Needs a climate whose night thresholds cross on DIFFERENT dates — the
    /// main fixture steps straight from 70° to 50° overnight, so all three cross
    /// together and the canonical one is never the calm sibling of a late one.
    func testALateSiblingThresholdIsReportedAndNamed() {
        func nights(_ monthDay: String) -> Double {
            guard monthDay >= "08-20",
                  let offset = DayKey.distance(from: "2001-08-20", to: "2001-\(monthDay)"),
                  offset >= 0 else { return monthDay >= "08-20" ? 60 : 78 }
            // 78° easing to 60° over seven weeks: 75° in late August, 70° in
            // mid-September, 65° at the end of it.
            return max(60, 78 - 18 * Double(offset) / 51)
        }
        var records: [DailyRecord] = []
        for year in 2021...2024 {
            var cursor = "\(year)-01-01"
            while cursor <= "\(year)-12-31" {
                var record = DailyRecord(day: cursor, sampleCount: 48, expectedSamples: 48)
                record.tempMin = nights(DayKey.monthDay(of: cursor))
                record.tempMax = 88
                record.dewPointMean = 62
                record.schemaVersion = DailyRecord.currentSchemaVersion
                records.append(record)
                guard let next = DayKey.next(cursor) else { break }
                cursor = next
            }
        }
        // This year, stalled at 72° — past the 70° date, short of the 65° one.
        var cursor = "2025-09-01"
        while cursor <= "2025-09-20" {
            var record = DailyRecord(day: cursor, sampleCount: 48, expectedSamples: 48)
            record.tempMin = 72
            record.tempMax = 88
            record.dewPointMean = 62
            record.schemaVersion = DailyRecord.currentSchemaVersion
            records.append(record)
            guard let next = DayKey.next(cursor) else { break }
            cursor = next
        }

        let climate = Climatology(records: records)
        let tracks = climate.seasonalTracks(asOf: "2025-09-20", horizonDays: 75)
        let question = climate.rhythmQuestions().first { $0.id == "nights·easing" }
        XCTAssertEqual(question?.answer.threshold, 65)

        let line = question?.thisYear(tracks)
        XCTAssertNotNil(line, "the 70° crossing is overdue and this card is where it lands")
        // Named, so a note about 70° can't be mistaken for one about the 65°
        // answer printed above it.
        XCTAssertTrue(line?.contains("70°") ?? false, line ?? "nil")
        XCTAssertTrue(line?.contains("late") ?? false, line ?? "nil")
    }

    /// A floor is not a date and must not be printed as one.
    func testAForecastThatRulesACrossingOutReadsAsAFloor() {
        let climate = station()
        let questions = climate.rhythmQuestions()
        // Ten days of nights holding at 74°, well above the 65° line.
        let outlook = (0..<10).compactMap { offset -> SeasonForecastDay? in
            DayKey.step("2025-09-01", by: offset).map {
                SeasonForecastDay(day: $0, tempMax: 95, tempMin: 74, dewPointMean: 70)
            }
        }
        let tracks = climate.seasonalTracks(asOf: "2025-09-01", horizonDays: 75, forecast: outlook)
        let line = questions.first { $0.id == "nights·easing" }?.thisYear(tracks)
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("not before") ?? false, line ?? "nil")
    }

    /// Where the answer sits relative to today, for the mark on the strip.
    func testDaysFromTodayIsSignedSoAPassedAnswerReadsAsBehind() {
        let questions = station().rhythmQuestions()
        let freeze = questions.first { $0.id == "freeze·easing" }   // mid-November
        XCTAssertEqual(freeze?.daysFromToday("2025-09-01") ?? 0 > 0, true)
        XCTAssertEqual(freeze?.daysFromToday("2025-12-01") ?? 0 < 0, true)
    }
}
