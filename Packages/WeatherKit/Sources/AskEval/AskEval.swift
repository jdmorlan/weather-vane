//
//  AskEval.swift  (ask-eval)
//
//  How often the on-device model gets a weather question RIGHT — the page it
//  picks, and for Explore the query it writes. Not a test: the model is a
//  measurement, not a fixed function, and the number this prints is the point.
//
//      swift run -c release ask-eval            every case
//      swift run -c release ask-eval freeze     only questions containing "freeze"
//      swift run -c release ask-eval --held-out the questions it was never tuned on
//
//  Needs Apple Intelligence on this Mac. Greedy sampling, so a run repeats.
//
//  "Right" is judged by MEANING, not spelling: a band and the numbers it stands
//  for are the same test ("Dry" rain = below 0.01"), the query's name and limit
//  are ignored, and a case lists every reading a person would accept.
//

import Foundation
import FoundationModels
import WeatherKit
import WeatherAsk

/// Today, fixed, so "this year" and "last summer" mean the same thing every run.
let today = DateComponents(calendar: .current, year: 2026, month: 10, day: 15).date!

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

struct Case {
    var question: String
    /// Every page that would be a fair answer.
    var pages: [String]
    /// Every query that would be a fair answer, in the query language. Empty = the
    /// question doesn't go to Explore, so only the page is graded.
    var queries: [String] = []
}

// MARK: - The cases

