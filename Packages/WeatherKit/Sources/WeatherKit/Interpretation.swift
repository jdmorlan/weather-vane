//
//  Interpretation.swift  (WeatherKit)
//
//  The point of the whole module: turn a Tempest forecast into ANSWERS, not a
//  wall of numbers. "Is it muggy?" "Will it rain, when, how much?" "Is the
//  pressure dropping — storm coming?" Every phrase here is a pure function of the
//  data so it's deterministic and unit-testable (see WeatherKitTests).
//
//  Everything assumes US-common units (°F, mph, inHg, inches) because TempestClient
//  requests them from the API.
//

import Foundation

// MARK: - Report shape

/// The interpreted, view-ready weather. Values carry both the raw number (for the
/// view to render however it likes) and a `text` sentence (the actual insight).
public struct WeatherReport: Equatable, Sendable {
    public var asOf: Date
    public var timezone: TimeZone?       // station-local, for sunrise/sunset/day labels
    public var conditions: String
    public var icon: String
    public var temperature: Double?      // °F, right now
    public var feelsLike: Double?        // °F

    /// One-line "here's your day" — the single most important thing.
    public var headline: String

    public var comfort: ComfortNote
    public var rain: RainNote
    public var wind: WindNote
    public var pressure: PressureNote
    public var alerts: [String]          // lightning, severe, etc.

    /// Plain-language read on humidity across the coming days ("A muggy stretch — dew
    /// points near 70° most days"). nil when we can't estimate it. Derived from the
    /// hourly temp+humidity, since the daily forecast carries no dew point.
    public var weekComfort: String?

    // Current-conditions numbers for the stat tiles.
    public var windAvg: Double?
    public var windGust: Double?
    public var windDirectionCardinal: String?
    /// True degrees the wind is coming FROM. The cardinal is a 16-point rounding of
    /// this; anything that POINTS (a dial, a rotated map) needs the number.
    public var windDirection: Double?
    public var precipToday: Double?      // accumulation so far today, inches

    public var hours: [HourSlice]        // next ~24h strip
    public var days: [DayNote]           // 10-day, interpretation-first
}

public struct ComfortNote: Equatable, Sendable {
    public var dewPoint: Double?
    public var humidity: Double?
    public var label: String             // "muggy", "crisp & dry", …
    public var text: String
}

public struct RainNote: Equatable, Sendable {
    public var willRain: Bool
    public var totalAccum: Double         // inches expected across today's windows
    public var peakProbability: Double    // %
    public var text: String
    public var windows: [RainWindow]
}

public struct RainWindow: Equatable, Sendable {
    public var startHour: Int             // local clock hour 0–23
    public var endHour: Int
    public var peakProbability: Double
    public var accum: Double              // inches
    public var text: String
}

public struct WindNote: Equatable, Sendable {
    public var peakGust: Double           // mph
    public var peakGustHour: Int?
    public var label: String              // "calm", "breezy", "windy"
    public var text: String
    /// Worth calling out? (breezy or gusty — not a dead-calm day).
    public var isNotable: Bool
}

public struct PressureNote: Equatable, Sendable {
    public var trend: String              // "falling" | "steady" | "rising"
    public var current: Double?           // inHg
    public var delta3h: Double?           // inHg, forecast change over next 3h
    public var stormWatch: Bool
    public var text: String
    /// Whether the pressure is actually doing something (rising/falling). When steady,
    /// there's nothing to report — the UI stays quiet rather than saying "steady".
    public var isNotable: Bool
}

