//
//  ClimateInterpretation.swift  (WeatherKit)
//
//  The archive's sentence layer — the same job `Interpretation.swift` does for
//  the forecast, done for history. `Climatology` produces numbers; this decides
//  which of them are worth saying out loud and how.
//
//  The editorial rule throughout: SAY NOTHING RATHER THAN SAY SOMETHING THIN. A
//  normal built from one year, a "record" set against two Augusts, a dry streak
//  of two days — these are all technically true and all worthless, so each phrase
//  below is gated on having enough record to mean anything. A young archive
//  should look quiet, not confidently wrong; it earns its voice as it fills.
//

import Foundation

/// Today placed against the same date in the record.
public struct ClimateComparison: Equatable, Sendable {
    public var monthDay: String
    public var normal: DailyNormal
    /// Today's high/low minus the normal.
    public var highDelta: Double?
    public var lowDelta: Double?
    /// Departure in units of the sample's own spread — how unusual, not just how far.
    public var highAnomaly: Double?
    public var ranking: Ranking?

    /// "8° warmer than usual for August 6" — nil when there isn't enough record.
    public var headline: String?
    /// "Normal for August 6: 84° / 63°, across 4 years"
    public var detail: String?
    /// Only present when today is genuinely at an end of the record.
    public var rankText: String?

    public var hasSomethingToSay: Bool { headline != nil || rankText != nil }
}

/// One line worth surfacing about the record.
public struct ClimateHighlight: Equatable, Sendable, Identifiable {
    public var id: String
    public var symbol: String
    public var text: String

    public init(id: String, symbol: String, text: String) {
        self.id = id
        self.symbol = symbol
        self.text = text
    }
}

public enum WeatherAlmanac {

    // MARK: Today vs. the record

    /// Place today's forecast high/low against this date's history.
    ///
    /// `high`/`low` come from the live forecast rather than the archive because
    /// today isn't archived yet — the archive stops at yesterday by design, since
    /// a day still in progress can't report its own extremes.
    public static func comparison(_ climate: Climatology,
                                  day: String,
                                  high: Double?,
                                  low: Double?) -> ClimateComparison {
        let monthDay = DayKey.monthDay(of: day)
        let year = DayKey.year(of: day)
        let normal = climate.normal(monthDay: monthDay)

        var result = ClimateComparison(monthDay: monthDay, normal: normal)
        guard normal.isMeaningful else { return result }

        let name = dateLabel(monthDay)
        if let high, let normalHigh = normal.high {
            result.highDelta = high - normalHigh
            result.highAnomaly = climate.anomalyScore(high, normal: normalHigh, spread: normal.highSpread)
            result.headline = departure(high - normalHigh, on: name)
            result.ranking = climate.rank(high, monthDay: monthDay, by: \.tempMax, excludingYear: year)
        }
        if let low, let normalLow = normal.low {
            result.lowDelta = low - normalLow
        }

        if let normalHigh = normal.high, let normalLow = normal.low {
            result.detail = "Normal for \(name): \(degrees(normalHigh)) / \(degrees(normalLow)), across \(normal.years) \(normal.years == 1 ? "year" : "years") of record"
        }

        // A ranking is only interesting at the ends, and only with years enough
        // behind it that "warmest ever" isn't just "warmest of the two we saw".
        if let rank = result.ranking, rank.total >= 4 {
            if rank.isHighest {
                result.rankText = "Warmest \(name) in \(rank.total) years of record"
            } else if rank.isLowest {
                result.rankText = "Coolest \(name) in \(rank.total) years of record"
            } else if rank.rank == 2 {
                result.rankText = "2nd warmest \(name) of the \(rank.total) on record"
            } else if rank.rankFromBottom == 2 {
                result.rankText = "2nd coolest \(name) of the \(rank.total) on record"
            }
        }
        return result
    }

