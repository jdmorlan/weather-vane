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
//  where the field has nothing to say. Radar learned this the expensive way (see
//  `RadarTileShading`); the others inherit it rather than repeat it.
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

// MARK: - Radar

/// NEXRAD base reflectivity, the loop this whole substrate was built for.
public struct RadarFieldSource: FieldTileSource {
    public var curve: RadarTileShading.Curve

    /// The curve is IN THE ID because it is in the pixels. Two curves sharing an
    /// id would mean changing the shading silently kept showing the old one until
    /// the cache turned over.
    public var id: String { "nexrad-n0q-\(curve.floor)-\(curve.solid)-\(curve.minAlpha)-\(curve.maxAlpha)" }

    /// CLAMPED AT 8, AND THE MEASUREMENT IS THE WHOLE ARGUMENT.
    ///
    /// This was 10, on the reasoning that 76 m per pixel against a roughly 1 km
    /// composite was already generous. It was generous by two more levels than
    /// that, and the cost was not theoretical — tiles go up fourfold per level, so
    /// a ten-frame loop over a laptop viewport was 300 requests.
    ///
    /// Measured against IEM, same scan, each level upscaled nearest to the same
    /// ground and compared against a z11 render:
    ///
    ///     z10   23.6% of pixels differ      z9   3.2%      z8   4.8%      z7   9.8%
    ///
    /// z10 differs from z11 MORE than z9 does, which is the giveaway: past z9 the
    /// service is not resolving anything, it is resampling, and two renders of the
    /// same 1 km cells disagree with each other. Side by side, z8 through z11 are
    /// the same picture — same cells, same edges, same colours.
    ///
    /// What the two levels bought, measured on the same viewport:
    ///
    ///     z10   300 requests, 17.0 s        z8   40 requests, 2.6 s
    ///
    /// Seventeen seconds of a frozen loop for pixels nobody can tell apart. The
    /// clamp scales the nearest level up rather than blanking — see
    /// `Radar.tileURL` for why MapKit's own min/max zoom could not do this — so
    /// zooming past it shows the 1 km bins as 1 km bins, which is what the radar
    /// actually measured.
    public var zoomRange: ClosedRange<Int> { 3...8 }
    public var tileSize: Int { Radar.tileSize }

    public init(curve: RadarTileShading.Curve = .standard) { self.curve = curve }

    public func url(stamp: String, z: Int, x: Int, y: Int) -> URL? {
        Radar.tileURL(stamp: stamp, z: z, x: x, y: y, size: tileSize)
    }

    public func process(_ data: Data) -> CGImage? {
        RadarTileShading.shadeImage(data, curve: curve)
    }
}

// MARK: - Satellite cloud

/// GOES-East ABI, from the same Iowa State mesonet that serves the radar.
///
/// NOT A LOOP, AND THE SERVICE IS WHY. The NEXRAD endpoint is time-enabled — you
/// name a five-minute valid time and it renders that scan, which is what lets the
/// radar be scrubbed back fifty minutes. `goes_east.cgi` publishes no TIME
/// dimension at all: it renders the latest imagery and nothing else. So this is a
/// layer showing NOW, refreshed on the ABI cadence, and the app does not offer a
/// timeline it cannot honour.
public struct SatelliteFieldSource: FieldTileSource {

    /// Which ABI channel, named by what it shows rather than its number.
    public enum Band: String, CaseIterable, Sendable, Identifiable {
        /// 10.3 µm clean longwave IR. Cloud tops day and night, and the coldest
        /// tops are the tallest storms. The default because it is the only one
        /// that works at 3am.
        case infrared
        /// 0.64 µm red visible. The sharpest cloud picture there is — and blank
        /// after sunset, which the UI has to say out loud rather than show as
        /// clear sky.
        case visible
        /// 6.9 µm mid-level water vapour. Not clouds: MOISTURE, which is how you
        /// see the trough that the 500 mb chart draws as contours.
        case waterVapor

        public var id: String { rawValue }

