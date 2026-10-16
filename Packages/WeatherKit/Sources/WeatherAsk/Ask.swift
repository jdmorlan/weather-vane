//
//  Ask.swift  (WeatherAsk)
//
//  A question in words → where in the app it is answered, and with what settings.
//
//  THE MODEL CHOOSES, THE APP ANSWERS. The on-device model is small (≈3B, an 8K
//  window) and would misstate a number it was handed; it is never asked for one.
//  It makes two narrow choices — which page, then that page's settings — each
//  constrained to a schema, and the app's own code does the counting.
//
//  Two steps rather than one because each stays small enough to check: a wrong
//  page is visibly wrong, and a wrong query arrives as filters you can read and
//  correct. Only pages that take settings need a second step; today that is
//  Explore (`DayQuery`).
//
//  Measured, not assumed: `swift run -c release ask-eval` (Sources/AskEval).
//

#if canImport(FoundationModels)
import Foundation
import FoundationModels
import WeatherKit

/// A page the router may send a question to. The app passes its own destinations
/// (`Destination.slug` and `.caption`), so the list can't drift from the sidebar.
public struct AskPage: Sendable {
    public var slug: String
    public var caption: String
    /// What a question for this page sounds like. The caption orients a person
    /// who has already opened the page; the router needs the other direction.
    public var answers: String
    public init(slug: String, caption: String, answers: String) {
        self.slug = slug
        self.caption = caption
        self.answers = answers
    }

    /// The slug that means "no page answers this". Said, rather than guessed around.
    public static let none = "none"
}

/// What a question asks for — read before the query is written. See `Ask.query`.
///
/// Yes/no rather than the question's words copied out: asked for the words that
/// name dates, with "" for none, the model never once wrote "" and every clause
/// came back. Yes/no was wrong less often (ask-eval: 5/20 queries against 0/20).
@available(macOS 26, iOS 26, visionOS 26, *)
@Generable
struct Reading {
    @Guide(description: """
        Each thing the question says the day ITSELF was like, in the question's own words — \
        "below 50", "hot", "dry", "gusts over 40". Not dates, not years, not what came before. \
        Empty when it says nothing about the day, as in "which month gets the most rain".
        """, .maximumCount(3))
    var aboutTheDay: [String]
    @Guide(description: "Does it name a month, a season, or dates? \"July\", \"this fall\", \"summer\".")
    var namesDates: Bool
    @Guide(description: "Does it name a particular year? \"2023\", \"this year\", \"last year\", \"this summer\".")
    var namesYear: Bool
    @Guide(description: "Does it ask for the first time, the last time, or days in a row?")
    var position: Position
    @Guide(description: "Does it say what happened on the days BEFORE, as in \"the day after it rained\"?")
    var aboutDaysBefore: Bool
    @Guide(description: "Does it ask for a number about the days — a total, an average, a count by month or year, or which month or year had the most?")
    var asksForANumber: Bool

    @Generable
    enum Position { case none, first, last, inARow }
}

@available(macOS 26, iOS 26, visionOS 26, *)
public enum Ask {

