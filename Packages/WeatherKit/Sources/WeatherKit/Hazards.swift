//
//  Hazards.swift  (WeatherKit)
//
//  Watches, warnings and advisories for ONE fixed point — your acre. Everything
//  here is pure: decoding, classification, the point-in-polygon test, and the
//  ranking. Fetching lives in `NWSClient`.
//
//  Three design points carry the file.
//
//  1. A HAZARD HAS A NATIVE RESOLUTION, and it is not always a point. A warning is
//     a storm-based POLYGON and the point test is the real test. A watch is issued
//     FOR COUNTIES — there is no finer answer, and pretending otherwise would
//     invent precision the product doesn't have. So `resolution` is carried on
//     every hazard and shown, because "you're in it" and "your county is in it"
//     are different facts and only one of them means go inside.
//
//  2. LEVEL IS NORMALIZED, `native` IS NOT. A single 0…1 ordinal is what lets a
//     tornado warning, a heat advisory and an air quality alert rank against each
//     other on one surface. But the source's own word is never thrown away — it's
//     what you actually act on, and no scale of mine improves on "Tornado Warning".
//
//  3. ABSENCE NEEDS COVERAGE. This is the archive's rule ([[DailyRecord]], `Reading`)
//     at higher stakes: a feed we failed to reach must never render as "all clear".
//     `HazardWatch.state` makes that unrepresentable — there is no case that means
//     "nothing" without also carrying the time we last actually heard from NWS.
//

import Foundation

// MARK: - Geometry

/// A coordinate. Stored plainly so every spatial question stays testable without
/// MapKit — the same posture `PlaceBlock` takes.
public struct GeoPoint: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// The alert's own geometry, when it has one. Ring 0 of a polygon is the outer
/// boundary; any further rings are holes.
public enum GeoShape: Codable, Equatable, Sendable {
    case polygon([[GeoPoint]])
    case multiPolygon([[[GeoPoint]]])

    /// Every ring, outer and hole alike, flattened. Only a DRAWING concern — the
    /// containment answer is `contains`, and no caller should be re-deriving it
    /// from these.
    public var rings: [[GeoPoint]] {
        switch self {
        case .polygon(let rings):     return rings
        case .multiPolygon(let polys):return polys.flatMap { $0 }
        }
    }

    /// Ray casting. Deliberately ignores the antimeridian: NWS alert polygons are
    /// storm-sized and domestic, so a wrap-around case cannot arise, and handling
    /// one would add a branch no test could ever exercise honestly.
    public func contains(_ point: GeoPoint) -> Bool {
        switch self {
        case .polygon(let rings):
            return Self.rings(rings, contain: point)
        case .multiPolygon(let polygons):
            return polygons.contains { Self.rings($0, contain: point) }
        }
    }

    private static func rings(_ rings: [[GeoPoint]], contain point: GeoPoint) -> Bool {
        guard let outer = rings.first, ringContains(outer, point) else { return false }
        // Inside the outer boundary but inside a hole is outside the shape.
        return !rings.dropFirst().contains { ringContains($0, point) }
    }

    static func ringContains(_ ring: [GeoPoint], _ p: GeoPoint) -> Bool {
        guard ring.count > 2 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.latitude > p.latitude) != (b.latitude > p.latitude) {
                let span = b.latitude - a.latitude
                if span != 0 {
                    let t = (p.latitude - a.latitude) / span
                    if p.longitude < a.longitude + t * (b.longitude - a.longitude) { inside.toggle() }
                }
            }
            j = i
        }
        return inside
    }
}

// MARK: - Classification

/// What KIND of thing is threatened. Used for grouping and iconography only —
/// never for ranking, which is `level`'s job.
public enum HazardKind: String, Codable, Sendable, CaseIterable {
    case tornado, thunderstorm, flood, winter, heat, cold, wind, fire, marine, air, other

    /// Keyword match on the NWS event name. Order matters: "Tornado Warning"
    /// must not fall through to `.wind`, and a "Flash Flood" is a flood before
    /// it is anything else.
    public static func classify(event: String) -> HazardKind {
        let e = event.lowercased()
        if e.contains("tornado") { return .tornado }
        if e.contains("thunderstorm") || e.contains("severe weather") { return .thunderstorm }
        if e.contains("flood") || e.contains("flash") { return .flood }
        if e.contains("fire") || e.contains("red flag") || e.contains("smoke") { return .fire }
        if e.contains("snow") || e.contains("ice") || e.contains("winter")
            || e.contains("blizzard") || e.contains("sleet") || e.contains("freezing") { return .winter }
        if e.contains("freeze") || e.contains("frost") || e.contains("cold")
            || e.contains("wind chill") { return .cold }
        if e.contains("heat") || e.contains("excessive heat") { return .heat }
        if e.contains("wind") || e.contains("dust") || e.contains("hurricane")
            || e.contains("tropical") { return .wind }
        if e.contains("marine") || e.contains("small craft") || e.contains("surf")
            || e.contains("rip current") { return .marine }
        if e.contains("air quality") || e.contains("ozone") { return .air }
        return .other
    }
}

