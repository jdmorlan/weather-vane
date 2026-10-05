//
//  FieldSources.swift  (WeatherKit)
//
//  The actual fields, each one a `FieldTileSource`: where its tiles come from and
//  what its pixels mean.
//
//  ALL OF THEM SHADE, AND FOR THE SAME REASON. Every service here hands back a
//  finished picture meant to be looked at ON ITS OWN — opaque, edge to edge, its
//  own idea of a background. Dropped straight onto a map that is the end of the
//  map: the roads that say WHERE the weather is disappear underneath it. So each
//  source turns its own quantity into an alpha, and the map keeps showing through
//  where the field has nothing to say.
//
//  WHAT IS DELIBERATELY NOT HERE. The 500 mb flow is not a raster field — it is a
//  height grid that becomes contours and barbs, and `UpperAirFlow` already
//  computes them. Forcing it through a tile source to reuse this file would mean
//  rendering vectors to PNG somewhere just to decode them again. It gets its own
//  renderer.
//

import Foundation
import CoreGraphics
import ImageIO

// MARK: - Satellite

/// GOES-East and GOES-West ABI imagery, from NOAA's nowCOAST, as a loop.
///
/// WHAT THIS REPLACED. Iowa State's `goes_east.cgi`, which served the newest
/// image only — no TIME dimension, so the cloud view was a still — and served
/// it already coloured, which this file then turned back into opacity by
/// brightness. For water vapour that was backwards: the enhancement paints moist
/// air blue, blue is dark by luma, so the moisture — the thing the band exists to
/// show — was the part that faded out, and the dry slots were drawn solid yellow.
///
/// WHY nowCOAST. It publishes each band as a WMS layer WITH a time dimension:
/// every five-minute scan for the last seven and a half hours, the newest about
/// four minutes after it was taken (measured 2026-09-30, 22:28Z listed at
/// 22:32Z). The tiles come as plain greyscale — a 256-entry grey palette — so
/// the colour is ours to choose, and chosen once, every frame of the loop shares
/// it. Composite of GOES-19 (East) and GOES-18 (West), so the Pacific trough
/// upstream is in the picture too.
///
/// GREY MEANS COLD in all three infrared-type bands: bright is a cold cloud top
/// or, in water vapour, moisture high enough to be cold. The tables below are
/// indexed by that grey.
public struct SatelliteFieldSource: FieldTileSource {

    /// Which ABI channel, named by what it shows rather than its number.
    public enum Band: String, CaseIterable, Sendable, Identifiable {
        /// Band 13, 10.3 µm clean longwave IR. Cloud tops day and night, and the
        /// coldest tops are the tallest storms. The default because it is the
        /// only one that works at 3am.
        case infrared
        /// Band 2, 0.64 µm red visible. The sharpest cloud picture there is — and
        /// blank after sunset, which the UI has to say out loud rather than show
        /// as clear sky.
        case visible
        /// Band 8, 6.2 µm upper-level water vapour. Not clouds: MOISTURE in the
        /// upper troposphere, which is how you see the trough that the 500 mb
        /// chart draws as contours — and, looped, how you watch it move.
        case waterVapor

        public var id: String { rawValue }

        var layer: String {
            switch self {
            case .infrared:   return "goes_longwave_imagery"
            case .visible:    return "goes_visible_imagery"
            case .waterVapor: return "goes_water_vapor_imagery"
            }
        }

        public var label: String {
            switch self {
            case .infrared:   return "Infrared"
            case .visible:    return "Visible"
            case .waterVapor: return "Water vapour"
            }
        }

        /// Visible imagery is night-blind. Stated as a property so the UI can say
        /// "dark until sunrise" instead of drawing an empty sky.
        public var isNightBlind: Bool { self == .visible }
    }

    public var band: Band

    /// Bump when a colour table changes, so cached tiles drawn with the old one
    /// are not handed back under the new name.
    private static let tableVersion = 1

    public var id: String { "nowcoast-\(band.layer)-v\(Self.tableVersion)" }
    /// The ABI's infrared bands are 2 km at best, and further from nadir over
    /// Texas; past z7 a tile pixel is finer than the scan. Visible is 0.5 km,
    /// which z9 still resolves.
    public var zoomRange: ClosedRange<Int> { band == .visible ? 3...9 : 3...7 }
    public var maxPixelScale: Double? { 1 }
    /// Where the tables draw at all, they draw at 0.8–0.9 — and water vapour
    /// draws everywhere, so a dissolve that dipped below that showed the map.
    public var dissolveOpacity: Double? { 0.85 }

