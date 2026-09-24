//
//  Level2Render.swift  (WeatherKit)
//
//  Turning a sweep into map tiles: where each pixel is as seen from the radar,
//  what the radar measured there, and what colour that is.
//
//  WORKING BACKWARDS, PIXEL BY PIXEL. The obvious way to draw polar data is to
//  push each gate out as a little wedge and paint it. That draws the radar's
//  grid — blocky bins, visible at every zoom, the "Level II look" apps spend a
//  lot of effort hiding. This goes the other way: for every pixel in a tile, ask
//  what bearing and range from the site it is, and read the sweep there with
//  bilinear interpolation between the four surrounding gates. The result is
//  smooth at any zoom and exact where it counts, and it slots straight into the
//  same tile machinery the satellite and fire fields use — `FieldTileStore`
//  caches it, the loop dissolves it, and the map never knows the difference.
//
//  SHARPER AS YOU ZOOM. The old national mosaic stopped resolving anything past
//  z9 because it was a 1 km grid. A 250 m gate is four times finer, and near the
//  radar the 0.5° beam is narrower still, so tiles are worth drawing down to
//  neighbourhood scale.
//

import Foundation
import CoreGraphics
import ImageIO

// MARK: - Geometry

public enum RadarGeometry {
    static let earthRadius = 6_371_000.0
    /// The standard 4/3-Earth model. The beam bends toward the ground as it
    /// crosses denser air, and treating the Earth as a third bigger turns that
    /// curved beam back into a straight line.
    static let effectiveRadius = earthRadius * 4 / 3

    /// Distance (metres) and initial bearing (degrees from north) along the
    /// surface from one point to another.
    public static func groundPath(fromLatitude lat1: Double, longitude lon1: Double,
                                  toLatitude lat2: Double, longitude lon2: Double)
        -> (distance: Double, bearing: Double) {
        let φ1 = lat1 * .pi / 180, φ2 = lat2 * .pi / 180
        let Δφ = φ2 - φ1, Δλ = (lon2 - lon1) * .pi / 180
        let a = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        let distance = 2 * earthRadius * asin(min(1, sqrt(a)))
        var bearing = atan2(sin(Δλ) * cos(φ2), cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return (distance, bearing)
    }

    /// The point `distance` metres from a start along an initial `bearing`
    /// (degrees from north). What turns "the beam is at 213°" into a line on a map.
    public static func destination(fromLatitude lat: Double, longitude lon: Double,
                                   bearing: Double, distance: Double) -> (latitude: Double, longitude: Double) {
        let φ1 = lat * .pi / 180, λ1 = lon * .pi / 180
        let θ = bearing * .pi / 180, δ = distance / earthRadius
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return (φ2 * 180 / .pi, λ2 * 180 / .pi)
    }

    /// The range ALONG THE BEAM at which a beam tilted `elevation` degrees is
    /// over a point `ground` metres away.
    ///
    /// Not the same as the ground distance, and the gap is what puts a storm in
    /// the wrong town if it is ignored: the beam climbs, so the gate over a point
    /// is further out than the point is.
    public static func slantRange(ground: Double, elevation: Double) -> Double {
        let θ = ground / effectiveRadius
        let e = elevation * .pi / 180
        return effectiveRadius * sin(θ) / cos(θ + e)
    }

    /// The inverse of `slantRange`: how far along the ground a point on the beam
    /// `slant` metres out lies.
    public static func groundRange(slant r: Double, elevation: Double) -> Double {
        let e = elevation * .pi / 180
        let R = effectiveRadius
        return R * atan(r * cos(e) / (R + r * sin(e)))
    }

    /// How high the beam centre is above the radar at a given slant range,
    /// metres. What a sentence like "the beam is 3 km up by then" is built from.
    public static func beamHeight(slantRange r: Double, elevation: Double) -> Double {
        let e = elevation * .pi / 180
        let R = effectiveRadius
        return sqrt(r * r + R * R + 2 * r * R * sin(e)) - R
    }
}

// MARK: - Colour

/// Reflectivity in dBZ to colour and opacity.
///
/// REAL dBZ, SO THE LEGEND CAN SAY NUMBERS. The stops sit on the values
/// forecasters actually use:
///
///     20 dBZ  light rain begins to reach the ground
///     35      moderate rain; where the palette turns warm
///     50      heavy rain, and the start of the range where hail is possible
///     60+     hail almost certainly; drawn in magenta so it cannot be missed
///
/// OPACITY RISES WITH INTENSITY: the map under light returns is information, and
/// a drizzle pixel as solid as a hail core hides it for nothing.
public struct ReflectivityPalette: Sendable, Equatable {
    public struct Stop: Sendable, Equatable {
        public let dBZ: Float
        public let r: Float, g: Float, b: Float, a: Float
    }
    public let stops: [Stop]