/// One hour of the near-term strip.
public struct HourSlice: Equatable, Sendable, Identifiable {
    public var epoch: Int
    public var clock: String              // "2pm"
    public var temperature: Double?
    public var precipProbability: Double?
    public var precip: Double?
    public var windAvg: Double?
    public var windGust: Double?
    public var windDirectionCardinal: String?
    /// True degrees the wind is coming FROM, for anything that points.
    public var windDirection: Double?
    /// Sea-level pressure for this hour, inHg — so the coming SHAPE of the barometer
    /// can be drawn, which is the half of pressure that actually predicts anything.
    public var pressure: Double?
    /// Estimated dew point for this hour, °F (Magnus from temp+humidity). Lets the
    /// hourly strip show when the mugginess eases off in the evening.
    public var dewPoint: Double?
    public var icon: String
    public var conditions: String
    public var isNight: Bool
    /// Whether this hour was MEASURED or is still a guess.
    ///
    /// The strip used to hold only the latter, so the distinction couldn't come
    /// up. Once an hour behind us is drawn from the station's own samples, the
    /// two must not read the same: a temperature at eight this morning is a
    /// fact, and one at eight tonight is a forecast that will move. See
    /// `DayStrip`.
    public var isObserved: Bool = false
    public var id: Int { epoch }
}

/// One named stretch of a day — the unit that keeps a day from collapsing into a
/// single verdict. A day is rarely "oppressive"; its *morning* is, and then the dew
/// point drops while the temperature climbs. That distinction lives here.
public struct DayPart: Equatable, Sendable, Identifiable {
    public var name: String               // "Morning"
    public var startHour: Int             // local clock hour, inclusive
    public var endHour: Int               // local clock hour, exclusive
    public var high: Double?              // °F, warmest hour in the stretch
    public var low: Double?
    public var feelsLike: Double?         // °F, peak feels-like
    /// Muggiest dew point in the stretch, °F (Magnus from temp+humidity).
    public var dewPoint: Double?
    public var comfortTag: String         // "Muggy", "Sticky", … empty if unknown
    public var precipProbability: Double? // peak % across the stretch
    public var precip: Double             // inches expected in the stretch
    public var icon: String
    public var text: String               // "Hot 92° but drier — dew point 64°"
    public var id: String { "\(startHour)-\(name)" }
}

/// One day of the 10-day outlook, led by what matters.
public struct DayNote: Equatable, Sendable, Identifiable {
    public var epoch: Int
    public var weekday: String            // "Sat"
    public var high: Double?
    public var low: Double?
    public var conditions: String
    public var icon: String
    public var precipProbability: Double?
    public var sunrise: Int?
    public var sunset: Int?
    /// Estimated peak (muggiest) daytime dew point, °F — computed from the hourly
    /// temp+humidity via Magnus, not reported by the daily forecast. nil if no hours.
    public var dewPoint: Double?
    /// Short comfort tag for that dew point ("Muggy", "Oppressive", …). Empty if unknown.
    public var comfortTag: String
    /// Muggiest and least-muggy hour of the whole day. The spread is the story: a 72°
    /// peak that falls to 61° by evening is a very different day from a flat 72°.
    public var dewPointHigh: Double?
    public var dewPointLow: Double?
    /// The day broken into overnight/morning/afternoon/evening. Empty when the hourly
    /// forecast doesn't reach this far out.
    public var parts: [DayPart]
    /// How the day changes shape — "Muggy morning, easier by evening". Empty when the
    /// day holds steady or we have no parts.
    public var shape: String
    public var headline: String           // "Rain likely — bring a jacket"
    public var id: Int { epoch }
}

// MARK: - Interpreter

public enum WeatherInterpreter {

