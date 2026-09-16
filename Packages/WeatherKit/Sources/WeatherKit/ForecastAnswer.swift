//
//  ForecastAnswer.swift  (WeatherKit)
//
//  A `ForecastQuery` ANSWERED IN WORDS, off a `WeatherReport`. The screen already answers these
//  questions in cards; this is the same answers said out loud, for a conversation that has the report
//  in hand and needs a sentence rather than a layout.
//
//  Two rules, both learned from the archive side ([[weatherkit-tempest]], "say nothing rather than
//  thin"):
//
//  1. SAY WHAT ISN'T THERE. A ten-day forecast run at 11pm has almost no hours left in "today", and
//     the honest answer to "what's the rest of today look like" is that the day is over — not a
//     confident summary of two remaining hours dressed up as a day.
//  2. NEVER WIDEN SILENTLY. Asked about tomorrow with only today decoded, this says so; it does not
//     answer about today and let the label do the lying.
//
//  The interpretation itself is NOT redone here. `WeatherReport` already carries the sentences the Now
//  tab shows — `rain.text`, `wind.text`, each `DayNote.headline`, each `DayPart.text` — so this file
//  is a SELECTOR, not a second interpreter. Two interpreters would drift, and the screen would stop
//  agreeing with the answer.
//

import Foundation

public extension WeatherReport {

    /// The forecast question, answered in one to a few sentences.
    func answer(_ query: ForecastQuery) -> String {
        switch query.horizon {
        case .now:      return nowText(query.focus)
        case .today:    return dayText(index: 0, label: "Today", focus: query.focus, todayNotes: true)
        case .tonight:  return tonightText(query.focus)
        case .tomorrow: return dayText(index: 1, label: "Tomorrow", focus: query.focus, todayNotes: false)
        case .week:     return weekText(query.focus)
        }
    }

    // MARK: Right now

    private func nowText(_ focus: ForecastQuery.Focus) -> String {
        var parts: [String] = []
        // "Feels like" only when it DISAGREES with the thermometer — 92° feels like 92° is a number
        // that says nothing and makes the answer read like a readout instead of a reply.
        var bits: [String] = []
        if let t = temperature { bits.append(WeatherInterpreter.temp(t)) }
        if let f = feelsLike, let t = temperature, abs(f - t) >= 3 {
            bits.append("feels like \(WeatherInterpreter.temp(f))")
        }
        let now = bits.joined(separator: ", ")

        switch focus {
        case .everything:
            parts.append(now.isEmpty ? conditions : "Right now: \(now), \(conditions.lowercasedFirst).")
            parts.append(comfort.text)
            parts.append(wind.text)
            if pressure.isNotable { parts.append(pressure.text) }
            parts.append(rain.text)
        case .temperature:
            parts.append(now.isEmpty ? "The station isn't reporting a temperature right now." : "Right now: \(now).")
        case .comfort:
            parts.append(comfort.text)
        case .wind:
            parts.append(wind.text)
            if let gust = windGust, let avg = windAvg, let dir = windDirectionCardinal {
                parts.append("Currently \(dir) at \(WeatherInterpreter.mph(avg)), gusting \(WeatherInterpreter.mph(gust)).")
            }
        case .rain:
            parts.append(rain.text)
            if let today = precipToday, today > 0 {
                parts.append("\(WeatherInterpreter.inches(today)) has fallen so far today.")
            }
        }
        // Alerts ride along on every focus — lightning nearby is not something to withhold because
        // the question was about temperature.
        parts.append(contentsOf: alerts)
        return join(parts)
    }

    // MARK: A single day

    /// `todayNotes` = use the current-day notes (`rain`/`wind`), which are built from what's LEFT of
    /// today and are more specific than the daily summary. A future day has only its `DayNote`.
    private func dayText(index: Int, label: String, focus: ForecastQuery.Focus, todayNotes: Bool) -> String {
        guard days.indices.contains(index) else {
            return "The forecast I have doesn't reach \(label.lowercased())."
        }
        let day = days[index]
        var parts: [String] = []

        let range = [day.high.map { "high \(WeatherInterpreter.temp($0))" },
                     day.low.map { "low \(WeatherInterpreter.temp($0))" }]
            .compactMap { $0 }.joined(separator: ", ")

        switch focus {
        case .everything:
            parts.append("\(label): \(day.headline)\(range.isEmpty ? "" : " — \(range)").")
            if !day.shape.isEmpty { parts.append(day.shape) }
            parts.append(todayNotes ? rain.text : rainLine(day))
            if todayNotes, wind.isNotable { parts.append(wind.text) }
        case .temperature:
            parts.append(range.isEmpty ? "\(label) has no temperatures in the forecast yet."
                                       : "\(label): \(range).")
            if let warmest = day.parts.max(by: { ($0.high ?? -999) < ($1.high ?? -999) }), let h = warmest.high {
                parts.append("Warmest in the \(warmest.name.lowercased()), around \(WeatherInterpreter.temp(h)).")
            }
        case .rain:
            parts.append(todayNotes ? rain.text : rainLine(day))
            let wet = day.parts.filter { ($0.precipProbability ?? 0) >= 30 }
            if !wet.isEmpty {
                parts.append("Most likely " + wet.map { "\($0.name.lowercased()) (\(WeatherInterpreter.pct($0.precipProbability ?? 0)))" }
                    .joined(separator: ", ") + ".")
            }
        case .wind:
            parts.append(todayNotes ? wind.text : "\(label)'s forecast doesn't break out wind by hour.")
        case .comfort:
            if let dew = day.dewPoint {
                parts.append("\(label): dew point peaks near \(WeatherInterpreter.temp(dew))"
                             + (day.comfortTag.isEmpty ? "." : " — \(day.comfortTag.lowercased())."))
            } else {
                parts.append("No humidity in the forecast for \(label.lowercased()) yet.")
            }
            if !day.shape.isEmpty { parts.append(day.shape) }
        }
        return join(parts)
    }