/// The product tier, read off the event name's last word. This is the axis the
/// public actually understands: a WATCH means conditions are favourable, a
/// WARNING means it is happening.
public enum HazardTier: String, Codable, Sendable {
    case warning, watch, advisory, statement

    public static func parse(event: String) -> HazardTier {
        switch event.split(separator: " ").last?.lowercased() {
        case "warning", "emergency": return .warning
        case "watch": return .watch
        case "advisory": return .advisory
        default: return .statement
        }
    }

    var base: Double {
        switch self {
        case .warning: return 0.75
        case .watch: return 0.50
        case .advisory: return 0.30
        case .statement: return 0.15
        }
    }
}

/// How precisely this hazard is known to apply to you. Not decoration — it is the
/// difference between a feature people trust and one they learn to ignore.
public enum HazardResolution: String, Codable, Sendable {
    /// The alert carried a polygon and your point is inside it.
    case polygon
    /// The alert is issued for zones or counties, and yours is one of them.
    case zone

    /// Said the way you'd say it out loud, so the banner doesn't have to.
    public var phrase: String {
        switch self {
        case .polygon: return "you're in it"
        case .zone: return "your county"
        }
    }
}

// MARK: - Hazard

/// One live hazard over your point.
public struct Hazard: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// NWS's own event name, verbatim: "Severe Thunderstorm Warning".
    public var event: String
    public var kind: HazardKind
    public var tier: HazardTier
    public var resolution: HazardResolution
    /// 0…1, comparable ACROSS sources. See the file header.
    public var level: Double
    /// When it applies. `ends` where NWS gives one, `expires` otherwise.
    public var onset: Date?
    public var expires: Date?
    /// When NWS sent this version of the product.
    public var sent: Date?
    /// When NWS says this STATEMENT runs out — which, for a long watch, is
    /// not when the watch ends but when the office will reissue it. Kept
    /// apart from `expires` because the two were once conflated in a way that
    /// made a two-day flood watch read as ending at the afternoon update.
    /// Nil when it is the same moment as the end.
    public var nextStatement: Date?
    /// The plain-language halves, when the product carries them. A watch usually
    /// carries both; a statement often carries neither.
    public var headline: String?
    public var instruction: String?
    /// The counties/zones named by the issuing office.
    public var areaDesc: String?
    public var senderName: String?
    /// The product's own polygon, kept ONLY so it can be drawn over the radar —
    /// which is the whole reason the alert half and the radar half want to ship
    /// together. Nil for zone products, which genuinely have no finer outline.
    /// Containment was already decided by `HazardParser`; nothing downstream
    /// should re-ask it.
    public var shape: GeoShape?

    public init(id: String, event: String, kind: HazardKind, tier: HazardTier,
                resolution: HazardResolution, level: Double,
                onset: Date? = nil, expires: Date? = nil,
                sent: Date? = nil, nextStatement: Date? = nil,
                headline: String? = nil, instruction: String? = nil,
                areaDesc: String? = nil, senderName: String? = nil,
                shape: GeoShape? = nil) {
        self.id = id
        self.event = event
        self.kind = kind
        self.tier = tier
        self.resolution = resolution
        self.level = level
        self.onset = onset
        self.expires = expires
        self.sent = sent
        self.nextStatement = nextStatement
        self.headline = headline
        self.instruction = instruction
        self.areaDesc = areaDesc
        self.senderName = senderName
        self.shape = shape
    }

    public func isActive(at now: Date) -> Bool {
        if let expires, expires <= now { return false }
        return true
    }

    /// "until tomorrow 7 AM" · "today 1 PM – tomorrow 7 AM" · "" when NWS
    /// bounded neither end. EVERY END CARRIES ITS DAY: a flood watch that runs
    /// into Thursday must never print as a same-day window. A hazard whose
    /// window we can't state is still a hazard — the phrase goes empty rather
    /// than the hazard going missing.
    public func timing(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch (onset, expires) {
        case let (o?, e?) where o > now: return When.range(o, e, now: now, calendar: calendar)
        case let (_, e?): return "until \(When.moment(e, now: now, calendar: calendar))"
        case let (o?, nil) where o > now: return "from \(When.moment(o, now: now, calendar: calendar))"
        default: return ""
        }
    }

    /// "Fort Worth TX · issued today 8:23 AM · next expected today 4:30 PM".
    public var stamp: SourceStamp {
        SourceStamp(source: senderName ?? "NWS",
                    made: sent.map { .issued($0) } ?? .unpublished,
                    next: nextStatement)
    }
}