    /// "8° warmer than usual for August 6" / "right about normal for August 6".
    static func departure(_ delta: Double, on name: String) -> String {
        let magnitude = Int(abs(delta).rounded())
        if magnitude < 2 { return "Right about normal for \(name)" }
        return "\(magnitude)° \(delta > 0 ? "warmer" : "cooler") than usual for \(name)"
    }

    // MARK: Streaks and running totals

    /// Lines about the state of the record right now — dry spells, hot runs,
    /// where the month's rainfall stands. Ordered by how much they'd change
    /// someone's day.
    public static func highlights(_ climate: Climatology,
                                  today day: String,
                                  precipToday: Double? = nil) -> [ClimateHighlight] {
        guard !climate.isEmpty else { return [] }
        var lines: [ClimateHighlight] = []

        // Dry spell. Today's live accumulation ends it even though today isn't
        // archived — the screen would look silly saying "9 days without rain"
        // while it's raining.
        if (precipToday ?? 0) < 0.01, let dry = climate.daysSincePrecip(before: day), dry.length >= 3 {
            var text = "\(dry.length) days without measurable rain"
            if let last = climate.lastPrecipDay(onOrBefore: day), let amount = last.precipTotal {
                text += " — last was \(inches(amount)) on \(dayLabel(last.day))"
            }
            if dry.endedAtGap { text += ", as far back as the record goes" }
            lines.append(ClimateHighlight(id: "dry-spell", symbol: "sun.max.trianglebadge.exclamationmark", text: text))
        }

        // Runs of heat or cold, counted through yesterday and phrased inclusive
        // of it — today's high isn't settled yet.
        if let hot = climate.streak(before: day, matches: { ($0.tempMax ?? 0) >= 90 }), hot.length >= 3 {
            lines.append(ClimateHighlight(id: "hot-run", symbol: "thermometer.sun.fill",
                                          text: "\(hot.length) days in a row at or above 90°, through yesterday"))
        }
        if let cold = climate.streak(before: day, matches: { ($0.tempMin ?? 99) <= 32 }), cold.length >= 3 {
            lines.append(ClimateHighlight(id: "freeze-run", symbol: "thermometer.snowflake",
                                          text: "\(cold.length) nights in a row at or below freezing, through yesterday"))
        }

        if let rainfall = monthToDate(climate, day: day) {
            lines.append(rainfall)
        }
        return lines
    }

    /// This month's rain so far against the same stretch of past years.
    ///
    /// Compared to-date rather than to a whole-month normal: on the 6th, "0.4 of
    /// the monthly 4 inches" reads as a drought when it's just early.
    static func monthToDate(_ climate: Climatology, day: String) -> ClimateHighlight? {
        guard let year = DayKey.year(of: day) else { return nil }
        let monthDay = DayKey.monthDay(of: day)
        let month = String(monthDay.prefix(2))
        let firstOfMonth = "\(month)-01"

        let thisYear = climate.precipTotal(from: "\(year)-\(firstOfMonth)", through: day)
        guard thisYear.days >= 3 else { return nil }

        let priorYears = Set(climate.reliable.compactMap { DayKey.year(of: $0.day) })
            .filter { $0 < year }
            .map { climate.precipTotal(from: "\($0)-\(firstOfMonth)", through: "\($0)-\(monthDay)") }
            .filter { $0.days >= thisYear.days - 2 }   // only years that actually cover the stretch

        guard priorYears.count >= 2, let typical = priorYears.map(\.total).mean else { return nil }
        let name = monthName(month)

        // Under a tenth of an inch either way isn't a signal, it's noise.
        guard abs(thisYear.total - typical) >= 0.1 else {
            return ClimateHighlight(id: "month-precip", symbol: "drop",
                                    text: "\(inches(thisYear.total)) of rain this \(name) — about typical for the date")
        }
        let wetter = thisYear.total > typical
        return ClimateHighlight(
            id: "month-precip",
            symbol: wetter ? "drop.fill" : "drop",
            text: "\(inches(thisYear.total)) of rain this \(name) — \(inches(abs(thisYear.total - typical))) \(wetter ? "above" : "below") the \(inches(typical)) usual by this date")
    }