    public init(band: Band = .infrared) {
        self.band = band
    }

    public static let host = "https://nowcoast.noaa.gov"
    public static let credit = "GOES-19 / GOES-18 ABI · NOAA nowCOAST"

    static let wms = "\(host)/geoserver/satellite/wms"

    /// The service's list of scans for every layer.
    public static let capabilitiesURL =
        URL(string: "\(wms)?service=WMS&request=GetCapabilities&version=1.3.0")!

    /// The stamp is the scan's own time, exactly as the capabilities list it.
    /// It is both the TIME argument and the cache key, so a scan fetched once is
    /// never fetched again.
    public func url(stamp: String, z: Int, x: Int, y: Int) -> URL? {
        var components = URLComponents(string: Self.wms)
        components?.queryItems = [
            .init(name: "service", value: "WMS"),
            .init(name: "version", value: "1.1.1"),
            .init(name: "request", value: "GetMap"),
            .init(name: "layers", value: band.layer),
            .init(name: "styles", value: ""),
            .init(name: "srs", value: "EPSG:3857"),
            .init(name: "bbox", value: FieldTileGrid.bbox3857(z: z, x: x, y: y)),
            .init(name: "width", value: "\(tileSize)"),
            .init(name: "height", value: "\(tileSize)"),
            .init(name: "format", value: "image/png"),
            .init(name: "transparent", value: "true"),
            .init(name: "time", value: stamp),
        ]
        return components?.url
    }

    public func process(_ data: Data) -> CGImage? {
        let table = Self.table(for: band)
        return FieldPixels.map(data) { r, _, _, _ in table[Int(r)] }
    }

    /// The colour and opacity for each grey level. Built once per band.
    public static func table(for band: Band) -> [(UInt8, UInt8, UInt8, Float)?] {
        switch band {
        case .waterVapor: return waterVaporTable
        case .infrared:   return infraredTable
        case .visible:    return visibleTable
        }
    }

    // MARK: Colour tables

    /// One stop: at this grey, this colour at this opacity.
    struct Stop {
        let grey: Int
        let r: Double, g: Double, b: Double
        let alpha: Double
        init(_ grey: Int, _ r: Double, _ g: Double, _ b: Double, _ alpha: Double) {
            self.grey = grey; self.r = r; self.g = g; self.b = b; self.alpha = alpha
        }
    }

