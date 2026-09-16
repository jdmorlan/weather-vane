//
//  QueryLanguageTests.swift
//
//  Can a question SURVIVE being said? The round trip is the real test: a query that goes out as JSON
//  and comes back a different value would send you to a view answering a question you didn't ask —
//  and since it still returns days, nothing downstream could tell you it happened.
//
//  The presets are the corpus on purpose. They're the questions the app actually ships, so a language
//  that can't carry all ten isn't a language yet.
//

import XCTest
@testable import WeatherKit

final class QueryLanguageTests: XCTestCase {

    private func roundTrip(_ query: DayQuery, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let back = try DayQuery(json: query.jsonObject)
            XCTAssertEqual(back, query, "round trip changed the question", file: file, line: line)
            XCTAssertEqual(back.describe, query.describe, file: file, line: line)
        } catch {
            XCTFail("round trip threw: \(error)", file: file, line: line)
        }
    }

    func testEveryPresetSurvivesTheRoundTrip() {
        for preset in DayQuery.presets { roundTrip(preset) }
    }

    /// Every clause at once — the shape no preset exercises: a day condition, a named scope, one year,
    /// a preceding clause with its own conditions, and a run rule.
    func testTheFullQueryLanguageSurvives() {
        let query = DayQuery(
            name: "Hot dry stretches after rain",
            conditions: [Condition(.high, .atOrAbove(90)), Condition(.dewPoint, .below(60))],
            scope: WeatherPeriod.months[6],                 // July
            years: .year(2026),
            precededBy: PrecedingClause(conditions: [Condition(.rain, .atOrAbove(0.1))], within: 3),
            sequence: .inRunOfAtLeast(3))
        roundTrip(query)
    }

    func testBandAndBetweenSurvive() {
        roundTrip(DayQuery(name: "Muggy but not hot",
                           conditions: [Condition(.dewPointPeak, .inBand("Muggy")),
                                        Condition(.high, .between(80, 90))]))
    }

    /// A named month must come back NAMED, not as a pair of boundaries — otherwise the second time a
    /// question is written down it reads as "07-01–08-01" and stops being something a person recognises.
    func testANamedPeriodStaysNamed() throws {
        let july = WeatherPeriod.months[6]
        let json = DayQuery(conditions: [Condition(.high, .atOrAbove(90))], scope: july).jsonObject
        XCTAssertEqual((json["scope"] as? [String: Any])?["period"] as? String, "July")
        XCTAssertEqual(try DayQuery(json: json).scope, july)
    }

    func testCustomWindowSurvives() throws {
        let json: [String: Any] = [
            "conditions": [["measure": "low", "test": ["kind": "below", "value": 32]]],
            "scope": ["name": "Late spring", "start": "05-01", "endExclusive": "06-15"],
        ]
        let query = try DayQuery(json: json)
        XCTAssertEqual(query.scope?.start, "05-01")
        XCTAssertEqual(query.scope?.kind, .custom)
        roundTrip(query)
    }

    // MARK: - Refusing, rather than quietly answering something else

    func testUnknownMeasureIsRefusedWithTheRealList() {
        let json: [String: Any] = [
            "conditions": [["measure": "snowfall", "test": ["kind": "atOrAbove", "value": 1]]]
        ]
        XCTAssertThrowsError(try DayQuery(json: json)) { error in
            guard case QueryLanguageError.unknown(_, let got, let allowed)? = error as? QueryLanguageError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(got, "snowfall")
            XCTAssertTrue(allowed.contains("rain"), "the refusal should hand back what IS askable")
        }
    }

    /// A band belongs to a measure. "Muggy" is a dew point; asked of wind it would match nothing at
    /// all — a query that runs, returns zero days, and looks like an answer.
    func testABandFromTheWrongMeasureIsRefused() {
        let json: [String: Any] = [
            "conditions": [["measure": "dewPoint", "test": ["kind": "inBand", "band": "Windy"]]]
        ]
        XCTAssertThrowsError(try DayQuery(json: json)) { error in
            guard case QueryLanguageError.unknown(_, _, let allowed)? = error as? QueryLanguageError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(allowed.contains("Muggy"), "the refusal must hand back that measure's real bands")
        }
    }

    /// A measure with no bands at all needs its own sentence — "must be one of: " followed by nothing
    /// tells you that you were wrong and nothing about how to be right.
    func testABandOnAMeasureThatHasNoneSaysSo() {
        let json: [String: Any] = [
            "conditions": [["measure": "gust", "test": ["kind": "inBand", "band": "Muggy"]]]
        ]
        XCTAssertThrowsError(try DayQuery(json: json)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("no named bands"), "unhelpful refusal: \(message)")
        }
    }

    func testAMalformedTestIsRefusedRatherThanDropped() {
        let json: [String: Any] = [
            "conditions": [["measure": "high", "test": ["kind": "atOrAbove", "value": "ninety"]]]
        ]
        XCTAssertThrowsError(try DayQuery(json: json))
    }

    /// Dropping a bad condition would leave a RUNNING query that answers a different question — the
    /// one failure mode with no visible symptom. It must take the whole proposal down.
    func testOneBadConditionRefusesTheWholeQuery() {
        let json: [String: Any] = [
            "conditions": [["measure": "high", "test": ["kind": "atOrAbove", "value": 90]],
                           ["measure": "high", "test": ["kind": "warmish", "value": 90]]]
        ]
        XCTAssertThrowsError(try DayQuery(json: json))
    }

    // MARK: - The schema says only what the app can actually run

    func testSchemaEnumeratesTheRealMeasuresAndPeriods() throws {
        let schema = DayQuery.jsonSchema
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let conditions = try XCTUnwrap(properties["conditions"] as? [String: Any])
        let item = try XCTUnwrap(conditions["items"] as? [String: Any])
        let itemProps = try XCTUnwrap(item["properties"] as? [String: Any])
        let measure = try XCTUnwrap(itemProps["measure"] as? [String: Any])
        XCTAssertEqual(measure["enum"] as? [String], Measure.allCases.map(\.rawValue))

        let scope = try XCTUnwrap(properties["scope"] as? [String: Any])
        let named = try XCTUnwrap((scope["oneOf"] as? [[String: Any]])?.first)
        let period = try XCTUnwrap((named["properties"] as? [String: Any])?["period"] as? [String: Any])
        let names = try XCTUnwrap(period["enum"] as? [String])
        XCTAssertEqual(names.count, 16, "twelve months and four seasons")
        XCTAssertTrue(names.contains("July") && names.contains("Summer"))
    }

    /// The schema must be REAL JSON — it goes out over the wire as part of a tool definition, and a
    /// value Foundation can't serialise takes the whole tool list down with it.
    func testSchemaSerialises() {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(DayQuery.jsonSchema))
    }
}
