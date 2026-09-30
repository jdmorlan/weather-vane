//
//  Outlooks.swift  (WeatherKit)
//
//  National forecasts drawn as AREAS, days ahead: the Storm Prediction Center's
//  convective outlook, the Weather Prediction Center's Excessive Rainfall
//  Outlook, and WPC's forecast rain totals. The first two are areas drawn by a
//  forecaster, both are categories rather than amounts, and both answer the
//  same shape of question — how likely is the bad version of this, near you —
//  for two different ways weather hurts people. The third is an AMOUNT: how
//  much rain, in inches, contoured into bands. It shares everything below
//  except that, and the categories it uses are those bands.
//
//  FOR THE TWO OUTLOOKS, THE CATEGORY IS A PROBABILITY, NOT A SEVERITY, and
//  that is the thing most worth knowing about those maps. "Moderate" does not mean the storms will be
//  moderate. It means the forecaster puts the chance of the dangerous event
//  within 25 miles of you above a threshold. Each product's `measures` says what
//  that event is, and the app shows it next to the map rather than leaving the
//  colours to speak for themselves. See [[weather-app-teaches-not-displays]].
//
//  FROM THE DATA, NOT A PICTURE. SPC publishes each outlook as GeoJSON on its
//  own site. WPC does not, but NOAA's vector map service serves the same
//  polygons — outlook and rain totals both — as GeoJSON. Both come back as real shapes, so the map can outline
//  them over its own counties and the app can say which category your home is
//  in — neither of which a PNG could do.
//
//  ABSENCE NEEDS COVERAGE, as in `Hazards.swift`. An outlook with no areas is a
//  real answer (the forecaster drew nothing), and a fetch that failed is not.
//  The two must never look the same, so emptiness is only ever represented by a
//  successfully decoded `Outlook`.
//

import Foundation

// MARK: - Products

public enum OutlookProduct: String, CaseIterable, Identifiable, Sendable {
    /// SPC's categorical convective outlook — severe thunderstorms.
    case severeStorms
    /// WPC's Excessive Rainfall Outlook — flash flooding.
    case excessiveRain
    /// WPC's quantitative precipitation forecast — how much rain, in inches,
    /// accumulated from the start of day 1.
    case rainTotals

    public var id: String { rawValue }

    /// The office that draws it, named because a person looking this up
    /// elsewhere will search for it by that name.
    public var issuer: String {
        switch self {
        case .severeStorms:  return "SPC"
        case .excessiveRain, .rainTotals: return "WPC"
        }
    }

    public var label: String {
        switch self {
        case .severeStorms:  return "Severe storms"
        case .excessiveRain: return "Excessive rain"
        case .rainTotals:    return "Rain totals"
        }
    }

    public var fullName: String {
        switch self {
        case .severeStorms:  return "Storm Prediction Center convective outlook"
        case .excessiveRain: return "Weather Prediction Center Excessive Rainfall Outlook"
        case .rainTotals:    return "Weather Prediction Center quantitative precipitation forecast"
        }
    }

    /// WHAT THE CATEGORIES ARE A PROBABILITY OF, in one sentence. This is the
    /// mechanism the colours encode; see the file header.
    public var measures: String {
        switch self {
        case .severeStorms:
            return "The chance of a tornado, hail an inch or larger, or a 58 mph gust "
                + "within 25 miles of a point. The category comes from whichever of "
                + "the three is most likely."
        case .excessiveRain:
            return "The chance that rain will exceed flash flood guidance within 25 miles "
                + "of a point. Guidance is how much rain it takes to flood small streams, "
                + "and it is lower where the ground is already wet — so the same rain "
                + "can be a risk one week and not the next."
        case .rainTotals:
            return "WPC forecasters' best estimate of the total rain — and melted snow — "
                + "that will fall, added up from 7 AM Central on day 1. It is one "
                + "number, not a range: it says nothing about how sure they are, and "
                + "it spreads the total over the whole period rather than saying how "
                + "hard it will rain at once."
        }
    }

