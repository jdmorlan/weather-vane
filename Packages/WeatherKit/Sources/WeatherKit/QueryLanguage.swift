//
//  QueryLanguage.swift  (WeatherKit)
//
//  A `DayQuery` AS SOMETHING THAT CAN BE SAID — a JSON Schema derived from the types, and a strict
//  decode back into the real value. This is what lets a question asked in words ("hot dry days in
//  July, three or more in a row") arrive as the same value the explore view is already driven by,
//  instead of as prose about the weather.
//
//  DERIVED, NEVER HAND-WRITTEN. The measures come from `Measure.allCases`, the band names from each
//  measure's own `bands`, the period names from `WeatherPeriod.months + .seasons`. Add a measure and
//  it is sayable the same day; rename a band and the schema renames with it. A hand-authored copy of
//  this shape would drift within a week, which is the lesson `mediaKinds` taught and the capability
//  schema was built on.
//
//  THE ENUM CONVENTION, decided here and meant to be reused: a Swift enum with associated values
//  becomes a TAGGED OBJECT — `{"kind": "atOrAbove", "value": 90}` — expressed in JSON Schema as
//  `oneOf` + a `const` discriminator. `kind` rather than the vault's `t`/`v` because that is a
//  storage format for files you read and this is a wire format for a model you instruct. The next
//  value type that needs saying (`Rule`: trigger + action + guard) is the same shape and should
//  follow this file rather than invent a second convention.
//
//  Nothing here knows about MCP, or about a tool. It knows how to say a query and how to read one.
//

import Foundation

public enum QueryLanguageError: Error, CustomStringConvertible {
    case malformed(path: String, expected: String, got: String)
    case unknown(path: String, got: String, allowed: [String])

    public var description: String {
        switch self {
        case .malformed(let path, let expected, let got):
            return "`\(path)` should be \(expected); got \(got)."
        case .unknown(let path, let got, let allowed):
            return "`\(path)` was \"\(got)\"; it must be one of: \(allowed.joined(separator: ", "))."
        }
    }
}

// MARK: - Reading a query

public extension DayQuery {

    /// Build a query from a proposal. STRICT: an unknown measure or a malformed test throws rather
    /// than being quietly dropped, because a query missing one of its conditions still runs and still
    /// returns days — it just answers a different question than the one that was asked, and nothing
    /// downstream can tell. A refused proposal is recoverable; a silently different one isn't.
    init(json: [String: Any]) throws {
        let conditionsJSON = (json["conditions"] as? [[String: Any]]) ?? []
        let conditions = try conditionsJSON.enumerated().map { index, raw in
            try Condition(json: raw, path: "conditions[\(index)]")
        }

        var scope: WeatherPeriod?
        if let raw = json["scope"] as? [String: Any] { scope = try WeatherPeriod(json: raw, path: "scope") }

        var years: YearScope = .all
        if let raw = json["years"] as? [String: Any] { years = try YearScope(json: raw, path: "years") }

        var preceding: PrecedingClause?
        if let raw = json["precededBy"] as? [String: Any] {
            preceding = try PrecedingClause(json: raw, path: "precededBy")
        }

        var sequence: SequenceRule?
        if let raw = json["sequence"] as? [String: Any] {
            sequence = try SequenceRule(json: raw, path: "sequence")
        }

        var aggregate: Aggregate?
        if let raw = json["aggregate"] as? [String: Any] {
            aggregate = try Aggregate(json: raw, path: "aggregate")
        }

        self.init(name: (json["name"] as? String) ?? "",
                  conditions: conditions, scope: scope, years: years,
                  precededBy: preceding, sequence: sequence, aggregate: aggregate)
    }

    /// The same query back out as JSON — so a proposal the user CORRECTED can be re-emitted from the
    /// value that was actually shown, never from the text that arrived.
    var jsonObject: [String: Any] {
        var out: [String: Any] = ["conditions": conditions.map(\.jsonObject)]
        if !name.isEmpty { out["name"] = name }
        if let scope { out["scope"] = scope.jsonObject }
        if years != .all { out["years"] = years.jsonObject }
        if let precededBy { out["precededBy"] = precededBy.jsonObject }
        if let sequence { out["sequence"] = sequence.jsonObject }
        if let aggregate { out["aggregate"] = aggregate.jsonObject }
        return out
    }
}