// MARK: - Coverage

/// What we know about hazards over your point, INCLUDING whether we currently
/// know anything at all.
///
/// The whole reason this isn't just `[Hazard]`: a closed laptop, an expired
/// certificate or a network blip would otherwise be indistinguishable from a
/// quiet sky, and the two must never look the same during a storm.
public struct HazardWatch: Equatable, Sendable {
    public var hazards: [Hazard]
    /// The last time NWS actually answered. `nil` means we have never reached it.
    public var lastReached: Date?
    /// The last time we TRIED, successful or not.
    public var lastAttempt: Date?
    /// Why the most recent attempt failed, if it did.
    public var failure: String?

    public init(hazards: [Hazard] = [], lastReached: Date? = nil,
                lastAttempt: Date? = nil, failure: String? = nil) {
        self.hazards = hazards
        self.lastReached = lastReached
        self.lastAttempt = lastAttempt
        self.failure = failure
    }

    /// How old a successful fetch may be before "nothing active" stops being a
    /// claim we're entitled to make. Warnings are issued and expire on a scale of
    /// minutes, so this is deliberately short.
    public static let freshness: TimeInterval = 15 * 60

    public enum State: Equatable, Sendable {
        /// Live hazards, ranked most serious first.
        case active([Hazard])
        /// Genuinely nothing, and we can say so because we heard this recently.
        case clear(asOf: Date)
        /// We cannot currently claim anything. Carries the last time we DID know,
        /// so the surface can say how long it has been blind.
        case unknown(since: Date?, reason: String?)
    }

    public func state(now: Date = Date()) -> State {
        let live = hazards.filter { $0.isActive(at: now) }.sorted(by: Hazard.moreSerious)
        if !live.isEmpty { return .active(live) }
        guard let lastReached, now.timeIntervalSince(lastReached) <= Self.freshness else {
            return .unknown(since: lastReached, reason: failure)
        }
        return .clear(asOf: lastReached)
    }

    /// The single most serious thing over your acre right now, if anything is.
    public func top(now: Date = Date()) -> Hazard? {
        if case .active(let live) = state(now: now) { return live.first }
        return nil
    }
}

extension Hazard {
    /// Rank by level, then by whichever ends soonest — of two equally serious
    /// things the one about to expire is the one you're living through.
    static func moreSerious(_ a: Hazard, _ b: Hazard) -> Bool {
        if a.level != b.level { return a.level > b.level }
        switch (a.expires, b.expires) {
        case let (x?, y?): return x < y
        case (nil, _?): return false
        case (_?, nil): return true
        default: return a.event < b.event
        }
    }
}

// MARK: - GeoJSON geometry

/// A GeoJSON `geometry` object — Polygon or MultiPolygon, which is every shape
/// an NWS alert, an SPC outlook or a WPC outlook is drawn with. It lived inside
/// `NWSAlertFeed` until the outlooks needed it; reading SPC's file through a
/// type named for NWS alerts would have been a generic thing wearing one
/// product's name. See [[explicit-platform-naming]].
public struct GeoJSONGeometry: Decodable, Sendable {
    public var type: String
    /// Left untyped at the boundary because a GeoJSON `coordinates` array is a
    /// different depth per geometry type; `shape()` is where it becomes typed.
    public var coordinates: Nested

    enum CodingKeys: String, CodingKey { case type, coordinates }

    /// SPC WRITES A QUIET DAY AS AN EMPTY `GeometryCollection` — no
    /// `coordinates` key at all. Required, that key failed the whole file, so a
    /// day with no hail anywhere read as a failed fetch rather than as no hail.
    /// Missing coordinates decode as an empty list, and `shape()` returns nil.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        coordinates = try c.decodeIfPresent(Nested.self, forKey: .coordinates) ?? .list([])
    }

    public func shape() -> GeoShape? {
        switch type {
        case "Polygon":     return coordinates.rings().map { GeoShape.polygon($0) }
        case "MultiPolygon":return coordinates.polygons().map { GeoShape.multiPolygon($0) }
        default:            return nil
        }
    }

    /// A minimal recursive JSON-array decoder. GeoJSON nests coordinates to a
    /// depth that varies by type, and `[[[Double]]]` would simply fail to decode a
    /// MultiPolygon rather than telling us why.
    public indirect enum Nested: Decodable, Sendable {
        case number(Double)
        case list([Nested])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .number(d); return }
            self = .list(try c.decode([Nested].self))
        }

        var items: [Nested]? { if case .list(let l) = self { return l }; return nil }
        var value: Double? { if case .number(let d) = self { return d }; return nil }

        /// GeoJSON positions are [longitude, latitude] — in that order, which is
        /// the reverse of how they're said aloud and the classic way to put a
        /// Texas warning in the Indian Ocean.
        func point() -> GeoPoint? {
            guard let pair = items, pair.count >= 2,
                  let lon = pair[0].value, let lat = pair[1].value else { return nil }
            return GeoPoint(latitude: lat, longitude: lon)
        }

        func ring() -> [GeoPoint]? { items?.compactMap { $0.point() } }
        func rings() -> [[GeoPoint]]? { items?.compactMap { $0.ring() } }
        func polygons() -> [[[GeoPoint]]]? { items?.compactMap { $0.rings() } }
    }
}