    /// WHICH PERIODS A PERSON CAN ASK FOR. For the two outlooks, a day: days
    /// 1–3 each. WPC also issues ERO days 4 and 5, but SPC's categorical outlook
    /// stops at 3, and the two sit side by side in the panel.
    ///
    /// For rain totals, a RUNNING TOTAL from the start of day 1 — through day
    /// 1, 2, 3, 5 or 7. Those are the accumulations WPC publishes; "how much by
    /// the weekend" is the question, and a day-4-only total is not one anyone
    /// asks.
    public var periods: [Int] {
        switch self {
        case .severeStorms, .excessiveRain: return [1, 2, 3]
        case .rainTotals:                   return [1, 2, 3, 5, 7]
        }
    }

    /// "Day 2", or for rain totals "Days 1–5" — WPC's own names for them.
    public func periodName(_ period: Int) -> String {
        switch self {
        case .severeStorms, .excessiveRain: return "Day \(period)"
        case .rainTotals: return period == 1 ? "Day 1" : "Days 1–\(period)"
        }
    }

    /// How often a fresh copy is worth asking for while it is on screen. The
    /// outlooks are small and reissued up to five times a day. A seven-day
    /// rain total is half a megabyte even simplified, and WPC updates it four
    /// times a day, so half an hour is already eager.
    public var refreshInterval: TimeInterval {
        switch self {
        case .severeStorms, .excessiveRain: return 10 * 60
        case .rainTotals:                   return 30 * 60
        }
    }

    /// Every category this product can draw, lowest first.
    public var categories: [OutlookCategory] {
        switch self {
        case .severeStorms:  return OutlookCategory.spc
        case .excessiveRain: return OutlookCategory.wpc
        case .rainTotals:    return OutlookCategory.rainTotals
        }
    }
}

// MARK: - Categories

/// An sRGB colour as 0xRRGGBB. Plain so WeatherKit stays free of UI types.
public struct OutlookColor: Equatable, Hashable, Sendable {
    public var rgb: UInt32
    public init(_ rgb: UInt32) { self.rgb = rgb }

    public init(red: Int, green: Int, blue: Int) {
        rgb = UInt32(red & 0xFF) << 16 | UInt32(green & 0xFF) << 8 | UInt32(blue & 0xFF)
    }

    public var red: Double   { Double((rgb >> 16) & 0xFF) / 255 }
    public var green: Double { Double((rgb >> 8) & 0xFF) / 255 }
    public var blue: Double  { Double(rgb & 0xFF) / 255 }

    /// "#DDAA00", as SPC's GeoJSON writes it. Nil for anything else, so a
    /// malformed colour falls back to the published one rather than to black.
    public init?(hex: String?) {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        rgb = value
    }
}

public struct OutlookCategory: Equatable, Hashable, Sendable, Identifiable {
    /// The issuing office's abbreviation: "SLGT".
    public let code: String
    /// "Slight".
    public let name: String
    /// The public 1–5 (SPC) or 1–4 (WPC) scale. SPC's general-thunderstorm area
    /// is 0: it is drawn, but it says no storm is expected to be severe.
    public let level: Int
    /// What the office says the category means, in its own terms.
    public let meaning: String
    /// The probability floor, where the office states one as the definition.
    public let threshold: String?
    public let fill: OutlookColor
    public let stroke: OutlookColor

    public var id: String { code }

    /// SPC's categories and published colours. The GeoJSON carries its own
    /// `fill` and `stroke`, which win when present; these are the fallback and
    /// the legend's source for categories not on today's map.
    public static let spc: [OutlookCategory] = [
        .init(code: "TSTM", name: "Thunderstorms", level: 0,
              meaning: "Thunderstorms, none expected to be severe", threshold: nil,
              fill: .init(0xC1E9C1), stroke: .init(0x55BB55)),
        .init(code: "MRGL", name: "Marginal", level: 1,
              meaning: "Isolated severe storms possible", threshold: nil,
              fill: .init(0x66A366), stroke: .init(0x005500)),
        .init(code: "SLGT", name: "Slight", level: 2,
              meaning: "Scattered severe storms possible", threshold: nil,
              fill: .init(0xFFE066), stroke: .init(0xDDAA00)),
        .init(code: "ENH", name: "Enhanced", level: 3,
              meaning: "Numerous severe storms possible", threshold: nil,
              fill: .init(0xFFA366), stroke: .init(0xFF6600)),
        .init(code: "MDT", name: "Moderate", level: 4,
              meaning: "Widespread severe storms likely", threshold: nil,
              fill: .init(0xE06666), stroke: .init(0xCD0000)),
        .init(code: "HIGH", name: "High", level: 5,
              meaning: "Widespread severe storms expected", threshold: nil,
              fill: .init(0xEE99EE), stroke: .init(0xFF00FF)),
    ]