    /// Linear between stops; a level whose opacity comes out zero is dropped.
    static func interpolate(_ stops: [Stop]) -> [(UInt8, UInt8, UInt8, Float)?] {
        (0...255).map { level in
            guard let hi = stops.firstIndex(where: { $0.grey >= level }) else { return nil }
            let b = stops[hi], a = stops[max(0, hi - 1)]
            let t = b.grey == a.grey ? 1 : Double(level - a.grey) / Double(b.grey - a.grey)
            let alpha = a.alpha + (b.alpha - a.alpha) * t
            guard alpha > 0.004 else { return nil }
            func mix(_ x: Double, _ y: Double) -> UInt8 { UInt8(max(0, min(255, (x + (y - x) * t).rounded()))) }
            return (mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b), Float(alpha))
        }
    }

    /// DRY IS BROWN, MOIST IS WHITE, STORMS ARE BLUE — the forecasters' own
    /// convention, and the reason their loops read at a glance. Over Texas on
    /// 2026-09-30 the grey sat at p10 5, p50 86, p90 126, p99 178, so the
    /// browns and oranges get the bottom fifth (the dry slots), greys and white
    /// the broad middle (the ordinary moist plume), and the blues and greens only
    /// the cold, deep moisture of convection above it.
    ///
    /// A FIELD, NOT A MASK. There is a value everywhere — the dry slot is as much
    /// a reading as the plume — so the whole range is drawn, at an opacity that
    /// still lets the county lines and the coast through.
    static let waterVaporTable = interpolate([
        Stop(0,    60,  28,   8, 0.82),
        Stop(20,  140,  62,  14, 0.82),
        Stop(45,  215, 125,  40, 0.82),
        Stop(65,  230, 185, 110, 0.82),
        Stop(85,  150, 140, 125, 0.80),
        Stop(105, 185, 190, 195, 0.80),
        Stop(125, 235, 238, 242, 0.82),
        Stop(150, 140, 185, 235, 0.85),
        Stop(180,  45, 105, 210, 0.88),
        Stop(205,  20,  55, 150, 0.90),
        Stop(222,  25, 140,  70, 0.90),
        Stop(240, 160, 225, 110, 0.90),
        Stop(255, 255, 255, 255, 0.90),
    ])

    /// Warm ground is dropped, cloud comes in grey to white, and past that the
    /// classic enhancement: blue, green, yellow, orange, red, magenta as the
    /// tops get colder — which is to say taller. The colour starts where the
    /// tops are cold enough to be convection; measured over Texas the same
    /// afternoon, cloud-free ground ran p50 83 and the storms' cores 225–240.
    static let infraredTable = interpolate([
        Stop(0,     0,   0,   0, 0),
        Stop(95,   90,  90,  90, 0),
        Stop(120, 150, 150, 150, 0.35),
        Stop(160, 220, 220, 220, 0.75),
        Stop(185, 255, 255, 255, 0.85),
        Stop(195, 120, 190, 255, 0.90),
        Stop(208,  30,  90, 220, 0.92),
        Stop(218,  40, 170,  70, 0.92),
        Stop(226, 250, 230,  60, 0.95),
        Stop(234, 245, 140,  30, 0.95),
        Stop(242, 215,  30,  30, 0.95),
        Stop(250, 160,  20, 160, 0.95),
        Stop(255, 255, 255, 255, 0.95),
    ])

    /// Brightness becomes white cloud. Sunlit land is well up the scale in the
    /// visible (p50 51, p90 113 that afternoon), so the floor clears it and only
    /// cloud brighter than the ground survives.
    static let visibleTable = interpolate([
        Stop(0,     0,   0,   0, 0),
        Stop(70,  200, 200, 200, 0),
        Stop(110, 225, 225, 225, 0.55),
        Stop(160, 245, 245, 245, 0.88),
        Stop(255, 255, 255, 255, 0.92),
    ])
}

// MARK: - Satellite, read at a point

/// What a band's grey MEANS, in words — for the key under the map and for the
/// one place on it a person most wants read for them: home.
///
/// The grey is the service's own, so these bands line up with the colour
/// tables above: each band's name starts where its table changes colour.
public struct SatelliteReading: Equatable, Sendable {
    public var grey: Int
    /// "Very dry high up", "Tall storm tops".
    public var name: String
    /// What that air is doing — the mechanism, not just the colour.
    public var meaning: String
}

extension SatelliteFieldSource.Band {

    /// The words for each stretch of grey, lowest first, starting at `from`.
    public var readings: [(from: Int, name: String, meaning: String)] {
        switch self {
        case .waterVapor:
            return [
                (0, "Very dry high up",
                 "Air sinking from high in the atmosphere, drying as it comes down. It holds the sky clear and keeps storms from building tall. This band doesn't see near the ground, so it can still be humid at the surface."),
                (45, "Dry high up",
                 "Drier air aloft. Sinking air is winning here, and high cloud is scarce."),
                (85, "Some moisture high up",
                 "The ordinary moist plume of the upper air. High, thin cloud is possible; nothing is being pushed upward hard."),
                (150, "Deep moisture",
                 "Moisture lifted high, which means air is rising. Rising air is where clouds and storms form."),
                (205, "Storm tops",
                 "Tops of tall storms, cold enough to be near the top of the weather."),
            ]
        case .infrared:
            return [
                (0, "Clear, or low cloud only",
                 "Nothing cold overhead. Infrared sees the warm ground, or low cloud too warm to tell apart from it."),
                (120, "Cloud",
                 "Cloud tops colder than the ground, at middle heights."),
                (185, "High, cold cloud",
                 "Cloud tops high enough to be well below freezing: thick cirrus, or the anvil of a storm."),
                (208, "Tall storm tops",
                 "The coldest tops are the tallest storms. The colder, the stronger the updraft holding them up."),
            ]
        case .visible:
            return [
                (0, "Clear",
                 "Sunlit ground with no cloud brighter than it."),
                (110, "Cloud",
                 "Sunlight reflected off cloud."),
                (160, "Thick cloud",
                 "Bright, thick cloud: deep enough to reflect most of the sunlight."),
            ]
        }
    }