extension Aggregate {
    /// Plain strings, not the tagged objects `Test` and `YearScope` use: every choice here is a bare
    /// case with no payload, so a discriminator would be ceremony. The convention is "tag what carries
    /// a value", not "tag every enum".
    init(json: [String: Any], path: String) throws {
        guard let rawMeasure = json["measure"] as? String else {
            throw QueryLanguageError.malformed(path: "\(path).measure", expected: "a measure name",
                                               got: String(describing: json["measure"] ?? "nothing"))
        }
        guard let measure = Measure(rawValue: rawMeasure) else {
            throw QueryLanguageError.unknown(path: "\(path).measure", got: rawMeasure,
                                             allowed: Measure.allCases.map(\.rawValue))
        }
        let rawReduce = (json["reduce"] as? String) ?? ""
        guard let reduce = Reduction(rawValue: rawReduce) else {
            throw QueryLanguageError.unknown(path: "\(path).reduce", got: rawReduce,
                                             allowed: Reduction.allCases.map(\.rawValue))
        }
        // A total only means something for a measure that ACCUMULATES. Summing daily highs produces a
        // four-figure temperature, which is not a wrong answer to the question asked — it's an answer
        // to no question at all. Refused for the same reason an unknown measure is: a nonsense number
        // still renders, still ranks, and nothing downstream can tell it apart from a real one.
        guard reduce != .sum || measure.accumulates else {
            throw QueryLanguageError.unknown(path: "\(path).reduce", got: rawReduce,
                                             allowed: measure.reductions.map(\.rawValue))
        }
        var grouping: Grouping = .none
        if let raw = json["groupBy"] as? String {
            guard let parsed = Grouping(rawValue: raw) else {
                throw QueryLanguageError.unknown(path: "\(path).groupBy", got: raw,
                                                 allowed: Grouping.allCases.map(\.rawValue))
            }
            grouping = parsed
        }
        var rank: Rank?
        if let raw = json["rank"] as? String {
            guard let parsed = Rank(rawValue: raw) else {
                throw QueryLanguageError.unknown(path: "\(path).rank", got: raw,
                                                 allowed: Rank.allCases.map(\.rawValue))
            }
            rank = parsed
        }
        let limit = (json["limit"] as? Int) ?? (json["limit"] as? Double).map(Int.init)
        self.init(measure: measure, reduce: reduce, groupBy: grouping, rank: rank, limit: limit)
    }

    var jsonObject: [String: Any] {
        var out: [String: Any] = ["measure": measure.rawValue, "reduce": reduce.rawValue,
                                  "groupBy": groupBy.rawValue]
        if let rank { out["rank"] = rank.rawValue }
        if let limit { out["limit"] = limit }
        return out
    }

    static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "description": """
            REPORT A NUMBER about the selected days instead of listing them — this is how "which month \
            got the most rain", "average high by year", "total rain last summer" are asked. Without it a \
            query counts matching days; with it, it reduces them.
            """,
            "properties": [
                "measure": ["type": "string", "enum": Measure.allCases.map(\.rawValue),
                            "description": "Which measure to reduce."],
                "reduce": ["type": "string", "enum": Reduction.allCases.map(\.rawValue),
                           "description": """
                           sum = add the days up; mean = average; max/min = the extreme reached; \
                           count = how many days. sum is ONLY valid for a measure that accumulates \
                           (\(Measure.allCases.filter(\.accumulates).map(\.rawValue).joined(separator: ", "))) \
                           — a total high temperature is not a number.
                           """],
                "groupBy": ["type": "string", "enum": Grouping.allCases.map(\.rawValue),
                            "description": """
                            What each number is per. month = July 2023 separately from July 2024; \
                            monthOfYear = every July together (use this for "which month is usually \
                            wettest"); year = per calendar year; none = one number for everything.
                            """],
                "rank": ["type": "string", "enum": Rank.allCases.map(\.rawValue),
                         "description": "Order by the value to answer \"the most/least\". Omit to keep chronological order."],
                "limit": ["type": "integer", "description": "Keep only this many groups after ranking."],
            ],
            "required": ["measure", "reduce"],
        ]
    }
}

