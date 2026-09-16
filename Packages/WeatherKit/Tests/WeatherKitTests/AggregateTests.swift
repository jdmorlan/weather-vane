//
//  AggregateTests.swift
//
//  The other verb. A predicate that quietly answers a different question is bad; an AGGREGATE that does
//  is worse, because a wrong total looks exactly like a right one — there's no day list to sanity-check
//  it against. So: the reductions, the grouping that decides what a number is per, and above all the
//  coverage a thin group has to admit to.
//

import XCTest
@testable import WeatherKit

final class AggregateTests: XCTestCase {

    /// Two Julys and one August, with known rain so every total is checkable by hand.
    private func archive() -> Climatology {
        var records: [DailyRecord] = []
        func add(_ day: String, rain: Double?, high: Double?) {
            // Fully sampled, so nothing is excluded for being a partial day — coverage of the DAY is a
            // separate concern from coverage of the GROUP, which is what these tests are about.
            var record = DailyRecord(day: day, sampleCount: 288, expectedSamples: 288)
            record.tempMax = high
            record.precipTotal = rain
            records.append(record)
        }
        // July 2023: 3 days, 1.00" total. August 2023: 2 days, 0.50". July 2024: 2 days, 4.00".
        add("2023-07-01", rain: 0.50, high: 95)
        add("2023-07-02", rain: 0.50, high: 101)
        add("2023-07-03", rain: 0.00, high: 99)
        add("2023-08-01", rain: 0.25, high: 90)
        add("2023-08-02", rain: 0.25, high: 88)
        add("2024-07-01", rain: 3.00, high: 80)
        add("2024-07-02", rain: 1.00, high: 105)
        return Climatology(records: records)
    }

    private func result(_ aggregate: Aggregate, conditions: [Condition] = [],
                       scope: WeatherPeriod? = nil, years: YearScope = .all) throws -> AggregateResult {
        let query = DayQuery(conditions: conditions, scope: scope, years: years, aggregate: aggregate)
        return try XCTUnwrap(archive().aggregate(query))
    }

    // MARK: - The question that couldn't be asked

    /// "Which month/year did we get the most rain?" — the question that hit a wall in the ask lane and
    /// produced the first gap note.
    func testWettestMonthOfRecord() throws {
        let out = try result(Aggregate(measure: .rain, reduce: .sum, groupBy: .month, rank: .highest))
        XCTAssertEqual(out.leader?.label, "July 2024")
        XCTAssertEqual(out.leader?.value ?? 0, 4.00, accuracy: 0.001)
        XCTAssertEqual(out.groupsConsidered, 3, "two Julys and an August")
    }

    /// `monthOfYear` stacks every July together — "which month is usually wettest" — as against `month`,
    /// which keeps them apart. Getting these two confused would answer a different question with a
    /// perfectly plausible number.
    func testMonthOfYearStacksTheSameMonthAcrossYears() throws {
        let out = try result(Aggregate(measure: .rain, reduce: .sum, groupBy: .monthOfYear, rank: .highest))
        XCTAssertEqual(out.leader?.label, "July")
        XCTAssertEqual(out.leader?.value ?? 0, 5.00, accuracy: 0.001, "1.00 in 2023 plus 4.00 in 2024")
    }

    func testGroupByYear() throws {
        let out = try result(Aggregate(measure: .rain, reduce: .sum, groupBy: .year))
        XCTAssertEqual(out.groups.map(\.label), ["2023", "2024"], "chronological with no rank")
        XCTAssertEqual(out.groups[0].value, 1.50, accuracy: 0.001)
    }

    func testMeanMaxMinAndCount() throws {
        let july2024 = WeatherPeriod(name: "July", start: "07-01", endExclusive: "08-01")
        let mean = try result(Aggregate(measure: .high, reduce: .mean), scope: july2024, years: .year(2024))
        XCTAssertEqual(mean.leader?.value ?? 0, 92.5, accuracy: 0.001)

        let max = try result(Aggregate(measure: .high, reduce: .max))
        XCTAssertEqual(max.leader?.value ?? 0, 105, accuracy: 0.001)

        let min = try result(Aggregate(measure: .high, reduce: .min))
        XCTAssertEqual(min.leader?.value ?? 0, 80, accuracy: 0.001)

        let count = try result(Aggregate(measure: .rain, reduce: .count))
        XCTAssertEqual(count.leader?.value ?? 0, 7, accuracy: 0.001)
    }

    /// An aggregate reduces the days the PREDICATE selected — "how much rain fell on days over 100°" is
    /// one question, not two. If conditions were ignored here the number would be silently wrong.
    func testAggregateReducesOnlyTheSelectedDays() throws {
        let out = try result(Aggregate(measure: .rain, reduce: .sum),
                             conditions: [Condition(.high, .atOrAbove(100))])
        XCTAssertEqual(out.leader?.value ?? 0, 1.50, accuracy: 0.001,
                       "only 2023-07-02 (0.50) and 2024-07-02 (1.00) were over 100°")
    }

