//
//  QuestionParser.swift  (WeatherKit)
//
//  A question in words → the page that answers it, and for Explore the query —
//  by rules, not a model.
//
//  WHY RULES. Apple's on-device model was measured at this (branch ask-experiment,
//  `ask-eval`) and wrote no correct query out of eight it hadn't been tuned on. Its
//  failure was INVENTION: offered a clause, it filled it, so questions came back
//  with seasons, years and totals nobody asked for. The query language is small —
//  a dozen measures, four tests, months, seasons, years, first/last/in a row,
//  after, a handful of reductions — and a parser over a small language can only
//  ever say what it matched. Its failure is the honest one: a word it didn't
//  understand, which it hands back in `unread` so the asker sees it.
//
//  HOW IT READS. Clauses are taken off the question in a fixed order, each one
//  blanking the words it used: dates and years first (so "2023" is never read as
//  a temperature), then runs ("3 or more in a row", before "3 or more" can be read
//  as a threshold), then reductions, then first/last, and only then conditions —
//  split at "after", so what comes after it describes the days BEFORE. Whatever
//  is left is what it didn't understand.
//

import Foundation

public struct ParsedQuestion: Equatable, Sendable {
    /// The page that answers it, as a link name — `explore`, `rain`, `history` —
    /// or `ParsedQuestion.noPage`.
    public var page: String
    /// What Explore should show, when anything in the question could be read as a
    /// query. Present even when `page` is elsewhere, so a page that takes settings
    /// later can use it.
    public var query: DayQuery?
    /// Words it didn't understand, in order — shown, never silently dropped.
    public var unread: [String]

    public static let noPage = "none"
}

public enum QuestionParser {

    public static func parse(_ question: String, today: Date = .now,
                             calendar: Calendar = .current) -> ParsedQuestion {
        let year = calendar.component(.year, from: today)
        let month = calendar.component(.month, from: today)
        let text = Scratch(normalized(question))
        let page = route(text)

        var query = DayQuery(conditions: [])
        readDates(text, into: &query, year: year, month: month)
        readRun(text, into: &query)
        readAggregate(text, into: &query)
        readFirstOrLast(text, into: &query)

        // Split at "after": the words following it describe the days before.
        var before: Scratch?
        if let split = text.splitOff(#"\b(?:after|following)\b"#) { before = split }
        query.conditions = readConditions(text)
        if let before {
            let earlier = readConditions(before)
            if !earlier.isEmpty { query.precededBy = PrecedingClause(conditions: earlier, within: 1) }
            text.text += " " + before.text
        }
        // A count is of days; its measure only has to be one the days have.
        if let aggregate = query.aggregate, aggregate.reduce == .count {
            query.aggregate?.measure = query.conditions.first?.measure ?? aggregate.measure
        }

        let asked = !query.conditions.isEmpty || query.aggregate != nil || query.precededBy != nil
        let destination = page ?? (asked ? "explore" : ParsedQuestion.noPage)
        // Unread words only mean something where the query is the answer — or where
        // nothing was understood at all, which is when they matter most. On the
        // other pages the question was never read as a query, so every word is
        // "unread" and none of them is news.
        return ParsedQuestion(page: destination,
                              query: asked ? query : nil,
                              unread: destination == "explore" || destination == ParsedQuestion.noPage
                                  ? text.unread : [])
    }

    // MARK: - Normalizing

    private static let numberWords = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "twenty": 20, "thirty": 30,
    ]

