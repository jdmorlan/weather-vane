//
//  AskQuestions.swift  (AskQuestions)
//
//  The questions "ask a question" is measured against, and how an answer is judged.
//  Shared by `ask-eval` (which scores the on-device model or the parser) and the
//  parser's checklist in `swift test`, so there is one list.
//
//  Good questions first, a measuring stick second: once a rule is written while
//  looking at a question here, getting it right only shows the rule exists. The
//  honest score is on questions nobody fitted anything to — add those to
//  `heldOut`, and fold them into `cases` once they've been fixed.
//

import Foundation
import WeatherKit

public struct Case: Sendable {
    public var question: String
    /// Every page that would be a fair answer.
    public var pages: [String]
    /// Every query that would be a fair answer, in the query language. Empty = the
    /// question doesn't go to Explore, so only the page is graded.
    public var queries: [String]

    public init(question: String, pages: [String], queries: [String] = []) {
        self.question = question
        self.pages = pages
        self.queries = queries
    }
}

/// The day the expected answers assume, so "this year" and "last summer" mean the
/// same thing on every run.
public let askToday = DateComponents(calendar: .current, year: 2026, month: 10, day: 15).date!

// MARK: - The cases

public let cases: [Case] = [
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
         // Every year, or this one: "last" means the most recent time, which is this
         // year's last only if it has rained this year. Widened from this-year-only
         // on 2026-10-16, when that turned out to be the narrower reading.
         queries: [
            #"{"conditions":[{"measure":"rain","test":{"kind":"atOrAbove","value":0.01}}],"years":{"kind":"year","value":2026},"sequence":{"kind":"lastEachYear"}}"#,
            #"{"conditions":[{"measure":"rain","test":{"kind":"atOrAbove","value":0.01}}],"sequence":{"kind":"lastEachYear"}}"#,
         ]),

    // Found by trying fresh phrasings on the parser, 2026-10-16.
    Case(question: "Coldest night this year",
         pages: ["explore"],
         queries: [#"{"conditions":[],"years":{"kind":"year","value":2026},"aggregate":{"measure":"low","reduce":"min","groupBy":"none"}}"#]),
    Case(question: "Hottest day ever",
         pages: ["explore"],
         queries: [#"{"conditions":[],"aggregate":{"measure":"high","reduce":"max","groupBy":"none"}}"#]),
    Case(question: "Rainiest month",
         pages: ["explore", "rain"],
         queries: [#"{"conditions":[],"aggregate":{"measure":"rain","reduce":"sum","groupBy":"monthOfYear","rank":"highest"}}"#]),
    Case(question: "How many inches of rain in 2024?",
         pages: ["explore", "rain", "history"],
         queries: [#"{"conditions":[],"years":{"kind":"year","value":2024},"aggregate":{"measure":"rain","reduce":"sum","groupBy":"none"}}"#]),
    Case(question: "How many days above 90 in August 2025?",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"high","test":{"kind":"atOrAbove","value":90}}],"scope":{"period":"August"},"years":{"kind":"year","value":2025}}"#]),
    Case(question: "When was the last time it hit 100?",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"high","test":{"kind":"atOrAbove","value":100}}],"sequence":{"kind":"lastEachYear"}}"#]),
    Case(question: "When did it last get below freezing?",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"low","test":{"kind":"below","value":32}}],"sequence":{"kind":"lastEachYear"}}"#]),
    Case(question: "Days with highs in the 90s and dew points over 70",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"high","test":{"kind":"between","lower":90,"upper":100}},{"measure":"dewPoint","test":{"kind":"atOrAbove","value":70}}]}"#]),
    Case(question: "Lows in the 30s",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"low","test":{"kind":"between","lower":30,"upper":40}}]}"#]),
    Case(question: "Days the wind gusted over 50 mph",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"gust","test":{"kind":"atOrAbove","value":50}}]}"#]),
    Case(question: "How many days with no rain this summer",
         pages: ["explore"],
         queries: [#"{"conditions":[{"measure":"rain","test":{"kind":"below","value":0.01}}],"scope":{"period":"Summer"},"years":{"kind":"year","value":2026}}"#]),
    Case(question: "Week-long stretches without rain",
         pages: ["explore", "rain"],
         queries: [#"{"conditions":[{"measure":"rain","test":{"kind":"below","value":0.01}}],"sequence":{"kind":"inRunOfAtLeast","value":7}}"#]),

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
    Case(question: "What's the meaning of life?", pages: ["none"]),
    Case(question: "Text my dad", pages: ["none"]),
]

/// Written before the first tuned run and NEVER tuned against: the instructions and
/// page notes were changed while looking at `cases`, so only these say how it does
/// on a question nobody fitted it to. Run with `--held-out`.
public let heldOut: [Case] = [
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
public func canonical(_ q: DayQuery) -> String {
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

public func decode(_ text: String) -> DayQuery {
    let object = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    return try! DayQuery(json: object)
}

