//
//  QuestionParserChecklistTests.swift
//
//  Every question in AskQuestions, read by `QuestionParser`. A checklist, not a
//  score: these are the questions the rules were written against, so each one
//  failing means a rule broke. (The score is `ask-eval --parser --held-out`.)
//

import XCTest
import WeatherKit
import AskQuestions

final class QuestionParserChecklistTests: XCTestCase {

    func testEveryQuestionGoesToAnAcceptablePage() {
        for c in cases + heldOut {
            let page = QuestionParser.parse(c.question, today: askToday).page
            XCTAssertTrue(c.pages.contains(page),
                          "“\(c.question)” went to \(page); wanted \(c.pages.joined(separator: " or "))")
        }
    }

    func testEveryQueryMeansWhatWasAsked() {
        for c in cases + heldOut where !c.queries.isEmpty {
            guard let query = QuestionParser.parse(c.question, today: askToday).query else {
                XCTFail("“\(c.question)” wasn't read as a query")
                continue
            }
            let wanted = c.queries.map { canonical(decode($0)) }
            XCTAssertTrue(wanted.contains(canonical(query)),
                          "“\(c.question)” read as \(canonical(query)); wanted \(wanted.joined(separator: " or "))")
        }
    }

    /// A question it can't read says which words it couldn't, rather than nothing.
    func testWhatIsNotUnderstoodIsSaid() {
        let parsed = QuestionParser.parse("Windy days", today: askToday)
        XCTAssertNil(parsed.query)
        XCTAssertEqual(parsed.unread, ["windy"])
    }

    /// Never invents: a question that names no year or dates gets neither.
    func testNothingIsAddedThatWasNotAsked() {
        let query = QuestionParser.parse("Days with an inch of rain or more", today: askToday).query
        XCTAssertNil(query?.scope)
        XCTAssertEqual(query?.years, .all)
        XCTAssertNil(query?.sequence)
        XCTAssertNil(query?.aggregate)
    }
}