        var layer: String {
            switch self {
            case .infrared:   return "conus_ch13"
            case .visible:    return "conus_ch02"
            case .waterVapor: return "conus_ch09"
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
    public var curve: Curve

    /// How brightness becomes opacity, per band.
    ///
    /// ONE CURVE CANNOT SERVE THREE BANDS, and trying it is why the water-vapour
    /// layer first shipped invisible. The bands do not share a brightness scale:
    /// measured over six tiles spread across Texas and its surroundings, the
    /// middle of each band's distribution sits somewhere completely different.
    ///
    ///                p1     p25    p50    p90    p99
    ///     ch13 IR   .012   .118   .392   .552   .906
    ///     ch09 WV   .087   .125   .165   .342   .796
    ///     ch02 VIS  .173   .239   .290   .459   .612
    ///
    /// A floor of .10 with a solid of .62 — the single curve that was here first —
    /// is roughly right for IR, puts the whole useful half of WV under 10%
    /// opacity, and does not clear the ground in VIS at all.
    public struct Curve: Equatable, Sendable {
        /// Brightness below which a pixel is dropped entirely.
        public var floor: Float
        /// Brightness at and above which it is drawn at full strength.
        public var solid: Float
        /// Ceiling, so even a thunderstorm top lets a little of the map through —
        /// satellite you cannot see the ground under is satellite you cannot
        /// locate.
        public var maxAlpha: Float

        public init(floor: Float, solid: Float, maxAlpha: Float) {
            self.floor = floor; self.solid = solid; self.maxAlpha = maxAlpha
        }
    }

    public static func curve(for band: Band) -> Curve {
        switch band {
        // Warm ground is the dark quarter of the scale and cold tops run past .9,
        // so the floor sits above p25 and the solid point is reachable by a real
        // thunderstorm rather than by nothing at all.
        case .infrared:   return Curve(floor: 0.16, solid: 0.75, maxAlpha: 0.85)
        // NOT A CLOUD MASK. Water vapour is a field with a value everywhere — the
        // dry slot behind a trough is as much of a reading as the moist plume
        // ahead of it — so the floor only clears the very bottom and the whole
        // band is drawn. Held further back than the others because it is context
        // under the radar, not the subject.
        case .waterVapor: return Curve(floor: 0.09, solid: 0.48, maxAlpha: 0.72)
        // Sunlit LAND is bright in the visible, which is exactly what makes this
        // band hard to overlay: the floor has to clear ground that is genuinely
        // well up the scale, so only the brighter cloud survives.
        case .visible:    return Curve(floor: 0.30, solid: 0.62, maxAlpha: 0.90)
        }
    }

    public var id: String { "goes-east-\(band.layer)-\(curve.floor)-\(curve.solid)-\(curve.maxAlpha)" }
    public var zoomRange: ClosedRange<Int> { 3...9 }

    public init(band: Band = .infrared) {
        self.band = band
        self.curve = Self.curve(for: band)
    }

    public init(band: Band, curve: Curve) {
        self.band = band
        self.curve = curve
    }

    public static let host = "https://mesonet.agron.iastate.edu"
    public static let credit = "GOES-East ABI · NOAA via Iowa State Mesonet"

    /// The ABI CONUS sector refreshes every five minutes. The stamp is a bucket
    /// rather than a real valid time — the service has no TIME argument, so this
    /// is only here to stop a cached tile being shown for an hour.
    public static func currentStamp(_ now: Date = Date()) -> String {
        String(Int(now.timeIntervalSince1970) / 300)
    }

    public func url(stamp: String, z: Int, x: Int, y: Int) -> URL? {
        var components = URLComponents(string: "\(Self.host)/cgi-bin/wms/goes_east.cgi")
        components?.queryItems = [
            .init(name: "SERVICE", value: "WMS"),
            .init(name: "VERSION", value: "1.1.1"),
            .init(name: "REQUEST", value: "GetMap"),
            .init(name: "LAYERS", value: band.layer),
            .init(name: "SRS", value: "EPSG:3857"),
            .init(name: "BBOX", value: Radar.tileBBox(z: z, x: x, y: y)),
            .init(name: "WIDTH", value: "\(tileSize)"),
            .init(name: "HEIGHT", value: "\(tileSize)"),
            .init(name: "FORMAT", value: "image/png"),
            .init(name: "TRANSPARENT", value: "TRUE"),
            // Not a TIME argument — the service has none. This only keeps the
            // bucket in the URL so a new bucket is a new request.
            .init(name: "_", value: stamp),
        ]
        return components?.url
    }

    /// BRIGHTNESS BECOMES OPACITY. The service hands back an opaque greyscale
    /// image where dark is warm ground and bright is a cold cloud top. Drawn as
    /// it arrives it is a lid over the entire map; mapped through this curve the
    /// ground falls away and only the cloud is left.
    ///
    /// The COLOUR is kept rather than forced to white: the cold end of the
    /// enhancement is tinted, and that tint is the part that says "this top is
    /// high enough to matter".
    public func process(_ data: Data) -> CGImage? {
        FieldPixels.map(data) { r, g, b, _ in
            // Rec. 601 luma — the service's own enhancement is built on it, so
            // matching it keeps the tinted cold end where the eye expects.
            let luma = (0.299 * Float(r) + 0.587 * Float(g) + 0.114 * Float(b)) / 255
            guard luma >= curve.floor else { return nil }
            let t = min(1, (luma - curve.floor) / max(0.0001, curve.solid - curve.floor))
            return (r, g, b, t * t * (3 - 2 * t) * curve.maxAlpha)
        }
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
    /// `Radar.tileBBox` exists to prevent, and just as quiet.
    public func url(stamp: String, z: Int, x: Int, y: Int) -> URL? {
        var components = URLComponents(string: "\(Self.host)/\(product.service)/MapServer/export")
        components?.queryItems = [
            .init(name: "bbox", value: Radar.tileBBox(z: z, x: x, y: y)),
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
/// One buffer walk shared by every source that is not radar. Radar keeps its own
/// in `RadarTileShading` because it memoises a colour-to-ramp lookup that only
/// makes sense against a known legend.
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