    /// Whether this device can ask at all — Apple Intelligence on, a capable device.
    public static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Greedy so the same question gets the same answer, and a ceiling on length
    /// because a runaway generation was seen to repeat until the context was full.
    private static let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 300)

    // MARK: Step 1 — which page

    public static func page(for question: String, among pages: [AskPage]) async throws -> String {
        let list = pages.map { "\($0.slug) — \($0.caption). Answers: \($0.answers)" }
            .joined(separator: "\n")
        let root = DynamicGenerationSchema(
            name: "Route",
            properties: [
                DynamicGenerationSchema.Property(
                    name: "page",
                    description: "The screen that answers the question, or \"\(AskPage.none)\" if none does.",
                    schema: DynamicGenerationSchema(name: "Page",
                                                    anyOf: pages.map(\.slug) + [AskPage.none])),
            ])
        let session = LanguageModelSession(instructions: """
            You route questions in a personal weather app to the screen that answers them. \
            The app reads one home weather station and keeps its full daily record.

            The screens:
            \(list)

            Answer "\(AskPage.none)" if the question isn't about weather or the station.
            """)
        let response = try await session.respond(
            to: question, schema: try GenerationSchema(root: root, dependencies: []), options: options)
        return try response.content.value(String.self, forProperty: "page")
    }

    // MARK: Step 2 — Explore's settings

    /// The question as a `DayQuery`, plus the JSON the model wrote (for showing a
    /// refusal). Decoded through `DayQuery(json:)`, the same strict reader any
    /// other proposal goes through.
    ///
    /// TWO CALLS, because the model can't leave a clause out. Offered the whole
    /// query with every clause optional, it filled every clause — a season and a
    /// year on nearly every question, "Rain 0.00\" or above" four times over on a
    /// question that said nothing about the day — and telling it not to changed
    /// nothing. So the first call only READS the question (what does it say about
    /// the day, does it name dates, a year, first/last), and the second is shown a
    /// query with exactly those clauses, all required. A clause the question didn't
    /// ask for is no longer something it can write.
    public static func query(for question: String,
                             today: Date = .now) async throws -> (query: DayQuery, json: String) {
        let year = Calendar.current.component(.year, from: today)
        let reading = try await read(question)

        // The query language's own schema, cut down to what was asked.
        var schema = DayQuery.jsonSchema
        var properties = schema["properties"] as! [String: Any]
        var required: [String] = []
        properties["name"] = nil   // the app titles it with the question itself
        properties["sequence"] = nil   // first/last are set below; only a run needs the model
        func keep(_ key: String, if asked: Bool) {
            if asked { required.append(key) } else { properties[key] = nil }
        }
        if reading.aboutTheDay.isEmpty {
            properties["conditions"] = nil
        } else {
            var conditions = properties["conditions"] as! [String: Any]
            conditions["minItems"] = reading.aboutTheDay.count
            conditions["maxItems"] = reading.aboutTheDay.count
            properties["conditions"] = conditions
            required.append("conditions")
        }
        keep("scope", if: reading.namesDates)
        keep("years", if: reading.namesYear)
        keep("precededBy", if: reading.aboutDaysBefore)
        keep("aggregate", if: reading.asksForANumber)
        if reading.position == .inARow {
            properties["run"] = ["type": "integer",
                                 "description": "How many days in a row, at least."]
            required.append("run")
        }
        schema["properties"] = properties
        schema["required"] = required

        let session = LanguageModelSession(instructions: """
            You turn a question about a home weather station's daily record into a query \
            over that record. The current year is \(year): "this year" is \(year), \
            "last year" is \(year - 1). Temperatures are °F, rain is inches, wind and gusts are mph. \
            A night, or how cold it got, is the low; how hot a day got is the high.
            """)
        let prompt = reading.aboutTheDay.isEmpty ? question : """
            \(question)
            What it says about the day, one condition each: \(reading.aboutTheDay.joined(separator: "; "))
            """
        let response = try await session.respond(
            to: prompt, schema: try GenerationSchema(root: SchemaBridge.schema(schema, name: "DayQuery"),
                                                     dependencies: []),
            options: options)
        let text = response.content.jsonString
        var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        switch reading.position {
        case .none: break
        case .first: object["sequence"] = ["kind": "firstEachYear"]
        case .last: object["sequence"] = ["kind": "lastEachYear"]
        case .inARow: object["sequence"] = ["kind": "inRunOfAtLeast", "value": object["run"] ?? 2]
        }
        return (try DayQuery(json: object), text)
    }

    /// Step 2's first call: what the question asks for, before anything is built.
    private static func read(_ question: String) async throws -> Reading {
        let session = LanguageModelSession(instructions: """
            You read a question about a home weather station's daily record and note \
            what it asks for. Note only what the question actually says.
            """)
        return try await session.respond(to: question, generating: Reading.self,
                                         options: options).content
    }
}
#endif