    public static func report(from forecast: BetterForecast,
                              now: Date = Date(),
                              calendar: Calendar = .current) -> WeatherReport {
        let cc = forecast.currentConditions ?? CurrentConditions()
        let hourly = forecast.forecast?.hourly ?? []
        let daily = forecast.forecast?.daily ?? []

        let nowEpoch = Int(now.timeIntervalSince1970)
        // Keep the current hour plus everything ahead.
        let future = hourly
            .filter { ($0.time ?? 0) >= nowEpoch - 3600 }
            .sorted { ($0.time ?? 0) < ($1.time ?? 0) }
        let todayNum = future.first?.localDay ?? daily.first?.dayNum
        let todayHours = future.filter { $0.localDay == todayNum }

        let tz = forecast.timezone.flatMap { TimeZone(identifier: $0) } ?? calendar.timeZone
        var tzCalendar = calendar
        tzCalendar.timeZone = tz

        let comfort = comfortNote(cc)
        let rain = rainNote(todayHours)
        let wind = windNote(todayHours, current: cc)
        let pressure = pressureNote(cc, future: future)
        let alerts = alertNotes(cc, rain: rain)

        // Day/night for the hourly strip, from today's sun times (fallback 6am–8pm).
        let sunriseHour = daily.first?.sunrise.map { hour(ofEpoch: $0, calendar: tzCalendar) } ?? 6
        let sunsetHour = daily.first?.sunset.map { hour(ofEpoch: $0, calendar: tzCalendar) } ?? 20

        let hours = Array(future.prefix(24)).map {
            hourSlice($0, sunriseHour: sunriseHour, sunsetHour: sunsetHour)
        }

        // Group the hourly series by local day so each day can be described by its
        // PARTS rather than one number. Hours already behind us are dropped, so "today"
        // describes what's LEFT of today. (An hour with no timestamp is kept — only real
        // payloads carry one, and dropping them would blank the whole outlook.)
        var hoursByDay: [Int: [HourlyForecast]] = [:]
        for h in hourly where (h.time ?? Int.max) >= nowEpoch - 3600 {
            guard let day = h.localDay else { continue }
            hoursByDay[day, default: []].append(h)
        }
        let days = daily.prefix(10).map {
            dayNote($0, hours: $0.dayNum.flatMap { hoursByDay[$0] } ?? [], calendar: tzCalendar)
        }
        let weekComfort = weekComfortSummary(Array(days))

        let headline = makeHeadline(cc: cc, comfort: comfort, rain: rain,
                                    wind: wind, pressure: pressure, alerts: alerts,
                                    today: days.first)

        return WeatherReport(
            asOf: cc.time.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? now,
            timezone: tz,
            conditions: cc.conditions ?? "—",
            icon: cc.icon ?? "cloudy",
            temperature: cc.airTemperature,
            feelsLike: cc.feelsLike,
            headline: headline,
            comfort: comfort,
            rain: rain,
            wind: wind,
            pressure: pressure,
            alerts: alerts,
            weekComfort: weekComfort,
            windAvg: cc.windAvg,
            windGust: cc.windGust,
            windDirectionCardinal: cc.windDirectionCardinal,
            windDirection: cc.windDirection,
            precipToday: cc.precipAccumLocalDay,
            hours: hours,
            days: Array(days)
        )
    }

    // MARK: Comfort (dew point + feels-like)

    /// Dew point is the honest "how muggy" number; humidity alone lies when it's cold.
    static func dewPointLabel(_ dew: Double) -> String {
        switch dew {
        case ..<50:  return "dry and comfortable"
        case ..<55:  return "very comfortable"
        case ..<60:  return "comfortable"
        case ..<65:  return "a little sticky"
        case ..<70:  return "humid and muggy"
        case ..<75:  return "oppressively humid"
        default:     return "tropical — heavy, sweaty air"
        }
    }

    /// Dew point (°F) from air temperature (°F) and relative humidity (%), via the
    /// Magnus-Tetens approximation. This is how we get a FUTURE dew point: the forecast
    /// reports temp + humidity per hour but no dew point, and the two fully determine it.
    public static func dewPointF(tempF: Double, humidity: Double) -> Double {
        let t = (tempF - 32) * 5 / 9                 // °F → °C
        let rh = min(100, max(1, humidity))
        let b = 17.625, c = 243.04
        let gamma = log(rh / 100) + (b * t) / (c + t)
        let td = (c * gamma) / (b - gamma)            // °C
        return td * 9 / 5 + 32                         // °C → °F
    }