    // MARK: - Coverage: the failure with no symptom

    /// A month with three days on record must not present its total as though it saw the month. This is
    /// the whole reason `daysExpected` exists — the group most likely to be thin is the month in
    /// progress, which is also the one most likely to be asked about.
    func testAThinGroupIsNotTrustworthy() throws {
        let out = try result(Aggregate(measure: .rain, reduce: .sum, groupBy: .month))
        let july2023 = try XCTUnwrap(out.groups.first { $0.label == "July 2023" })
        XCTAssertEqual(july2023.daysCounted, 3)
        XCTAssertGreaterThan(july2023.daysExpected, 3, "the archive spans past these three days")
        XCTAssertFalse(july2023.isTrustworthy)
    }

    /// A group is measured against its OWN calendar, not against the slice of it the archive reached.
    ///
    /// Clipping was the first implementation and it was wrong on real data: the station's first year held
    /// only an autumn, and clipping presented it as a complete year — "2022: 65°" beside "2023: 79°",
    /// reading as a cool year when it was a seasonal fragment. A partial year is not slightly less
    /// certain, it is BIASED, and nothing in the number shows it.
    func testAPartialYearIsMeasuredAgainstTheWholeYear() throws {
        let out = try result(Aggregate(measure: .rain, reduce: .sum, groupBy: .year))
        let y2024 = try XCTUnwrap(out.groups.first { $0.label == "2024" })
        XCTAssertEqual(y2024.daysExpected, 366, "2024 owes a full leap year, however little was recorded")
        XCTAssertFalse(y2024.isTrustworthy, "two days of a year must never quote as the year")
    }

    /// MATCHING IS NOT MISSING. A lightning total once reported "only 76 of 365 days on record", which
    /// reads as a broken station when it means 289 quiet days. Coverage asks what the station SAW; the
    /// conditions decide what fed the number, and those are different questions.
    func testConditionsNarrowTheNumberButNotTheCoverage() throws {
        let july = WeatherPeriod(name: "July", start: "07-01", endExclusive: "08-01")
        let out = try result(Aggregate(measure: .rain, reduce: .sum),
                            conditions: [Condition(.high, .atOrAbove(100))],
                            scope: july, years: .year(2023))
        let group = try XCTUnwrap(out.leader)
        XCTAssertEqual(group.daysCounted, 1, "one July 2023 day was over 100°")
        XCTAssertEqual(group.daysObserved, 3, "but the station saw three days that July")
        XCTAssertEqual(group.daysExpected, 31)
    }

    func testNoMatchingDaysIsAnEmptyResultNotZero() throws {
        let out = try result(Aggregate(measure: .rain, reduce: .sum),
                             conditions: [Condition(.high, .atOrAbove(200))])
        XCTAssertTrue(out.isEmpty, "nothing to reduce must not report a total of 0.00\"")
    }

    // MARK: - Saying it

    func testAggregateSurvivesTheRoundTrip() throws {
        let query = DayQuery(name: "Wettest months",
                             conditions: [Condition(.high, .atOrAbove(90))],
                             scope: WeatherPeriod.seasons[1],
                             years: .year(2024),
                             aggregate: Aggregate(measure: .rain, reduce: .sum,
                                                  groupBy: .monthOfYear, rank: .highest, limit: 3))
        XCTAssertEqual(try DayQuery(json: query.jsonObject), query)
    }

    /// With an aggregate the reduction is the question; "Any day, total rain by month" reads like a bug.
    func testDescribeLeadsWithTheReduction() {
        let bare = DayQuery(conditions: [], aggregate: Aggregate(measure: .rain, reduce: .sum, groupBy: .month))
        XCTAssertEqual(bare.describe, "Total rain by month")

        let narrowed = DayQuery(conditions: [Condition(.high, .atOrAbove(100))],
                                aggregate: Aggregate(measure: .rain, reduce: .sum))
        XCTAssertTrue(narrowed.describe.hasPrefix("Total rain on days with"), narrowed.describe)
    }

    func testUnknownReductionIsRefusedWithTheRealList() {
        let json: [String: Any] = [
            "conditions": [],
            "aggregate": ["measure": "rain", "reduce": "median"],
        ]
        XCTAssertThrowsError(try DayQuery(json: json)) { error in
            guard case QueryLanguageError.unknown(_, _, let allowed)? = error as? QueryLanguageError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(allowed.contains("sum"))
        }
    }