    /// Anything below this is not drawn. Clear-air returns — insects, dust,
    /// refractive turbulence — live under it.
    public var floor: Float { stops.first?.dBZ ?? 0 }

    public static let standard = ReflectivityPalette(stops: [
        .init(dBZ: 5, r: 0.40, g: 0.55, b: 0.65, a: 0.00),
        .init(dBZ: 12, r: 0.33, g: 0.62, b: 0.72, a: 0.35),
        .init(dBZ: 20, r: 0.22, g: 0.72, b: 0.42, a: 0.62),
        .init(dBZ: 28, r: 0.10, g: 0.56, b: 0.20, a: 0.78),
        .init(dBZ: 34, r: 0.05, g: 0.42, b: 0.12, a: 0.84),
        .init(dBZ: 36, r: 0.96, g: 0.88, b: 0.18, a: 0.88),
        .init(dBZ: 42, r: 0.98, g: 0.66, b: 0.08, a: 0.90),
        .init(dBZ: 48, r: 0.93, g: 0.35, b: 0.08, a: 0.92),
        .init(dBZ: 52, r: 0.84, g: 0.08, b: 0.10, a: 0.94),
        .init(dBZ: 58, r: 0.58, g: 0.00, b: 0.10, a: 0.95),
        .init(dBZ: 62, r: 0.95, g: 0.30, b: 0.90, a: 0.96),
        .init(dBZ: 68, r: 0.66, g: 0.36, b: 1.00, a: 0.96),
        .init(dBZ: 74, r: 1.00, g: 1.00, b: 1.00, a: 0.97),
    ])

    /// A 256-entry table covering -32...95.5 dBZ in half-dB steps, which is the
    /// resolution the 8-bit REF moment is stored at. Per pixel the renderer does
    /// one index, never a search.
    public func table() -> [(r: Float, g: Float, b: Float, a: Float)] {
        (0..<256).map { i in color(at: -32 + Float(i) * 0.5) }
    }

    public func color(at dBZ: Float) -> (r: Float, g: Float, b: Float, a: Float) {
        guard let first = stops.first, dBZ >= first.dBZ else { return (0, 0, 0, 0) }
        guard let upper = stops.firstIndex(where: { $0.dBZ > dBZ }) else {
            let s = stops[stops.count - 1]; return (s.r, s.g, s.b, s.a)
        }
        let lo = stops[upper - 1], hi = stops[upper]
        // The 34→36 step is deliberately a near-jump: the palette changes family
        // at moderate rain, and blending green into yellow across it would draw a
        // band of olive that means nothing.
        let t = (dBZ - lo.dBZ) / (hi.dBZ - lo.dBZ)
        return (lo.r + (hi.r - lo.r) * t, lo.g + (hi.g - lo.g) * t,
                lo.b + (hi.b - lo.b) * t, lo.a + (hi.a - lo.a) * t)
    }
}

// MARK: - Tiles

public enum Level2TileRenderer {

    /// WHAT THE CORRELATION COEFFICIENT BUYS. Rain drops are alike, so pulse to
    /// pulse the horizontal and vertical returns move together and ρhv sits near
    /// 1. Birds, bugs and ground clutter are a jumble of shapes and it falls well
    /// below — which is how a dual-pol radar tells a flock from a shower of the
    /// same strength.
    ///
    /// WEAK RETURNS ONLY. Hail and tornado debris ALSO drag ρhv down, and those
    /// are the returns nobody should ever filter; they come with high
    /// reflectivity, so the cut is gated on strength.
    static func isClutter(dBZ: Float, rho: Float) -> Bool {
        dBZ < 25 && rho < 0.85
    }