// MARK: - The pieces

extension Condition {
    init(json: [String: Any], path: String) throws {
        guard let raw = json["measure"] as? String else {
            throw QueryLanguageError.malformed(path: "\(path).measure", expected: "a measure name",
                                               got: String(describing: json["measure"] ?? "nothing"))
        }
        guard let measure = Measure(rawValue: raw) else {
            throw QueryLanguageError.unknown(path: "\(path).measure", got: raw,
                                             allowed: Measure.allCases.map(\.rawValue))
        }
        guard let testJSON = json["test"] as? [String: Any] else {
            throw QueryLanguageError.malformed(path: "\(path).test", expected: "a test object",
                                               got: String(describing: json["test"] ?? "nothing"))
        }
        self.init(measure, try Test(json: testJSON, path: "\(path).test", measure: measure))
    }

    var jsonObject: [String: Any] { ["measure": measure.rawValue, "test": test.jsonObject] }
}

extension Test {
    init(json: [String: Any], path: String, measure: Measure) throws {
        let kind = (json["kind"] as? String) ?? ""
        func number(_ key: String) throws -> Double {
            if let d = json[key] as? Double { return d }
            if let i = json[key] as? Int { return Double(i) }
            throw QueryLanguageError.malformed(path: "\(path).\(key)", expected: "a number",
                                               got: String(describing: json[key] ?? "nothing"))
        }
        switch kind {
        case "atOrAbove": self = .atOrAbove(try number("value"))
        case "below":     self = .below(try number("value"))
        case "atOrBelow": self = .atOrBelow(try number("value"))
        case "between":   self = .between(try number("lower"), try number("upper"))
        case "inBand":
            guard let band = json["band"] as? String else {
                throw QueryLanguageError.malformed(path: "\(path).band", expected: "a band name",
                                                   got: String(describing: json["band"] ?? "nothing"))
            }
            // A band belongs to a MEASURE — "Muggy" is a dew point, not a wind speed. Checking it here
            // turns a query that would silently match nothing into a proposal that gets refused.
            //
            // And a measure with NO bands needs its own sentence: "must be one of: " followed by
            // nothing is a refusal that tells you only that you were wrong, which is the half of a
            // refusal that doesn't help anyone fix it.
            guard !measure.bands.isEmpty else {
                throw QueryLanguageError.malformed(
                    path: path,
                    expected: "a numeric test — \(measure.name) has no named bands",
                    got: "the band \"\(band)\"")
            }
            guard measure.bands.contains(where: { $0.name == band }) else {
                throw QueryLanguageError.unknown(path: "\(path).band", got: band,
                                                 allowed: measure.bands.map(\.name))
            }
            self = .inBand(band)
        default:
            throw QueryLanguageError.unknown(path: "\(path).kind", got: kind,
                                             allowed: ["atOrAbove", "below", "atOrBelow", "between", "inBand"])
        }
    }

    var jsonObject: [String: Any] {
        switch self {
        case .atOrAbove(let v): return ["kind": "atOrAbove", "value": v]
        case .below(let v):     return ["kind": "below", "value": v]
        case .atOrBelow(let v): return ["kind": "atOrBelow", "value": v]
        case .between(let a, let b): return ["kind": "between", "lower": a, "upper": b]
        case .inBand(let name): return ["kind": "inBand", "band": name]
        }
    }
}

extension YearScope {
    init(json: [String: Any], path: String) throws {
        switch (json["kind"] as? String) ?? "" {
        case "all": self = .all
        case "year":
            guard let year = (json["value"] as? Int) ?? (json["value"] as? Double).map(Int.init) else {
                throw QueryLanguageError.malformed(path: "\(path).value", expected: "a year",
                                                   got: String(describing: json["value"] ?? "nothing"))
            }
            self = .year(year)
        default:
            throw QueryLanguageError.unknown(path: "\(path).kind",
                                             got: (json["kind"] as? String) ?? "",
                                             allowed: ["all", "year"])
        }
    }

    var jsonObject: [String: Any] {
        switch self {
        case .all: return ["kind": "all"]
        case .year(let y): return ["kind": "year", "value": y]
        }
    }
}