    /// WPC's categories, in the colours NOAA's map service renders them with.
    /// Keyed by the service's `dn` field, which is the level.
    public static let wpc: [OutlookCategory] = [
        .init(code: "MRGL", name: "Marginal", level: 1,
              meaning: "Isolated flash floods possible", threshold: "5%",
              fill: .init(0x38A800), stroke: .init(0x00734C)),
        .init(code: "SLGT", name: "Slight", level: 2,
              meaning: "Scattered flash floods possible", threshold: "15%",
              fill: .init(0xFFFE00), stroke: .init(0xE69800)),
        .init(code: "MDT", name: "Moderate", level: 3,
              meaning: "Numerous flash floods likely", threshold: "40%",
              fill: .init(0xF50000), stroke: .init(0x8A0000)),
        .init(code: "HIGH", name: "High", level: 4,
              meaning: "Widespread flash floods expected", threshold: "70%",
              fill: .init(0xFF69C5), stroke: .init(0xFF00FF)),
    ]

    /// WPC's rain-total bands, in inches, with the colours NOAA's map service
    /// renders them in. Each band is its value UP TO the next one: the "1"
    /// polygon is where WPC forecasts at least an inch and less than 1.25.
    public static let rainTotals: [OutlookCategory] = {
        let bands: [(inches: Double, color: (Int, Int, Int))] = [
            (0.01, (127, 255, 0)), (0.1, (0, 255, 0)), (0.25, (8, 139, 0)),
            (0.5, (16, 78, 139)), (0.75, (30, 144, 255)), (1, (0, 178, 238)),
            (1.25, (0, 238, 238)), (1.5, (137, 104, 205)), (1.75, (145, 44, 238)),
            (2, (139, 0, 139)), (2.5, (139, 0, 0)), (3, (255, 0, 0)),
            (4, (238, 64, 0)), (5, (255, 127, 0)), (7, (206, 133, 0)),
            (10, (255, 215, 0)), (15, (255, 255, 0)), (20, (255, 192, 183)),
        ]
        return bands.enumerated().map { index, band in
            let next = index + 1 < bands.count ? bands[index + 1].inches : nil
            let name = next.map { "\(inchesLabel(band.inches))–\(inchesLabel($0)) in" }
                ?? "\(inchesLabel(band.inches))+ in"
            let color = OutlookColor(red: band.color.0, green: band.color.1, blue: band.color.2)
            return OutlookCategory(code: inchesLabel(band.inches), name: name, level: index + 1,
                                   meaning: "", threshold: nil, fill: color, stroke: color,
                                   inches: band.inches)
        }
    }()

    /// "0.25", "1", "1.5" — no trailing zeros, which is how WPC labels them.
    public static func inchesLabel(_ inches: Double) -> String {
        inches == inches.rounded() ? String(Int(inches)) : String(format: "%g", inches)
    }

    /// The band's floor, for rain totals only.
    public let inches: Double?

    public init(code: String, name: String, level: Int, meaning: String, threshold: String?,
                fill: OutlookColor, stroke: OutlookColor, inches: Double? = nil) {
        self.code = code
        self.name = name
        self.level = level
        self.meaning = meaning
        self.threshold = threshold
        self.fill = fill
        self.stroke = stroke
        self.inches = inches
    }