    /// Lowercase, punctuation out, numbers as digits, units as one spelling each.
    private static func normalized(_ question: String) -> String {
        // "May" the month and "may" the verb only differ by the capital, so the
        // month is marked before case is thrown away.
        var s = question.replacingOccurrences(of: #"\bMay\b"#, with: "maymonth", options: .regularExpression)
        s = " " + s.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        s = s.replacingOccurrences(of: #"[?!,;:]|\.(?!\d)"#, with: " ", options: .regularExpression)
        for (word, value) in numberWords {
            s = s.replacingOccurrences(of: "\\b\(word)\\b", with: "\(value)", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\bhalf an? inch"#, with: "0.5 inch", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\ban? inch"#, with: "1 inch", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\d)\s*(?:°\s*f?|degrees?(?: f\b)?)"#, with: "$1 deg",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"\bdew ?points?\b"#, with: "dewpoint", options: .regularExpression)
        return s
    }

    // MARK: - Which page

    /// First match wins, so the order matters: the station's own problems before
    /// anything that names a measure ("the rain gauge reads zero" is not a rain
    /// question), what's coming before what's usual. Explore is not on the list —
    /// it is where a question goes when it reads as a query and nothing here claimed it.
    private static let routes: [(page: String, all: [String])] = [
        ("station", [#"\b(?:gauge|sensors?|station|barometer|acting up|broken|not working|working right|reading (?:zero|0)|battery|offline)\b"#]),
        ("blog", [#"\b(?:eric berger|berger|matt lanza|lanza|space city|blog|scw)\b"#]),
        ("videos", [#"\b(?:videos?|convective chronicles|texas weather center|youtube|live stream)\b"#]),
        ("forecast-check", [#"\bforecasts?\b"#, #"\b(?:accurate|accuracy|been|right|wrong)\b"#]),
        ("pattern", [#"\b(?:jet stream|upper air|500 ?mb|ridge|trough)\b"#]),
        ("compare", [#"\b(?:than (?:usual|normal|average)|compared?|unusual)\b"#]),
        ("history", [#"\b(?:what|how)\b"#, #"\blike\b"#]),
        ("map", [#"\b(?:radar|satellite|coming|on the way|headed|front|fires?)\b"#]),
        ("forecast", [#"\b(?:tomorrow|tonight|this weekend|next week|next few days|later today|will it|going to|forecast)\b"#]),
        ("now", [#"\b(?:right now|now|outside|currently)\b|\bout\s*$"#]),
        ("wind", [#"\b(?:wind|winds)\b"#, #"\b(?:usually|which way|direction|blows?|from)\b"#]),
        ("rain", [#"\b(?:rain|rains|rained|rainfall)\b"#,
                  #"\b(?:usually|typically|normally|in a year|how long|since)\b"#]),
        ("rhythms", [#"\b(?:usually|typically|normally)\b"#, #"\b(?:when|start|begin|end|first|last)\b"#]),
    ]

    private static func route(_ text: Scratch) -> String? {
        routes.first { $0.all.allSatisfy(text.has) }?.page
    }

    // MARK: - Dates and years

    private static let monthWords = ["january", "february", "march", "april", "maymonth", "june",
                                     "july", "august", "september", "october", "november", "december"]
    private static let seasonWords = ["spring": "Spring", "summer": "Summer", "fall": "Fall",
                                      "autumn": "Fall", "winter": "Winter"]
    /// The month each season ends in — "last summer" is this year's once August is over.
    private static let seasonEnds = ["Spring": 5, "Summer": 8, "Fall": 11, "Winter": 2]

    private static func readDates(_ text: Scratch, into query: inout DayQuery, year: Int, month: Int) {
        let periodWord = "(" + (monthWords + seasonWords.keys).joined(separator: "|") + ")"

        if text.take(#"\bthis year\b"#) != nil { query.years = .year(year) }
        if text.take(#"\blast year\b"#) != nil { query.years = .year(year - 1) }
        if let g = text.take(#"\b((?:19|20)\d\d)\b"#), let y = Int(g[1]) { query.years = .year(y) }

        if let g = text.take("\\b(this|last) \(periodWord)\\b"), let period = period(g[2]) {
            query.scope = period
            if g[1] == "this" {
                query.years = .year(year)
            } else {
                let ends = seasonEnds[period.name] ?? (monthWords.firstIndex(of: g[2]).map { $0 + 1 } ?? 12)
                query.years = .year(ends < month ? year : year - 1)
            }
        } else if let g = text.take("\\b\(periodWord)\\b"), let period = period(g[1]) {
            query.scope = period
        }
    }

    private static func period(_ word: String) -> WeatherPeriod? {
        if let index = monthWords.firstIndex(of: word) { return WeatherPeriod.months[index] }
        if let name = seasonWords[word] { return WeatherPeriod.seasons.first { $0.name == name } }
        return nil
    }

    // MARK: - Runs, reductions, first and last

    private static func readRun(_ text: Scratch, into query: inout DayQuery) {
        let patterns = [
            #"\b(\d+)\+? (?:or more )?(?:days? )?(?:in a row|straight|consecutive)(?: days?)?\b"#,
            #"\b(?:spells?|stretch(?:es)?|streaks?|runs?) of (\d+)\+? (?:or more )?days?(?: or (?:more|longer))?"#,
            #"\b(\d+)\+? days? or (?:more|longer)\b"#,
        ]
        let spans = [(#"\b(?:week-long|weeklong|week long|a week or (?:more|longer))\b"#, 7),
                     (#"\b(?:2 weeks?|two-week|2-week)(?: or (?:more|longer))?\b"#, 14)]
        for (pattern, n) in spans where text.take(pattern) != nil {
            query.sequence = .inRunOfAtLeast(n)
            text.take(#"\b(?:spells?|stretch(?:es)?|streaks?)\b"#)
            return
        }
        for pattern in patterns {
            if let g = text.take(pattern), let n = Int(g[1]) {
                query.sequence = .inRunOfAtLeast(n)
                text.take(#"\b(?:spells?|stretch(?:es)?|streaks?)\b"#)
                return
            }
        }
    }

    /// The measure a word names, for reductions and for conditions.
    private static let measureWords: [(pattern: String, measure: Measure)] = [
        (#"\bdewpoint\b"#, .dewPoint),
        (#"\bhumidity\b"#, .humidity),
        (#"\b(?:gusts?|gusted|gusting|gusty)\b"#, .gust),
        (#"\bwinds?\b"#, .wind),
        (#"\b(?:rain|rains|rained|rainfall)\b"#, .rain),
        (#"\bpressure\b"#, .pressure),
        (#"\buv\b"#, .uv),
        (#"\blightning\b"#, .lightning),
        (#"\b(?:lows?|nights?|overnight)\b"#, .low),
        (#"\bhighs?\b"#, .high),
        (#"\b(?:temperatures?|temps?)\b"#, .meanTemp),
    ]

    private static func readAggregate(_ text: Scratch, into query: inout DayQuery) {
        func grouping() -> Aggregate.Grouping {
            if text.take(#"\b(?:by|each|every|per|in each) month of the year\b"#) != nil { return .monthOfYear }
            if text.take(#"\b(?:by|each|every|per) year\b"#) != nil { return .year }
            if text.take(#"\b(?:by|each|every|per) month\b"#) != nil { return .month }
            return .none
        }

        // Superlatives: "the wettest year", "the coolest month", "which year had the hottest summer".
        let superlatives: [String: (Measure, Aggregate.Reduction, Aggregate.Rank)] = [
            "hottest": (.high, .mean, .highest), "warmest": (.meanTemp, .mean, .highest),
            "coolest": (.meanTemp, .mean, .lowest), "coldest": (.low, .mean, .lowest),
            "wettest": (.rain, .sum, .highest), "rainiest": (.rain, .sum, .highest),
            "driest": (.rain, .sum, .lowest),
            "windiest": (.gust, .mean, .highest), "muggiest": (.dewPoint, .mean, .highest),
        ]
        if let g = text.take(#"\b(hottest|warmest|coolest|coldest|wettest|rainiest|driest|windiest|muggiest)(?: (month|year|day|night))?\b"#),
           let (measure, reduce, rank) = superlatives[g[1]].map({ ($0.0, $0.1, $0.2) }) {
            var unit = g[2]
            // One day or night, not a month: the extreme itself, not an average.
            if unit == "day" || unit == "night" {
                while text.take(#"\b(?:of the year|on record|ever)\b"#) != nil {}
                let night = unit == "night"
                let extreme: (Measure, Aggregate.Reduction) = switch g[1] {
                case "hottest", "warmest": (night ? .low : .high, .max)
                case "coolest", "coldest": (.low, .min)
                case "wettest", "rainiest": (.rain, .max)
                case "windiest": (.gust, .max)
                case "muggiest": (.dewPoint, .max)
                default: (.rain, .min)   // driest day: the least rain
                }
                query.aggregate = Aggregate(measure: extreme.0, reduce: extreme.1, groupBy: .none)
                return
            }
            if unit.isEmpty, let w = text.take(#"\b(?:which|what) (month|year)\b"#) { unit = w[1] }
            while text.take(#"\b(?:of the year|on record|ever|on average)\b"#) != nil {}
            query.aggregate = Aggregate(measure: measure, reduce: reduce,
                                        groupBy: unit == "year" ? .year : .monthOfYear, rank: rank)
            return
        }

        // "Which month gets the most rain".
        if let g = text.take(#"\b(?:which|what) (month|year)\b.*?\b(most|least) (?:rain|rainfall)\b"#) {
            query.aggregate = Aggregate(measure: .rain, reduce: .sum,
                                        groupBy: g[1] == "year" ? .year : .monthOfYear,
                                        rank: g[2] == "most" ? .highest : .lowest)
            return
        }

        // "Total rain", "how much rain".
        if text.take(#"\b(?:total|how much) (?:rain|rainfall)\b|\bhow many inches(?: of (?:rain|rainfall))?\b"#) != nil {
            query.aggregate = Aggregate(measure: .rain, reduce: .sum, groupBy: grouping())
            return
        }

        // "Average high by year".
        if let g = text.take(#"\b(?:average|mean|avg) ([a-z]+(?: [a-z]+)?)"#) {
            if let measure = measureWords.first(where: { Scratch(" \(g[1]) ").has($0.pattern) })?.measure {
                text.take(#"\b(?:temperatures?|temps?)\b"#)
                query.aggregate = Aggregate(measure: measure, reduce: .mean, groupBy: grouping())
            }
            return
        }

        // "How many … each year". Without a per-something it's just the matching days, counted.
        if text.has(#"\bhow many\b"#) {
            let group = grouping()
            text.take(#"\bhow many\b"#)
            if group != .none { query.aggregate = Aggregate(measure: .high, reduce: .count, groupBy: group) }
        }
    }

    private static func readFirstOrLast(_ text: Scratch, into query: inout DayQuery) {
        if text.take(#"\bfirst\b"#) != nil { query.sequence = .firstEachYear }
        if text.take(#"\b(?:last|most recent|latest)\b"#) != nil { query.sequence = .lastEachYear }
    }

    // MARK: - Conditions

    private static let number = #"(\d+(?:\.\d+)?)"#

    /// Words that ARE a condition, with no number. Read after the numbers, and
    /// only for a measure no number already spoke for: "rained more than an inch"
    /// is one condition, not "rained" plus "more than an inch".
    private static let adjectives: [(pattern: String, condition: Condition, unless: String?)] = [
        (#"\bhot\b"#, Condition(.high, .atOrAbove(90)), nil),
        (#"\bcold\b"#, Condition(.high, .inBand("Cold")), nil),
        (#"\b(?:freezing|freezes?|froze|frost)\b"#, Condition(.low, .below(32)), nil),
        (#"\b(?:dry|no rain|without rain)\b"#, Condition(.rain, .below(0.01)), "dewpoint"),
        (#"\b(?:rain|rains|rained|rainy|raining|wet)\b"#, Condition(.rain, .atOrAbove(0.01)), nil),
        (#"\bmuggy\b"#, Condition(.dewPoint, .inBand("Muggy")), nil),
        (#"\bsticky\b"#, Condition(.dewPoint, .inBand("Sticky")), nil),
        (#"\boppressive\b"#, Condition(.dewPoint, .inBand("Oppressive")), nil),
        (#"\b(?:lightning|thunder|thunderstorms?)\b"#, Condition(.lightning, .atOrAbove(1)), nil),
    ]

    private static func readConditions(_ text: Scratch) -> [Condition] {
        var conditions: [Condition] = []
        func add(_ c: Condition) {
            if !conditions.contains(where: { $0.measure == c.measure }) { conditions.append(c) }
        }
        // The measure a number belongs to: its unit, else the nearest measure word
        // before it, else after it, else a temperature — the low if the question
        // is about nights.
        let original = text.text
        func measure(at location: Int, unit: String) -> Measure {
            if unit.hasPrefix("inch") || unit.hasPrefix("in ") || unit.hasPrefix("\"") { return .rain }
            if unit.hasPrefix("mph") { return Scratch(original).has(#"\b(?:gusts?|gusted|gusting|gusty)\b"#) ? .gust : .wind }
            if unit.hasPrefix("%") || unit.hasPrefix("percent") { return .humidity }
            if unit.hasPrefix("strike") { return .lightning }
            let head = String(original.prefix(location)), tail = String(original.dropFirst(location))
            let nearest = measureWords.compactMap { word -> (Int, Measure)? in
                guard let regex = try? NSRegularExpression(pattern: word.pattern),
                      let last = regex.matches(in: head, range: NSRange(head.startIndex..., in: head)).last
                else { return nil }
                return (last.range.location, word.measure)
            }.max { $0.0 < $1.0 }
            if let nearest, nearest.1 != .meanTemp { return nearest.1 }
            if let after = measureWords.first(where: { Scratch(tail).has($0.pattern) && $0.measure != .meanTemp }) {
                return after.measure
            }
            return Scratch(original).has(#"\b(?:lows?|nights?|overnight)\b"#) ? .low : .high
        }

        if text.take(#"\b(?:below|under) freezing\b"#) != nil { add(Condition(.low, .below(32))) }
        if text.take(#"\b(?:above|over) freezing\b"#) != nil { add(Condition(.low, .atOrAbove(32))) }

        // "100 degree day".
        while let g = text.take("\\b\(number) deg days?\\b"), let v = Double(g[1]) {
            add(Condition(.high, .atOrAbove(v)))
        }
        // "never got below 80" is "at or above 80".
        while let hit = text.takeLocated("\\b(?:never|not|didn't|did not)\\b(?:\\s+[a-z']+){0,2}?\\s+(below|under|above|over) \(number)(?: deg)?\\s*(\\S*)"),
              case let (g, at) = hit, let v = Double(g[2]) {
            let m = measure(at: at, unit: g[3])
            add(Condition(m, g[1] == "below" || g[1] == "under" ? .atOrAbove(v) : .below(v)))
        }
        while let hit = text.takeLocated("\\bin the (\\d)0s\\b"), case let (g, at) = hit, let d = Double(g[1]) {
            add(Condition(measure(at: at, unit: ""), .between(d * 10, d * 10 + 10)))
        }
        while let hit = text.takeLocated("\\bbetween \(number) and \(number)(?: deg)?\\s*(\\S*)"),
              case let (g, at) = hit, let a = Double(g[1]), let b = Double(g[2]) {
            add(Condition(measure(at: at, unit: g[3]), .between(a, b)))
        }
        while let hit = text.takeLocated("\\b(?:below|under|less than|colder than|cooler than|lower than) \(number)(?: deg)?\\s*(\\S*)"),
              case let (g, at) = hit, let v = Double(g[1]) {
            add(Condition(measure(at: at, unit: g[2]), .below(v)))
        }
        while let hit = text.takeLocated("\\b(?:over|above|more than|at least|warmer than|hotter than|higher than|reached|reach|hit|hits|of) \(number)(?: deg)?\\s*(\\S*)"),
              case let (g, at) = hit, let v = Double(g[1]) {
            add(Condition(measure(at: at, unit: g[2]), .atOrAbove(v)))
        }
        while let hit = text.takeLocated("\\b\(number)(?: deg)?\\s*(\\S*)(?:\\s+[a-z]+){0,2}?\\s+or (?:more|higher|above|greater)\\b"),
              case let (g, at) = hit, let v = Double(g[1]) {
            add(Condition(measure(at: at, unit: g[2]), .atOrAbove(v)))
        }

        for adjective in adjectives {
            if let unless = adjective.unless, text.has("\\b\(unless)\\b") { continue }
            if text.take(adjective.pattern) != nil { add(adjective.condition) }
        }
        // The measure words have been read for what they name; they aren't unread.
        for word in measureWords { while text.take(word.pattern) != nil {} }
        while text.take(#"\b(?:inch(?:es)?|mph|deg|days?)\b"#) != nil {}
        return conditions
    }
}

// MARK: - Reading by taking

/// The question, worn down as it is read. Every clause that's understood is
/// blanked out of `text`, so what remains at the end is exactly what wasn't.
final class Scratch {
    var text: String
    init(_ text: String) { self.text = text }

    private static let ignorable: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "that", "this",
        "it", "is", "was", "were", "be", "been", "are", "did", "do", "does", "we", "our", "us", "there",
        "when", "what", "what's", "which", "how", "show", "me", "find", "days", "day", "time", "times",
        "had", "has", "have", "get", "got", "gets", "getting", "go", "went", "right", "usually", "happen",
        "since", "ever", "record", "year", "years", "month", "months", "many", "much", "dropped", "drop",
        "stayed", "where", "any", "all", "more", "most",
    ]

    /// What wasn't understood: the words left, minus the ones that carry no meaning.
    var unread: [String] {
        text.split(separator: " ").map(String.init)
            .map { $0 == "maymonth" ? "May" : $0 }
            .filter { !Self.ignorable.contains($0) }
    }

    func has(_ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The first match's capture groups (index 0 is the whole match), blanked out.
    @discardableResult
    func take(_ pattern: String) -> [String]? { takeLocated(pattern)?.groups }

    /// As `take`, with where the match started, for finding the words near it.
    func takeLocated(_ pattern: String) -> (groups: [String], location: Int)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text) else { return nil }
        let groups = (0..<match.numberOfRanges).map { index -> String in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
        let location = text.distance(from: text.startIndex, to: whole.lowerBound)
        text.replaceSubrange(whole, with: String(repeating: " ", count: text[whole].count))
        return (groups, location)
    }

    /// Everything from the first match on, removed and returned as its own scratch.
    func splitOff(_ pattern: String) -> Scratch? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let rest = Scratch(" " + text[range.upperBound...] + " ")
        text = String(text[..<range.lowerBound]) + " "
        return rest
    }
}
