import XCTest
@testable import WeatherKit

/// The query engine. Most of these are about the asymmetry: a partial day can
/// PROVE some things and can't rule out others, and the difference decides
/// whether the station's downtime reads as dry weather.
final class DayQueryTests: XCTestCase {

    // MARK: Fixtures

    private func day(_ key: String, high: Double? = nil, low: Double? = nil,
                     dew: Double? = nil, rain: Double? = nil,
                     samples: Int = 48) -> DailyRecord {
        var record = DailyRecord(day: key, sampleCount: samples, expectedSamples: 48)
        record.tempMax = high
        record.tempMin = low
        record.dewPointMean = dew
        record.dewPointMax = dew
        record.precipTotal = rain
        record.schemaVersion = DailyRecord.currentSchemaVersion
        return record
    }

    // MARK: The honesty rule

    /// A day the station half-watched recorded a high of 97°. Its true high can
    /// only have been HIGHER, so "97 or above" is settled — the missed hours
    /// can't take it back. This is "presence doesn't need coverage".
    func testAPartialDayCanStillProveAHighWasReached() {
        let partial = day("2024-08-01", high: 97, samples: 6)
        XCTAssertFalse(partial.isReliable)

        let reached = Condition(.high, .atOrAbove(95))
        XCTAssertEqual(reached.evaluate(partial), true)
    }

    /// The same day cannot prove its high stayed BELOW 100 — the hour nobody
    /// watched is exactly where the afternoon peak would have been. "Absence
    /// needs coverage."
    func testThePartialDayCannotProveAHighWasNeverReached() {
        let partial = day("2024-08-01", high: 97, samples: 6)
        let stayedUnder = Condition(.high, .below(100))
        XCTAssertNil(stayedUnder.evaluate(partial),
                     "a partial day must not settle an upper bound on its own maximum")

        // Watched throughout, the same reading answers it.
        let watched = day("2024-08-02", high: 97)
        XCTAssertEqual(stayedUnder.evaluate(watched), true)
    }

    /// The mirror image: a recorded LOW is a ceiling, so it proves cold was
    /// reached and can't prove cold was avoided.
    func testALowIsACeilingSoTheProvableDirectionFlips() {
        let partial = day("2024-01-05", low: 28, samples: 6)
        XCTAssertEqual(Condition(.low, .below(32)).evaluate(partial), true)
        XCTAssertNil(Condition(.low, .atOrAbove(20)).evaluate(partial))
    }

    /// A mean is moved either way by the hours that went missing, so a partial
    /// day settles nothing about it in either direction.
    func testAMeanIsUnanswerableOnAPartialDay() {
        let partial = day("2024-08-01", dew: 70, samples: 6)
        XCTAssertNil(Condition(.dewPoint, .atOrAbove(65)).evaluate(partial))
        XCTAssertNil(Condition(.dewPoint, .below(75)).evaluate(partial))
    }

    /// A band is bounded on both sides, so no partial day can settle one.
    func testABandNeedsAWatchedDay() {
        let partial = day("2024-08-01", dew: 67, samples: 6)
        XCTAssertNil(Condition(.dewPointPeak, .inBand("Muggy")).evaluate(partial))
        XCTAssertEqual(Condition(.dewPointPeak, .inBand("Muggy"))
            .evaluate(day("2024-08-02", dew: 67)), true)
    }

    // MARK: Counting