    /// "Slight · level 2 of 5". SPC's thunderstorm area has no level to state,
    /// and a rain band is an amount, not a level of anything.
    public func scale(of product: OutlookProduct) -> String {
        if product == .rainTotals { return name }
        let top = product.categories.map(\.level).max() ?? level
        return level == 0 ? name : "\(name) · level \(level) of \(top)"
    }
}

// MARK: - An outlook

/// One drawn area, in the colours it arrived with.
public struct OutlookArea: Equatable, Sendable {
    public var category: OutlookCategory
    public var shape: GeoShape
    public var fill: OutlookColor
    public var stroke: OutlookColor

    public init(category: OutlookCategory, shape: GeoShape,
                fill: OutlookColor? = nil, stroke: OutlookColor? = nil) {
        self.category = category
        self.shape = shape
        self.fill = fill ?? category.fill
        self.stroke = stroke ?? category.stroke
    }
}

/// One product for one day, as issued.
public struct Outlook: Equatable, Sendable {
    public var product: OutlookProduct
    /// The day (outlooks) or the number of days totalled (rain totals). See
    /// `OutlookProduct.periods`.
    public var period: Int
    public var issued: Date?
    public var validFrom: Date?
    public var validUntil: Date?
    /// LOWEST CATEGORY FIRST, which is draw order: each higher risk is painted
    /// over the lower one it sits inside.
    public var areas: [OutlookArea]

    public init(product: OutlookProduct, period: Int, issued: Date? = nil,
                validFrom: Date? = nil, validUntil: Date? = nil, areas: [OutlookArea]) {
        self.product = product
        self.period = period
        self.issued = issued
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.areas = areas.sorted { $0.category.level < $1.category.level }
    }

    /// The highest category whose area contains the point, or nil when the
    /// point is outside every area the forecaster drew. Rain-total bands do not
    /// nest — each point is in exactly one — so for them this is simply the
    /// band you are in.
    public func category(at point: GeoPoint) -> OutlookCategory? {
        areas.last { $0.shape.contains(point) }?.category
    }

    /// The categories actually on this map, lowest first, once each.
    public var present: [OutlookCategory] {
        var seen = Set<String>()
        return areas.map(\.category).filter { seen.insert($0.code).inserted }
    }

    /// A day-1 outlook read after its window closed is yesterday's forecast.
    /// The offices replace them on schedule, so this only happens when fetching
    /// has been failing — and it is worth saying rather than drawing silently.
    public func isExpired(at now: Date = Date()) -> Bool {
        guard let validUntil else { return false }
        return validUntil <= now
    }
}

// MARK: - Severe weather, hazard by hazard

/// WHICH KIND OF SEVERE. The categorical outlook above folds three hazards into
/// one colour, and the three ask for different things of a person: hail puts
/// the car in the garage, a tornado means knowing where you would shelter,
/// damaging wind means the patio furniture. SPC draws each one's probability
/// separately for days 1 and 2; day 3 is published only as the three combined.
public enum SevereHazard: String, CaseIterable, Identifiable, Sendable {
    case tornado, hail, wind
    /// Day 3's only product: a tornado, 1-inch hail OR a 58 mph gust.
    case any

    public var id: String { rawValue }

    /// SPC's filename fragment: `day1otlk_torn.lyr.geojson`.
    var file: String {
        switch self {
        case .tornado: return "torn"
        case .hail:    return "hail"
        case .wind:    return "wind"
        case .any:     return "prob"
        }
    }

    public var label: String {
        switch self {
        case .tornado: return "Tornado"
        case .hail:    return "Hail"
        case .wind:    return "Damaging wind"
        case .any:     return "Any severe"
        }
    }

    /// The days SPC publishes this hazard for.
    public var days: [Int] { self == .any ? [3] : [1, 2] }
}

/// One hazard's probability areas for one day, as SPC drew them.
///
/// THE NUMBER IS THE CHANCE OF IT HAPPENING WITHIN 25 MILES OF A POINT, not at
/// the point. That is why the values look small — 5% hail is a real day to
/// garage the car — and why they are never shown as a raw percentage alone.
public struct SevereProbability: Equatable, Sendable {
    public struct Area: Equatable, Sendable {
        /// 0.02, 0.05, 0.15 …
        public var probability: Double
        public var shape: GeoShape
    }