    /// The reflectivity a map should draw: non-weather removed where the
    /// correlation coefficient can vouch for it, then pinholes closed.
    ///
    /// DONE ONCE PER SCAN, NOT PER PIXEL. The two moments share azimuth rows and
    /// gate spacing (ρhv simply stops at a shorter range), so the filter is a
    /// straight walk down both grids; doing it here means every tile of every
    /// zoom inherits it for free, and the frame cache holds one grid instead of
    /// two.
    public static func display(reflectivity ref: Level2Sweep, rho: Level2Sweep?) -> Level2Sweep {
        guard let rho, rho.rowCount == ref.rowCount,
              rho.gateSpacing == ref.gateSpacing, rho.firstGate == ref.firstGate
        else { return ref.pinholesFilled() }
        var values = ref.values
        let gates = min(ref.gateCount, rho.gateCount)
        let refGates = ref.gateCount, rhoGates = rho.gateCount
        rho.values.withUnsafeBufferPointer { rhoValues in
            values.withUnsafeMutableBufferPointer { v in
                for row in 0..<ref.rowCount {
                    for g in 0..<gates {
                        let i = row * refGates + g
                        let r = rhoValues[row * rhoGates + g]
                        if !v[i].isNaN, !r.isNaN, isClutter(dBZ: v[i], rho: r) { v[i] = .nan }
                    }
                }
            }
        }
        return Level2Sweep(moment: ref.moment, elevationNumber: ref.elevationNumber,
                           elevationAngle: ref.elevationAngle, time: ref.time,
                           firstGate: ref.firstGate, gateSpacing: ref.gateSpacing,
                           gateCount: ref.gateCount, rowCount: ref.rowCount, values: values,
                           radialCount: ref.radialCount, isComplete: ref.isComplete, path: ref.path)
            .pinholesFilled()
    }

