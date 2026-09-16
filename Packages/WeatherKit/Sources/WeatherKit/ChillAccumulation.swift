//
//  ChillAccumulation.swift  (WeatherKit)
//
//  Winter chill, for deciding what fruit will actually fruit here.
//
//  Deciduous fruit trees break dormancy on ACCUMULATED COLD, not on a date. A
//  variety quoted at "800 chill hours" needs roughly that much time in the
//  32–45°F band over winter, or it wakes up ragged: strung-out bloom, poor set,
//  a light crop. Nursery catalogs quote the number; almost nobody knows their own
//  yard's. The archive does.
//
//  Two models, because they disagree in the way that matters:
//    · CHILL HOURS (Weinberger) — hours in 32–45°F. The unit catalogs use, so
//      it's the one that answers "can I plant this". Its weakness is that it has
//      no idea a 70° February afternoon happened.
//    · UTAH CHILL UNITS — same idea, weighted, and warm afternoons SUBTRACT.
//      Closer to the tree's actual physiology in a climate with warm spells,
//      but not the unit anything is sold in.
//
//  Both are counted per-sample at rollup rather than modeled from daily min/max
//  (see DailyRecord), so what's stored is what the station saw.
//

import Foundation

// MARK: - The models

public enum ChillModel {

    /// Utah-model weight for one hour at a given temperature.
    ///
    /// The thresholds are the published °C bands converted to °F; keeping them as
    /// converted constants rather than re-rounding to tidy Fahrenheit numbers is
    /// what keeps this the Utah model rather than something adjacent to it.
    public static func utahUnit(forF temperature: Double) -> Double {
        switch temperature {
        case ..<34.52:  return 0        // too cold to count
        case ..<36.32:  return 0.5
        case ..<48.38:  return 1.0      // the effective band
        case ..<54.32:  return 0.5
        case ..<60.62:  return 0
        case ..<64.40:  return -0.5     // warm spells undo chill
        default:        return -1.0
        }
    }

    /// Chill season bounds. October through February is the common accounting
    /// window: it covers the whole dormancy period without letting an early-fall
    /// cool snap or a March warm spell into the total.
    public static let seasonStartMonthDay = "10-01"
    /// Inclusive upper bound, and it has to be the 29th rather than the 28th:
    /// these are string comparisons on `MM-dd`, so a "02-28" bound silently drops
    /// February 29 and every leap-year winter comes up a day short.
    public static let seasonEndMonthDay = "02-29"

    /// A chill season is named for the year it ENDS in — the winter of 2024–25
    /// is season 2025 — because that's the spring whose bloom it governs.
    public static func endingYear(for day: String) -> Int? {
        guard let year = DayKey.year(of: day) else { return nil }
        return DayKey.monthDay(of: day) >= seasonStartMonthDay ? year + 1 : year
    }
}

// MARK: - A season's accumulation

/// One winter's accumulation.
///
/// Accounted in HOURS SEEN, not days present. A real station misses scattered
/// hours all winter — battery, radio, storms — so no winter ever consists of
/// 150 perfect days, and a threshold counting whole days rejects every one of
/// them. Hours are also just the honest unit: a day recorded 27 samples out of
/// 48 didn't fail, it contributed 13 hours of fact.
///
/// So `chillHours` is a FLOOR, not an estimate — hours actually observed in the
/// band. The true total can only be higher, never lower, which makes it the
/// right number to plant against without a single modeling assumption.
public struct ChillSeason: Equatable, Sendable, Identifiable {
    /// The spring this winter feeds. Season 2025 = Oct 2024 → Feb 2025.
    public var endingYear: Int
    /// Hours observed in 32–45°F. A lower bound on the winter's real chill.
    public var chillHours: Double
    public var utahUnits: Double

    /// Hours of the window the station actually reported, and how many it holds.
    public var observedHours: Double
    public var windowHours: Double
    /// Day records present, for display only — the arithmetic is all in hours.
    public var daysCovered: Int
    /// The season hasn't finished yet; the total is still climbing.
    public var isInProgress: Bool

    public var id: Int { endingYear }

    /// "2024–25"
    public var label: String { "\(endingYear - 1)–\(String(endingYear).suffix(2))" }

    /// Share of the winter's hours the station reported.
    public var coverage: Double {
        guard windowHours > 0 else { return 0 }
        return min(1, observedHours / windowHours)
    }