    public var hazard: SevereHazard
    public var day: Int
    public var issued: Date?
    public var validFrom: Date?
    public var validUntil: Date?
    public var areas: [Area]

    public init(hazard: SevereHazard, day: Int, issued: Date? = nil,
                validFrom: Date? = nil, validUntil: Date? = nil, areas: [Area]) {
        self.hazard = hazard
        self.day = day
        self.issued = issued
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.areas = areas
    }

    /// The highest probability whose area contains the point. ZERO, not nil,
    /// outside every area: SPC drawing nothing over you is a statement — below
    /// its lowest contour — rather than a gap in what we know.
    public func probability(at point: GeoPoint) -> Double {
        areas.filter { $0.shape.contains(point) }.map(\.probability).max() ?? 0
    }
}

// MARK: - Decoding

public enum OutlookParser {
    public enum Failure: Error, LocalizedError {
        case unreadable(Error)
        case serviceError(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let error): return "Couldn't read the outlook: \(error.localizedDescription)"
            case .serviceError(let message): return "The map service said: \(message)"
            }
        }
    }

    /// SPC's `dayNotlk_cat.lyr.geojson`. Each feature is one category's whole
    /// extent — "layered", so a Slight area also lies inside the Marginal one
    /// around it — which is exactly what painting lowest-first wants.
    public static func spc(_ data: Data, period: Int) throws -> Outlook {
        struct Properties: Decodable {
            var LABEL: String?
            var VALID_ISO: String?
            var EXPIRE_ISO: String?
            var ISSUE_ISO: String?
            var fill: String?
            var stroke: String?
        }
        let features = try decode(Properties.self, from: data)
        var issued: Date?, from: Date?, until: Date?
        var areas: [OutlookArea] = []
        for feature in features {
            let p = feature.properties
            issued = issued ?? iso(p?.ISSUE_ISO)
            from = from ?? iso(p?.VALID_ISO)
            until = until ?? iso(p?.EXPIRE_ISO)
            // A category we do not know is not drawn: guessing its colour or
            // rank would put a made-up risk on the map.
            guard let label = p?.LABEL,
                  let category = OutlookCategory.spc.first(where: { $0.code == label }),
                  let shape = feature.geometry?.shape() else { continue }
            areas.append(OutlookArea(category: category, shape: shape,
                                     fill: OutlookColor(hex: p?.fill),
                                     stroke: OutlookColor(hex: p?.stroke)))
        }
        return Outlook(product: .severeStorms, period: period, issued: issued,
                       validFrom: from, validUntil: until, areas: areas)
    }

    /// SPC's `dayNotlk_{torn,hail,wind,prob}.lyr.geojson`. `LABEL` is the
    /// probability as a fraction ("0.05"); a quiet day arrives as one feature
    /// labelled "Less Than 5% All Areas" with no geometry, which parses to no
    /// areas rather than to a failure.
    public static func spcProbability(_ data: Data, hazard: SevereHazard, day: Int) throws -> SevereProbability {
        struct Properties: Decodable {
            var LABEL: String?
            var VALID_ISO: String?
            var EXPIRE_ISO: String?
            var ISSUE_ISO: String?
        }
        let features = try decode(Properties.self, from: data)
        var issued: Date?, from: Date?, until: Date?
        var areas: [SevereProbability.Area] = []
        for feature in features {
            let p = feature.properties
            issued = issued ?? iso(p?.ISSUE_ISO)
            from = from ?? iso(p?.VALID_ISO)
            until = until ?? iso(p?.EXPIRE_ISO)
            guard let label = p?.LABEL, let probability = Double(label), probability > 0,
                  let shape = feature.geometry?.shape() else { continue }
            areas.append(.init(probability: probability, shape: shape))
        }
        return SevereProbability(hazard: hazard, day: day, issued: issued,
                                 validFrom: from, validUntil: until, areas: areas)
    }

    /// WPC's Excessive Rainfall Outlook, as NOAA's ArcGIS vector service
    /// answers a `query?f=geojson`. Categories are keyed by `dn`, the level.
    ///
    /// UNLIKE SPC'S, THESE ARE NOT LAYERED. A Slight area can have a hole where
    /// a Moderate one sits, and the areas overlap in places — so a fill drawn
    /// translucent per polygon would stack into colours neither office chose.
    /// The map paints them as one group; see `OutlookRenderer`.
    public static func wpc(_ data: Data, period: Int) throws -> Outlook {
        struct Properties: Decodable {
            var dn: Int?
            var issue_time: String?
            var start_time: String?
            var end_time: String?
        }
        try rejectServiceError(data)
        let features = try decode(Properties.self, from: data)
        var issued: Date?, from: Date?, until: Date?
        var areas: [OutlookArea] = []
        for feature in features {
            let p = feature.properties
            issued = issued ?? wpcTime(p?.issue_time)
            from = from ?? wpcTime(p?.start_time)
            until = until ?? wpcTime(p?.end_time)
            guard let dn = p?.dn,
                  let category = OutlookCategory.wpc.first(where: { $0.level == dn }),
                  let shape = feature.geometry?.shape() else { continue }
            areas.append(OutlookArea(category: category, shape: shape))
        }
        return Outlook(product: .excessiveRain, period: period, issued: issued,
                       validFrom: from, validUntil: until, areas: areas)
    }

    /// WPC's forecast rain totals, from the same ArcGIS service. Each feature
    /// is one band, keyed by `qpf` — its floor in inches.
    ///
    /// THE BANDS DO NOT NEST. Where SPC's Slight lies inside its Marginal, a
    /// rain band has a hole wherever the next band up sits, so every point is
    /// in exactly one of them. Painting them lowest-first still gives the right
    /// picture, and even-odd filling keeps the holes open.
    public static func wpcRainTotals(_ data: Data, period: Int) throws -> Outlook {
        struct Properties: Decodable {
            var qpf: Double?
            var issue_time: String?
            var start_time: String?
            var end_time: String?
        }
        try rejectServiceError(data)
        let features = try decode(Properties.self, from: data)
        var issued: Date?, from: Date?, until: Date?
        var areas: [OutlookArea] = []
        for feature in features {
            let p = feature.properties
            issued = issued ?? wpcTime(p?.issue_time)
            from = from ?? wpcTime(p?.start_time)
            until = until ?? wpcTime(p?.end_time)
            // Matched by value, not by position, and with a tolerance: the
            // service writes 0.25 as a float, and a band it adds one day must
            // not be silently painted in its neighbour's colour.
            guard let inches = p?.qpf, inches > 0,
                  let category = OutlookCategory.rainTotals.first(where: {
                      abs(($0.inches ?? -1) - inches) < 0.001 }),
                  let shape = feature.geometry?.shape() else { continue }
            areas.append(OutlookArea(category: category, shape: shape))
        }
        return Outlook(product: .rainTotals, period: period, issued: issued,
                       validFrom: from, validUntil: until, areas: areas)
    }

    /// An ArcGIS error still comes back as HTTP 200, in a shape of its own.
    private static func rejectServiceError(_ data: Data) throws {
        struct ServiceError: Decodable {
            struct Body: Decodable { var message: String? }
            var error: Body
        }
        if let failure = try? JSONDecoder().decode(ServiceError.self, from: data) {
            throw Failure.serviceError(failure.error.message ?? "an error with no message")
        }
    }

    private struct Feature<P: Decodable>: Decodable {
        var geometry: GeoJSONGeometry?
        var properties: P?
    }

    private struct Collection<P: Decodable>: Decodable {
        var features: [Feature<P>]
    }

    private static func decode<P: Decodable>(_: P.Type, from data: Data) throws -> [Feature<P>] {
        do { return try JSONDecoder().decode(Collection<P>.self, from: data).features }
        catch { throw Failure.unreadable(error) }
    }

    private static func iso(_ s: String?) -> Date? {
        guard let s else { return nil }
        return HazardParser.iso.date(from: s)
    }

    /// "2026-09-29 15:30:00", in UTC — the service's own `valid_time` field
    /// spells the same window as "16Z 09/29/26 - 12Z 09/30/26".
    static let wpcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func wpcTime(_ s: String?) -> Date? {
        guard let s else { return nil }
        return wpcFormatter.date(from: s)
    }
}

