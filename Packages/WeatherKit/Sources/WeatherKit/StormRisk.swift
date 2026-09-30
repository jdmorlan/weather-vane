//
//  StormRisk.swift  (WeatherKit)
//
//  One day's severe-weather and flooding risk AT HOME, gathered from the
//  offices' outlooks — the Forecast page's storm row. The map draws these same
//  outlooks as areas; this answers the only question the page asks of them:
//  what does it mean for this point, on this day, and what would you do.
//
//  EACH HAZARD IS RATED ON SPC'S OWN 1–5 SCALE. A raw "5%" reads as nothing,
//  and the same 5% means different things per hazard: 5% tornado is a Slight
//  risk day, 5% hail is only Marginal. SPC builds its categorical outlook from
//  exactly this conversion, so rating each hazard with it gives three chips
//  that share the categorical map's colours and never disagree with it.
//

import Foundation

extension SevereHazard {
    /// SPC's probability-to-category conversion for this hazard: the lowest
    /// probability that reaches each level, levels 1 through 5.
    ///
    /// From SPC's published table. Hail and wind top out at Moderate; only a
    /// tornado probability can make a High risk on its own.
    var thresholds: [Double] {
        switch self {
        case .tornado: return [0.02, 0.05, 0.10, 0.30, 0.45]
        case .hail:    return [0.05, 0.15, 0.30, 0.60]
        case .wind:    return [0.05, 0.15, 0.30, 0.60]
        case .any:     return [0.05, 0.15, 0.30, 0.45]
        }
    }

    /// 0 when the probability is below the hazard's lowest contour.
    public func level(for probability: Double) -> Int {
        // A small tolerance: the GeoJSON writes 0.15 as a string, and a float
        // a hair under the threshold must not drop a whole level.
        thresholds.lastIndex { probability + 1e-6 >= $0 }.map { $0 + 1 } ?? 0
    }

    /// What a person does about it, by level. Nil below level 1.
    public func action(level: Int) -> String? {
        guard level >= 1 else { return nil }
        switch self {
        case .tornado:
            return level >= 3 ? "Have a shelter plan and alerts on"
                              : "Know where you'd shelter"
        case .hail:
            return level >= 2 ? "Put the car in the garage"
                              : "Garage the car if it's easy"
        case .wind:
            return level >= 2 ? "Tie down or bring in loose things"
                              : "Loose things outside could blow"
        case .any:
            return "Worth watching — tomorrow's outlook splits it by hazard"
        }
    }
}

/// One day's risk at home.
public struct StormRisk: Equatable, Sendable {
    public struct Hazard: Equatable, Sendable, Identifiable {
        public var hazard: SevereHazard
        /// Chance within 25 miles, 0–1.
        public var probability: Double
        /// SPC's 1–5; 0 below the lowest contour.
        public var level: Int
        public var id: SevereHazard { hazard }

        public init(hazard: SevereHazard, probability: Double) {
            self.hazard = hazard
            self.probability = probability
            self.level = hazard.level(for: probability)
        }

        public var action: String? { hazard.action(level: level) }
    }

    /// SPC's categorical outlook at home. Nil when home is outside every area,
    /// including general thunder — no storms expected at all.
    public var category: OutlookCategory?
    /// Hazard by hazard, strongest first. Empty when SPC publishes none for
    /// this day or they have not loaded.
    public var hazards: [Hazard]
    /// WPC's Excessive Rainfall Outlook at home.
    public var flood: OutlookCategory?

    public init(category: OutlookCategory?, hazards: [Hazard], flood: OutlookCategory?) {
        self.category = category
        self.hazards = hazards.sorted { ($0.level, $0.probability) > ($1.level, $1.probability) }
        self.flood = flood
    }

    /// The hazards worth a chip: those that reach level 1.
    public var notable: [Hazard] { hazards.filter { $0.level >= 1 } }

    /// Nothing drawn over home by either office: not even general thunder.
    public var isQuiet: Bool { (category == nil || category?.level == 0) && notable.isEmpty && flood == nil }
}

public enum OutlookDay {
    /// The station-local day an outlook period covers, as a `DayKey` string.
    ///
    /// SPC and WPC days run 12Z to 12Z — 7 AM to 7 AM in Central daylight
    /// time — so the day is the one that holds most of the window. Twelve hours
    /// before it closes is always inside it and always on that day in any US
    /// time zone: 12Z is 1–8 AM local, and twelve hours earlier is the evening
    /// before — the day the outlook is FOR. Nil without an end time.
    public static func key(validUntil: Date?, timeZone: TimeZone) -> String? {
        guard let validUntil else { return nil }
        return DayKey.string(for: validUntil.addingTimeInterval(-12 * 3600), timeZone: timeZone)
    }
}