    /// The floor scaled up as if the unrecorded hours chilled at the same rate
    /// as the recorded ones. A central estimate rather than a bound — outages
    /// aren't random, so this is the softer number of the two and is always
    /// shown as an "about", never as the answer.
    public var estimatedChillHours: Double {
        guard coverage > 0 else { return chillHours }
        return chillHours / coverage
    }

    /// Hours the station never saw — the width of the uncertainty.
    public var unrecordedHours: Double { max(0, windowHours - observedHours) }

    /// Complete enough to quote. Three quarters of a winter's hours still bounds
    /// the answer usefully; below that the floor sits too far under the truth to
    /// mean much.
    public var isTrustworthy: Bool { !isInProgress && coverage >= 0.75 }
}

/// What the whole record says about winter chill here.
public struct ChillSummary: Equatable, Sendable {
    public var seasons: [ChillSeason]
    /// Median of the trustworthy seasons' observed floors. Median rather than
    /// mean so one freak winter doesn't move the recommendation.
    public var typicalChillHours: Double?
    /// Median of the coverage-corrected estimates — the softer companion number.
    public var typicalEstimate: Double?
    public var lowestChillHours: Double?
    public var highestChillHours: Double?
    public var typicalUtahUnits: Double?
    public var seasonsCounted: Int
    /// Median share of a winter's hours the station recorded, for phrasing the
    /// uncertainty on the headline number.
    public var typicalCoverage: Double?
    /// The winter currently accumulating, if there is one.
    public var inProgress: ChillSeason?

    /// Below three complete winters, "typical" is a coincidence. Everything
    /// user-facing checks this before recommending a tree.
    public var isMeaningful: Bool { seasonsCounted >= 3 }

    /// The number to plant against: the median winter's OBSERVED FLOOR.
    ///
    /// Not the lowest winter. Each season's figure is already a lower bound on
    /// that season's real chill, so taking the minimum of lower bounds stacks two
    /// separate pessimisms and lands on a number the yard comfortably beats —
    /// which would rule out fruit that in fact grows here. One conservatism is
    /// prudence; two is a wrong answer.
    public var planningChillHours: Double? { typicalChillHours }
}

extension Climatology {

    /// Accumulated chill per winter across the record, newest first.
    public func chillSeasons(now: Date = Date(), timeZone: TimeZone = .current) -> [ChillSeason] {
        let today = DayKey.string(for: now, timeZone: timeZone)
        var totals: [Int: ChillSeason] = [:]

        for record in all {
            let monthDay = DayKey.monthDay(of: record.day)
            // October–February only; the months between contribute nothing and
            // would drag warm-season noise into the Utah total.
            guard monthDay >= ChillModel.seasonStartMonthDay || monthDay <= ChillModel.seasonEndMonthDay,
                  let season = ChillModel.endingYear(for: record.day) else { continue }

            var entry = totals[season] ?? ChillSeason(endingYear: season, chillHours: 0, utahUnits: 0,
                                                      observedHours: 0, windowHours: 0,
                                                      daysCovered: 0, isInProgress: false)
            entry.daysCovered += 1
            // A partial day still contributes every in-band hour it DID see.
            // Discarding it would throw away fact to avoid admitting uncertainty;
            // instead the hours it missed are carried in `observedHours`, where
            // they widen the stated uncertainty rather than silently lowering the
            // total. A day with no counters at all contributes nothing but still
            // counts its hours as unrecorded.
            entry.observedHours += 24 * record.coverage
            entry.chillHours += record.chillHours ?? 0
            entry.utahUnits += record.chillUnitsUtah ?? 0
            totals[season] = entry
        }

        // Today is inside a chill window only from October through February;
        // in July nothing is accumulating and every season on record is closed.
        let todayMonthDay = DayKey.monthDay(of: today)
        let isWinter = todayMonthDay >= ChillModel.seasonStartMonthDay
            || todayMonthDay <= ChillModel.seasonEndMonthDay
        let currentSeason = ChillModel.endingYear(for: today)

        return totals.values.map { season in
            var season = season
            season.windowHours = Double(Climatology.seasonLength(endingYear: season.endingYear)) * 24
            season.isInProgress = isWinter && season.endingYear == currentSeason
            return season
        }.sorted { $0.endingYear > $1.endingYear }
    }