// MARK: - Decoding the NWS feed

/// GeoJSON `FeatureCollection` from `api.weather.gov/alerts/active`.
public struct NWSAlertFeed: Decodable, Sendable {
    public var features: [Feature]

    public struct Feature: Decodable, Sendable {
        public var id: String?
        public var geometry: Geometry?
        public var properties: Properties
    }

    /// The alert's geometry, decoded by the same GeoJSON reader the SPC and WPC
    /// outlooks use. See `GeoJSONGeometry`.
    public typealias Geometry = GeoJSONGeometry

    public struct Properties: Decodable, Sendable {
        public var id: String?
        public var event: String?
        public var severity: String?
        public var certainty: String?
        public var urgency: String?
        public var status: String?
        public var messageType: String?
        public var onset: String?
        public var effective: String?
        public var sent: String?
        public var expires: String?
        public var ends: String?
        public var headline: String?
        public var description: String?
        public var instruction: String?
        public var areaDesc: String?
        public var senderName: String?
    }
}

public enum HazardParser {
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return iso.date(from: s) ?? isoFractional.date(from: s)
    }

    /// The normalized 0…1 ordinal.
    ///
    /// Note there is NO special case for a tornado warning: it arrives as
    /// Extreme + Immediate, so the general rule already lands it at 1.0. A table
    /// of hand-tuned event names would drift out of date the first time NWS added
    /// a product; deriving it from the fields NWS actually maintains does not.
    static func level(tier: HazardTier, severity: String?, urgency: String?) -> Double {
        var score = tier.base
        if severity?.caseInsensitiveCompare("Extreme") == .orderedSame { score += 0.15 }
        if urgency?.caseInsensitiveCompare("Immediate") == .orderedSame { score += 0.10 }
        return min(1, max(0, score))
    }

    /// Turn one decoded feature into a hazard for THIS point, or nothing.
    ///
    /// The polygon test is run here even though NWS already filtered by point,
    /// because the two disagreeing is precisely the case worth catching: a
    /// polygon product whose polygon does not contain you is not your warning,
    /// and passing it through is how a county-wide false alarm gets manufactured.
    public static func hazard(from feature: NWSAlertFeed.Feature, at point: GeoPoint) -> Hazard? {
        let p = feature.properties
        guard let event = p.event, !event.isEmpty else { return nil }
        // Drafts, tests and cancellations are not conditions over your acre.
        if let status = p.status, status.caseInsensitiveCompare("Actual") != .orderedSame { return nil }
        if let type = p.messageType, type.caseInsensitiveCompare("Cancel") == .orderedSame { return nil }

        let resolution: HazardResolution
        let shape = feature.geometry?.shape()
        if let shape {
            guard shape.contains(point) else { return nil }
            resolution = .polygon
        } else {
            resolution = .zone
        }

        let tier = HazardTier.parse(event: event)
        return Hazard(
            id: p.id ?? feature.id ?? event,
            event: event,
            kind: .classify(event: event),
            tier: tier,
            resolution: resolution,
            level: level(tier: tier, severity: p.severity, urgency: p.urgency),
            onset: date(p.onset) ?? date(p.effective),
            expires: date(p.ends) ?? date(p.expires),
            sent: date(p.sent),
            // Only worth keeping when it differs from the end — otherwise the
            // statement simply runs to the end of the event.
            nextStatement: date(p.ends) != nil && date(p.expires) != date(p.ends) ? date(p.expires) : nil,
            headline: p.headline,
            instruction: p.instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
            areaDesc: p.areaDesc,
            senderName: p.senderName,
            shape: shape)
    }

    /// Whole-feed version. Duplicates are collapsed by id — NWS can carry the same
    /// product under several zones.
    public static func hazards(from feed: NWSAlertFeed, at point: GeoPoint) -> [Hazard] {
        var seen = Set<String>()
        return feed.features
            .compactMap { hazard(from: $0, at: point) }
            .filter { seen.insert($0.id).inserted }
            .sorted(by: Hazard.moreSerious)
    }
}