    /// The reading for a grey level.
    public func reading(grey: Int) -> SatelliteReading {
        let band = readings.last { grey >= $0.from } ?? readings[0]
        return SatelliteReading(grey: grey, name: band.name, meaning: band.meaning)
    }
}

extension SatelliteFieldSource {

    /// The key's colours: the band's table sampled evenly across its greys,
    /// from 0 to 1. Levels the table drops come back clear, as on the map.
    public func legendStops(count: Int = 32) -> [(location: Double, r: UInt8, g: UInt8, b: UInt8, alpha: Float)] {
        let table = Self.table(for: band)
        return (0..<count).map { i in
            let location = Double(i) / Double(count - 1)
            let entry = table[Int((location * 255).rounded())]
            return (location, entry?.0 ?? 0, entry?.1 ?? 0, entry?.2 ?? 0, entry?.3 ?? 0)
        }
    }

    /// A tiny picture of one scan centred on a point — a few pixels about
    /// two kilometres wide, about the scan's own resolution — so the grey
    /// at home can be read without a tile's worth of download.
    public func pointURL(stamp: String, latitude: Double, longitude: Double) -> URL? {
        let r = 6_378_137.0
        let x = r * longitude * .pi / 180
        let y = r * log(tan(.pi / 4 + latitude * .pi / 360))
        let half = 3_000.0
        var components = URLComponents(string: Self.wms)
        components?.queryItems = [
            .init(name: "service", value: "WMS"),
            .init(name: "version", value: "1.1.1"),
            .init(name: "request", value: "GetMap"),
            .init(name: "layers", value: band.layer),
            .init(name: "styles", value: ""),
            .init(name: "srs", value: "EPSG:3857"),
            .init(name: "bbox", value: [x - half, y - half, x + half, y + half]
                .map { String(format: "%.1f", $0) }.joined(separator: ",")),
            .init(name: "width", value: "3"),
            .init(name: "height", value: "3"),
            .init(name: "format", value: "image/png"),
            .init(name: "transparent", value: "true"),
            .init(name: "time", value: stamp),
        ]
        return components?.url
    }

    /// The grey at the middle of a picture from `pointURL`; nil where the
    /// scan has nothing (transparent) or the picture won't decode.
    public static func centreGrey(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else { return nil }
        // Drawn into a one-pixel buffer we define, offset so the image's
        // middle pixel is the one that lands in it.
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: -(image.width / 2), y: -(image.height / 2),
                                           width: image.width, height: image.height))
            return true
        }
        let alpha = pixel[3]
        guard drawn, alpha > 0 else { return nil }
        return min(255, Int(pixel[0]) * 255 / Int(alpha))
    }

    /// The grey at a point in one scan. One request of a few hundred bytes.
    public func grey(stamp: String, latitude: Double, longitude: Double) async -> Int? {
        guard let url = pointURL(stamp: stamp, latitude: latitude, longitude: longitude),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        return Self.centreGrey(data)
    }
}

// MARK: - Satellite scans

/// Which scans exist for a band, from nowCOAST's capabilities document.
public enum SatelliteScans {