// MARK: - Fetching

public struct OutlookClient: Sendable {
    private let session: URLSession
    private let contact: String

    public init(contact: String, session: URLSession = .shared) {
        self.contact = contact
        self.session = session
    }

    public enum Failure: Error, LocalizedError {
        case badResponse(issuer: String, status: Int)

        public var errorDescription: String? {
            switch self {
            case .badResponse(let issuer, let status):
                return "\(issuer)'s outlook returned HTTP \(status)."
            }
        }
    }

    public static func url(_ product: OutlookProduct, period: Int) -> URL {
        switch product {
        case .severeStorms:
            return URL(string: "https://www.spc.noaa.gov/products/outlook/day\(period)otlk_cat.lyr.geojson")!
        case .excessiveRain:
            // Layers 0–4 are days 1–5.
            return arcGISQuery("hazards/wpc_precip_hazards", layer: period - 1,
                               fields: "dn,issue_time,start_time,end_time")
        case .rainTotals:
            // Day 1 is the 24-hour layer; the longer totals are the service's
            // "Cumulative Precip Forecasts" group, 48 to 168 hours.
            let layer = [1: 1, 2: 8, 3: 9, 5: 10, 7: 11][period] ?? 1
            return arcGISQuery("precip/wpc_qpf", layer: layer,
                               fields: "qpf,issue_time,start_time,end_time",
                               // SIMPLIFIED BY THE SERVICE. At full detail a
                               // seven-day total is 25 MB and 600,000 points —
                               // contours traced around every hill. Allowing
                               // 0.02° (about 2 km) of deviation takes it to
                               // 600 KB over the wire, and 2 km is finer than
                               // WPC's own forecast grid, so nothing the
                               // forecast actually says is lost.
                               simplify: 0.02)
        }
    }