    /// Compact comfort tag for a dew point (the week-view chip).
    public static func dewComfortTag(_ dew: Double) -> String {
        switch dew {
        case ..<55: return "Dry"
        case ..<60: return "Comfortable"
        case ..<65: return "Sticky"
        case ..<70: return "Muggy"
        default:    return "Oppressive"
        }
    }

    static func comfortNote(_ cc: CurrentConditions) -> ComfortNote {
        guard let dew = cc.dewPoint else {
            return ComfortNote(dewPoint: nil, humidity: cc.relativeHumidity,
                               label: "—", text: "Comfort data unavailable.")
        }
        let label = dewPointLabel(dew)
        var text = "Dew point \(temp(dew)) — \(label)."

        if let air = cc.airTemperature, let feels = cc.feelsLike {
            let delta = feels - air
            if delta >= 4 {
                text += " Feels warmer than it reads (~\(temp(feels))) with the humidity and sun."
            } else if delta <= -4 {
                text += " Feels colder than it reads (~\(temp(feels))) in the wind."
            }
        }
        return ComfortNote(dewPoint: dew, humidity: cc.relativeHumidity, label: label, text: text)
    }

    // MARK: Rain (timing + amount, the 80%/0.02″ problem)

    static func rainAmountCharacter(_ accum: Double) -> String {
        switch accum {
        case ..<0.005: return "barely measurable — a stray drop or two"
        case ..<0.05:  return "just a sprinkle, enough to dot the windshield"
        case ..<0.10:  return "a light shower"
        case ..<0.25:  return "a decent shower"
        case ..<0.50:  return "moderate, steady rain"
        case ..<1.0:   return "a soaking rain"
        default:       return "heavy rain"
        }
    }

    static func rainNote(_ hours: [HourlyForecast]) -> RainNote {
        let windows = detectRainWindows(hours)
        let total = windows.reduce(0) { $0 + $1.accum }
        let peak = windows.map(\.peakProbability).max() ?? 0

        guard !windows.isEmpty else {
            return RainNote(willRain: false, totalAccum: 0, peakProbability: peak,
                            text: "No rain expected the rest of today.", windows: [])
        }

        // The insight the user specifically asked for: separate "how likely" from
        // "how much", because they are not the same thing.
        let text: String
        if windows.count == 1 {
            text = windows[0].text
        } else {
            let amount = rainAmountCharacter(total)
            text = "A few rounds of rain today (\(pct(peak)) at peak), \(inches(total)) total — \(amount)."
        }
        return RainNote(willRain: true, totalAccum: total, peakProbability: peak,
                        text: text, windows: windows)
    }

    /// Maximal runs of hours that read as "wet" (≥25% chance or actual accumulation).
    static func detectRainWindows(_ hours: [HourlyForecast]) -> [RainWindow] {
        var windows: [RainWindow] = []
        var run: [HourlyForecast] = []

        func isWet(_ h: HourlyForecast) -> Bool {
            (h.precipProbability ?? 0) >= 25 || (h.precip ?? 0) > 0
        }
        func flush() {
            defer { run = [] }
            guard let first = run.first, let last = run.last else { return }
            let peak = run.map { $0.precipProbability ?? 0 }.max() ?? 0
            let accum = run.reduce(0) { $0 + ($1.precip ?? 0) }
            let start = first.localHour ?? 0
            let end = (last.localHour ?? start) + 1   // window is inclusive of the last hour
            windows.append(RainWindow(startHour: start, endHour: end,
                                      peakProbability: peak, accum: accum,
                                      text: windowSentence(start: start, end: end, peak: peak, accum: accum)))
        }

        for h in hours {
            if isWet(h) { run.append(h) }
            else if !run.isEmpty { flush() }
        }
        if !run.isEmpty { flush() }
        return windows
    }

