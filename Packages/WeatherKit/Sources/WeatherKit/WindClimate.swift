//
//  WindClimate.swift  (WeatherKit)
//
//  THE WIND AT THIS STATION ACROSS A YEAR, which is a different question from
//  the wind over the whole record and cannot be got by slicing one rose.
//
//  A rose over four years answers "where does the wind come from here". It
//  averages away the thing anyone actually notices: that the wind here turns with
//  the season, and that the month it blows hardest is not the month it gusts
//  hardest. Those are the two questions Jay asked out loud — does it change
//  through the year, when is it strongest — and a single rose refuses both.
//
//  ONE PASS, TWELVE BUILDERS. The archive is ~1,400 gzipped files and some two
//  million samples; reading it twelve times to slice it twelve ways would cost
//  twelve times the disk for a result that already knows which bucket each day
//  belongs in. So every day is read once and folded into the overall builder and
//  its month's builder together, which is the only reason a whole-record wind
//  climatology is affordable at all.
//
//  A MONTH IS A CALENDAR MONTH, not a rolling 30 days, because the answer is for
//  a person planning a season — "don't hang laundry in March" — and a person
//  thinks in named months. `DailyArchive`'s normals already made that choice; this
//  matches it so the two can be read side by side.
//

import Foundation

/// The wind at one station, over the record and around the year.
public struct WindClimate: Codable, Sendable {
    /// Every moving minute in the record, in one rose.
    public var overall: WindRose
    /// Keyed 1…12. A month with no archived days is simply absent — better than a
    /// rose of zeros that a chart would draw as a genuine calm.
    public var byMonth: [Int: WindRose]
    /// Days actually read, and the span they came from.
    public var days: Int
    public var firstDay: String?
    public var lastDay: String?

    /// The month with the highest mean speed — "when is it strongest" for sustained
    /// wind, which is the one that governs how a season FEELS.
    public var windiestMonth: (month: Int, rose: WindRose)? {
        byMonth.filter { $0.value.movingMinutes > 0 }
            .max { $0.value.meanSpeed < $1.value.meanSpeed }
            .map { ($0.key, $0.value) }
    }

    public var calmestMonth: (month: Int, rose: WindRose)? {
        byMonth.filter { $0.value.movingMinutes > 0 }
            .min { $0.value.meanSpeed < $1.value.meanSpeed }
            .map { ($0.key, $0.value) }
    }

    /// The month holding the biggest gust on record. Deliberately separate from
    /// `windiestMonth`: a peak gust is a single convective minute and a mean speed
    /// is a season, and at most stations they land in different halves of the year.
    public var gustiestMonth: (month: Int, rose: WindRose)? {
        byMonth.filter { $0.value.peakGust != nil }
            .max { ($0.value.peakGust?.speed ?? 0) < ($1.value.peakGust?.speed ?? 0) }
            .map { ($0.key, $0.value) }
    }

    /// Months whose prevailing sector differs from the record's — the concrete
    /// form of "does it change through the year".
    /// Compared arc to arc rather than bin to bin: a month whose mode slips one
    /// notch from S to SSE has not turned, it's the same southerly wind read at a
    /// resolution finer than the claim.
    public func monthsAgainstTheGrain() -> [Int] {
        guard let grain = overall.dominantArc() else { return [] }
        return byMonth
            .filter { _, rose in
                guard let arc = rose.dominantArc() else { return false }
                var delta = abs(arc.sectors[arc.sectors.count / 2] - grain.sectors[grain.sectors.count / 2])
                if delta > 8 { delta = 16 - delta }
                return delta >= 4          // 90° or more — a genuinely different quarter
            }
            .keys.sorted()
    }

    public static let monthNames = ["January", "February", "March", "April", "May", "June",
                                    "July", "August", "September", "October", "November", "December"]

    public static func monthName(_ month: Int) -> String {
        monthNames[max(1, min(12, month)) - 1]
    }
}

extension WindClimate {
    /// Build from the sample archive, reading each day exactly once.
    ///
    /// `days` defaults to everything the archive holds. A day that fails to read is
    /// skipped rather than thrown: one corrupt file out of 1,400 should cost that
    /// day's minutes, not the whole climatology.
    public static func build(from store: SampleArchiveStore,
                             days: [String]? = nil,
                             bands: [WindBand] = WindBand.standard) -> WindClimate {
        let keys = days ?? ((try? store.archivedDays()) ?? [])

        var overall = WindRoseBuilder(bands: bands)
        var months: [Int: WindRoseBuilder] = [:]
        var read = 0

        for day in keys {
            guard let samples = try? store.samples(onDay: day), !samples.isEmpty else { continue }
            read += 1
            overall.add(samples)

            guard let month = Int(day.dropFirst(5).prefix(2)), (1...12).contains(month) else { continue }
            var builder = months[month] ?? WindRoseBuilder(bands: bands)
            builder.add(samples)
            months[month] = builder
        }

        return WindClimate(overall: overall.build(),
                           byMonth: months.mapValues { $0.build() },
                           days: read,
                           firstDay: keys.first,
                           lastDay: keys.last)
    }
}