extension PrecedingClause {
    init(json: [String: Any], path: String) throws {
        let raw = (json["conditions"] as? [[String: Any]]) ?? []
        let conditions = try raw.enumerated().map { index, c in
            try Condition(json: c, path: "\(path).conditions[\(index)]")
        }
        guard !conditions.isEmpty else {
            throw QueryLanguageError.malformed(path: "\(path).conditions",
                                               expected: "at least one condition", got: "an empty list")
        }
        self.init(conditions: conditions, within: (json["within"] as? Int) ?? 1)
    }

    var jsonObject: [String: Any] {
        ["conditions": conditions.map(\.jsonObject), "within": within]
    }
}

extension SequenceRule {
    init(json: [String: Any], path: String) throws {
        switch (json["kind"] as? String) ?? "" {
        case "firstEachYear": self = .firstEachYear
        case "lastEachYear":  self = .lastEachYear
        case "inRunOfAtLeast":
            guard let n = (json["value"] as? Int) ?? (json["value"] as? Double).map(Int.init) else {
                throw QueryLanguageError.malformed(path: "\(path).value", expected: "a whole number",
                                                   got: String(describing: json["value"] ?? "nothing"))
            }
            self = .inRunOfAtLeast(n)
        default:
            throw QueryLanguageError.unknown(path: "\(path).kind",
                                             got: (json["kind"] as? String) ?? "",
                                             allowed: ["firstEachYear", "lastEachYear", "inRunOfAtLeast"])
        }
    }

    var jsonObject: [String: Any] {
        switch self {
        case .firstEachYear: return ["kind": "firstEachYear"]
        case .lastEachYear:  return ["kind": "lastEachYear"]
        case .inRunOfAtLeast(let n): return ["kind": "inRunOfAtLeast", "value": n]
        }
    }
}

extension WeatherPeriod {
    /// A scope is either a NAMED period (a month, a season — the ones the app already offers) or an
    /// explicit `MM-dd` window. Named comes first because making a model compute month boundaries is
    /// asking it to get "07-01".."08-01" right every time for no reason; the app already knows.
    init(json: [String: Any], path: String) throws {
        if let name = json["period"] as? String {
            guard let match = Self.sayable.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                throw QueryLanguageError.unknown(path: "\(path).period", got: name,
                                                 allowed: Self.sayable.map(\.name))
            }
            self = match
            return
        }
        guard let start = json["start"] as? String, let end = json["endExclusive"] as? String else {
            throw QueryLanguageError.malformed(
                path: path, expected: "either {\"period\": <name>} or {\"start\", \"endExclusive\"} as MM-dd",
                got: String(describing: json))
        }
        guard Self.isMonthDay(start), Self.isMonthDay(end) else {
            throw QueryLanguageError.malformed(path: path, expected: "MM-dd dates",
                                               got: "\(start) … \(end)")
        }
        self.init(name: (json["name"] as? String) ?? "\(start)–\(end)",
                  start: start, endExclusive: end, kind: .custom)
    }

    var jsonObject: [String: Any] {
        // A named period says its NAME, so a round trip stays readable rather than decaying into
        // boundaries the second time it's written down.
        if Self.sayable.contains(where: { $0.name == name && $0.start == start }) {
            return ["period": name]
        }
        return ["name": name, "start": start, "endExclusive": endExclusive]
    }

    /// The periods a question can name: the twelve months and the four seasons.
    static var sayable: [WeatherPeriod] { months + seasons }

    static func isMonthDay(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let m = Int(parts[0]), let d = Int(parts[1]) else { return false }
        return (1...12).contains(m) && (1...31).contains(d)
    }
}

// MARK: - Saying it: the schema, derived

public extension DayQuery {