    static func windowSentence(start: Int, end: Int, peak: Double, accum: Double) -> String {
        let when = "\(clock(start))–\(clock(end))"
        let amount = rainAmountCharacter(accum)
        // High chance, tiny amount → say so plainly. Low chance, real amount → also worth flagging.
        if peak >= 60 && accum < 0.05 {
            return "Rain likely \(when) (\(pct(peak)) chance) — but only about \(inches(accum)), \(amount)."
        }
        if peak < 50 && accum >= 0.1 {
            return "A chance of rain \(when) (\(pct(peak))); if it comes it'll be \(amount) (~\(inches(accum)))."
        }
        return "Rain \(when): \(pct(peak)) chance, about \(inches(accum)) — \(amount)."
    }

    // MARK: Wind

    static func windLabel(_ avg: Double) -> String {
        switch avg {
        case ..<4:   return "calm"
        case ..<8:   return "light"
        case ..<13:  return "a light breeze"
        case ..<19:  return "breezy"
        case ..<25:  return "windy"
        default:     return "very windy"
        }
    }

    static func windNote(_ hours: [HourlyForecast], current: CurrentConditions) -> WindNote {
        let gusts = hours.compactMap { h -> (Double, Int)? in
            guard let g = h.windGust else { return nil }
            return (g, h.localHour ?? 0)
        }
        let peak = gusts.map(\.0).max() ?? (current.windGust ?? 0)
        let peakHour = gusts.max(by: { $0.0 < $1.0 })?.1
        let typicalAvg = hours.compactMap(\.windAvg).max() ?? (current.windAvg ?? 0)
        let label = windLabel(typicalAvg)

        let text: String
        if typicalAvg < 8 && peak < 18 {
            text = "Winds stay light today, under \(mph(max(typicalAvg, peak)))."
        } else if peak >= 18, let ph = peakHour {
            text = "\(label.capitalizedFirst) today — sustained around \(mph(typicalAvg)), gusting to \(mph(peak)) near \(clock(ph))."
        } else {
            text = "\(label.capitalizedFirst) today, sustained around \(mph(typicalAvg))."
        }
        return WindNote(peakGust: peak, peakGustHour: peakHour, label: label, text: text,
                        isNotable: typicalAvg >= 13 || peak >= 18)
    }

    // MARK: Pressure (the storm clue)

    static func pressureNote(_ cc: CurrentConditions, future: [HourlyForecast]) -> PressureNote {
        let trend = (cc.pressureTrend ?? "steady").lowercased()
        let current = cc.seaLevelPressure
        // Forecast change over the next ~3 hours, if we can see it.
        var delta3h: Double?
        if let current, future.count > 3, let later = future[3].seaLevelPressure {
            delta3h = later - current
        }

        var deltaPhrase = ""
        if let d = delta3h, abs(d) >= 0.02 {
            deltaPhrase = " (about \(String(format: "%.2f", abs(d))) inHg over the next 3h)"
        }

        let stormWatch = trend == "falling" && (delta3h ?? 0) <= -0.04
        var text: String
        switch trend {
        case "falling":
            text = "Barometric pressure is falling\(deltaPhrase) — often the approach of clouds, wind, or rain in the coming hours."
            if stormWatch { text += " Dropping fast enough to watch for a storm." }
        case "rising":
            text = "Pressure is rising\(deltaPhrase) — skies tend to clear and settle as it climbs."
        default:
            text = "Pressure is steady — no big change in the pattern expected."
        }
        return PressureNote(trend: trend, current: current, delta3h: delta3h,
                            stormWatch: stormWatch, text: text,
                            isNotable: trend == "falling" || trend == "rising")
    }

    // MARK: Alerts