let cases: [Case] = [
    // The one that started this.
    Case(question: "When was the last time this year that the low was below 50?",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"low","test":{"kind":"below","value":50}}],"years":{"kind":"year","value":2026},"sequence":{"kind":"lastEachYear"}}"#]),
    Case(question: "When does the first fall night below 50 usually happen?",
         pages: ["explore", "rhythms"],
         queries: [#"{"conditions":[{"measure":"low","test":{"kind":"below","value":50}}],"scope":{"period":"Fall"},"sequence":{"kind":"firstEachYear"}}"#]),
    Case(question: "When was our first 100 degree day this year?",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"high","test":{"kind":"atOrAbove","value":100}}],"years":{"kind":"year","value":2026},"sequence":{"kind":"firstEachYear"}}"#]),
    Case(question: "Hot dry days in July, three or more in a row",
         pages: ["explore"],
         queries: [
            #"{"conditions":[{"measure":"high","test":{"kind":"atOrAbove","value":90}},{"measure":"rain","test":{"kind":"below","value":0.01}}],"scope":{"period":"July"},"sequence":{"kind":"inRunOfAtLeast","value":3}}"#,
            #"{"conditions":[{"measure":"high","test":{"kind":"inBand","band":"Hot"}},{"measure":"rain","test":{"kind":"below","value":0.01}}],"scope":{"period":"July"},"sequence":{"kind":"inRunOfAtLeast","value":3}}"#,
         ]),
    Case(question: "Days right after it rained more than an inch",
         pages: ["explore"],
         queries: [#"{"conditions":[],"precededBy":{"conditions":[{"measure":"rain","test":{"kind":"atOrAbove","value":1}}],"within":1}}"#]),
    Case(question: "Which month usually gets the most rain?",
         pages: ["explore", "rain"],
         queries: [
            #"{"conditions":[],"aggregate":{"measure":"rain","reduce":"sum","groupBy":"monthOfYear","rank":"highest"}}"#,
            #"{"conditions":[],"aggregate":{"measure":"rain","reduce":"mean","groupBy":"monthOfYear","rank":"highest"}}"#,
         ]),
    Case(question: "How much rain did we get this summer?",
         pages: ["explore", "rain", "history"],
         queries: [#"{"conditions":[],"scope":{"period":"Summer"},"years":{"kind":"year","value":2026},"aggregate":{"measure":"rain","reduce":"sum","groupBy":"none"}}"#]),
    Case(question: "How many days hit 100 this year?",
         pages: ["explore"],
         queries: [
            #"{"conditions":[{"measure":"high","test":{"kind":"atOrAbove","value":100}}],"years":{"kind":"year","value":2026}}"#,
            #"{"conditions":[{"measure":"high","test":{"kind":"atOrAbove","value":100}}],"years":{"kind":"year","value":2026},"aggregate":{"measure":"high","reduce":"count","groupBy":"none"}}"#,
         ]),
    Case(question: "Average high temperature by year",
         pages: ["explore"],
         queries: [#"{"conditions":[],"aggregate":{"measure":"high","reduce":"mean","groupBy":"year"}}"#]),
    Case(question: "Muggy days in October",
         pages: ["explore"],
         queries: [
            #"{"conditions":[{"measure":"dewPoint","test":{"kind":"inBand","band":"Muggy"}}],"scope":{"period":"October"}}"#,
            #"{"conditions":[{"measure":"dewPoint","test":{"kind":"atOrAbove","value":65}}],"scope":{"period":"October"}}"#,
            #"{"conditions":[{"measure":"dewPointPeak","test":{"kind":"inBand","band":"Muggy"}}],"scope":{"period":"October"}}"#,
         ]),
    Case(question: "Days in 2023 with gusts over 40",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"gust","test":{"kind":"atOrAbove","value":40}}],"years":{"kind":"year","value":2023}}"#]),
    Case(question: "Nights this summer that never got below 80",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"low","test":{"kind":"atOrAbove","value":80}}],"scope":{"period":"Summer"},"years":{"kind":"year","value":2026}}"#]),
    Case(question: "Days with an inch of rain or more",
         pages: ["explore", "rain"],
         queries: [#"{"conditions":[{"measure":"rain","test":{"kind":"atOrAbove","value":1}}]}"#]),
    Case(question: "Cold days in January 2024",
         pages: ["explore", "history"],
         queries: [
            #"{"conditions":[{"measure":"high","test":{"kind":"inBand","band":"Cold"}}],"scope":{"period":"January"},"years":{"kind":"year","value":2024}}"#,
            #"{"conditions":[{"measure":"high","test":{"kind":"below","value":55}}],"scope":{"period":"January"},"years":{"kind":"year","value":2024}}"#,
         ]),
    Case(question: "What's the coolest month of the year on average?",
         pages: ["explore", "rhythms"],
         queries: [
            #"{"conditions":[],"aggregate":{"measure":"meanTemp","reduce":"mean","groupBy":"monthOfYear","rank":"lowest"}}"#,
            #"{"conditions":[],"aggregate":{"measure":"high","reduce":"mean","groupBy":"monthOfYear","rank":"lowest"}}"#,
            #"{"conditions":[],"aggregate":{"measure":"low","reduce":"mean","groupBy":"monthOfYear","rank":"lowest"}}"#,
         ]),
    // A front's signature, asked as a sequence.
    Case(question: "Days when the high dropped below 60 right after a 90 degree day",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"high","test":{"kind":"below","value":60}}],"precededBy":{"conditions":[{"measure":"high","test":{"kind":"atOrAbove","value":90}}],"within":1}}"#]),
    Case(question: "What was the wettest year on record?",
         pages: ["explore", "rain"],
         queries: [#"{"conditions":[],"aggregate":{"measure":"rain","reduce":"sum","groupBy":"year","rank":"highest"}}"#]),
    Case(question: "How many 100 degree days were there each year?",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"high","test":{"kind":"atOrAbove","value":100}}],"aggregate":{"measure":"high","reduce":"count","groupBy":"year"}}"#]),
    Case(question: "Dry spells of 30 days or more",
         pages: ["explore", "rain"],
         queries: [#"{"conditions":[{"measure":"rain","test":{"kind":"below","value":0.01}}],"sequence":{"kind":"inRunOfAtLeast","value":30}}"#]),
    Case(question: "When did it last rain?",
         pages: ["explore", "rain", "now"],
         queries: [#"{"conditions":[{"measure":"rain","test":{"kind":"atOrAbove","value":0.01}}],"years":{"kind":"year","value":2026},"sequence":{"kind":"lastEachYear"}}"#]),

    // Page only.
    Case(question: "Is it going to rain tomorrow?", pages: ["forecast", "now"]),
    Case(question: "Is there a storm coming?", pages: ["map", "forecast"]),
    Case(question: "What's the temperature right now?", pages: ["now"]),
    Case(question: "What was September 2023 like?", pages: ["history"]),
    Case(question: "Is this October drier than usual?", pages: ["compare"]),
    Case(question: "When does it usually start getting cold here?", pages: ["rhythms"]),
    Case(question: "When is the first freeze usually?", pages: ["rhythms", "explore"]),
    Case(question: "Which way does the wind usually blow in spring?", pages: ["wind"]),
    Case(question: "How accurate has the forecast been?", pages: ["forecast-check"]),
    Case(question: "Why is the rain gauge reading zero?", pages: ["station"]),
    Case(question: "What's the jet stream doing?", pages: ["pattern"]),
    Case(question: "What is Eric Berger saying?", pages: ["blog"]),
    Case(question: "How much rain do we usually get in a year?", pages: ["rain"]),
    Case(question: "Show me the radar", pages: ["map"]),
    Case(question: "Has the front gotten here yet?", pages: ["map", "now"]),
    Case(question: "How long has it been since it rained?", pages: ["rain", "now", "explore"]),
    Case(question: "Is it windy out?", pages: ["now"]),
    Case(question: "What's the meaning of life?", pages: [AskPage.none]),
    Case(question: "Text my dad", pages: [AskPage.none]),
]

/// Written before the first tuned run and NEVER tuned against: the instructions and
/// page notes were changed while looking at `cases`, so only these say how it does
/// on a question nobody fitted it to. Run with `--held-out`.
let heldOut: [Case] = [
    Case(question: "When did we last hit 95?",
         pages: ["explore"],
         queries: [
            #"{"conditions":[{"measure":"high","test":{"kind":"atOrAbove","value":95}}],"sequence":{"kind":"lastEachYear"}}"#,
            #"{"conditions":[{"measure":"high","test":{"kind":"atOrAbove","value":95}}],"years":{"kind":"year","value":2026},"sequence":{"kind":"lastEachYear"}}"#,
         ]),
    Case(question: "First night in the 40s this fall",
         pages: ["explore"],
         queries: [
            #"{"conditions":[{"measure":"low","test":{"kind":"between","lower":40,"upper":50}}],"scope":{"period":"Fall"},"years":{"kind":"year","value":2026},"sequence":{"kind":"firstEachYear"}}"#,
            #"{"conditions":[{"measure":"low","test":{"kind":"below","value":50}}],"scope":{"period":"Fall"},"years":{"kind":"year","value":2026},"sequence":{"kind":"firstEachYear"}}"#,
         ]),
    Case(question: "Days over 105 in 2023",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"high","test":{"kind":"atOrAbove","value":105}}],"years":{"kind":"year","value":2023}}"#]),
    Case(question: "Total rain in May 2025",
         pages: ["explore", "history", "rain"],
         queries: [#"{"conditions":[],"scope":{"period":"May"},"years":{"kind":"year","value":2025},"aggregate":{"measure":"rain","reduce":"sum","groupBy":"none"}}"#]),
    Case(question: "Which year had the hottest summer?",
         pages: ["explore", "compare"],
         queries: [
            #"{"conditions":[],"scope":{"period":"Summer"},"aggregate":{"measure":"high","reduce":"mean","groupBy":"year","rank":"highest"}}"#,
            #"{"conditions":[],"scope":{"period":"Summer"},"aggregate":{"measure":"meanTemp","reduce":"mean","groupBy":"year","rank":"highest"}}"#,
         ]),
    Case(question: "Oppressive dew point days in June",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"dewPoint","test":{"kind":"inBand","band":"Oppressive"}}],"scope":{"period":"June"}}"#]),
    Case(question: "Days with lightning in August",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"lightning","test":{"kind":"atOrAbove","value":1}}],"scope":{"period":"August"}}"#]),
    Case(question: "Four or more days in a row below freezing",
         pages: ["explore"],
         queries: [
            #"{"conditions":[{"measure":"low","test":{"kind":"below","value":32}}],"sequence":{"kind":"inRunOfAtLeast","value":4}}"#,
            #"{"conditions":[{"measure":"high","test":{"kind":"below","value":32}}],"sequence":{"kind":"inRunOfAtLeast","value":4}}"#,
         ]),
    Case(question: "Will it freeze tonight?", pages: ["forecast", "now"]),
    Case(question: "What did last August look like?", pages: ["history"]),
    Case(question: "Is the barometer acting up?", pages: ["station"]),
    Case(question: "Play the latest Convective Chronicles video", pages: ["videos"]),
]

// MARK: - Judging by meaning

/// A query written out in a form where two ways of saying the same thing come out
/// the same. Name and limit don't change what's asked, so they're left out.
func canonical(_ q: DayQuery) -> String {
    func range(_ c: Condition) -> String {
        var lower: Double?, upper: Double?
        switch c.test {
        case .atOrAbove(let v): lower = v
        case .below(let v): upper = v
        case .between(let a, let b): lower = a; upper = b
        case .inBand(let name):
            let band = c.measure.bands.first { $0.name == name }
            lower = band?.lower; upper = band?.upper
        }
        return "\(c.measure.rawValue)[\(lower.map { "\($0)" } ?? "-∞"),\(upper.map { "\($0)" } ?? "∞"))"
    }
    var parts = ["when " + q.conditions.map(range).sorted().joined(separator: " & ")]
    if let s = q.scope { parts.append("dates \(s.start)..<\(s.endExclusive)") }
    if case .year(let y) = q.years { parts.append("year \(y)") }
    if let p = q.precededBy {
        parts.append("after " + p.conditions.map(range).sorted().joined(separator: " & ") + " within \(p.within)")
    }
    if let s = q.sequence { parts.append("seq \(s)") }
    if let a = q.aggregate {
        parts.append("\(a.reduce.rawValue) \(a.measure.rawValue) per \(a.groupBy.rawValue)"
                     + (a.rank.map { " rank \($0.rawValue)" } ?? ""))
    }
    return parts.joined(separator: " · ")
}

func decode(_ text: String) -> DayQuery {
    let object = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    return try! DayQuery(json: object)
}

// MARK: - Run

@main
struct AskEval {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard #available(macOS 26, *), Ask.isAvailable else {
            print("Apple Intelligence isn't available on this Mac.")
            exit(1)
        }
        var arguments = Array(CommandLine.arguments.dropFirst())
        let useHeldOut = arguments.contains("--held-out")
        arguments.removeAll { $0 == "--held-out" }
        let filter = arguments.joined(separator: " ").lowercased()
        let selected = (useHeldOut ? heldOut : cases).filter { filter.isEmpty || $0.question.lowercased().contains(filter) }

        var pageRight = 0, queryRight = 0, queryTotal = 0
        var seconds: [Double] = []
        for c in selected {
            print("\n“\(c.question)”")

            let started = Date()
            let page = (try? await Ask.page(for: c.question, among: pages)) ?? "(error)"
            seconds.append(Date().timeIntervalSince(started))
            let pageOK = c.pages.contains(page)
            if pageOK { pageRight += 1 }
            print("  page   \(pageOK ? "✓" : "✗") \(page)" + (pageOK ? "" : "   wanted \(c.pages.joined(separator: " or "))"))

            guard !c.queries.isEmpty else { continue }
            queryTotal += 1
            let wanted = c.queries.map { canonical(decode($0)) }
            let queryStarted = Date()
            do {
                let (query, _) = try await Ask.query(for: c.question, today: today)
                seconds.append(Date().timeIntervalSince(queryStarted))
                let got = canonical(query)
                if wanted.contains(got) {
                    queryRight += 1
                    print("  query  ✓ \(query.describe)")
                } else {
                    print("  query  ✗ \(query.describe)")
                    print("           got    \(got)")
                    print("           wanted \(wanted.joined(separator: "\n                  or "))")
                }
            } catch {
                seconds.append(Date().timeIntervalSince(queryStarted))
                print("  query  ✗ refused: \(error)")
            }
        }

        let median = seconds.sorted()[seconds.count / 2]
        print("""

            Pages    \(pageRight)/\(selected.count)
            Queries  \(queryRight)/\(queryTotal)
            Median   \(String(format: "%.1f", median)) s per model call, \
            slowest \(String(format: "%.1f", seconds.max() ?? 0)) s
            """)
    }
}