    private static func arcGISQuery(_ service: String, layer: Int, fields: String,
                                    simplify: Double? = nil) -> URL {
        var components = URLComponents(string:
            "https://mapservices.weather.noaa.gov/vector/rest/services/\(service)/MapServer/\(layer)/query")!
        components.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            URLQueryItem(name: "outFields", value: fields),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "f", value: "geojson"),
        ]
        if let simplify {
            components.queryItems! += [
                URLQueryItem(name: "outSR", value: "4326"),
                URLQueryItem(name: "maxAllowableOffset", value: String(simplify)),
                URLQueryItem(name: "geometryPrecision", value: "3"),
            ]
        }
        return components.url!
    }

    public static func url(_ hazard: SevereHazard, day: Int) -> URL {
        URL(string: "https://www.spc.noaa.gov/products/outlook/day\(day)otlk_\(hazard.file).lyr.geojson")!
    }

    public func outlook(_ product: OutlookProduct, period: Int) async throws -> Outlook {
        // Longer for rain totals, which are the size of a photo rather than
        // of a page.
        let data = try await fetch(Self.url(product, period: period), issuer: product.issuer,
                                   timeout: product == .rainTotals ? 60 : 20)
        switch product {
        case .severeStorms:  return try OutlookParser.spc(data, period: period)
        case .excessiveRain: return try OutlookParser.wpc(data, period: period)
        case .rainTotals:    return try OutlookParser.wpcRainTotals(data, period: period)
        }
    }

    public func severeProbability(_ hazard: SevereHazard, day: Int) async throws -> SevereProbability {
        let data = try await fetch(Self.url(hazard, day: day), issuer: "SPC", timeout: 20)
        return try OutlookParser.spcProbability(data, hazard: hazard, day: day)
    }

    private func fetch(_ url: URL, issuer: String, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("(Vane, \(contact))", forHTTPHeaderField: "User-Agent")
        // Reissued several times a day under the same URL; a cached copy is how
        // this morning's outlook would be shown as this afternoon's.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(issuer: issuer, status: http.statusCode)
        }
        return data
    }
}