    /// Every time listed for `layer`, oldest first.
    ///
    /// The time dimension is written as a comma list of instants; WMS also
    /// allows `start/end/period`, which is read too in case the service switches
    /// to it, since a period is how a five-minute series is usually written.
    public static func times(in capabilities: String, layer: String) -> [Date] {
        guard let name = capabilities.range(of: "<Name>\(layer)</Name>") else { return [] }
        let rest = capabilities[name.upperBound...]
        // The NEXT layer's dimension must not be read as this one's.
        let end = rest.range(of: "</Layer>")?.lowerBound ?? rest.endIndex
        let scope = rest[..<end]
        guard let tag = scope.range(of: "<Dimension name=\"time\""),
              let open = scope[tag.upperBound...].firstIndex(of: ">"),
              let close = scope[open...].range(of: "</Dimension>") else { return [] }
        let body = scope[scope.index(after: open)..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var out: [Date] = []
        for item in body.split(separator: ",") {
            let parts = item.split(separator: "/")
            if parts.count == 3, let start = date(parts[0]), let stop = date(parts[1]),
               let step = seconds(String(parts[2])), step > 0 {
                var t = start
                while t <= stop { out.append(t); t += step }
            } else if let t = date(item) {
                out.append(t)
            }
        }
        return out.sorted()
    }

    /// The loop's frames: the newest scan, and scans back from it no closer
    /// together than `spacing`, reaching back `span`.
    ///
    /// TEN MINUTES APART OVER THREE HOURS, and both numbers are the point. Water
    /// vapour is read for motion on the scale of a trough — a jet streak or a dry
    /// slot moves a county or two an hour — so an hour of loop barely shows it
    /// moving, and three does. Every scan at five minutes over that span is 36
    /// frames of tiles for motion the dissolve smooths out anyway; eighteen is
    /// the same motion at half the downloads.
    public static func frames(from times: [Date], span: TimeInterval = 3 * 3600,
                              spacing: TimeInterval = 600) -> [Date] {
        guard let newest = times.last else { return [] }
        var picked: [Date] = [newest]
        for t in times.reversed().dropFirst() {
            guard newest.timeIntervalSince(t) <= span else { break }
            // A little slack, so a scan that landed at 9:59 still counts as ten
            // minutes on.
            if picked.last!.timeIntervalSince(t) >= spacing - 30 { picked.append(t) }
        }
        return picked.reversed()
    }

    /// The stamp for a scan: its time as the capabilities write it, which is
    /// also what the TIME argument wants.
    public static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private static func date(_ s: Substring) -> Date? {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    /// `PT5M`, `PT1H`, `PT30S` — the only shapes a scan period takes.
    private static func seconds(_ period: String) -> TimeInterval? {
        guard period.hasPrefix("PT") else { return nil }
        var total: TimeInterval = 0, number = ""
        for ch in period.dropFirst(2) {
            if ch.isNumber || ch == "." { number.append(ch); continue }
            guard let n = Double(number) else { return nil }
            switch ch {
            case "H": total += n * 3600
            case "M": total += n * 60
            case "S": total += n
            default: return nil
            }
            number = ""
        }
        return total
    }
}

// MARK: - Fire

/// Texas A&M Forest Service, via their ArcGIS map services.
///
/// TEXAS ONLY, AND THAT IS THE POINT rather than a limitation to apologise for.
/// The national fire-weather grids say what the atmosphere is doing; a burn ban
/// is what the county has actually DECIDED, and there is no national source for
/// that because it is not a national fact.
public struct TexasFireFieldSource: FieldTileSource {

    public enum Product: String, CaseIterable, Sendable, Identifiable {
        /// County-level burn bans — the operative fact for anyone with land.
        case burnBan
        /// Fires the state is currently working.
        case activeFires

        public var id: String { rawValue }

        var service: String {
            switch self {
            case .burnBan:     return "EOC/BurnBan"
            case .activeFires: return "EOC/TAMSFires_Public"
            }
        }

        public var label: String {
            switch self {
            case .burnBan:     return "Burn bans"
            case .activeFires: return "Active fires"
            }
        }
    }

    public var product: Product
    public var alpha: Float

    /// HOW MUCH OF THE SCREEN THE PRODUCT COVERS IS THE WHOLE ARGUMENT, and it is
    /// the same rule radar and satellite already follow: a layer you cannot see
    /// the ground under is a layer you cannot locate.
    ///
    /// A burn ban is a whole-county fill and most of Texas is usually under one —
    /// measured live, 74% of a state-sized tile. At the 0.55 this shipped with,
    /// that is a red sheet: the county lines and town names you need in order to
    /// tell WHICH counties are banned are the exact thing it paints over, so the
    /// layer covers up its own subject.
    ///
    /// Active fires are the opposite — a handful of small marks on an otherwise
    /// empty tile, 2.8% of the same area. Those have to be nearly solid or they
    /// are not legible at all. One number could not have served both.
    public static func alpha(for product: Product) -> Float {
        switch product {
        case .burnBan:     return 0.32
        case .activeFires: return 0.95
        }
    }

    public var id: String { "tfs-\(product.rawValue)-\(alpha)" }
    public var zoomRange: ClosedRange<Int> { 3...10 }

    public init(product: Product = .burnBan) {
        self.product = product
        self.alpha = Self.alpha(for: product)
    }

    public init(product: Product, alpha: Float) {
        self.product = product; self.alpha = alpha
    }

    public static let host = "https://gis.tfs.tamu.edu/arcgis/rest/services"
    public static let credit = "Texas A&M Forest Service"

    /// A burn ban is a county commissioners' order, not an observation — it
    /// changes on the scale of a meeting, so an hourly bucket is already eager.
    public static func currentStamp(_ now: Date = Date()) -> String {
        String(Int(now.timeIntervalSince1970) / 3600)
    }

    /// ArcGIS `export`, NOT a WMS GetMap. Same idea, different spelling: a
    /// bounding box and a pixel size in, a rendered image out. `bboxSR` and
    /// `imageSR` both have to be named or the service answers in the service's
    /// own projection and the result lands in the wrong place — the same failure
    /// `FieldTileGrid.bbox3857` exists to prevent, and just as quiet.
    public func url(stamp: String, z: Int, x: Int, y: Int) -> URL? {
        var components = URLComponents(string: "\(Self.host)/\(product.service)/MapServer/export")
        components?.queryItems = [
            .init(name: "bbox", value: FieldTileGrid.bbox3857(z: z, x: x, y: y)),
            .init(name: "bboxSR", value: "3857"),
            .init(name: "imageSR", value: "3857"),
            .init(name: "size", value: "\(tileSize),\(tileSize)"),
            .init(name: "format", value: "png32"),
            .init(name: "transparent", value: "true"),
            .init(name: "f", value: "image"),
            .init(name: "_", value: stamp),
        ]
        return components?.url
    }

    /// Only a flat knock-down. The service's own symbology already carries the
    /// meaning — a county is banned or it is not, and there is no intensity to
    /// recover the way there is in a reflectivity ramp. Inventing a gradient here
    /// would be drawing a distinction the data does not make.
    public func process(_ data: Data) -> CGImage? {
        FieldPixels.map(data) { r, g, b, a in
            guard a > 0 else { return nil }
            return (r, g, b, Float(a) / 255 * alpha)
        }
    }
}

// MARK: - Pixel plumbing

/// Decode a tile, rewrite every pixel, hand back an image.
///
/// One buffer walk shared by every fetched source. Radar is not one: its tiles
/// are drawn from measurements, not recoloured from pictures.
public enum FieldPixels {

    /// `transform` returns the new colour and alpha (alpha 0...1), or nil to drop
    /// the pixel entirely. It is handed UN-premultiplied colour.
    public static func map(_ data: Data,
                           _ transform: (UInt8, UInt8, UInt8, UInt8) -> (UInt8, UInt8, UInt8, Float)?) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        // ONE SCOPE, DELIBERATELY. The context is built over this array's storage,
        // so `pixels` must not be copied or reassigned between here and
        // `makeImage()` — a `var (pixels, context) = decode(...)` helper reads
        // beautifully and hands the context a buffer the copy no longer owns.
        // Decoded into a buffer WE define rather than read out of the PNG, so
        // byte order and alpha handling are known rather than whatever the file
        // happened to carry.
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = pixels.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(data: buffer.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for index in stride(from: 0, to: buffer.count, by: 4) {
                let a = base[index + 3]
                guard a != 0 else { continue }

                // The context is premultiplied, so undo it before the transform
                // sees a colour — otherwise a half-transparent pixel is handed a
                // darkened version of itself.
                var r = base[index], g = base[index + 1], b = base[index + 2]
                if a < 255 {
                    let scale = 255.0 / Float(a)
                    r = UInt8(min(255, Float(r) * scale))
                    g = UInt8(min(255, Float(g) * scale))
                    b = UInt8(min(255, Float(b) * scale))
                }

                guard let (nr, ng, nb, alpha) = transform(r, g, b, a), alpha > 0 else {
                    base[index] = 0; base[index + 1] = 0
                    base[index + 2] = 0; base[index + 3] = 0
                    continue
                }
                let clamped = max(0, min(1, alpha))
                base[index]     = UInt8(Float(nr) * clamped)
                base[index + 1] = UInt8(Float(ng) * clamped)
                base[index + 2] = UInt8(Float(nb) * clamped)
                base[index + 3] = UInt8(clamped * 255)
            }
        }
        return context.makeImage()
    }
}