// MARK: - Saying it

extension WeatherInterpreter {
    /// The wind climatology as sentences, in the posture the rest of this kit uses:
    /// state the fact against THIS station's own record, and say nothing rather
    /// than say something thin.
    ///
    /// The word "prevailing" is spent carefully. A station whose wind alternates has
    /// no prevailing direction, and calling its mode one would be the same class of
    /// error as calling a county-wide watch a warning — technically derived from the
    /// data, and wrong about what it means.
    public static func windSummary(_ climate: WindClimate) -> [String] {
        let rose = climate.overall
        guard rose.isRepresentative(), let arc = rose.dominantArc() else { return [] }

        var lines: [String] = []

        // The arc, not the single bin. Speaking from the mode would say "from the
        // south, 14% of the time" about a station that is southerly 37% of the
        // time, which understates the fact it's trying to state.
        let share = Int((arc.fraction * 100).rounded())
        if rose.isSplit, let other = rose.secondaryArc(to: arc) {
            lines.append("There's no single prevailing wind here — it alternates between the \(longName(arc.compass)) (\(share)%) and the \(longName(other.compass)) (\(Int((other.fraction * 100).rounded()))%).")
        } else {
            lines.append("The wind here comes out of the \(longName(arc.compass)) — \(share)% of the moving hours are from \(arc.from) through \(arc.to).")
            // Constancy is a SEPARATE fact from which way it favours, and this is
            // the pair of sentences that stops the two being confused: a wind can
            // clearly favour one quarter and still be restless within and against it.
            if rose.constancy < 0.3 {
                lines.append("It's a variable wind, though: on net it barely goes anywhere, so any given day is a poor guess at the average.")
            } else if rose.constancy >= 0.5 {
                lines.append("And it's steady — it holds that direction rather than wandering.")
            }
        }

        if rose.calmFraction > 0.1 {
            lines.append("It's dead calm \(Int((rose.calmFraction * 100).rounded()))% of the time.")
        }

        if let windiest = climate.windiestMonth, let calmest = climate.calmestMonth,
           windiest.month != calmest.month,
           windiest.rose.meanSpeed > calmest.rose.meanSpeed * 1.25 {
            // A tenth, not a whole mph: these are season-long means a couple of mph
            // apart, and rounding them to integers makes 8.1 and 7.6 look identical.
            lines.append("\(WindClimate.monthName(windiest.month)) is the windiest month (\(preciseMPH(windiest.rose.meanSpeed)) on average) and \(WindClimate.monthName(calmest.month)) the calmest (\(preciseMPH(calmest.rose.meanSpeed))).")
        }

        // Only worth a sentence when it CONTRADICTS the sustained-wind answer;
        // otherwise it's the same fact said twice.
        if let gustiest = climate.gustiestMonth, let peak = gustiest.rose.peakGust,
           gustiest.month != climate.windiestMonth?.month {
            lines.append("The hardest gust on record — \(mph(peak.speed)) — came in \(WindClimate.monthName(gustiest.month)), not in the windy season.")
        }

        let turning = climate.monthsAgainstTheGrain()
        if !turning.isEmpty && turning.count <= 5 {
            let named = turning.map { WindClimate.monthName($0) }
            lines.append("The wind turns away from its usual quarter in \(list(named)).")
        }

        // Only when the hard wind arrives from OUTSIDE the everyday quarter — that's
        // the fact worth knowing when you're siting a tree or a fence.
        if let strongest = rose.strongest, !arc.sectors.contains(strongest.index),
           let gust = strongest.peakGust {
            lines.append("The strongest wind comes out of the \(longName(strongest.compass)) — that's the side gusts to \(mph(gust)) arrive from.")
        }

        return lines
    }

    static func preciseMPH(_ v: Double) -> String { String(format: "%.1f mph", v) }

    static func longName(_ compass: String) -> String {
        switch compass.uppercased() {
        case "N": return "north"
        case "NNE": return "north-northeast"
        case "NE": return "northeast"
        case "ENE": return "east-northeast"
        case "E": return "east"
        case "ESE": return "east-southeast"
        case "SE": return "southeast"
        case "SSE": return "south-southeast"
        case "S": return "south"
        case "SSW": return "south-southwest"
        case "SW": return "southwest"
        case "WSW": return "west-southwest"
        case "W": return "west"
        case "WNW": return "west-northwest"
        case "NW": return "northwest"
        case "NNW": return "north-northwest"
        default: return compass
        }
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