    /// A future day's rain, from the daily summary — the only rain detail a day beyond today has.
    private func rainLine(_ day: DayNote) -> String {
        guard let prob = day.precipProbability, prob >= 10 else { return "No rain in the forecast." }
        return "\(WeatherInterpreter.pct(prob)) chance of rain."
    }

    // MARK: Tonight

    /// Evening and overnight — the parts of today that are still ahead, plus the low. The parts list
    /// SHRINKS as the day goes ([[Interpretation.dayParts]] drops stretches with no hours left), so an
    /// empty result is a real answer: the evening has already happened.
    private func tonightText(_ focus: ForecastQuery.Focus) -> String {
        guard let today = days.first else { return "The forecast I have doesn't reach tonight." }
        let tonight = today.parts.filter { $0.name == "Evening" || $0.name == "Overnight" }
        let tomorrowOvernight = days.indices.contains(1)
            ? days[1].parts.first(where: { $0.name == "Overnight" }) : nil
        let stretches = tonight.isEmpty ? [tomorrowOvernight].compactMap { $0 } : tonight
        guard !stretches.isEmpty else {
            return "Nothing left of tonight in the forecast — it only reaches to the end of the day."
        }

        switch focus {
        case .everything, .temperature, .comfort:
            var parts = stretches.map { "\($0.name): \($0.text)" }
            if focus != .comfort, let low = today.low {
                parts.append("Overnight low around \(WeatherInterpreter.temp(low)).")
            }
            return join(parts)
        case .rain:
            let peak = stretches.compactMap(\.precipProbability).max() ?? 0
            let accum = stretches.reduce(0) { $0 + $1.precip }
            guard peak >= 10 else { return "No rain expected tonight." }
            return "Up to \(WeatherInterpreter.pct(peak)) chance tonight"
                 + (accum > 0 ? ", around \(WeatherInterpreter.inches(accum)) if it falls." : ".")
        case .wind:
            return wind.isNotable ? wind.text : "Nothing notable in the wind tonight."
        }
    }

    // MARK: The ten days

    private func weekText(_ focus: ForecastQuery.Focus) -> String {
        guard !days.isEmpty else { return "No ten-day outlook in the forecast I have." }

        switch focus {
        case .comfort:
            return weekComfort ?? "Not enough humidity data in the outlook to call the week."
        case .rain:
            let wet = days.filter { ($0.precipProbability ?? 0) >= 30 }
            guard !wet.isEmpty else { return "No day in the next \(days.count) shows a real chance of rain." }
            return "Rain most likely " + wet.map { "\($0.weekday) (\(WeatherInterpreter.pct($0.precipProbability ?? 0)))" }
                .joined(separator: ", ") + "."
        case .temperature:
            let highs = days.compactMap(\.high)
            let lows = days.compactMap(\.low)
            guard let hottest = days.max(by: { ($0.high ?? -999) < ($1.high ?? -999) }), let peak = hottest.high else {
                return "No temperatures in the outlook yet."
            }
            var text = "Highs \(WeatherInterpreter.temp(highs.min() ?? peak))–\(WeatherInterpreter.temp(highs.max() ?? peak))"
            if let low = lows.min() { text += ", lows down to \(WeatherInterpreter.temp(low))" }
            return text + ". Hottest is \(hottest.weekday) at \(WeatherInterpreter.temp(peak))."
        case .wind:
            return wind.isNotable ? wind.text : "The outlook doesn't break out wind beyond today."
        case .everything:
            // A LINE PER DAY, because "the week" is the one question whose answer is a list: the shape
            // of the stretch is what's being asked about, and a paragraph averaging it away answers
            // nothing. Short lines — weekday, temps, what it's doing.
            let lines = days.map { day -> String in
                let range = [day.high, day.low].compactMap { $0 }.map(WeatherInterpreter.temp).joined(separator: "/")
                return "\(day.weekday) \(range) — \(day.headline)"
            }
            var text = lines.joined(separator: "\n")
            if let comfort = weekComfort { text += "\n\n\(comfort)" }
            return text
        }
    }

    // MARK: -

    private func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
