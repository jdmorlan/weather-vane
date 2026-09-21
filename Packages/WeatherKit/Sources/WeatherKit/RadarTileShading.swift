//
//  RadarTileShading.swift  (WeatherKit)
//
//  Re-rendering a radar tile so that opacity carries intensity.
//
//  THE PROBLEM, MEASURED. A tile fetched from the WMS over a mostly-clear day
//  came back 98.75% fully transparent, 1.25% fully OPAQUE, and 0.00% anything in
//  between. The service resolves its colour ramp to RGBA and hands back hard
//  alpha-255 pixels: a drizzle return is exactly as solid as a hail core. Drawn
//  through one flat layer opacity the result is a poster-paint smear with no
//  depth and no hierarchy.
//
//  THE FIX. Look each pixel's colour up in `RadarRamp` to recover where it sits
//  in the ramp, then set its alpha from that position. Weak returns go nearly
//  transparent, cores stay solid, and the structure inside a storm becomes
//  visible — the gradient from edge to core is information the data always
//  carried and the flat render threw away. A noise floor drops the bottom of the
//  ramp, which is ground clutter, insects and birds.
//
//  CORE GRAPHICS, NOT APPKIT. This began in the Mac app against
//  `NSBitmapImageRep` and moved here when the TV target needed the same work —
//  writing it twice would have meant two noise floors to keep in step. CGImage
//  is on every platform the app will ever run on, and the arithmetic is the
//  interesting part anyway.
//

import Foundation
import CoreGraphics
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public enum RadarTileShading {

    /// How a ramp position becomes an opacity.
    public struct Curve: Equatable, Sendable {
        /// Ramp position below which a pixel is dropped entirely.
        public var floor: Float
        /// Ramp position at and above which a pixel is fully opaque.
        public var solid: Float
        /// Opacity for the faintest pixel that survives the floor. Not zero: a
        /// pixel that survives should be visible, or the floor should have taken it.
        public var minAlpha: Float
        /// Ceiling, so even a core lets a little of the map through. Radar you
        /// cannot see the ground under is radar you cannot locate.
        public var maxAlpha: Float

        public init(floor: Float, solid: Float, minAlpha: Float, maxAlpha: Float) {
            self.floor = floor; self.solid = solid
            self.minAlpha = minAlpha; self.maxAlpha = maxAlpha
        }

        // TUNED TO THE DATA, NOT TO THE RAMP. The first attempt spread the curve
        // across the full 0...1 of the ramp and came out washed out, because real
        // returns do not use the full ramp. Measured over live tiles — a CONUS
        // view and a local one, 16,564 non-empty pixels — ramp position runs:
        //
        //     p1 .325   p10 .424   p25 .503   p50 .564   p90 .667   p99 .766
        //
        // So the useful signal lives between about .33 and .70, and a curve
        // anchored outside that band spends its whole range on values that never
        // occur.

        /// The default: floor at roughly the 1st percentile, solid at about the
        /// 90th, so ordinary heavy rain reaches full strength rather than that
        /// being reserved for hail twice a year.
        public static let standard = Curve(floor: 0.36, solid: 0.66, minAlpha: 0.55, maxAlpha: 1.0)
        /// Everything the service drew, for looking at drizzle and boundaries.
        public static let everything = Curve(floor: 0.30, solid: 0.70, minAlpha: 0.40, maxAlpha: 1.0)
        /// Only what is worth naming — cores, with the light stuff gone.
        public static let heavyOnly = Curve(floor: 0.46, solid: 0.62, minAlpha: 0.70, maxAlpha: 1.0)
    }

    /// Re-render PNG tile data with intensity-driven alpha, as PIXELS.
    ///
    /// THE FORM THE RENDERER ACTUALLY WANTS. `shade` below re-encodes this to PNG
    /// for callers that hand bytes to MapKit; the field renderer skips that and
    /// keeps the image, because encoding a tile so it can be decoded again on the
    /// next line is work nobody asked for. Returns nil when the data will not
    /// decode.
    public static func shadeImage(_ data: Data, curve: Curve) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        // Drawn into a buffer we define rather than read from the decoded image,
        // so the byte order and alpha handling are known rather than whatever the
        // PNG happened to carry.
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = pixels.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(data: buffer.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // A tile holds a couple of hundred distinct colours out of a quarter
        // million pixels, so the ramp's binary search runs a few hundred times
        // rather than 262,144.
        var memo: [UInt32: Float] = [:]
        memo.reserveCapacity(320)
        let span = max(0.0001, curve.solid - curve.floor)

        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for index in stride(from: 0, to: buffer.count, by: 4) {
                let a = base[index + 3]
                guard a != 0 else { continue }

                // The context is premultiplied, so undo it before matching or the
                // lookup is against colours the ramp has never seen.
                var r = base[index], g = base[index + 1], b = base[index + 2]
                if a < 255 {
                    let scale = 255.0 / Float(a)
                    r = UInt8(min(255, Float(r) * scale))
                    g = UInt8(min(255, Float(g) * scale))
                    b = UInt8(min(255, Float(b) * scale))
                }

                let key = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
                let position: Float
                if let hit = memo[key] {
                    position = hit
                } else {
                    // An off-ramp colour is an anti-aliased edge. Calling it
                    // maximum intensity would outline every cell in solid colour,
                    // so it inherits the floor and fades with everything else.
                    position = RadarRamp.intensity(r: r, g: g, b: b) ?? curve.floor
                    memo[key] = position
                }

                if position < curve.floor {
                    base[index] = 0; base[index + 1] = 0
                    base[index + 2] = 0; base[index + 3] = 0
                    continue
                }

                let t = min(1, (position - curve.floor) / span)
                // Eased rather than linear: the interesting part of a storm is the
                // top of the ramp, and a straight line spends most of its opacity
                // budget on the half nobody is looking at.
                let eased = t * t * (3 - 2 * t)
                let alpha = curve.minAlpha + eased * (curve.maxAlpha - curve.minAlpha)
                base[index]     = UInt8(Float(r) * alpha)
                base[index + 1] = UInt8(Float(g) * alpha)
                base[index + 2] = UInt8(Float(b) * alpha)
                base[index + 3] = UInt8(max(0, min(255, alpha * 255)))
            }
        }

        return context.makeImage()
    }

    /// The same shading, re-encoded as PNG — for callers that must hand BYTES to
    /// something else's tile loader. The Mac's field renderer does not; the TV's
    /// `MKTileOverlay` path still does.
    ///
    /// Returns nil when the data will not decode, and the caller then uses the
    /// original bytes — a tile drawn the old way beats a hole in the map.
    public static func shade(_ data: Data, curve: Curve) -> Data? {
        guard let shaded = shadeImage(data, curve: curve) else { return nil }
        let out = NSMutableData()
        let type = "public.png" as CFString
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, shaded, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
