import XCTest
@testable import WeatherKit

/// The interval as the unit of the question. Most of what's checked here is
/// arithmetic that only goes wrong at the edges of the calendar — leap days,
/// windows that run through New Year, windows that haven't finished — plus the
/// honesty gates that keep a young archive quiet.
final class PeriodSummaryTests: XCTestCase {

    // MARK: Fixtures

    /// A smooth seasonal year: highs peak near Aug 1 and bottom in late January,
    /// nights 22° below, dew point 3° below the night.
    ///
    /// Smooth on purpose — two flat levels put a median exactly ON a value and
    /// let a tie decide the answer, which has bitten this suite before.
    private func seasonalYear(_ y: Int, through end: String? = nil,
                              warmerBy offset: Double = 0) -> [DailyRecord] {
        var records: [DailyRecord] = []
        var cursor = "\(y)-01-01"
        let last = end ?? "\(y)-12-31"
        while cursor <= last {
            let doy = Double((DayKey.distance(from: "\(y)-01-01", to: cursor) ?? 0) + 1)
            let high = 72 + 26 * cos(2 * .pi * (doy - 213) / 365) + offset

            var record = DailyRecord(day: cursor, sampleCount: 48, expectedSamples: 48)
            record.tempMax = high
            record.tempMin = high - 22
            record.tempMean = high - 11
            record.dewPointMean = high - 25
            record.dewPointMax = high - 20
            record.precipTotal = DayKey.monthDay(of: cursor).hasSuffix("-10") ? 0.5 : 0
            record.schemaVersion = DailyRecord.currentSchemaVersion
            records.append(record)
            guard let next = DayKey.next(cursor) else { break }
            cursor = next
        }
        return records
    }

    private func fourYearClimate() -> Climatology {
        Climatology(records: (0..<4).flatMap { i in
            seasonalYear(2021 + i, warmerBy: Double(i) * 0.5)
        })
    }

    private var september: WeatherPeriod {
        WeatherPeriod.months[8]
    }

    // MARK: The period as a calendar object

    /// A period is half-open in MONTH-DAYS for exactly one reason: an inclusive
    /// `"02-28"` end silently drops February 29 every leap year. That bug has
    /// already cost this codebase a chill-hours season; the type shouldn't be
    /// able to express it.
    func testFebruaryKeepsItsTwentyNinth() {
        let february = WeatherPeriod.months[1]
        XCTAssertEqual(february.endExclusive, "03-01")
        XCTAssertTrue(february.monthDays.contains("02-29"))
        XCTAssertEqual(february.monthDays.count, 29)

        // And it resolves to the right real dates on both sides of a leap year.
        XCTAssertEqual(february.bounds(inYear: 2024)?.end, "2024-02-29")
        XCTAssertEqual(february.bounds(inYear: 2023)?.end, "2023-02-28")
    }

    /// A wrapping window belongs to the year it OPENED in and runs into the next.
    func testWinterWrapsTheYearEnd() {
        let winter = WeatherPeriod.seasons.first { $0.name == "Winter" }!
        XCTAssertTrue(winter.wrapsYearEnd)
        XCTAssertTrue(winter.contains(monthDay: "12-15"))
        XCTAssertTrue(winter.contains(monthDay: "01-15"))
        XCTAssertFalse(winter.contains(monthDay: "03-01"))

        let bounds = winter.bounds(inYear: 2024)
        XCTAssertEqual(bounds?.start, "2024-12-01")
        XCTAssertEqual(bounds?.end, "2025-02-28")

        // Ordered ALONG the window, so December comes before January.
        XCTAssertEqual(winter.monthDays.first, "12-01")
        XCTAssertEqual(winter.monthDays.last, "02-29")
    }

    /// Tempest's week/month/year selector needs no separate machinery — a
    /// rolling window is a period anchored to a day.
    func testRollingWindowIsJustAPeriod() {
        let week = WeatherPeriod.rolling(days: 7, name: "Last 7 days", endingAt: "2025-06-10")
        XCTAssertEqual(week?.start, "06-04")
        XCTAssertEqual(week?.endExclusive, "06-11")
        XCTAssertEqual(week?.curveLength, 7)
    }