    static func alertNotes(_ cc: CurrentConditions, rain: RainNote) -> [String] {
        var out: [String] = []
        if let strikes = cc.lightningStrikeCountLast1hr, strikes > 0 {
            if let dist = cc.lightningStrikeLastDistance {
                out.append("⚡️ Lightning nearby — last strike ~\(Int(dist.rounded())) mi away, \(strikes) in the past hour.")
            } else {
                out.append("⚡️ \(strikes) lightning strike\(strikes == 1 ? "" : "s") detected in the past hour.")
            }
        }
        if rain.totalAccum >= 1.0 {
            out.append("🌧️ Heavy rain expected today — over an inch total.")
        }
        return out
    }

    // MARK: Headline (the one thing)

    static func makeHeadline(cc: CurrentConditions, comfort: ComfortNote, rain: RainNote,
                             wind: WindNote, pressure: PressureNote, alerts: [String],
                             today: DayNote? = nil) -> String {
        if let first = alerts.first { return first }
        if rain.totalAccum >= 0.25 {
            let when = rain.windows.first.map { " around \(clock($0.startHour))" } ?? ""
            return "Grab a jacket — real rain moving in\(when)."
        }
        if pressure.stormWatch {
            return "Pressure is dropping fast — unsettled weather on the way."
        }
        if wind.peakGust >= 25 {
            return "Windy day — gusts to \(mph(wind.peakGust)). Secure anything loose."
        }
        if rain.willRain {
            return rain.windows.first?.text ?? "A chance of rain today."
        }
        if comfort.dewPoint ?? 0 >= 68 {
            // If the rest of the day breaks the mugginess, that's the more useful headline
            // than repeating what you can already feel standing outside.
            if let shape = today?.shape, !shape.isEmpty { return shape }
            return "Warm and muggy today\(cc.airTemperature.map { " (\(temp($0)))" } ?? "")."
        }
        if let temp = cc.airTemperature, temp <= 34 {
            return "Cold out — \(self.temp(temp)) and \((cc.conditions ?? "clear").lowercased())."
        }
        return "\(cc.conditions ?? "Fair") and pleasant\(cc.airTemperature.map { " — \(temp($0))" } ?? "")."
    }

    // MARK: Per-hour / per-day mapping

    static func hourSlice(_ h: HourlyForecast, sunriseHour: Int, sunsetHour: Int) -> HourSlice {
        let localHour = h.localHour ?? 12
        let dew = h.airTemperature.flatMap { t in h.relativeHumidity.map { dewPointF(tempF: t, humidity: $0) } }
        return HourSlice(epoch: h.time ?? 0,
                  clock: clock(localHour),
                  temperature: h.airTemperature,
                  precipProbability: h.precipProbability,
                  precip: h.precip,
                  windAvg: h.windAvg,
                  windGust: h.windGust,
                  windDirectionCardinal: h.windDirectionCardinal,
                  windDirection: h.windDirection,
                  pressure: h.seaLevelPressure,
                  dewPoint: dew,
                  icon: h.icon ?? "cloudy",
                  conditions: h.conditions ?? "—",
                  isNight: localHour < sunriseHour || localHour >= sunsetHour)
    }