    public func chillSummary(now: Date = Date(), timeZone: TimeZone = .current) -> ChillSummary {
        let seasons = chillSeasons(now: now, timeZone: timeZone)
        let usable = seasons.filter(\.isTrustworthy)
        let hours = usable.map(\.chillHours).sorted()

        return ChillSummary(seasons: seasons,
                            typicalChillHours: hours.median,
                            typicalEstimate: usable.map(\.estimatedChillHours).sorted().median,
                            lowestChillHours: hours.first,
                            highestChillHours: hours.last,
                            typicalUtahUnits: usable.map(\.utahUnits).sorted().median,
                            seasonsCounted: usable.count,
                            typicalCoverage: usable.map(\.coverage).sorted().median,
                            inProgress: seasons.first { $0.isInProgress })
    }

    /// Days from Oct 1 through the end of February, leap years included.
    static func seasonLength(endingYear: Int) -> Int {
        let zone = TimeZone(identifier: "UTC") ?? .current
        guard let start = DayKey.date(from: "\(endingYear - 1)-10-01", timeZone: zone),
              let end = DayKey.date(from: "\(endingYear)-03-01", timeZone: zone) else { return 151 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents([.day], from: start, to: end).day ?? 151
    }
}

// MARK: - What that buys you

/// A fruit's dormancy requirement, as a range across its common cultivars.
public struct FruitChillRequirement: Equatable, Sendable, Identifiable {
    public var name: String
    public var low: Double
    public var high: Double
    /// The thing a range alone doesn't tell you.
    public var note: String
    public var id: String { name }

    /// Whether a given winter's chill reaches this fruit, and how surely.
    public func fit(_ chillHours: Double) -> ChillFit {
        if chillHours >= high { return .comfortable }
        if chillHours >= low { return .marginal }
        return .insufficient
    }
}

public enum ChillFit: String, Sendable {
    /// Clears even the high-chill cultivars.
    case comfortable
    /// Only the low-chill cultivars of this fruit will be reliable.
    case marginal
    /// Not enough chill; the tree will bloom raggedly and set poorly.
    case insufficient
}

public enum FruitChill {
    /// Common backyard fruit and the chill their cultivars ask for.
    ///
    /// These are CULTIVAR RANGES, not species constants — "peach" spans a
    /// low-chill Florida selection at 150 hours and a northern one at 1000.
    /// Every consumer of this list has to say so, because the useful move is
    /// always "pick the variety to the number", never "give up on the fruit".
    public static let common: [FruitChillRequirement] = [
        .init(name: "Fig", low: 100, high: 300, note: "Almost anywhere; the limit is summer heat, not winter chill"),
        .init(name: "Pomegranate", low: 100, high: 200, note: "Wants a long hot summer to ripen"),
        .init(name: "Persimmon", low: 100, high: 400, note: "Asian varieties sit at the low end"),
        .init(name: "Almond", low: 200, high: 500, note: "Blooms very early — late frost is the real risk"),
        .init(name: "Apricot", low: 300, high: 900, note: "Early bloom; a warm February then a freeze loses the crop"),
        .init(name: "Peach & nectarine", low: 400, high: 1000, note: "The widest cultivar spread of any stone fruit"),
        .init(name: "Japanese plum", low: 500, high: 900, note: "Needs a second variety nearby to pollinate"),
        .init(name: "Asian pear", low: 400, high: 800, note: "Reliable where apples are marginal"),
        .init(name: "Apple", low: 500, high: 1200, note: "Low-chill cultivars exist near 300; most standards want 800+"),
        .init(name: "European plum", low: 700, high: 1100, note: "Later bloom than Japanese — safer against frost"),
        .init(name: "Sweet cherry", low: 800, high: 1200, note: "Also needs a dry ripening window or the fruit splits"),
        .init(name: "European pear", low: 600, high: 1500, note: "Long-lived and forgiving once established"),
        .init(name: "Sour cherry", low: 1000, high: 1200, note: "The highest chill requirement here"),
    ]

    /// Fruit sorted by how well it fits a given winter — plantable first.
    public static func ranked(for chillHours: Double) -> [(FruitChillRequirement, ChillFit)] {
        common.map { ($0, $0.fit(chillHours)) }
            .sorted { a, b in
                if a.1 == b.1 { return a.0.low < b.0.low }
                return order(a.1) < order(b.1)
            }
    }

    private static func order(_ fit: ChillFit) -> Int {
        switch fit {
        case .comfortable: return 0
        case .marginal: return 1
        case .insufficient: return 2
        }
    }
}

extension Array where Element == Double {
    /// Middle value; the mean of the two middles on an even count. Assumes sorted.
    var median: Double? {
        guard !isEmpty else { return nil }
        let middle = count / 2
        return count % 2 == 1 ? self[middle] : (self[middle - 1] + self[middle]) / 2
    }
}