    /// The curve is drawn in a LEAP reference year, so a window touching the end
    /// of February carries one more point than most real years will fill. That's
    /// the right trade — Feb 29 is a real date with real records — but it means
    /// a year's actual length comes from `bounds`, never from the curve.
    func testTheCurveIsALeapYearLengthAndBoundsAreNot() {
        let week = WeatherPeriod.rolling(days: 7, name: "Last 7 days", endingAt: "2025-03-05")!
        XCTAssertEqual(week.curveLength, 8)
        XCTAssertTrue(week.monthDays.contains("02-29"))

        let bounds = week.bounds(inYear: 2025)!
        XCTAssertEqual((DayKey.distance(from: bounds.start, to: bounds.end) ?? 0) + 1, 7)
        let leap = week.bounds(inYear: 2024)!
        XCTAssertEqual((DayKey.distance(from: leap.start, to: leap.end) ?? 0) + 1, 8)
    }

    /// Feb 29 doesn't exist in most years; resolving it there must fail rather
    /// than lenient-parse into March 1 wearing February's name.
    func testALeapDayDoesNotSilentlyBecomeMarchFirst() {
        XCTAssertEqual(WeatherPeriod.resolve("02-29", inYear: 2024), "2024-02-29")
        XCTAssertNil(WeatherPeriod.resolve("02-29", inYear: 2023))
    }

    // MARK: Which instance is "this one"

    /// Asked about September in August, the answer is LAST September — the most
    /// recent real one — not an empty line for a month that hasn't started.
    func testFocusYearIsTheMostRecentInstanceThatHasBegun() {
        let summary = fourYearClimate().summary(for: september, asOf: "2025-08-06")
        XCTAssertEqual(summary.focusYear, 2024)
        XCTAssertEqual(summary.days.count, 30)
        XCTAssertNotNil(summary.days.first?.actual)
        XCTAssertEqual(summary.days.first?.actual?.day, "2024-09-01")
    }

    /// Inside the window, the focus is the running instance.
    func testAWindowInProgressIsItsOwnFocus() {
        let records = (0..<4).flatMap { seasonalYear(2021 + $0) }
            + seasonalYear(2025, through: "2025-09-14")
        let summary = Climatology(records: records).summary(for: september, asOf: "2025-09-15")

        XCTAssertEqual(summary.focusYear, 2025)
        let running = summary.current
        XCTAssertTrue(running?.isInProgress ?? false)
        XCTAssertFalse(running?.isTrustworthy ?? true)

        // The archive stops at yesterday BY DESIGN, so a running window expects
        // days only through yesterday — 14 of them, all present.
        XCTAssertEqual(running?.daysExpected, 14)
        XCTAssertEqual(running?.daysCovered, 14)
        XCTAssertEqual(running?.coverage ?? 0, 1.0, accuracy: 0.001)
    }

    // MARK: Aggregates