    static func hour(ofEpoch epoch: Int, calendar: Calendar) -> Int {
        calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    static func dayNote(_ d: DailyForecast, hours: [HourlyForecast], calendar: Calendar) -> DayNote {
        let epoch = d.dayStartLocal ?? 0
        let weekday = weekdayLabel(epoch: epoch, calendar: calendar)
        let prob = d.precipProbability ?? 0
        var headline = d.conditions ?? "—"
        if prob >= 50 {
            headline = "\(d.conditions ?? "Rain likely") — \(pct(prob)) chance of \(d.precipType ?? "rain")"
        } else if prob >= 25 {
            headline = "\(d.conditions ?? "Partly cloudy"), a \(pct(prob)) chance of \(d.precipType ?? "rain")"
        }

        let parts = dayParts(hours)
        // The headline dew point stays the muggiest DAYTIME hour (8am–9pm) — when it's
        // actually felt — while high/low carry the day's full spread.
        let daytimeDews = hours.compactMap { h -> Double? in
            guard (8...21).contains(h.localHour ?? 12) else { return nil }
            return hourDewPoint(h)
        }
        let allDews = hours.compactMap(hourDewPoint)

        return DayNote(epoch: epoch, weekday: weekday,
                       high: d.airTempHigh, low: d.airTempLow,
                       conditions: d.conditions ?? "—", icon: d.icon ?? "cloudy",
                       precipProbability: d.precipProbability,
                       sunrise: d.sunrise, sunset: d.sunset,
                       dewPoint: daytimeDews.max(),
                       comfortTag: daytimeDews.max().map { dewComfortTag($0) } ?? "",
                       dewPointHigh: allDews.max(), dewPointLow: allDews.min(),
                       parts: parts, shape: dayShape(parts),
                       headline: headline)
    }

    // MARK: Day parts (the fidelity the daily verdict throws away)

    /// The stretches a day gets described in. Boundaries are the ones people plan
    /// around, not meteorological ones.
    public static let dayPartWindows: [(name: String, start: Int, end: Int)] = [
        ("Overnight", 0, 6), ("Morning", 6, 12), ("Afternoon", 12, 18), ("Evening", 18, 24)
    ]

    static func hourDewPoint(_ h: HourlyForecast) -> Double? {
        guard let t = h.airTemperature, let rh = h.relativeHumidity else { return nil }
        return dewPointF(tempF: t, humidity: rh)
    }

    /// Split a day's hours into its parts. Stretches with no hours are dropped, so
    /// "today" naturally shrinks to what's left of it.
    static func dayParts(_ hours: [HourlyForecast]) -> [DayPart] {
        dayPartWindows.compactMap { window in
            let slice = hours.filter { (window.start..<window.end).contains($0.localHour ?? -1) }
            guard !slice.isEmpty else { return nil }

            let temps = slice.compactMap(\.airTemperature)
            let dews = slice.compactMap(hourDewPoint)
            let peakDew = dews.max()
            let prob = slice.compactMap(\.precipProbability).max()
            let accum = slice.reduce(0) { $0 + ($1.precip ?? 0) }
            // The icon of the wettest hour if it's wet at all, else the middle hour's —
            // a part reads by its most notable weather, not its first.
            let wettest = slice.max { ($0.precipProbability ?? 0) < ($1.precipProbability ?? 0) }
            let icon = ((prob ?? 0) >= 30 ? wettest?.icon : slice[slice.count / 2].icon) ?? "cloudy"

            return DayPart(name: window.name, startHour: window.start, endHour: window.end,
                           high: temps.max(), low: temps.min(),
                           feelsLike: slice.compactMap(\.feelsLike).max(),
                           dewPoint: peakDew,
                           comfortTag: peakDew.map { dewComfortTag($0) } ?? "",
                           precipProbability: prob, precip: accum, icon: icon,
                           text: partSentence(name: window.name, high: temps.max(),
                                              dew: peakDew, prob: prob, accum: accum))
        }
    }

    static func partSentence(name: String, high: Double?, dew: Double?, prob: Double?, accum: Double) -> String {
        var out = name
        if let high { out += ", \(temp(high))" }
        if let dew { out += " · dew \(temp(dew)) — \(dewPointLabel(dew))" }
        if let prob, prob >= 25 {
            out += ". \(pct(prob)) chance of rain"
            if accum >= 0.05 { out += " (~\(inches(accum)))" }
            out += "."
        }
        return out
    }

    /// The sentence the old one-tag-per-day model couldn't say: which PART is the bad
    /// part, and what it turns into. Empty when the day genuinely holds steady.
    static func dayShape(_ parts: [DayPart]) -> String {
        let withDew = parts.filter { $0.dewPoint != nil }
        guard withDew.count >= 2 else { return "" }
        guard let worst = withDew.max(by: { $0.dewPoint! < $1.dewPoint! }),
              let best = withDew.min(by: { $0.dewPoint! < $1.dewPoint! }) else { return "" }
        let spread = worst.dewPoint! - best.dewPoint!
        // Under ~4° the air feels the same all day; saying it changes would be a lie.
        guard spread >= 4, dewComfortTag(worst.dewPoint!) != dewComfortTag(best.dewPoint!) else { return "" }

        let easing = worst.startHour < best.startHour       // muggy first, then relief
        let hot = parts.compactMap(\.high).max()
        let hottest = parts.max { ($0.high ?? -1000) < ($1.high ?? -1000) }

        var out = "\(dewComfortTag(worst.dewPoint!)) \(worst.name.lowercased()) (dew \(temp(worst.dewPoint!)))"
        out += easing ? ", easing to " : ", building from "
        out += "\(dewComfortTag(best.dewPoint!).lowercased()) by \(best.name.lowercased()) (\(temp(best.dewPoint!)))"
        // The other half of the user's question: the afternoon can be the HOT part even
        // as it's the dry part, and that deserves saying in the same breath.
        if let hot, let hottest, hot >= 85, hottest.name != worst.name {
            out += " — but \(hottest.name.lowercased()) is the hot one at \(temp(hot))"
        }
        return out + "."
    }

    /// "Are all the days going to be oppressive?" — a read on humidity across the week,
    /// written in terms of when in the day the mugginess actually lands.
    static func weekComfortSummary(_ days: [DayNote]) -> String? {
        let dews = days.compactMap(\.dewPoint)
        guard dews.count >= 3 else { return nil }
        let oppressive = dews.filter { $0 >= 70 }.count       // sweaty, tropical
        let muggy = dews.filter { $0 >= 65 }.count             // noticeably humid+
        let peak = dews.max() ?? 0
        let comfortable = dews.filter { $0 < 60 }.count

        // How much each day swings, so a humid week that breaks every evening doesn't
        // get reported the same as one that stays heavy around the clock.
        let swings = days.compactMap { d -> Double? in
            guard let hi = d.dewPointHigh, let lo = d.dewPointLow else { return nil }
            return hi - lo
        }
        let typicalSwing = median(swings) ?? 0
        let typicalLow = median(days.compactMap(\.dewPointLow)) ?? peak
        let breaks = typicalSwing >= 5 && typicalLow < 68

        if oppressive >= dews.count - 1 {
            if breaks {
                return "Humid every day — but it lets go: dew points peak near \(temp(peak)) and fall to around \(temp(typicalLow)) later on. Watch the day strip for which half is the heavy one."
            }
            return "An oppressive stretch — dew points near \(temp(peak)) day and night; it never really breaks."
        }
        if muggy >= (dews.count + 1) / 2 {
            let tail = breaks ? ", though most days ease off to about \(temp(typicalLow))" : ""
            return "A muggy week — humid on \(muggy) of the next \(dews.count) days (peaking near \(temp(peak)))\(tail)."
        }
        if comfortable == dews.count {
            return "Comfortable humidity all week — dew points stay pleasant."
        }
        if muggy > 0 {
            return "Mostly comfortable, but muggy on \(muggy) of the next \(dews.count) days."
        }
        return "Comfortable humidity through the week."
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: Formatting helpers

    static func temp(_ v: Double) -> String { "\(Int(v.rounded()))°" }
    static func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
    static func mph(_ v: Double) -> String { "\(Int(v.rounded())) mph" }
    static func inches(_ v: Double) -> String { String(format: "%.2f", v) + "\u{2033}" } // ″

    /// 24h clock hour → friendly 12h label.
    static func clock(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        switch h {
        case 0:  return "12am"
        case 12: return "noon"
        case ..<12: return "\(h)am"
        default: return "\(h - 12)pm"
        }
    }

    static func weekdayLabel(epoch: Int, calendar: Calendar) -> String {
        guard epoch != 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US")
        if let tz = calendar.timeZone as TimeZone? { formatter.timeZone = tz }
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