    // MARK: How summer actually lets go

    /// Why early autumn feels better, told through CROSSINGS rather than drops.
    ///
    /// The obvious framing — which curve fell further — turns out to be the wrong
    /// one. At this station both give up about the same seven degrees between
    /// peak August and late September, so by magnitude it's a tie. What separates
    /// them is which lands on the far side of a threshold that means something: a
    /// night at 67° sheds a building's heat and starts the next day cool, while an
    /// afternoon at 91° is just as unusable as one at 97°.
    ///
    /// So the comparison is between the DATES those thresholds are crossed, which
    /// is also the thing you can feel: weeks of days that still read as summer on
    /// a thermometer but no longer behave like it by morning.
    public static func summerReliefNote(_ climate: Climatology,
                                        nightThreshold: Double = 70,
                                        afternoonThreshold: Double = 90) -> String? {
        let nights = climate.nightsCool(below: nightThreshold)
        let afternoons = climate.heatBreak(threshold: afternoonThreshold)
        guard nights.isMeaningful, afternoons.isMeaningful,
              let nightDay = nights.typical, let afternoonDay = afternoons.typical,
              let gap = DayKey.distance(from: "2001-\(nightDay)", to: "2001-\(afternoonDay)")
        else { return nil }

        let nightLabel = dateLabel(nightDay)
        let afternoonLabel = dateLabel(afternoonDay)

        if gap >= 10 {
            var note = "Nights let go first: they settle below \(Int(nightThreshold))° around \(nightLabel), but afternoons hold above \(Int(afternoonThreshold))° until about \(afternoonLabel) — \(gap) days that still read as summer at 3pm and don’t by morning."
            if let peakLow = climate.median(\.tempMin, from: "08-01", through: "08-20"),
               let laterLow = climate.median(\.tempMin, from: "09-05", through: "09-25") {
                note += " Typical overnight low goes \(Int(peakLow.rounded()))° in mid-August to \(Int(laterLow.rounded()))° in late September."
            }
            return note
        }
        if gap <= -10 {
            return "Afternoons let go first: they ease below \(Int(afternoonThreshold))° around \(afternoonLabel), while nights stay above \(Int(nightThreshold))° until about \(nightLabel) — \(abs(gap)) days that cool off by day but never overnight."
        }
        return "Afternoons and nights let go together here — below \(Int(afternoonThreshold))° by day around \(afternoonLabel), below \(Int(nightThreshold))° at night around \(nightLabel)."
    }

    // MARK: Formatting

    public static func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }

    public static func inches(_ value: Double) -> String { String(format: "%.2f\"", value) }

    /// "Aug 6" — a `yyyy-MM-dd` key as a date someone can read. Parsed and
    /// rendered in the same fixed zone so the label can't drift a day.
    public static func dayLabel(_ key: String, includeYear: Bool = false) -> String {
        let zone = TimeZone(identifier: "UTC") ?? .current
        guard let date = DayKey.date(from: key, timeZone: zone) else { return key }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = includeYear ? "MMM d, yyyy" : "MMM d"
        return formatter.string(from: date)
    }

    /// "August 6" from an `MM-dd` key — the form that reads well mid-sentence.
    public static func dateLabel(_ monthDay: String) -> String {
        let parts = monthDay.split(separator: "-")
        guard parts.count == 2, let day = Int(parts[1]) else { return monthDay }
        return "\(monthName(String(parts[0]), long: true)) \(day)"
    }

    public static func monthName(_ month: String, long: Bool = true) -> String {
        let names = ["01": "January", "02": "February", "03": "March", "04": "April",
                     "05": "May", "06": "June", "07": "July", "08": "August",
                     "09": "September", "10": "October", "11": "November", "12": "December"]
        let name = names[month] ?? month
        return long ? name : String(name.prefix(3))
    }
}