    func testTypicalsComeFromCompleteWellWatchedYearsOnly() {
        let summary = fourYearClimate().summary(for: september, asOf: "2025-08-06")

        XCTAssertEqual(summary.comparableYears, 4)
        XCTAssertTrue(summary.isMeaningful)
        // September's highs run ~94 → ~85 on this curve; the mean sits between.
        XCTAssertEqual(summary.typicalHigh ?? 0, 90, accuracy: 2.5)
        XCTAssertEqual(summary.typicalLow ?? 0, 68, accuracy: 2.5)
        // Three rain days a month at 0.5" → 0.5" in September (only the 10th).
        XCTAssertEqual(summary.typicalPrecip ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(summary.typicalRainDays ?? 0, 1, accuracy: 0.001)

        // The offsets make each year slightly warmer than the last.
        XCTAssertEqual(summary.warmestYear?.year, 2024)
        XCTAssertEqual(summary.coolestYear?.year, 2021)
    }

    /// One September is last September, not a climate. The years are still
    /// listed — seeing the record you have is right — but nothing is called
    /// typical.
    func testOneYearNamesNoTypical() {
        let summary = Climatology(records: seasonalYear(2024))
            .summary(for: september, asOf: "2025-08-06")

        XCTAssertEqual(summary.years.count, 1)
        XCTAssertFalse(summary.isMeaningful)
        XCTAssertNil(summary.typicalHigh)
        XCTAssertNil(summary.typicalPrecip)
        XCTAssertNil(WeatherAlmanac.periodHeadline(summary))
    }

    /// A half-watched day is still a day it rained, but it can't move a mean
    /// temperature — its "high" is the high of the hours we happened to catch.
    func testUnreliableDaysCountForRainAndNotForTemperature() {
        var records = seasonalYear(2023) + seasonalYear(2024)
        // Wreck Sept 20 2024's coverage, keeping a big rain total and an
        // impossible-looking cold high.
        let index = records.firstIndex { $0.day == "2024-09-20" }!
        records[index].sampleCount = 6
        records[index].tempMax = 20
        records[index].precipTotal = 3.0

        let summary = Climatology(records: records).summary(for: september, asOf: "2025-08-06")
        let year = summary.years.first { $0.year == 2024 }!

        XCTAssertEqual(year.precip, 3.5, accuracy: 0.001)     // 0.5 on the 10th + 3.0
        XCTAssertEqual(year.rainDays, 2)
        XCTAssertGreaterThan(year.high ?? 0, 85)              // the 20° day never landed
        XCTAssertNotEqual(year.coldest?.day, "2024-09-20")
    }

    /// Found against the real archive: a September–October window caught the
    /// station's very first days in October 2022 and printed "high 88.2" from
    /// three days, in a column beside years watched throughout. A mean over 8%
    /// of a window is not that window's mean. The rain stays — a floor is still
    /// a floor, and the day it poured is still a day it poured.
    func testABarelyWatchedYearWithholdsItsAveragesAndKeepsItsRain() {
        var records = seasonalYear(2023) + seasonalYear(2024)
        // 2022 starts on September 26 — five of September's thirty days.
        records += seasonalYear(2022).filter { $0.day >= "2022-09-26" }

        let summary = Climatology(records: records).summary(for: september, asOf: "2025-08-06")
        let thin = summary.years.first { $0.year == 2022 }

        XCTAssertNotNil(thin, "the year should still be listed")
        XCTAssertEqual(thin?.daysCovered, 5)
        XCTAssertNil(thin?.high)
        XCTAssertNil(thin?.low)
        XCTAssertNil(thin?.dewPoint)
        XCTAssertFalse(thin?.isTrustworthy ?? true)
        XCTAssertEqual(thin?.rainDays, 0)   // the 10th wasn't watched; nothing invented

        // And a well-watched year in the same summary is unaffected.
        XCTAssertNotNil(summary.years.first { $0.year == 2024 }?.high)
    }

    /// Two nights thresholds in one sentence say the same thing twice. The
    /// finding worth stating is that different measures let go weeks apart.
    func testTheHeadlinePairsTwoDifferentMeasures() {
        let summary = fourYearClimate().summary(for: september, asOf: "2025-08-06")
        let headline = WeatherAlmanac.periodHeadline(summary) ?? ""

        let named = ["nights", "afternoons", "humidity"].filter { headline.contains($0) }
        XCTAssertEqual(named.count, 2, "headline should name two distinct measures: \(headline)")
    }

    func testExtremesAreScopedToTheWindow() {
        let climate = fourYearClimate()
        let summary = climate.summary(for: september, asOf: "2025-08-06")

        // The all-time hottest day is at the peak of the curve, outside September.
        XCTAssertNotNil(climate.extremes().hottest)
        XCTAssertFalse(september.contains(monthDay: DayKey.monthDay(of: climate.extremes().hottest!.day)))
        // The window's hottest must be a September one.
        XCTAssertEqual(DayKey.monthDay(of: summary.extremes.hottest!.day).prefix(2), "09")
    }

    // MARK: The shape inside the window

    /// The whole point of the view: a month is a slope, and the overall average
    /// erases it.
    func testDriftReadsTheSlopeAcrossTheWindow() {
        let summary = fourYearClimate().summary(for: september, asOf: "2025-08-06")
        let drift = summary.drift

        XCTAssertNotNil(drift)
        XCTAssertLessThan(drift?.highChange ?? 0, -5)   // afternoons cool through the month
        XCTAssertLessThan(drift?.lowChange ?? 0, -5)    // and so do the nights
    }

    /// Crossings are the answer to "WHEN in September" — and they must land
    /// inside the window and run in window order, which for a wrapping period is
    /// not calendar order.
    func testCrossingsLandInsideTheWindowAndRunInWindowOrder() {
        let summary = fourYearClimate().summary(for: september, asOf: "2025-08-06")

        XCTAssertFalse(summary.crossings.isEmpty)
        for crossing in summary.crossings {
            XCTAssertTrue(september.contains(monthDay: crossing.monthDay),
                          "\(crossing.label) dated \(crossing.monthDay) is outside September")
        }
        let dates = summary.crossings.map(\.monthDay)
        XCTAssertEqual(dates, dates.sorted())

        // On this curve the nights cross 70° and the afternoons cross 90°, both
        // inside the month — the two facts that make September readable.
        XCTAssertTrue(summary.crossings.contains { $0.track == "Nights" && $0.label == "below 70°" })
        XCTAssertTrue(summary.crossings.contains { $0.track == "Afternoons" && $0.label == "below 90°" })
    }

    /// A window that sits between thresholds shouldn't invent one. The peak of
    /// the curve is the honest test: highs hold in the high 90s for a fortnight
    /// and cross nothing on the way through, so the card has nothing to say
    /// about when the window turns — because it doesn't.
    func testAWindowBetweenThresholdsHasNoCrossings() {
        let peak = WeatherPeriod(name: "Peak", from: "07-25", throughInclusive: "08-05")!
        let summary = fourYearClimate().summary(for: peak, asOf: "2025-09-06")
        XCTAssertTrue(summary.crossings.isEmpty,
                      "invented \(summary.crossings.map(\.id))")
    }

    /// …but July, which looks flat, genuinely isn't: the afternoons climb
    /// through 95° on the way to the peak, and that IS the fact about July.
    func testJulyReportsTheClimbToThePeak() {
        let summary = fourYearClimate().summary(for: WeatherPeriod.months[6], asOf: "2025-09-06")
        XCTAssertTrue(summary.crossings.contains { $0.track == "Afternoons" && $0.label == "above 95°" })
    }

    // MARK: Grain — the browser's one control

    /// A day is the shortest period, not a special case. That's what lets
    /// "September 1st, every year" and "September, every year" be one question
    /// at two grains.
    func testADayIsAWindowOfOne() {
        let day = WeatherPeriod.day(containing: "2025-09-01")
        XCTAssertEqual(day.monthDays, ["09-01"])
        XCTAssertEqual(day.bounds(inYear: 2024)?.start, "2024-09-01")
        XCTAssertEqual(day.bounds(inYear: 2024)?.end, "2024-09-01")
    }

    /// A week is date-anchored, not Sunday-anchored: a calendar week starts on a
    /// different DATE every year, so pooling one across years would compare
    /// seven different windows and call the result a comparison.
    func testAWeekIsSevenDaysEndingOnTheAnchor() {
        let week = WeatherPeriod.week(ending: "2025-09-07")
        XCTAssertEqual(week.monthDays.count, 7)
        XCTAssertEqual(week.monthDays.first, "09-01")
        XCTAssertEqual(week.monthDays.last, "09-07")
        // Same span in a different year — the whole point.
        XCTAssertEqual(week.bounds(inYear: 2023)?.start, "2023-09-01")
        XCTAssertEqual(week.bounds(inYear: 2023)?.end, "2023-09-07")
    }

    /// The arrows step by the grain's OWN width. Back from September is August,
    /// not August 31st — otherwise the control nudges instead of walking.
    func testEachGrainStepsByItsOwnWidth() {
        XCTAssertEqual(WeatherGrain.day.step("2025-09-04", by: -1), "2025-09-03")
        XCTAssertEqual(WeatherGrain.week.step("2025-09-08", by: -1), "2025-09-01")
        XCTAssertEqual(WeatherGrain.month.step("2025-09-15", by: 1), "2025-10-15")
        XCTAssertEqual(WeatherGrain.season.step("2025-09-15", by: 1), "2025-12-15")
        XCTAssertEqual(WeatherGrain.year.step("2025-09-15", by: -1), "2024-09-15")
        XCTAssertNil(WeatherGrain.all.step("2025-09-15", by: 1), "all time is not a position")
    }

    /// Month arithmetic must clamp, not overflow. Stepping back from March 31
    /// lands in February — a naive 30-day step lands on March 1 and the walk
    /// silently skips a month.
    func testSteppingMonthsClampsToTheShorterMonth() {
        XCTAssertEqual(WeatherGrain.month.step("2025-03-31", by: -1), "2025-02-28")
        XCTAssertEqual(WeatherGrain.month.step("2024-03-31", by: -1), "2024-02-29")
        // And twelve months forward from a leap day is the 28th, not March 1.
        XCTAssertEqual(WeatherGrain.year.step("2024-02-29", by: 1), "2025-02-28")
    }

    /// Pooling a YEAR across years is the whole archive — the grain next door.
    /// Offering the toggle there would give two controls one destination.
    func testOnlyTheCyclicGrainsCanPool() {
        XCTAssertTrue(WeatherGrain.day.canPool)
        XCTAssertTrue(WeatherGrain.month.canPool)
        XCTAssertTrue(WeatherGrain.season.canPool)
        XCTAssertFalse(WeatherGrain.year.canPool)
        XCTAssertFalse(WeatherGrain.all.canPool)
        XCTAssertFalse(WeatherGrain.all.isPositional)
        XCTAssertNil(WeatherGrain.all.period(containing: "2025-09-01"))
    }

    /// The grain's window has to contain the date that chose it — the invariant
    /// that keeps the label and the content describing the same thing.
    func testEveryPositionalGrainContainsItsAnchor() {
        for grain in WeatherGrain.allCases where grain.isPositional {
            let day = "2025-09-04"
            guard let period = grain.period(containing: day) else {
                return XCTFail("\(grain) made no window")
            }
            XCTAssertTrue(period.contains(monthDay: "09-04"),
                          "\(grain.label) window \(period.name) doesn't hold its own anchor")
        }
    }

    // MARK: A crossing shows its work

    /// "Nights drop below 70° on Sep 4" is a MEDIAN of one date per year. Those
    /// dates were always computed and always discarded, which left the app's
    /// only dated prediction as the one claim you couldn't interrogate.
    func testACrossingCarriesTheYearsBehindIt() {
        let summary = fourYearClimate().summary(for: september, asOf: "2025-08-06")
        guard let nights = summary.crossings.first(where: { $0.track == "Nights" && $0.label == "below 70°" }),
              let spread = nights.spread else { return XCTFail("no crossing to check") }

        XCTAssertEqual(spread.occurrences.count, nights.yearsObserved,
                       "one occurrence per observed year")
        XCTAssertEqual(Set(spread.occurrences.map(\.year)), [2021, 2022, 2023, 2024])

        // The headline date and the emphasised occurrence must be the SAME
        // number. They're both `summary.typical` by construction here, and a
        // second derivation off the axis is exactly how a card starts
        // contradicting the sentence above it.
        XCTAssertEqual(spread.typical, nights.monthDay)
        XCTAssertEqual(spread.earliest, nights.earliest)
        XCTAssertEqual(spread.latest, nights.latest)
    }

    /// The window numbers already exclude a year the station half-missed. The
    /// evidence list has to exclude it too — showing a date that isn't allowed
    /// to be the earliest, beside a range that says it isn't, is worse than
    /// showing three dates.
    func testAnUnwatchedYearContributesNoOccurrence() {
        var records = (0..<4).flatMap { seasonalYear(2021 + $0, warmerBy: Double($0) * 0.5) }
        // 2023 goes dark for the whole second half — the window the autumn
        // crossing is computed in.
        records.removeAll { $0.day >= "2023-07-01" && $0.day < "2024-01-01" }

        let summary = Climatology(records: records).summary(for: september, asOf: "2025-08-06")
        guard let nights = summary.crossings.first(where: { $0.track == "Nights" && $0.label == "below 70°" }),
              let spread = nights.spread else { return XCTFail("no crossing to check") }

        XCTAssertFalse(spread.occurrences.contains { $0.year == 2023 },
                       "an unwatched year can't be ranked, so it can't be shown as evidence")
        XCTAssertEqual(spread.occurrences.count, nights.yearsObserved)
    }

    func testHeadlineLeadsWithACrossingWhenThereIsOne() {
        let summary = fourYearClimate().summary(for: september, asOf: "2025-08-06")
        let headline = WeatherAlmanac.periodHeadline(summary)
        XCTAssertNotNil(headline)
        XCTAssertTrue(headline?.contains("September turns") ?? false)
    }

    /// A wrapping window has to summarize as one thing, not two half-years.
    func testAWrappingWindowSummarizesAsOneStretch() {
        let winter = WeatherPeriod.seasons.first { $0.name == "Winter" }!
        let summary = fourYearClimate().summary(for: winter, asOf: "2025-08-06")

        // 2021's winter opens Dec 1 2021 and closes Feb 28 2022 — inside the record.
        let instance = summary.years.first { $0.year == 2022 }
        XCTAssertEqual(instance?.start, "2022-12-01")
        XCTAssertEqual(instance?.end, "2023-02-28")
        XCTAssertEqual(instance?.daysCovered, 90)
        XCTAssertTrue(instance?.isTrustworthy ?? false)

        // The last winter on record runs past the archive and can't be trusted.
        XCTAssertFalse(summary.years.first { $0.year == 2024 }?.isTrustworthy ?? true)
    }
}