    /// The JSON Schema for a proposed query. Every enumeration in it is read off the types, so this
    /// can't describe a query the app can't run.
    static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "name": ["type": "string",
                         "description": "A short name for the question, in the user's own words — it titles the view."],
                "conditions": [
                    "type": "array",
                    "description": """
                    What must be true OF THE DAY ITSELF. ANDed together — every condition must hold. \
                    Leave empty only when another clause carries the question (\"days after it rained\").
                    """,
                    "items": conditionSchema,
                ],
                "scope": [
                    "description": "WHICH DATES of the year to look at. Omit for the whole year.",
                    "oneOf": [
                        ["type": "object",
                         "properties": ["period": ["type": "string", "enum": WeatherPeriod.sayable.map(\.name)]],
                         "required": ["period"],
                         "description": "A named month or season."],
                        ["type": "object",
                         "properties": [
                            "name": ["type": "string"],
                            "start": ["type": "string", "description": "Inclusive MM-dd, e.g. 06-15."],
                            "endExclusive": ["type": "string", "description": "EXCLUSIVE MM-dd — the day after the last day you mean."],
                         ],
                         "required": ["start", "endExclusive"],
                         "description": "A custom window of the year."],
                    ],
                ],
                "years": [
                    "description": "WHICH YEARS. Omit for every year on record.",
                    "oneOf": [
                        ["type": "object", "properties": ["kind": ["const": "all"]], "required": ["kind"]],
                        ["type": "object",
                         "properties": ["kind": ["const": "year"], "value": ["type": "integer"]],
                         "required": ["kind", "value"]],
                    ],
                ],
                "precededBy": [
                    "type": "object",
                    "description": """
                    A condition on the days BEFORE — this is how "days after it rained" is asked. \
                    The day itself may have no conditions at all when this carries the question.
                    """,
                    "properties": [
                        "conditions": ["type": "array", "items": conditionSchema],
                        "within": ["type": "integer",
                                   "description": "How many days back to look. 1 = yesterday only; 3 = at some point in the three days before."],
                    ],
                    "required": ["conditions"],
                ],
                "aggregate": Aggregate.jsonSchema,
                "sequence": [
                    "description": "A filter on a day's place among the matches. Omit unless asked for.",
                    "oneOf": [
                        ["type": "object", "properties": ["kind": ["const": "firstEachYear"]], "required": ["kind"],
                         "description": "The earliest match in each year — first frost, first 90° day."],
                        ["type": "object", "properties": ["kind": ["const": "lastEachYear"]], "required": ["kind"],
                         "description": "The latest match in each year — last freeze."],
                        ["type": "object",
                         "properties": ["kind": ["const": "inRunOfAtLeast"], "value": ["type": "integer"]],
                         "required": ["kind", "value"],
                         "description": "Only days inside a run of at least N consecutive matching days — a heat wave, a dry spell."],
                    ],
                ],
            ],
            "required": ["conditions"],
        ]
    }

    /// One condition. The measure list and every band name are read off `Measure`, so this describes
    /// exactly the questions the archive can answer and no others.
    private static var conditionSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "measure": [
                    "type": "string",
                    "enum": Measure.allCases.map(\.rawValue),
                    "description": Measure.allCases
                        .map { "\($0.rawValue) = \($0.name)" }
                        .joined(separator: "; "),
                ],
                "test": [
                    "description": "How to test the measure.",
                    "oneOf": [
                        ["type": "object",
                         "properties": ["kind": ["const": "atOrAbove"], "value": ["type": "number"]],
                         "required": ["kind", "value"]],
                        ["type": "object",
                         "properties": ["kind": ["const": "below"], "value": ["type": "number"]],
                         "required": ["kind", "value"]],
                        ["type": "object",
                         "properties": ["kind": ["const": "atOrBelow"], "value": ["type": "number"]],
                         "required": ["kind", "value"]],
                        ["type": "object",
                         "properties": ["kind": ["const": "between"],
                                        "lower": ["type": "number"],
                                        "upper": ["type": "number", "description": "Exclusive."]],
                         "required": ["kind", "lower", "upper"]],
                        ["type": "object",
                         "properties": ["kind": ["const": "inBand"],
                                        "band": ["type": "string", "description": bandHelp]],
                         "required": ["kind", "band"],
                         "description": "The qualitative way to ask — a named band of that measure."],
                    ],
                ],
            ],
            "required": ["measure", "test"],
        ]
    }

    /// Which bands belong to which measure — generated, because a band renamed in `Measure.bands`
    /// must never keep being offered here under its old name.
    private static var bandHelp: String {
        "Bands are per measure. " + Measure.allCases
            .filter { !$0.bands.isEmpty }
            .map { "\($0.rawValue): \($0.bands.map(\.name).joined(separator: "/"))" }
            .joined(separator: "; ")
    }
}
