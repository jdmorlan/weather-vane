//
//  AskEval.swift  (ask-eval)
//
//  How often a weather question is read RIGHT — the page picked, and for Explore
//  the query written — by the on-device model or by `QuestionParser`. Not a test:
//  the model is a measurement, not a fixed function, and the number this prints
//  is the point. (The parser's own checklist is in `swift test`.)
//
//      swift run -c release ask-eval            every case
//      swift run -c release ask-eval freeze     only questions containing "freeze"
//      swift run -c release ask-eval --held-out the questions it was never tuned on
//      swift run -c release ask-eval --parser   the rule-based parser instead of the model
//
//  The model needs Apple Intelligence on this Mac (greedy sampling, so a run
//  repeats). The parser needs nothing. The questions live in AskQuestions.
//
//  "Right" is judged by MEANING, not spelling: a band and the numbers it stands
//  for are the same test ("Dry" rain = below 0.01"), the query's name and limit
//  are ignored, and a case lists every reading a person would accept.
//

import Foundation
import FoundationModels
import WeatherKit
import WeatherAsk
import AskQuestions

/// The app's destinations as `Destination.slug` / `.caption` (Weather/App/Navigation.swift),
/// plus what a question for each sounds like. A copy, because that enum lives in the
/// app target; the app itself will pass its own.
let pages: [AskPage] = [
    .init(slug: "now", caption: "Conditions, today's shape, and the ten-day",
          answers: "what it's like outside right now — temperature, wind, rain — and today"),
    .init(slug: "forecast", caption: "Temperature, rain, wind and storms, three days out",
          answers: "what will happen tonight, tomorrow or the next few days"),
    .init(slug: "map", caption: "What's around you, and what's on the way",
          answers: "radar, storms nearby, and fronts on the way"),
    .init(slug: "rhythms", caption: "When things usually happen here",
          answers: "when in a typical year things usually start or end, and what each season is usually like"),
    .init(slug: "rain", caption: "How much falls, how often, and how long between",
          answers: "how much rain usually falls, how often, and how long it goes without"),
    .init(slug: "compare", caption: "This stretch against the same stretch in other years",
          answers: "whether this week, month or season is unusual compared with other years"),
    .init(slug: "history", caption: "What one day, month or season was like",
          answers: "what one particular past day, month or season was like"),
    .init(slug: "forecast-check", caption: "Each morning's forecast against the high that happened",
          answers: "how accurate the forecasts have been"),
    .init(slug: "wind", caption: "Where it comes from, and when that turns",
          answers: "which way the wind usually blows, and when that changes"),
    .init(slug: "explore", caption: "The days when anything happened",
          answers: "finding days that matched conditions: when it last or first happened in a given year, how many days, which month or year had the most"),
    .init(slug: "pattern", caption: "The 500 mb wave that steers all of it",
          answers: "the jet stream and upper-air pattern"),
    .init(slug: "videos", caption: "Texas Weather Center and Convective Chronicles",
          answers: "forecaster videos and live storm coverage"),
    .init(slug: "blog", caption: "Houston's forecast, from Eric Berger and Matt Lanza",
          answers: "Space City Weather posts and Houston's forecast"),
    .init(slug: "station", caption: "Whether the instrument itself is well",
          answers: "whether the weather station and its sensors are working"),
]

// MARK: - Run

/// One way of answering: the on-device model, or the parser.
struct Answer {
    var page: String
    var query: Result<DayQuery, Error>?
    var unread: [String] = []
}

@main
struct AskEval {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        var arguments = Array(CommandLine.arguments.dropFirst())
        let useHeldOut = arguments.contains("--held-out")
        let useParser = arguments.contains("--parser")
        arguments.removeAll { $0.hasPrefix("--") }
        let filter = arguments.joined(separator: " ").lowercased()
        let selected = (useHeldOut ? heldOut : cases).filter { filter.isEmpty || $0.question.lowercased().contains(filter) }

        let answer: (Case) async -> Answer
        if useParser {
            answer = { c in
                let parsed = QuestionParser.parse(c.question, today: askToday)
                return Answer(page: parsed.page,
                              query: parsed.query.map { .success($0) },
                              unread: parsed.unread)
            }
        } else {
            guard #available(macOS 26, *), Ask.isAvailable else {
                print("Apple Intelligence isn't available on this Mac. (--parser doesn't need it.)")
                exit(1)
            }
            answer = { c in
                let page = (try? await Ask.page(for: c.question, among: pages)) ?? "(error)"
                guard !c.queries.isEmpty else { return Answer(page: page) }
                do { return Answer(page: page, query: .success(try await Ask.query(for: c.question, today: askToday).query)) }
                catch { return Answer(page: page, query: .failure(error)) }
            }
        }

        var pageRight = 0, queryRight = 0, queryTotal = 0
        var seconds: [Double] = []
        for c in selected {
            print("\n“\(c.question)”")
            let started = Date()
            let result = await answer(c)
            seconds.append(Date().timeIntervalSince(started))

            let pageOK = c.pages.contains(result.page)
            if pageOK { pageRight += 1 }
            print("  page   \(pageOK ? "✓" : "✗") \(result.page)" + (pageOK ? "" : "   wanted \(c.pages.joined(separator: " or "))"))

            if !c.queries.isEmpty {
                queryTotal += 1
                let wanted = c.queries.map { canonical(decode($0)) }
                switch result.query {
                case .success(let query)?:
                    let got = canonical(query)
                    if wanted.contains(got) {
                        queryRight += 1
                        print("  query  ✓ \(query.describe)")
                    } else {
                        print("  query  ✗ \(query.describe)")
                        print("           got    \(got)")
                        print("           wanted \(wanted.joined(separator: "\n                  or "))")
                    }
                case .failure(let error)?:
                    print("  query  ✗ refused: \(error)")
                case nil:
                    print("  query  ✗ nothing read as a query")
                }
            }
            if !result.unread.isEmpty { print("  unread \(result.unread.joined(separator: " "))") }
        }

        let median = seconds.sorted()[seconds.count / 2]
        print("""

            Pages    \(pageRight)/\(selected.count)
            Queries  \(queryRight)/\(queryTotal)
            Median   \(String(format: "%.3f", median)) s per question, \
            slowest \(String(format: "%.3f", seconds.max() ?? 0)) s
            """)
    }
}