    /// THE AVERAGE OF AN AMOUNT IS PER CYCLE, NOT PER DAY.
    ///
    /// Two Julys hold 5.00" between them across 5 days. The per-day mean is 1.00" — a number that says
    /// nothing anyone asked, since most days it doesn't rain at all. What "July averages" means is the
    /// month's total across the Julys on record: 2.50".
    func testAverageRainIsPerMonthNotPerDay() throws {
        let julys = try result(Aggregate(measure: .rain, reduce: .mean, groupBy: .monthOfYear))
        let july = try XCTUnwrap(julys.groups.first { $0.label == "July" })
        XCTAssertEqual(july.value, 2.50, accuracy: 0.001)   // (1.00 + 4.00) / 2 Julys
        XCTAssertEqual(july.cycles, 2)
        XCTAssertEqual(july.daysCounted, 5)                 // …and NOT 5.00/5 = 1.00

        // Across all time the cycle is the year: 5.50" over two years.
        let overall = try result(Aggregate(measure: .rain, reduce: .mean, groupBy: .none))
        XCTAssertEqual(try XCTUnwrap(overall.groups.first).value, 2.75, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(overall.groups.first).cycles, 2)

        // A state measure keeps the per-day mean — no number of daily highs adds up to a month.
        let highs = try result(Aggregate(measure: .high, reduce: .mean, groupBy: .monthOfYear))
        let julyHigh = try XCTUnwrap(highs.groups.first { $0.label == "July" })
        XCTAssertEqual(julyHigh.value, (95 + 101 + 99 + 80 + 105) / 5.0, accuracy: 0.001)
    }

    /// A dry month still happened, so it belongs in the divisor — otherwise the average is of the wet
    /// ones only, which is a different and much larger number.
    func testACycleWithNoMatchingDaysStillCounts() throws {
        let query = DayQuery(conditions: [Condition(.rain, .atOrAbove(0.75))],
                             aggregate: Aggregate(measure: .rain, reduce: .mean, groupBy: .monthOfYear))
        let july = try XCTUnwrap(try XCTUnwrap(archive().aggregate(query)).groups.first)
        // Only 2024's 3.00" and 1.00" match, but both Julys are Julys: 4.00 / 2.
        XCTAssertEqual(july.value, 2.00, accuracy: 0.001)
        XCTAssertEqual(july.cycles, 2)
    }

    /// The label has to say what the number is per, or the wrong reading is the plausible one.
    func testAPerCycleMeanSaysWhatItIsPer() {
        XCTAssertEqual(Aggregate(measure: .rain, reduce: .mean, groupBy: .monthOfYear).describe,
                       "Average rain in each month of the year")
        XCTAssertEqual(Aggregate(measure: .rain, reduce: .mean, groupBy: .year).describe,
                       "Average rain in a month, by year")
        XCTAssertEqual(Aggregate(measure: .rain, reduce: .mean, groupBy: .none).describe,
                       "Average rain per year")
        // A state measure is unchanged — its average was always per day.
        XCTAssertEqual(Aggregate(measure: .high, reduce: .mean, groupBy: .year).describe,
                       "Average high by year")
        // July 2023 IS one July, so the per-cycle mean there is the total under another name.
        XCTAssertTrue(Aggregate(measure: .rain, reduce: .mean, groupBy: .month).meanRestatesTotal)
        XCTAssertFalse(Aggregate(measure: .rain, reduce: .mean, groupBy: .monthOfYear).meanRestatesTotal)
    }

    /// A total of a temperature is not a number, and the language says so instead of returning 7,412°.
    func testSummingAMeasureThatDoesNotAccumulateIsRefused() {
        let json: [String: Any] = [
            "conditions": [],
            "aggregate": ["measure": "high", "reduce": "sum", "groupBy": "year"],
        ]
        XCTAssertThrowsError(try DayQuery(json: json)) { error in
            guard case QueryLanguageError.unknown(let path, _, let allowed)? = error as? QueryLanguageError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(path, "aggregate.reduce")
            XCTAssertFalse(allowed.contains("sum"))
            XCTAssertTrue(allowed.contains("mean"))
        }
        // The same reduction on a measure that DOES accumulate stays askable.
        XCTAssertNoThrow(try DayQuery(json: ["conditions": [],
                                             "aggregate": ["measure": "rain", "reduce": "sum"]]))
    }

    /// Which measures add up, and what each falls back to when a total can't be asked of it.
    func testAccumulationAndTheNaturalReduction() {
        XCTAssertEqual(Set(Measure.allCases.filter(\.accumulates)), [.rain, .lightning])
        XCTAssertEqual(Measure.rain.defaultReduction, .sum)
        XCTAssertEqual(Measure.gust.defaultReduction, .max)      // a floor reading peaks
        XCTAssertEqual(Measure.low.defaultReduction, .min)       // a ceiling reading troughs
        XCTAssertEqual(Measure.humidity.defaultReduction, .mean) // a central one averages
        XCTAssertFalse(Measure.high.reductions.contains(.sum))
    }

    func testSchemaIncludesTheAggregateAndSerialises() throws {
        let properties = try XCTUnwrap(DayQuery.jsonSchema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["aggregate"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(DayQuery.jsonSchema))
    }
}
