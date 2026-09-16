//
//  ForecastQuery.swift  (WeatherKit)
//
//  WHAT A FORECAST QUESTION IS, as a value. The archive already had one (`DayQuery`) and the forecast
//  had none — which is exactly why the app could show you a full ten-day outlook on the Now tab while a
//  conversation standing next to it answered "I don't have a live forecast feed here". The data was
//  decoded and on screen; it just had no way to be ASKED FOR.
//
//  The unit of the question is a HORIZON — the stretch of time you mean — plus, optionally, the one
//  thing you care about. "Is it going to rain tomorrow" is `(tomorrow, rain)`; "what's it like out"
//  is `(now, everything)`. That's the whole language, and it's deliberately small: unlike the archive,
//  where the question is a genuine query (conditions, scope, sequence), a forecast is ten days of
//  already-interpreted text and the only real decisions are WHEN and WHAT ABOUT.
//
//  Same conventions as `QueryLanguage.swift`: the schema is DERIVED from `allCases`, the decode is
//  STRICT (an unknown horizon throws rather than silently becoming "today" and answering a different
//  question), and the value can SAY ITSELF in English so an answer can be checked against the question
//  it was actually read as.
//

import Foundation

public struct ForecastQuery: Equatable, Sendable {

    /// The stretch of time the question is about. Coarse on purpose: these are the spans people
    /// actually ask about, and a forecast has nothing finer to say honestly ten days out.
    public enum Horizon: String, CaseIterable, Sendable {
        case now        // this moment — current conditions
        case today      // what's LEFT of today
        case tonight    // this evening and overnight
        case tomorrow
        case week       // the ten-day outlook

        public var label: String {
            switch self {
            case .now: return "right now"
            case .today: return "today"
            case .tonight: return "tonight"
            case .tomorrow: return "tomorrow"
            case .week: return "the next ten days"
            }
        }
    }

    /// The ONE thing being asked about, when there is one. `everything` is the honest default: asked
    /// "what's the weather", answering only about rain would be a different question quietly answered.
    public enum Focus: String, CaseIterable, Sendable {
        case everything
        case rain
        case temperature
        case wind
        case comfort    // dew point / mugginess — the number that actually decides how a day feels

        public var label: String {
            switch self {
            case .everything: return "the weather"
            case .rain: return "rain"
            case .temperature: return "temperature"
            case .wind: return "wind"
            case .comfort: return "how muggy it is"
            }
        }
    }

    public var horizon: Horizon
    public var focus: Focus

    public init(horizon: Horizon, focus: Focus = .everything) {
        self.horizon = horizon
        self.focus = focus
    }

    /// The question in English — what an accept card would show, and what an answer can be checked
    /// against. A proposable value that can't say itself is one the user cannot check.
    public var describe: String {
        switch focus {
        case .everything: return "The forecast for \(horizon.label)"
        default: return "\(focus.label.capitalizedFirst) \(horizon.label)"
        }
    }
}

// MARK: - Saying it, and reading it back

public extension ForecastQuery {

    /// Derived from `allCases`, so a new horizon is sayable the day it exists.
    static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "horizon": [
                    "type": "string",
                    "enum": Horizon.allCases.map(\.rawValue),
                    "description": "The stretch of time the question is about. `now` = current "
                                 + "conditions; `today` = what's left of today; `tonight` = this "
                                 + "evening and overnight; `week` = the ten-day outlook.",
                ],
                "focus": [
                    "type": "string",
                    "enum": Focus.allCases.map(\.rawValue),
                    "description": "The one thing they asked about, if they named one. Leave it out "
                                 + "for a general \"what's the weather\" question — answering only "
                                 + "about rain when they asked about the day is a different question.",
                ],
            ],
            "required": ["horizon"],
        ]
    }

    /// STRICT, for the same reason `DayQuery` is: a horizon quietly defaulted to `today` still returns
    /// a plausible-sounding forecast, and nothing downstream can tell it answered the wrong day.
    init(json: [String: Any]) throws {
        guard let raw = json["horizon"] as? String else {
            throw QueryLanguageError.malformed(path: "horizon", expected: "a string",
                                               got: String(describing: json["horizon"] ?? "nothing"))
        }
        guard let horizon = Horizon(rawValue: raw) else {
            throw QueryLanguageError.unknown(path: "horizon", got: raw,
                                             allowed: Horizon.allCases.map(\.rawValue))
        }
        var focus = Focus.everything
        if let rawFocus = json["focus"] as? String {
            guard let parsed = Focus(rawValue: rawFocus) else {
                throw QueryLanguageError.unknown(path: "focus", got: rawFocus,
                                                 allowed: Focus.allCases.map(\.rawValue))
            }
            focus = parsed
        }
        self.init(horizon: horizon, focus: focus)
    }

    var jsonObject: [String: Any] {
        ["horizon": horizon.rawValue, "focus": focus.rawValue]
    }
}