    /// The headline number is a FLOOR whenever days went unanswered, and the
    /// result has to be able to say so — a count printed bare reads as complete.
    func testUnanswerableDaysAreNeverCountedAsMisses() {
        let records = [day("2024-06-01", high: 88),
                       day("2024-06-02", high: 92),
                       day("2024-06-03", high: 80, samples: 5)]   // can't rule out a hot afternoon
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .below(90))]))

        XCTAssertEqual(result.matchCount, 1)          // only June 1 is settled
        XCTAssertEqual(result.daysAnswered, 2)
        XCTAssertEqual(result.daysUnanswerable, 1)
        XCTAssertTrue(result.isFloor)
        // The rate is over what could be answered, not over the calendar.
        XCTAssertEqual(result.rate ?? 0, 0.5, accuracy: 0.001)
    }

    /// A definite NO on one condition settles the day even when another
    /// condition couldn't be answered — there's no need to know the dew point
    /// of a day that wasn't hot enough to qualify.
    func testADefiniteNoSettlesADayWithAnUnanswerableSibling() {
        // Watched enough to prove the high fell short; dew point still a mean
        // on a partial day, so unanswerable on its own.
        let record = day("2024-06-03", high: 70, dew: 50, samples: 5)
        let result = Climatology(records: [record])
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(90)),
                                       Condition(.dewPoint, .below(60))]))

        XCTAssertEqual(result.matchCount, 0)
        XCTAssertEqual(result.daysAnswered, 1, "the day was settled — it simply didn't match")
        XCTAssertFalse(result.isFloor)
    }

    func testConditionsAreAnded() {
        let records = [day("2024-07-01", high: 95, dew: 55),   // hot and dry ✓
                       day("2024-07-02", high: 95, dew: 70),   // hot, sticky ✗
                       day("2024-07-03", high: 80, dew: 55)]   // dry, not hot ✗
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(90)),
                                       Condition(.dewPoint, .below(60))]))

        XCTAssertEqual(result.days.map(\.day), ["2024-07-01"])
    }

    // MARK: Shapes

    /// The pattern view pools a date across years, and a date nothing could
    /// answer must read as unknown rather than as zero.
    func testCalendarPoolsAcrossYearsAndKeepsUnknownsDistinctFromZero() {
        let records = [day("2023-07-04", high: 101), day("2024-07-04", high: 95),
                       day("2023-07-05", high: 99),  day("2024-07-05", high: 92),
                       day("2023-07-06", high: 88, samples: 4)]   // unanswerable
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .below(100))]))

        let fourth = result.calendar.first { $0.monthDay == "07-04" }
        XCTAssertEqual(fourth?.yearsAnswered, 2)
        XCTAssertEqual(fourth?.yearsMatched, 1)
        XCTAssertEqual(fourth?.rate ?? 0, 0.5, accuracy: 0.001)

        let sixth = result.calendar.first { $0.monthDay == "07-06" }
        XCTAssertEqual(sixth?.yearsAnswered, 0)
        XCTAssertNil(sixth?.rate, "nothing could answer — that is not a zero")

        // A date in scope that simply never matched IS a zero, and says so.
        let seventh = result.calendar.first { $0.monthDay == "07-07" }
        XCTAssertEqual(seventh?.yearsMatched, 0)
    }

    /// A cell carries every year it stands for, not only the matching ones — a near miss and a nowhere-near
    /// miss are the same zero to the counts, and the readings are what tell them apart.
    func testCalendarCellsCarryEveryYearWithItsOutcome() {
        let records = [day("2023-07-04", high: 99), day("2024-07-04", high: 101),
                       // Reads as a match, but a partly-watched day can't prove a ceiling — set aside.
                       day("2025-07-04", high: 84, samples: 4)]
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .below(100))]))

        let fourth = result.calendar.first { $0.monthDay == "07-04" }
        XCTAssertEqual(fourth?.years.map(\.year), [2023, 2024, 2025], "oldest first, every year in scope")
        XCTAssertEqual(fourth?.years.map(\.outcome), [.matched, .missed, .setAside])
        XCTAssertEqual(fourth?.years[1].values.first ?? nil, 101, "the year that missed still says by how much")
        XCTAssertEqual(fourth?.years[0].high, 99)
    }

    /// A run only continues across genuinely adjacent days. Matching on the 3rd
    /// and the 6th is two streaks, never one of length two.
    func testStreaksDoNotStepOverAGap() {
        let records = ["2024-08-01", "2024-08-02", "2024-08-03", "2024-08-06", "2024-08-07"]
            .map { day($0, high: 101) }
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))]))

        XCTAssertEqual(result.streaks.count, 2)
        XCTAssertEqual(result.streaks.first?.length, 3)
        XCTAssertEqual(result.streaks.first?.firstDay, "2024-08-01")
        XCTAssertEqual(result.streaks.last?.length, 2)
    }

    func testScopeNarrowsToAPeriod() {
        let records = [day("2024-06-15", high: 101), day("2024-09-15", high: 101)]
        let query = DayQuery(conditions: [Condition(.high, .atOrAbove(100))],
                             scope: WeatherPeriod.months[8])   // September
        let result = Climatology(records: records).run(query)

        XCTAssertEqual(result.days.map(\.day), ["2024-09-15"])
        XCTAssertEqual(result.daysInScope, 1)
        XCTAssertEqual(result.calendar.count, 30, "the calendar covers the scope, not the year")
    }

    /// A typical date is only honest for something that happens in one season.
    /// Rain falls all year here, and averaging January and July would invent a
    /// date that means nothing.
    func testATypicalDateIsWithheldWhenMatchesAreScatteredAcrossTheYear() {
        let scattered = ["01-10", "04-10", "07-10", "10-10"].map { day("2024-\($0)", rain: 1.0) }
        let seasonal = ["07-08", "07-15", "07-22"].map { day("2024-\($0)", rain: 1.0) }
        let rained = DayQuery(conditions: [Condition(.rain, .atOrAbove(0.01))])

        XCTAssertNil(Climatology(records: scattered).run(rained).typicalMonthDay)
        XCTAssertEqual(Climatology(records: seasonal).run(rained).typicalMonthDay, "07-15")
    }

    // MARK: Vocabulary

    /// "Dew point below 64" and "dew point is Muggy" are the same question in
    /// two languages, and the measure knows both.
    func testABandAsksTheSameQuestionAsANumber() {
        let muggy = day("2024-08-01", dew: 67)
        XCTAssertEqual(Condition(.dewPointPeak, .inBand("Muggy")).evaluate(muggy), true)
        XCTAssertEqual(Condition(.dewPointPeak, .between(65, 70)).evaluate(muggy), true)
        XCTAssertEqual(Condition(.dewPointPeak, .inBand("Oppressive")).evaluate(muggy), false)
    }

    /// The bands are the ones the rest of the app already speaks, so "Muggy"
    /// means one thing everywhere.
    func testDewPointBandsMatchTheForecastComfortTags() {
        for value in stride(from: 45.0, through: 80.0, by: 1.0) {
            let band = Measure.dewPoint.bands.first { $0.contains(value) }
            XCTAssertEqual(band?.name, WeatherInterpreter.dewComfortTag(value),
                           "band disagrees with the forecast tag at \(value)°")
        }
    }

    /// A month bar labelled "May" has to be readable AS May. Raw totals across
    /// the record gave May 48 rainy days — more days than May has — which reads
    /// as a bug and undermines the chart.
    func testAMonthReportsDaysInOneMonthNotAcrossTheRecord() {
        // Four Mays, twelve rainy days in each.
        let records = (2021...2024).flatMap { year in
            (1...31).map { d -> DailyRecord in
                day(String(format: "%d-05-%02d", year, d), rain: d <= 12 ? 0.5 : 0)
            }
        }
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.rain, .atOrAbove(0.01))]))
        let may = result.months.first { $0.month == 5 }!

        XCTAssertEqual(may.matched, 48, "the raw total across the record is still available")
        XCTAssertEqual(may.typicalDays ?? 0, 12, accuracy: 0.01, "but a May has twelve of them")
        XCTAssertLessThanOrEqual(may.typicalDays ?? 0, 31)
    }

    /// Derived from the RATE, not from `matched ÷ years`: the archive opens
    /// mid-record and the current year is partial, so dividing by a year count
    /// reports every month short.
    func testTypicalDaysIsNotDraggedDownByUnwatchedYears() {
        // Three fully-watched Mays at 12 rainy days, plus a fourth May the
        // station only saw the first ten days of (4 of them rainy).
        var records = (2021...2023).flatMap { year in
            (1...31).map { d in day(String(format: "%d-05-%02d", year, d), rain: d <= 12 ? 0.5 : 0) }
        }
        records += (1...10).map { day(String(format: "2024-05-%02d", $0), rain: $0 <= 4 ? 0.5 : 0) }

        let may = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.rain, .atOrAbove(0.01))]))
            .months.first { $0.month == 5 }!

        // 40 matched over 103 answered → 0.388 × 31 ≈ 12, not 40/4 = 10.
        XCTAssertEqual(may.typicalDays ?? 0, 12, accuracy: 0.4)
    }

    // MARK: The two scope axes

    func testAYearNarrowsWithoutTouchingTheDateAxis() {
        let records = [day("2024-05-10", rain: 1.0), day("2025-05-10", rain: 1.0),
                       day("2025-11-10", rain: 1.0)]
        let rained = [Condition(.rain, .atOrAbove(0.01))]
        let climate = Climatology(records: records)

        XCTAssertEqual(climate.run(DayQuery(conditions: rained)).matchCount, 3)
        XCTAssertEqual(climate.run(DayQuery(conditions: rained, years: .year(2025))).matchCount, 2)
        XCTAssertEqual(climate.run(DayQuery(conditions: rained,
                                            scope: WeatherPeriod.months[4])).matchCount, 2)
        // Both axes together.
        XCTAssertEqual(climate.run(DayQuery(conditions: rained, scope: WeatherPeriod.months[4],
                                            years: .year(2025))).days.map(\.day), ["2025-05-10"])
    }

    /// "Winter 2024" is December 2024 through February 2025 — one continuous
    /// season. Matching month-days inside a pinned year would instead give Dec,
    /// Jan and Feb OF 2024: three disjoint months, and not a winter.
    func testAPinnedYearResolvesAWrappingPeriodToOneContinuousSeason() {
        let records = [day("2024-01-15", low: 20),   // the tail of the PREVIOUS winter
                       day("2024-12-15", low: 20),   // winter 2024 proper
                       day("2025-01-15", low: 20)]   // …and its January
        let winter = WeatherPeriod.seasons.first { $0.name == "Winter" }!
        let freezing = DayQuery(conditions: [Condition(.low, .below(32))],
                                scope: winter, years: .year(2024))

        let result = Climatology(records: records).run(freezing)
        XCTAssertEqual(result.days.map(\.day).sorted(), ["2024-12-15", "2025-01-15"])
    }

    func testDescribeNamesBothAxesOrNeither() {
        let rained = [Condition(.rain, .atOrAbove(0.01))]
        XCTAssertEqual(DayQuery(conditions: rained).describe, "Rain 0.01\" or above")
        XCTAssertTrue(DayQuery(conditions: rained, years: .year(2026)).describe.hasSuffix("in 2026"))
        XCTAssertTrue(DayQuery(conditions: rained, scope: WeatherPeriod.months[8],
                               years: .year(2026)).describe.hasSuffix("in September 2026"))
        XCTAssertTrue(DayQuery(conditions: rained, scope: WeatherPeriod.months[8])
            .describe.hasSuffix("in September of any year"))
    }

    // MARK: When it happens

    /// Four years where every June, July and August is hot and nothing else is.
    private func summersOnly(_ years: ClosedRange<Int>, hotMonths: Set<Int> = [6, 7, 8]) -> [DailyRecord] {
        years.flatMap { year -> [DailyRecord] in
            var records: [DailyRecord] = []
            var cursor = "\(year)-01-01"
            while cursor <= "\(year)-12-31" {
                let month = Int(cursor.dropFirst(5).prefix(2)) ?? 1
                records.append(day(cursor, high: hotMonths.contains(month) ? 101 : 70))
                guard let next = DayKey.next(cursor) else { break }
                cursor = next
            }
            return records
        }
    }

    func testASeasonIsFoundWhereTheConditionsUsuallyHold() {
        let result = Climatology(records: summersOnly(2021...2024))
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))]))
        let season = result.season

        XCTAssertNotNil(season)
        XCTAssertTrue(season?.isMeaningful ?? false)
        XCTAssertTrue(season?.hasSeason ?? false)
        // Smoothed over a fortnight, so the edges sit a week inside the months.
        XCTAssertEqual(season?.begins?.prefix(2), "06")
        XCTAssertEqual(season?.ends?.prefix(2), "08")
        XCTAssertEqual(season?.peak?.rate ?? 0, 1.0, accuracy: 0.01)
    }

    /// The year is a RING. A winter condition begins in November and ends in
    /// March; a curve that stopped at December 31 would cut that season in half
    /// and report two short ones instead of one real one.
    func testASeasonMayWrapTheYearEnd() {
        let records = summersOnly(2021...2024, hotMonths: [12, 1, 2])
        let season = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))])).season

        XCTAssertTrue(season?.hasSeason ?? false)
        XCTAssertEqual(season?.begins?.prefix(2), "12")
        XCTAssertEqual(season?.ends?.prefix(2), "02")
        // One season of roughly three months, not two of six weeks.
        XCTAssertGreaterThan(season?.seasonLength ?? 0, 60)
    }

    /// "When is it the norm" and "when does it happen" are different questions,
    /// and a threshold season answers only the first. Reporting a fortnight in
    /// late January for something that happens all winter reads as a claim that
    /// the rest of winter is safe.
    func testTheWiderWindowIsWiderThanTheSeason() {
        // Deep winter always freezes; the shoulders freeze in half the years.
        var records: [DailyRecord] = []
        for year in 2021...2024 {
            var cursor = "\(year)-01-01"
            while cursor <= "\(year)-12-31" {
                let monthDay = DayKey.monthDay(of: cursor)
                let deep = monthDay >= "01-10" && monthDay <= "01-25"
                let shoulder = monthDay >= "11-20" || monthDay <= "02-20"
                let cold = deep || (shoulder && year % 2 == 0)
                records.append(day(cursor, low: cold ? 28 : 50))
                guard let next = DayKey.next(cursor) else { break }
                cursor = next
            }
        }
        let season = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.low, .below(32))])).season

        XCTAssertTrue(season?.hasSeason ?? false)
        XCTAssertTrue(season?.hasUsefulActiveWindow ?? false)
        XCTAssertGreaterThan(season?.activeLength ?? 0, (season?.seasonLength ?? 0) + 14)
        // The wider window wraps the year end; the narrow season doesn't.
        XCTAssertEqual(season?.activeBegins?.prefix(2), "11")
        XCTAssertEqual(season?.begins?.prefix(2), "01")
    }

    /// Found against real data: rain here runs year-round at a lower winter
    /// rate, and a fixed low threshold carved it into "happens March 20 through
    /// July 23" — which reads as a claim that it doesn't rain in November. A
    /// window needs a genuine OFF SEASON to be a true sentence.
    func testNoWindowIsClaimedForSomethingThatHappensAllYear() {
        // Rain every fifth day, all year, every year — no off season at all.
        var records: [DailyRecord] = []
        for year in 2021...2024 {
            var cursor = "\(year)-01-01"
            var index = 0
            while cursor <= "\(year)-12-31" {
                records.append(day(cursor, rain: index % 5 == 0 ? 0.5 : 0))
                index += 1
                guard let next = DayKey.next(cursor) else { break }
                cursor = next
            }
        }
        let season = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.rain, .atOrAbove(0.01))])).season

        XCTAssertEqual(season?.quietDays, 0, "nothing about this year is quiet")
        XCTAssertFalse(season?.hasUsefulActiveWindow ?? true,
                       "claiming a window here would deny the months it left out")
    }

    /// Something that never happens more often than not still has an answer —
    /// its best odds — and reporting "no season" would throw that away.
    func testAnUnseasonalQueryReportsItsPeakInsteadOfInventingASeason() {
        // Hot on one day in ten, all year round.
        var records: [DailyRecord] = []
        for year in 2021...2024 {
            var cursor = "\(year)-01-01"
            var index = 0
            while cursor <= "\(year)-12-31" {
                records.append(day(cursor, high: index % 10 == 0 ? 101 : 70))
                index += 1
                guard let next = DayKey.next(cursor) else { break }
                cursor = next
            }
        }
        let season = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))])).season

        XCTAssertFalse(season?.hasSeason ?? true)
        XCTAssertNotNil(season?.peak)
        XCTAssertLessThan(season?.peak?.rate ?? 1, 0.5)
    }

    /// A seasonal answer pools every year over the whole calendar, so pinning to
    /// one year leaves nothing to pool and must return nothing.
    func testNoSeasonalAnswerWhenPinnedToOneYear() {
        let climate = Climatology(records: summersOnly(2021...2024))
        let hot = [Condition(.high, .atOrAbove(100))]

        XCTAssertNotNil(climate.run(DayQuery(conditions: hot)).season)
        XCTAssertNil(climate.run(DayQuery(conditions: hot, years: .year(2023))).season)
    }

    /// A DATE WINDOW MUST NOT NARROW THE CURVE — it has to keep spanning the
    /// whole calendar, because the question it answers under a window is
    /// "do these days carry on past the edges I picked, or did I pick the only
    /// ones there are", and only the days outside the window can answer it.
    ///
    /// Scoping to July used to withhold the curve entirely. Now July's curve is
    /// the year's curve: identical to the unscoped one, with June and August
    /// still on it.
    func testTheSeasonalCurveIgnoresTheDateWindow() {
        let climate = Climatology(records: summersOnly(2021...2024))
        let hot = [Condition(.high, .atOrAbove(100))]

        let unscoped = climate.run(DayQuery(conditions: hot)).season
        let july = climate.run(DayQuery(conditions: hot, scope: WeatherPeriod.months[6])).season

        XCTAssertEqual(july?.monthDays.first, "01-01")
        XCTAssertEqual(july?.monthDays.last, "12-31")
        XCTAssertEqual(july?.begins, unscoped?.begins)
        XCTAssertEqual(july?.ends, unscoped?.ends)
        // The season runs wider than the window it was asked inside of, which
        // is the whole point.
        XCTAssertEqual(july?.begins, "06-01")
    }

    // MARK: When it opens and closes, without being asked

    /// The point of the whole thing: you get the first and last dates without
    /// switching SHOW, and the day list stays intact.
    func testOpensAndClosesAreComputedWithoutASequenceRule() {
        // Whole years, not just the summers: a "first" is only a first if
        // everything before it was watched, so a record that starts in May can
        // never prove June 1 was the opening day.
        let lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        var records: [DailyRecord] = []
        for year in 2021...2024 {
            for month in 1...12 {
                for dayOfMonth in 1...lengths[month - 1] {
                    let key = String(format: "%d-%02d-%02d", year, month, dayOfMonth)
                    records.append(day(key, high: (6...8).contains(month) ? 101 : 80))
                }
            }
        }
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))]))

        XCTAssertNil(result.query.sequence)
        XCTAssertEqual(result.opens?.typical, "06-01")
        XCTAssertEqual(result.closes?.typical, "08-31")
        // The days themselves are untouched — this is a fact ABOUT the result,
        // not a narrowing of it.
        XCTAssertEqual(result.matchCount, 4 * (30 + 31 + 31))
    }

    /// A winter pattern files January under the winter that opened in December.
    /// Counting by calendar year would report the season's tail as its head.
    func testAWrappingWindowOpensInTheYearItStarted() {
        var records: [DailyRecord] = []
        for year in 2021...2024 {
            for (month, days) in [(12, 31), (1, 31), (2, 28)] {
                for dayOfMonth in 1...days {
                    let key = String(format: "%d-%02d-%02d", year, month, dayOfMonth)
                    records.append(day(key, low: month == 12 && dayOfMonth < 15 ? 40 : 20))
                }
            }
        }
        let winter = WeatherPeriod(name: "Winter", start: "12-01", endExclusive: "03-01")
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.low, .below(33))], scope: winter))

        // The window opens in December, so the first freeze is mid-December —
        // never January 1, which is where a calendar-year reading would land.
        XCTAssertEqual(result.opens?.typical, "12-15")
        XCTAssertEqual(result.closes?.typical, "02-28")
    }

    /// Under a sequence rule the result already IS a set of openings, so asking
    /// when they opened is circular.
    func testNoEdgesUnderASequenceRule() {
        let climate = Climatology(records: summersOnly(2021...2024))
        let query = DayQuery(conditions: [Condition(.high, .atOrAbove(100))],
                             sequence: .firstEachYear)
        let result = climate.run(query)

        XCTAssertNil(result.opens)
        XCTAssertNil(result.closes)
        XCTAssertNotNil(result.spread)
    }

    // MARK: What the weather was LIKE

    /// The baseline is the same DATES in other years, not the whole record.
    ///
    /// August is warm and January is not, so a January day averaged into the
    /// comparison drags it down and manufactures a departure out of the calendar.
    /// Here the hot day is only 3° above what its own date usually does — a
    /// baseline over all four days would have called it 20° above.
    func testTheProfileComparesAgainstTheSameDatesNotTheWholeRecord() {
        // A fortnight of each, so the ±7-day pool is thick enough to be a
        // normal at all — one day a year is coincidence, and `isMeaningful`
        // rightly refuses it.
        var records: [DailyRecord] = []
        for year in 2018...2024 {
            for dayOfMonth in 8...22 {
                records.append(day(String(format: "%d-01-%02d", year, dayOfMonth), high: 40))
                let july = String(format: "%d-07-%02d", year, dayOfMonth)
                records.append(day(july, high: july == "2024-07-15" ? 100 : 90))
            }
        }
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))]))

        let high = result.profile.averages.first { $0.measure == .high }
        XCTAssertEqual(high?.matched, 100)
        // Mid-July, not mid-January: ~90, never the ~65 of both pooled together.
        XCTAssertEqual(high?.usual ?? 0, 90.1, accuracy: 0.1)
        XCTAssertEqual(high?.departure ?? 0, 9.9, accuracy: 0.1)
        XCTAssertEqual(result.profile.matchedDays, 1)
    }

    /// A measure you set a condition on can only land on the side you asked for,
    /// so the box has to say so rather than presenting it as a finding.
    func testMeasuresNamedInTheQueryAreMarked() {
        let records = (2018...2024).map { day("\($0)-07-15", high: $0 == 2024 ? 100 : 90, low: 70) }
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))]))

        XCTAssertTrue(result.profile.averages.first { $0.measure == .high }?.wasAsked == true)
        XCTAssertFalse(result.profile.averages.first { $0.measure == .low }?.wasAsked == true)
    }

    /// A normal built from one year is last year's weather. With nothing to
    /// compare against the box says so — it must never read as a zero.
    func testNoBaselineWhereTheRecordIsTooThinForANormal() {
        let result = Climatology(records: [day("2024-08-01", high: 100, low: 78)])
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))]))

        let high = result.profile.averages.first { $0.measure == .high }
        XCTAssertEqual(high?.matched, 100)
        XCTAssertNil(high?.usual)
        XCTAssertNil(high?.departure)
    }

    /// Rain is a share of days, not a mean. Three dry days and one that dropped
    /// an inch is "25% of days", never "0.25 inches" — a figure that describes
    /// no day in the set.
    func testRainReadsAsAShareOfDaysNotADailyMean() {
        let records = [
            day("2024-08-01", high: 100, rain: 1.0),
            day("2024-08-02", high: 100, rain: 0),
            day("2024-08-03", high: 100, rain: 0),
            day("2024-08-04", high: 100, rain: 0),
        ]
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))]))

        let rain = result.profile.averages.first { $0.measure == .rain }
        XCTAssertEqual(rain?.matched, 0.25)
        XCTAssertTrue(rain?.isShare == true)
        XCTAssertEqual(rain?.matchedLabel, "25%")
    }

    /// Rain's baseline is a FREQUENCY, not the mean amount — otherwise the box
    /// would read "27% of days" against "0.03 inches", which compares nothing.
    func testRainIsJudgedAgainstHowOftenThoseDatesAreWet() {
        // Seven mid-Julys: one wet year in four of them, so those dates are wet
        // about 43% of the time. The matching day is dry.
        var records: [DailyRecord] = []
        for year in 2018...2024 {
            for dayOfMonth in 8...22 {
                let key = String(format: "%d-07-%02d", year, dayOfMonth)
                records.append(day(key, high: key == "2024-07-15" ? 100 : 90,
                                   rain: year % 2 == 0 ? 0.5 : 0))
            }
        }
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))]))

        let rain = result.profile.averages.first { $0.measure == .rain }
        XCTAssertEqual(rain?.matched, 1.0, "2024 is even, so the matching day was wet")
        XCTAssertEqual(rain?.usual ?? 0, 4.0 / 7.0, accuracy: 0.001)
        XCTAssertEqual(rain?.departureLabel, "+43 pts", "a share moves in POINTS, not percent")
    }

    /// A half-watched day can prove a high was reached, so it can still MATCH —
    /// but it can't be averaged. Its 40° low is an artifact of the hours nobody
    /// was looking, and it must not drag the mean down.
    func testAHalfWatchedDayMatchesButIsNotAveraged() {
        let records = [
            day("2024-08-01", high: 100, low: 78),
            day("2024-08-02", high: 100, low: 40, samples: 6),
        ]
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))]))

        XCTAssertEqual(result.matchCount, 2)
        XCTAssertEqual(result.profile.matchedDays, 1)
        XCTAssertEqual(result.profile.averages.first { $0.measure == .low }?.matched, 78)
    }

    // MARK: Year by year

    /// A year the station half-watched will always look calm. Comparing it to a
    /// full one compares uptime, not weather.
    func testAYearWithAGapIsCountedButMarkedIncomparable() {
        var records = summersOnly(2022...2024)
        // The station goes dark for four months of 2023 — a real gap, with the
        // archive running well past it on both sides.
        records.removeAll { $0.day >= "2023-02-01" && $0.day < "2023-06-01" }

        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))]))
        let holed = result.years.first { $0.year == 2023 }
        let full = result.years.first { $0.year == 2022 }

        XCTAssertNotNil(holed, "the year is still listed")
        XCTAssertFalse(holed?.isComparable ?? true)
        XCTAssertEqual(holed?.expected, 365, "a finished year expects all of itself")
        XCTAssertEqual(holed?.matched, 92, "the summer it DID watch still counts — Jun+Jul+Aug")
        XCTAssertTrue(full?.isComparable ?? false)
        XCTAssertEqual(full?.matched, 92)
    }

    /// "Do we normally get rain in September" is a question about YEARS, and
    /// the honest denominator is the comparable ones. A year the station
    /// half-watched must not be able to drag the fraction down — that reports
    /// uptime as weather, the mistake this file exists to prevent.
    func testTheYearRateCountsOnlyComparableYears() {
        var records = summersOnly(2021...2024)
        // 2022 loses four months. It still saw hot days, but it can't vote.
        records.removeAll { $0.day >= "2022-02-01" && $0.day < "2022-06-01" }

        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))]))
        guard let rate = result.yearRate else { return XCTFail("no year rate") }

        XCTAssertEqual(rate.yearsComparable, 3, "2022 is watched too thinly to count either way")
        XCTAssertEqual(rate.yearsWith, 3)
        XCTAssertEqual(rate.yearsUncounted, 1, "and it's reported, not silently dropped")
        XCTAssertTrue(rate.isUsual)
    }

    /// The other half of the same rule: a condition only two comparable years in
    /// four actually met is NOT usual, and the fraction has to say so rather
    /// than rounding itself into a pattern.
    func testAYearRateBelowHalfIsNotUsual() {
        var records = summersOnly(2021...2024)
        // Only 2023 and 2024 ever reach 100°.
        records = records.map { record in
            guard let year = DayKey.year(of: record.day), year < 2023 else { return record }
            var cooler = record
            cooler.tempMax = min(record.tempMax ?? 0, 95)
            return cooler
        }

        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))]))
        guard let rate = result.yearRate else { return XCTFail("no year rate") }

        XCTAssertEqual(rate.yearsComparable, 4)
        XCTAssertEqual(rate.yearsWith, 2)
        XCTAssertFalse(rate.isUsual, "two of four is not 'normally'")
    }

    /// Pinning a year narrows the days, the calendar and the months — but NOT
    /// the year-by-year card, whose whole job is cross-year comparison. One bar
    /// answers nothing, and "how does this year stack up" is exactly the
    /// question you have while looking at one year.
    func testYearByYearSpansEveryYearEvenWhenOneIsPinned() {
        let climate = Climatology(records: summersOnly(2021...2024))
        let hot = [Condition(.high, .atOrAbove(100))]

        let pinned = climate.run(DayQuery(conditions: hot, years: .year(2023)))
        XCTAssertEqual(pinned.matchCount, 92, "the days themselves are narrowed")
        XCTAssertEqual(pinned.years.map(\.year).sorted(), [2021, 2022, 2023, 2024])
        XCTAssertEqual(pinned.years.first { $0.year == 2021 }?.matched, 92)
    }

    /// …but the DATE scope still applies to it, so pinning September compares
    /// Septembers rather than whole years.
    func testYearByYearStillRespectsTheDateScope() {
        let climate = Climatology(records: summersOnly(2021...2024))
        let result = climate.run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))],
                                          scope: WeatherPeriod.months[7],   // August
                                          years: .year(2023)))

        XCTAssertEqual(result.years.count, 4)
        // August alone, not the whole 92-day summer.
        XCTAssertEqual(result.years.first { $0.year == 2021 }?.matched, 31)
    }

    /// The archive stops at yesterday, so a running year must expect only the
    /// days that have happened — otherwise every current year reads as a gap.
    func testTheRunningYearIsNotPenalisedForItsOwnFuture() {
        var records = summersOnly(2023...2023)
        records += (1...31).map { day(String(format: "2024-01-%02d", $0), high: 70) }

        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(100))]))
        let running = result.years.first { $0.year == 2024 }

        // 31 days elapsed of the record, 31 answered — complete as far as it goes.
        XCTAssertEqual(running?.expected, 31)
        XCTAssertTrue(running?.isComparable ?? false)
    }

    // MARK: A reading needs something to be read against

    /// 71° is an ordinary August dew point and a remarkable April one. Without
    /// a per-date baseline a list of forty readings is forty identical rows,
    /// and the day that actually mattered is buried in it.
    func testEachDayCarriesItsDepartureFromNormalForThatDate() {
        // A smooth seasonal curve, plus one freak warm day in early spring.
        var records = (2021...2024).flatMap { year -> [DailyRecord] in
            var out: [DailyRecord] = []
            var cursor = "\(year)-01-01"
            while cursor <= "\(year)-12-31" {
                let doy = Double((DayKey.distance(from: "\(year)-01-01", to: cursor) ?? 0) + 1)
                out.append(day(cursor, high: 72 + 26 * cos(2 * .pi * (doy - 213) / 365)))
                guard let next = DayKey.next(cursor) else { break }
                cursor = next
            }
            return out
        }
        let freak = records.firstIndex { $0.day == "2024-03-10" }!
        records[freak].tempMax = 95

        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(90))]))

        let march = result.days.first { $0.day == "2024-03-10" }
        XCTAssertNotNil(march?.departure)
        XCTAssertGreaterThan(march?.departure ?? 0, 25, "a 95° March day is far above its date's normal")

        // A 95° day in high summer is unremarkable — same reading, different fact.
        let august = result.days.first { $0.day.hasPrefix("2024-08") }
        XCTAssertLessThan(abs(august?.departure ?? 99), 10)

        // And it's the sort key that finds the interesting one.
        let ranked = result.days.sorted { abs($0.departure ?? 0) > abs($1.departure ?? 0) }
        XCTAssertEqual(ranked.first?.day, "2024-03-10")
    }

    /// No baseline is offered rather than a wrong one.
    func testNoDepartureWhereTheMeasureHasNoNormal() {
        let records = (1...40).map { day(String(format: "2024-07-%02d", min(31, $0)), high: 95) }
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.gust, .atOrAbove(0))]))
        XCTAssertTrue(result.days.allSatisfy { $0.departure == nil })
    }

    /// A "normal" built from one year is last year's weather; comparing to it
    /// would manufacture departures out of coincidence.
    func testNoDepartureFromAThinNormal() {
        let records = (1...31).map { day(String(format: "2024-07-%02d", $0), high: 95) }
        let result = Climatology(records: records)
            .run(DayQuery(conditions: [Condition(.high, .atOrAbove(90))]))
        XCTAssertTrue(result.days.allSatisfy { $0.departure == nil })
    }

    /// Found the hard way against real data: a January cold snap that sat
    /// between 17° and 19° all day reported ZERO days below 30°, because the
    /// station was struggling in the very cold that made it interesting — 8
    /// samples of 48. The rule is right and the count must stay clean, but the
    /// day can't just vanish.
    func testADayThatReadsAsAMatchButCantProveItIsKeptAside() {
        let solid = day("2026-01-20", high: 25)
        let thin = day("2026-01-24", high: 18, samples: 8)     // 17% watched
        let result = Climatology(records: [solid, thin])
            .run(DayQuery(conditions: [Condition(.high, .below(30))]))

        XCTAssertEqual(result.days.map(\.day), ["2026-01-20"], "only the provable day counts")
        XCTAssertEqual(result.unconfirmed.map(\.day), ["2026-01-24"])
        XCTAssertEqual(result.unconfirmed.first?.values.first, 18)
    }

    /// A thin day whose reading does NOT match isn't a near miss — it's just a
    /// day nothing can be said about, and listing it would be noise.
    func testAThinDayThatDoesntReadAsAMatchIsNotListed() {
        let thin = day("2026-01-24", high: 70, samples: 8)
        let result = Climatology(records: [thin])
            .run(DayQuery(conditions: [Condition(.high, .below(30))]))

        XCTAssertTrue(result.unconfirmed.isEmpty)
    }

    /// A day that CAN prove itself never lands in the aside, however cold.
    func testAWatchedDayIsNeverUnconfirmed() {
        let result = Climatology(records: [day("2026-01-24", high: 18)])
            .run(DayQuery(conditions: [Condition(.high, .below(30))]))

        XCTAssertEqual(result.matchCount, 1)
        XCTAssertTrue(result.unconfirmed.isEmpty)
    }

    func testEveryPresetIsRunnable() {
        let climate = Climatology(records: (1...28).map {
            day(String(format: "2024-07-%02d", $0), high: 95, low: 74, dew: 68, rain: 0.2)
        })
        for preset in DayQuery.presets {
            XCTAssertNoThrow(climate.run(preset), "\(preset.name) failed")
            XCTAssertFalse(preset.describe.isEmpty)
        }
    }
}
