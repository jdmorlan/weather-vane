//
//  ExploreQuestion.swift  (WeatherKit)
//
//  The questions Explore offers, in the words someone would ask them.
//
//  A `DayQuery` says what to look for; it can't say what you were asking. "Low
//  below 50°" is a condition. "When are the nights cool?" is the question, and
//  the answer reads differently: cool nights are answered with when they're the
//  norm, freezes with when one is possible at all, because nobody plans around
//  the fortnight in January when freezing is more likely than not.
//
//  SEASONS FIRST, because that's how people think about weather here: it cools
//  down in the fall, but when, and how many false starts first. Each season is
//  one card's worth of question. Rhythms is meant to become these same questions.
//

import Foundation

public struct ExploreQuestion: Identifiable, Equatable, Sendable {

    public enum Group: String, CaseIterable, Sendable {
        case seasons = "Seasons"
        /// The Rain page asks these too, under its own record.
        case rain = "Rain"
        case other = "Other questions"
    }

    /// Which pair of dates answers a season.
    public enum Answer: Equatable, Sendable {
        /// Where the curve is above half: when it's the norm.
        case mostDays
        /// The typical first and last: when it can happen at all.
        case possible
    }

    public var id: String
    public var group: Group
    /// "When is it hot?"
    public var asks: String
    /// What a matching day did, mid-sentence: "About 9 in 10 days hit 90°".
    public var matched: String
    /// The names of the two pairs of dates.
    public var mostDaysName: String
    public var possibleName: String
    public var answer: Answer
    public var query: DayQuery

    public init(id: String, group: Group, asks: String, matched: String,
                mostDaysName: String = "most days", possibleName: String = "first to last",
                answer: Answer = .mostDays, query: DayQuery) {
        self.id = id
        self.group = group
        self.asks = asks
        self.matched = matched
        self.mostDaysName = mostDaysName
        self.possibleName = possibleName
        self.answer = answer
        var query = query
        query.name = asks
        self.query = query
    }

    /// The same question, whatever it's called and however it was arrived at.
    public func asks(_ other: DayQuery) -> Bool {
        other.conditions == query.conditions && other.scope == query.scope
            && other.precededBy == query.precededBy && other.aggregate == nil
            && other.sequence == nil && other.years == .all
    }

    public static let all: [ExploreQuestion] = [
        ExploreQuestion(id: "hot", group: .seasons, asks: "When is it hot?", matched: "hit 90°",
                        mostDaysName: "hot most days", possibleName: "90° possible",
                        query: DayQuery(conditions: [Condition(.high, .atOrAbove(90))])),
        ExploreQuestion(id: "muggy", group: .seasons, asks: "When is it muggy?",
                        matched: "had a dew point of 65° or more", mostDaysName: "muggy most days",
                        query: DayQuery(conditions: [Condition(.dewPoint, .atOrAbove(65))])),
        ExploreQuestion(id: "warm-nights", group: .seasons, asks: "When are the nights warm?",
                        matched: "stayed at 65° or above", mostDaysName: "warm most nights",
                        query: DayQuery(conditions: [Condition(.low, .atOrAbove(65))])),
        ExploreQuestion(id: "cool-nights", group: .seasons, asks: "When are the nights cool?",
                        matched: "dropped below 50°", mostDaysName: "cool most nights",
                        query: DayQuery(conditions: [Condition(.low, .below(50))])),
        ExploreQuestion(id: "freeze", group: .seasons, asks: "When can it freeze?", matched: "froze",
                        mostDaysName: "most nights", possibleName: "first to last freeze", answer: .possible,
                        query: DayQuery(conditions: [Condition(.low, .atOrBelow(32))])),
        ExploreQuestion(id: "rain", group: .rain, asks: "When does it rain?", matched: "had rain",
                        mostDaysName: "rain most days", possibleName: "rain possible",
                        query: DayQuery(conditions: [Condition(.rain, .atOrAbove(0.01))])),
        ExploreQuestion(id: "hard-rain", group: .rain, asks: "When does it rain hard?", matched: "had 0.5\" or more",
                        query: DayQuery(conditions: [Condition(.rain, .atOrAbove(0.5))])),
        ExploreQuestion(id: "storms", group: .rain, asks: "When are storms likeliest?", matched: "had a storm",
                        query: DayQuery(conditions: [Condition(.lightning, .atOrAbove(1)),
                                                     Condition(.rain, .atOrAbove(0.1))])),
        ExploreQuestion(id: "september-rain", group: .other, asks: "Does September usually get rain?",
                        matched: "had rain",
                        query: DayQuery(conditions: [Condition(.rain, .atOrAbove(0.01))],
                                        scope: WeatherPeriod.months[8])),
    ]

    /// What opens Explore.
    public static var standard: ExploreQuestion { all[0] }

    /// A question the list doesn't hold — built by hand, or asked in words —
    /// worded from the query itself.
    ///
    /// A season answers with "most days" unless that stretch is short against
    /// the whole: freezes are the norm for twelve days of a four-month season,
    /// and naming the twelve days would read as a claim the rest is safe.
    public static func describing(_ query: DayQuery) -> ExploreQuestion {
        if let known = all.first(where: { $0.asks(query) }) { return known }
        let nights = !query.conditions.isEmpty && query.conditions.allSatisfy { $0.measure == .low }
        return ExploreQuestion(id: "custom", group: .other,
                               asks: query.name.isEmpty ? query.describe : query.name,
                               matched: "matched",
                               mostDaysName: nights ? "most nights" : "most days",
                               query: query)
    }
}

extension WhenInTheYear {

    /// The pair of dates that answers this question, and which pair it is. Nil
    /// for a question that isn't a season.
    public func answer(to question: ExploreQuestion) -> (dates: ClosedRange<Int>, answer: ExploreQuestion.Answer)? {
        guard kind == .season else { return nil }
        switch question.answer {
        case .possible:
            if let outer { return (outer, .possible) }
            return inner.map { ($0, .mostDays) }
        case .mostDays:
            guard let inner else { return outer.map { ($0, .possible) } }
            // A question nobody worded falls back on the wider pair when the norm
            // is only a sliver of it — see `ExploreQuestion.describing`.
            if question.id == "custom", let outer, inner.count * 3 < outer.count { return (outer, .possible) }
            return (inner, .mostDays)
        }
    }
}