    /// Render one web-Mercator tile. Nil only when the volume has no location;
    /// a tile out of the radar's reach is `clear`, because "nothing here" is an
    /// answer the store has to cache, not a failure it should retry.
    public static func render(sweep: Level2Sweep, siteLatitude siteLat: Double, siteLongitude siteLon: Double,
                              z: Int, x: Int, y: Int, size: Int,
                              palette: ReflectivityPalette = .standard) -> CGImage? {
        guard siteLat.isFinite, siteLon.isFinite else { return nil }

        let world = Double(size) * pow(2, Double(z))
        let maxGround = sweep.maxRange  // ground ≤ slant, so this over-covers slightly

        // Quick reject: the tile's nearest point to the site is out of range.
        func lon(_ gx: Double) -> Double { gx / world * 360 - 180 }
        func lat(_ gy: Double) -> Double { atan(sinh(.pi * (1 - 2 * gy / world))) * 180 / .pi }
        let west = lon(Double(x * size)), east = lon(Double((x + 1) * size))
        let north = lat(Double(y * size)), south = lat(Double((y + 1) * size))
        let nearLat = min(max(siteLat, south), north), nearLon = min(max(siteLon, west), east)
        if RadarGeometry.groundPath(fromLatitude: siteLat, longitude: siteLon,
                                    toLatitude: nearLat, longitude: nearLon).distance > maxGround {
            return clear
        }

        let table = palette == .standard ? standardTable : palette.table()
        let floor = palette.floor

        // Per-column and per-row terms of the haversine, so each pixel costs one
        // asin, one atan2 and the slant correction.
        let φ1 = siteLat * .pi / 180
        let sinφ1 = sin(φ1), cosφ1 = cos(φ1)
        var colSinHalf2 = [Double](repeating: 0, count: size)   // sin²(Δλ/2)
        var colSin = [Double](repeating: 0, count: size)        // sin Δλ
        var colCos = [Double](repeating: 0, count: size)        // cos Δλ
        for px in 0..<size {
            let Δλ = (lon(Double(x * size + px) + 0.5) - siteLon) * .pi / 180
            let h = sin(Δλ / 2)
            colSinHalf2[px] = h * h; colSin[px] = sin(Δλ); colCos[px] = cos(Δλ)
        }

        let rows = sweep.rowCount, gates = sweep.gateCount
        let step = sweep.azimuthStep
        let elevation = sweep.elevationAngle
        let firstGate = sweep.firstGate, spacing = sweep.gateSpacing
        let earth2 = 2 * RadarGeometry.earthRadius
        var pixels = [UInt8](repeating: 0, count: size * size * 4)

        // UNSAFE BUFFERS THROUGHOUT. This loop runs a quarter of a million times
        // per tile; with bounds checks and Array accessors on every read it was
        // 60 ms a tile in a Debug build, and a loop asks for hundreds of tiles.
        sweep.values.withUnsafeBufferPointer { values in
        table.withUnsafeBufferPointer { table in
        colSinHalf2.withUnsafeBufferPointer { colSinHalf2 in
        colSin.withUnsafeBufferPointer { colSin in
        colCos.withUnsafeBufferPointer { colCos in
        pixels.withUnsafeMutableBufferPointer { out in
            for py in 0..<size {
                let φ2 = lat(Double(y * size + py) + 0.5) * .pi / 180
                let sinφ2 = sin(φ2), cosφ2 = cos(φ2)
                let hφ = sin((φ2 - φ1) / 2), rowSinHalf2 = hφ * hφ
                let cc = cosφ1 * cosφ2
                let rowBase = py * size * 4

                for px in 0..<size {
                    let a = rowSinHalf2 + cc * colSinHalf2[px]
                    let ground = earth2 * asin(min(1, a.squareRoot()))
                    if ground > maxGround { continue }
                    var bearing = atan2(colSin[px] * cosφ2, cosφ1 * sinφ2 - sinφ1 * cosφ2 * colCos[px]) * 180 / .pi
                    if bearing < 0 { bearing += 360 }
                    let range = RadarGeometry.slantRange(ground: ground, elevation: elevation)

                    // Fractional row and gate. Row centres sit half a step past
                    // their edge; gate centres sit on firstGate + k·spacing.
                    let rf = bearing / step - 0.5
                    let gf = (range - firstGate) / spacing
                    guard gf >= -0.5, gf <= Double(gates) - 0.5 else { continue }
                    let r0 = Int(rf.rounded(.down)), g0 = Int(gf.rounded(.down))
                    let tr = Float(rf - Double(r0)), tg = Float(gf - Double(g0))
                    let ra = (r0 % rows + rows) % rows, rb = (ra + 1) % rows
                    let ga = max(0, min(gates - 1, g0)), gb = max(0, min(gates - 1, g0 + 1))

                    // Interpolate over the neighbours that HAVE a value, and let
                    // the missing ones fade the pixel out rather than pull its
                    // colour toward some made-up floor. The edge of an echo is
                    // soft, and nothing invented shows up as a halo around it.
                    var sum: Float = 0, weight: Float = 0
                    @inline(__always) func take(_ i: Int, _ w: Float) {
                        let v = values[i]
                        if !v.isNaN && w > 0 { sum += v * w; weight += w }
                    }
                    take(ra * gates + ga, (1 - tr) * (1 - tg))
                    take(ra * gates + gb, (1 - tr) * tg)
                    take(rb * gates + ga, tr * (1 - tg))
                    take(rb * gates + gb, tr * tg)
                    guard weight > 0.001 else { continue }
                    let dBZ = sum / weight
                    guard dBZ >= floor else { continue }

                    let c = table[max(0, min(255, Int(((dBZ + 32) * 2).rounded())))]
                    let alpha = c.a * min(1, weight * 1.4)
                    guard alpha > 0.004 else { continue }
                    let o = rowBase + px * 4
                    out[o] = UInt8(c.r * alpha * 255)
                    out[o + 1] = UInt8(c.g * alpha * 255)
                    out[o + 2] = UInt8(c.b * alpha * 255)
                    out[o + 3] = UInt8(alpha * 255)
                }
            }
        }}}}}}

        return image(pixels, size: size)
    }

    /// Built once: the table is a pure function of the palette, and rebuilding
    /// it per tile was a search over the stops for 256 entries, hundreds of times
    /// a loop.
    static let standardTable = ReflectivityPalette.standard.table()

    /// One transparent pixel, drawn stretched over a tile the radar cannot see.
    public static let clear: CGImage? = image([0, 0, 0, 0], size: 1)

    /// Pixels to PNG bytes, for the TV's `MKTileOverlay`, which only takes bytes.
    public static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    static func image(_ pixels: [UInt8], size: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
