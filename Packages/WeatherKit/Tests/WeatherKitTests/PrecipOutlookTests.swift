//
//  PrecipOutlookTests.swift  (WeatherKit)
//
//  THE CARD'S WHOLE VALUE IS THE DENOMINATOR. "4 of 5 models bring rain" is only
//  worth reading if the 5 is really 5 — if a model that failed to load quietly
//  vanished, the same screen would say "4 of 4 agree" about a split. So most of
//  what is checked here is the bookkeeping rather than the arithmetic.
//

import XCTest
@testable import WeatherKit

final class PrecipOutlookTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func times(_ n: Int) -> [Date] {
        (0..<n).map { base.addingTimeInterval(Double($0) * 3600) }
    }

    private func row(_ model: PrecipModel, _ values: [Double?]) -> PrecipOutlook.Row {
        PrecipOutlook.Row(model: model, inches: values)
    }

    // MARK: The denominator

    /// A MODEL THAT DID NOT ANSWER STILL OCCUPIES ITS ROW. Dropping it shrinks the
    /// denominator, so a genuine split would be reported as unanimous agreement
    /// among whoever happened to load — the exact false confidence this prevents.
    func testAModelThatReturnedNothingStillHoldsItsRow() throws {
        let json = """
        {"hourly":{"time":[1700000000,1700003600],
          "precipitation_ncep_nbm_conus":[0.05,0.10],
          "precipitation_ecmwf_ifs025":[0.00,0.02],
          "precipitation_ncep_hrrr_conus":[0.00,0.00]}}
        """.data(using: .utf8)!

        let outlook = try PrecipOutlookClient.decode(json)

        XCTAssertEqual(outlook.rows.count, PrecipModel.allCases.count)
        XCTAssertEqual(outlook.rows.map(\.model), PrecipModel.allCases,
                       "rows must stay in the declared order, whatever answered")
        XCTAssertEqual(outlook.modelCount, PrecipModel.allCases.count)

        // ICON and GFS were absent from the response — silent, not dry.
        let icon = try XCTUnwrap(outlook.rows.first { $0.model == .icon })
        XCTAssertTrue(icon.inches.allSatisfy { $0 == nil })
        XCTAssertFalse(icon.isWet)
    }

    /// NO DATA IS NOT NO RAIN, and it must not be counted as a model agreeing that
    /// an hour is dry. HRRR stops at 18 hours while the globals run for days.
    func testSilentHoursAreNotCountedAsDryAgreement() {
        let outlook = PrecipOutlook(times: times(2), rows: [
            row(.nbm,   [0.05, 0.05]),
            row(.ecmwf, [0.05, nil]),
            row(.hrrr,  [nil,  nil]),
        ])
        XCTAssertEqual(outlook.agreement(atHour: 0), 2)
        XCTAssertEqual(outlook.agreement(atHour: 1), 1, "a silent hour is not a wet one")
        XCTAssertFalse(outlook.rows[2].isWet)
        XCTAssertEqual(outlook.rows[2].total, 0)
    }

    // MARK: The headline

    func testHeadlineCountsWetModelsAgainstTheFullSet() {
        func headline(_ wet: Int) -> String {
            let rows = PrecipModel.allCases.enumerated().map { i, model in
                row(model, i < wet ? [0.05, 0.05] : [0, 0])
            }
            return PrecipOutlook(times: times(2), rows: rows).headline
        }
        let n = PrecipModel.allCases.count
        XCTAssertTrue(headline(0).hasPrefix("No rain in any of the "), headline(0))
        XCTAssertEqual(headline(2), "2 of \(n) models bring rain")
        XCTAssertTrue(headline(n).hasPrefix("All "), headline(n))
        XCTAssertFalse(headline(n).contains("\(n) of"), "a clean sweep should not be phrased as a count")
    }

    // MARK: The panel itself

    /// TWO ROWS THAT ARE THE SAME FORECAST WOULD BE ONE VOTE COUNTED TWICE, which
    /// is why KNMI and DMI are not on the list — over Texas they return
    /// byte-identical series. Nothing stops a future addition from doing the same,
    /// so the uniqueness of the panel is checked rather than assumed.
    func testEveryModelIsADistinctSource() {
        let apiNames = PrecipModel.allCases.map(\.apiName)
        XCTAssertEqual(Set(apiNames).count, apiNames.count, "two rows share an upstream model")

        let labels = PrecipModel.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "two rows are labelled the same")

        XCTAssertFalse(apiNames.contains { $0.isEmpty }, "a model with no upstream name")
    }

    /// Every model belongs to exactly one family, and the families together are
    /// the whole panel — a row that fell outside them would silently vanish from
    /// the grid while still counting in the headline.
    func testTheFamiliesPartitionThePanel() {
        let grouped = PrecipModel.Family.allCases.flatMap { family in
            PrecipModel.allCases.filter { $0.family == family }
        }
        XCTAssertEqual(grouped.count, PrecipModel.allCases.count)
        XCTAssertEqual(Set(grouped), Set(PrecipModel.allCases))

        // The two that are not globals are the two the card most wants separated.
        XCTAssertEqual(PrecipModel.nbm.family, .blend)
        XCTAssertEqual(PrecipModel.hrrr.family, .shortRange)
    }

    /// Anything under a hundredth is rounding, not a forecast of rain. A model
    /// that produced 0.004″ must not be counted as agreeing that it will rain.
    func testAHundredthIsTheFloorForCallingItRain() {
        let outlook = PrecipOutlook(times: times(2), rows: [
            row(.nbm, [0.004, 0.003]),
            row(.ecmwf, [0.01, 0]),
        ])
        XCTAssertFalse(outlook.rows[0].isWet)
        XCTAssertTrue(outlook.rows[1].isWet)
        XCTAssertEqual(outlook.headline, "1 of 2 models bring rain")
    }

    // MARK: Who disagrees, and when

    /// Naming the dissenter is the point. On the afternoon this was built the
    /// holdout was HRRR — the one model a single-model map layer would have shown.
    func testTheHoldoutIsNamedWhenExactlyOneStandsApart() {
        func outlook(wet: [PrecipModel]) -> PrecipOutlook {
            PrecipOutlook(times: times(2), rows: PrecipModel.allCases.map {
                row($0, wet.contains($0) ? [0.05, 0.05] : [0, 0])
            })
        }
        let allButHRRR = PrecipModel.allCases.filter { $0 != .hrrr }
        XCTAssertEqual(outlook(wet: allButHRRR).holdout, .hrrr)
        XCTAssertEqual(outlook(wet: [.nbm]).holdout, .nbm, "a lone wet model is also the odd one out")

        // A three-two split has no odd one out; claiming one would be a story.
        XCTAssertNil(outlook(wet: [.nbm, .ecmwf, .icon]).holdout)
    }

    /// ONSET IS THE MEDIAN OF THE WET MODELS, NOT THE EARLIEST. One eager model
    /// with a stray hundredth at noon must not be allowed to announce that the
    /// rain starts at noon.
    func testOnsetIsTheMedianNotTheEarliest() {
        let outlook = PrecipOutlook(times: times(6), rows: [
            row(.nbm,   [0.05, 0, 0, 0, 0, 0]),          // hour 0 — the eager one
            row(.ecmwf, [0, 0, 0, 0.05, 0.05, 0.05]),    // hour 3
            row(.hrrr,  [0, 0, 0, 0, 0.05, 0.05]),       // hour 4
            row(.icon,  [0, 0, 0, 0, 0, 0]),
            row(.gfs,   [0, 0, 0, 0, 0, 0]),
        ])
        XCTAssertEqual(outlook.onset, times(6)[3])
    }

    /// The spread is taken across the models that HAVE rain. A range opening at
    /// 0.00″ beside "4 of 5 bring rain" reads as a contradiction rather than as
    /// the disagreement, which the count has already stated.
    func testTheRangeCoversTheWetModelsOnly() throws {
        let outlook = PrecipOutlook(times: times(2), rows: [
            row(.nbm,   [0.10, 0.10]),   // 0.20
            row(.ecmwf, [0.02, 0.03]),   // 0.05
            row(.hrrr,  [0, 0]),         // dry — excluded
        ])
        let range = try XCTUnwrap(outlook.wetRange)
        XCTAssertEqual(range.low, 0.05, accuracy: 1e-9)
        XCTAssertEqual(range.high, 0.20, accuracy: 1e-9)

        let detail = try XCTUnwrap(outlook.detail)
        XCTAssertTrue(detail.contains("0.05"), detail)
        XCTAssertTrue(detail.contains("0.20"), detail)
    }

    /// Nothing anywhere means no amount and no timing to report — the headline
    /// says it all, and a detail line of "0.00″ from around 1am" would be noise
    /// dressed as precision.
    func testADryOutlookHasNoDetailLine() {
        let outlook = PrecipOutlook(times: times(4), rows: PrecipModel.allCases.map {
            row($0, [0, 0, 0, 0])
        })
        XCTAssertNil(outlook.detail)
        XCTAssertNil(outlook.onset)
        XCTAssertNil(outlook.holdout)
        XCTAssertTrue(outlook.headline.hasPrefix("No rain in any of the "), outlook.headline)
    }

    /// The real shape of the response, with unix times and one series per model.
    func testDecodesUnixTimesAndPerModelSeries() throws {
        let json = """
        {"hourly":{"time":[1700000000,1700003600,1700007200],
          "precipitation_ncep_nbm_conus":[0.01,0.16,0.11],
          "precipitation_ecmwf_ifs025":[0.00,0.06,0.06],
          "precipitation_ncep_hrrr_conus":[0.00,0.00,0.00],
          "precipitation_icon_seamless":[0.00,0.00,null],
          "precipitation_gfs_seamless":[0.00,0.00,0.00]}}
        """.data(using: .utf8)!

        let outlook = try PrecipOutlookClient.decode(json)
        XCTAssertEqual(outlook.times.count, 3)
        XCTAssertEqual(outlook.times.first, Date(timeIntervalSince1970: 1_700_000_000))

        let nbm = try XCTUnwrap(outlook.rows.first { $0.model == .nbm })
        XCTAssertEqual(nbm.total, 0.28, accuracy: 1e-9)
        XCTAssertTrue(nbm.isWet)

        // A null inside a series is silence for that hour, not zero.
        let icon = try XCTUnwrap(outlook.rows.first { $0.model == .icon })
        XCTAssertNil(icon.inches[2])

        XCTAssertEqual(outlook.headline, "2 of \(PrecipModel.allCases.count) models bring rain")
        XCTAssertEqual(outlook.agreement(atHour: 1), 2)
    }
}
