//
//  Nowcast.swift  (WeatherKit)
//
//  WHERE THE RAIN WILL BE IN AN HOUR, WORKED OUT FROM WHERE IT HAS BEEN.
//
//  THE IDEA, AND ITS LIMITS, STATED BEFORE THE CODE. Two consecutive radar scans
//  five minutes apart are the same storms in two places. Find the shift that best
//  lines one up on the other and you have the storms' velocity; apply that
//  velocity to the newest scan and you have a forecast. That is the whole method,
//  and it is what almost every "future radar" is at this range.
//
//  It is honest about exactly one thing and silent about everything else: WHERE.
//  Advection moves weather, it does not grow or decay it. A line that is falling
//  apart will be drawn still marching; a cell about to explode will be drawn the
//  size it is now. Past about an hour that is no longer a forecast, which is why
//  the horizon here is an hour and not six.
//
//  WHY IT IS WORTH HAVING ANYWAY. At thirty minutes it routinely beats the
//  hourly NWP run, because it starts from what is actually on the radar rather
//  than from a model's guess at what was on the radar three hours ago. On the day
//  this was written the 18Z HRRR had no line over San Saba at all while the radar
//  had a solid one. Extrapolation cannot miss a storm that is already there.
//
//  IT COSTS NO NETWORK, WHICH IS THE OTHER REASON THIS CAME FIRST. A forecast
//  frame is the newest scan's tiles drawn at an offset — the pixels are already
//  decoded in `FieldTileStore`, so the whole future half of the loop is free. See
//  `RadarModel.loop`.
//

import Foundation
import CoreGraphics

// MARK: - What the radar is doing

/// How fast the picture is moving, and how much to believe it.
public struct StormMotion: Equatable, Sendable {
    /// Cells per second, in grid space, positive right and down. Converted to map
    /// points by whoever knows the grid's scale — see `IntensityGrid.cellSize`.
    public var dx: Double
    public var dy: Double

    /// Peak correlation at the chosen shift, 0...1. NOT a forecast skill score —
    /// it says how confidently the two scans could be lined up at all, which is
    /// the question of whether there was anything coherent to track.
    public var confidence: Double

    public init(dx: Double, dy: Double, confidence: Double) {
        self.dx = dx; self.dy = dy; self.confidence = confidence
    }

    /// Nothing moving and no reason to think otherwise.
    public static let still = StormMotion(dx: 0, dy: 0, confidence: 0)

    public var isUsable: Bool { confidence >= MotionEstimator.minimumConfidence }
}

public extension StormMotion {

    /// Speed over the ground and the direction of travel, from a motion already
    /// converted to MAP POINTS per second.
    ///
    /// THE LATITUDE IS NOT OPTIONAL and it is not a rounding detail. Web Mercator
    /// stretches everything away from the equator by 1/cos(latitude), so a map
    /// point in Texas is about 85% of the ground a map point at the equator is.
    /// Reporting the unscaled number would have every storm in the lower 48 moving
    /// about 18% too fast, which is exactly the kind of wrong that looks plausible.
    func groundTrack(atLatitude latitude: Double) -> (metresPerSecond: Double, bearing: Double) {
        let metresPerPoint = 40_075_016.686 / FieldTileGrid.worldSize
            * cos(latitude * .pi / 180)
        let speed = (dx * dx + dy * dy).squareRoot() * metresPerPoint
        // Map space counts y DOWNWARD from the north edge, so a positive dy is
        // southward travel.
        var bearing = atan2(dx, -dy) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return (speed, bearing)
    }

    /// The direction as people say it — "NE", not "43°".
    static func compass(_ bearing: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let i = Int((bearing / 22.5).rounded()) % points.count
        return points[(i + points.count) % points.count]
    }
}

/// A square-ish sample of one scan's intensity over a patch of the map.
///
/// INTENSITY IS THE ALPHA CHANNEL, and that is not a shortcut. Every field source
/// bakes its ramp position into alpha in `process` — see `RadarTileShading` — so
/// the alpha of a shaded tile already IS "how hard is it raining here", on a
/// 0...1 scale, with the colour it was drawn in factored out. Correlating alpha
/// means correlating reflectivity rather than correlating green-ness.
public struct IntensityGrid: Sendable {
    public var values: [Float]
    public var width: Int
    public var height: Int
    /// Map points per cell. What turns a shift in cells into a shift on the map.
    public var cellSize: Double

    public init(values: [Float], width: Int, height: Int, cellSize: Double) {
        self.values = values; self.width = width; self.height = height
        self.cellSize = cellSize
    }

    /// Share of cells with anything in them. A grid of clear sky has no motion to
    /// find, and correlating two of them produces a confident answer about noise.
    public var wetFraction: Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.count { $0 > 0.02 }) / Double(values.count)
    }
}

// MARK: - Finding the motion

public enum MotionEstimator {

    /// Below this, the two scans could not be lined up on each other well enough
    /// to be tracking the same weather, and the honest answer is no forecast at
    /// all rather than a confident straight line.
    public static let minimumConfidence = 0.35

    /// Less rain than this on screen and there is nothing to track. Deliberately
    /// low: a single cell crossing the viewport is a perfectly good thing to
    /// extrapolate, and demanding a full screen of returns would refuse exactly
    /// the isolated storm somebody is watching most closely.
    public static let minimumWetFraction = 0.004

    /// The shift that best lines `a` up on `b`, in cells.
    ///
    /// COARSE TO FINE, because the honest search is too big to do directly. Storms
    /// run to about 100 km/h, which over a five-minute gap is 8 km — at a grid
    /// fine enough to be worth correlating that is a search radius of twenty-odd
    /// cells, so a direct search is 40x40 offsets scored over the whole grid. At
    /// quarter resolution the same ground is a 10x10 search over a sixteenth of
    /// the cells, and a ±3 refinement at full resolution recovers the precision.
    /// Two orders of magnitude, same answer.
    public static func estimate(from a: IntensityGrid, to b: IntensityGrid,
                                over seconds: Double,
                                maxShift: Int) -> StormMotion {
        guard a.width == b.width, a.height == b.height,
              a.width > 8, a.height > 8, seconds > 0,
              a.wetFraction >= minimumWetFraction,
              b.wetFraction >= minimumWetFraction else { return .still }

        let coarseA = downsample(a, by: 4)
        let coarseB = downsample(b, by: 4)
        let coarse = search(coarseA, coarseB, radius: max(1, maxShift / 4))

        // Refined around four times the coarse answer, which is where that answer
        // lands once it is scaled back up.
        let fine = search(a, b, radius: 3,
                          aroundX: coarse.x * 4, aroundY: coarse.y * 4)

        // SUB-CELL, OR THE FORECAST STEPS. The shift is quantised to whole cells,
        // and at a five-minute gap one cell of error is a real velocity error that
        // compounds over twelve forecast frames — the picture would visibly jump
        // by a cell between steps instead of sliding. Fitting a parabola to the
        // correlation either side of the peak recovers the fraction.
        let dx = Double(fine.x) + parabolicOffset(fine.scoreLeft, fine.score, fine.scoreRight)
        let dy = Double(fine.y) + parabolicOffset(fine.scoreUp, fine.score, fine.scoreDown)

        return StormMotion(dx: dx / seconds, dy: dy / seconds, confidence: fine.score)
    }

    /// One correlation peak, with its immediate neighbours kept for the sub-cell fit.
    private struct Peak {
        var x = 0, y = 0
        var score = 0.0
        var scoreLeft = 0.0, scoreRight = 0.0, scoreUp = 0.0, scoreDown = 0.0
    }

    /// Normalised cross-correlation over every shift in a window.
    ///
    /// NORMALISED, NOT A PLAIN DOT PRODUCT. The overlap shrinks as the shift grows,
    /// so an unnormalised score is biased towards no motion at all — the one answer
    /// that is always wrong when something is moving. Dividing by the norms of the
    /// two overlapping patches makes shifts comparable to each other.
    private static func search(_ a: IntensityGrid, _ b: IntensityGrid,
                               radius: Int, aroundX: Int = 0, aroundY: Int = 0) -> Peak {
        var best = Peak()
        var scores: [Int: Double] = [:]

        for sy in (aroundY - radius)...(aroundY + radius) {
            for sx in (aroundX - radius)...(aroundX + radius) {
                let score = correlate(a, b, shiftX: sx, shiftY: sy)
                scores[sy * 100_000 + sx] = score
                if score > best.score { best = Peak(x: sx, y: sy, score: score) }
            }
        }
        best.scoreLeft  = scores[best.y * 100_000 + best.x - 1] ?? best.score
        best.scoreRight = scores[best.y * 100_000 + best.x + 1] ?? best.score
        best.scoreUp    = scores[(best.y - 1) * 100_000 + best.x] ?? best.score
        best.scoreDown  = scores[(best.y + 1) * 100_000 + best.x] ?? best.score
        return best
    }

    /// How well `a` lines up on `b` when `b` is read `shift` cells along.
    private static func correlate(_ a: IntensityGrid, _ b: IntensityGrid,
                                  shiftX: Int, shiftY: Int) -> Double {
        let x0 = max(0, -shiftX), x1 = min(a.width, a.width - shiftX)
        let y0 = max(0, -shiftY), y1 = min(a.height, a.height - shiftY)
        guard x1 - x0 > 4, y1 - y0 > 4 else { return 0 }

        var dot = 0.0, normA = 0.0, normB = 0.0
        for y in y0..<y1 {
            let rowA = y * a.width
            let rowB = (y + shiftY) * b.width + shiftX
            for x in x0..<x1 {
                let va = Double(a.values[rowA + x])
                let vb = Double(b.values[rowB + x])
                dot += va * vb; normA += va * va; normB += vb * vb
            }
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA * normB).squareRoot()
    }

    /// The peak of the parabola through three samples, clamped to the cell either
    /// side. Returns 0 when the three are flat or the fit runs away.
    private static func parabolicOffset(_ before: Double, _ peak: Double, _ after: Double) -> Double {
        let denominator = before - 2 * peak + after
        guard abs(denominator) > 1e-9 else { return 0 }
        let offset = 0.5 * (before - after) / denominator
        return offset.isFinite ? max(-1, min(1, offset)) : 0
    }

    /// Box-average down by an integer factor. Averaging rather than sampling
    /// matters here: radar is full of single-cell spikes, and a decimated grid
    /// correlates the spikes' aliasing rather than the storm's shape.
    private static func downsample(_ grid: IntensityGrid, by factor: Int) -> IntensityGrid {
        let w = grid.width / factor, h = grid.height / factor
        guard w > 0, h > 0 else { return grid }
        var out = [Float](repeating: 0, count: w * h)
        let divisor = Float(factor * factor)
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0
                for dy in 0..<factor {
                    let row = (y * factor + dy) * grid.width + x * factor
                    for dx in 0..<factor { sum += grid.values[row + dx] }
                }
                out[y * w + x] = sum / divisor
            }
        }
        return IntensityGrid(values: out, width: w, height: h,
                             cellSize: grid.cellSize * Double(factor))
    }
}

// MARK: - Sampling the store

public extension IntensityGrid {

    /// Draw a set of tiles into an intensity grid over a patch of map space.
    ///
    /// SPLIT OUT FROM THE STORE ON PURPOSE, AND THE REASON IS A BUG THIS SHIPPED
    /// WITH. The grid's orientation is the one thing here that cannot be checked
    /// by looking at the map: a vertically mirrored grid still correlates
    /// beautifully, still produces a confident vector, and still draws a smooth
    /// plausible forecast — with the north-south component reversed. Storms
    /// tracking northeast all afternoon turned around at the seam and headed back
    /// southeast, which is the only reason anybody noticed.
    ///
    /// Taking the tiles as a closure rather than reaching into `FieldTileStore`
    /// means the orientation can be pinned by a test with a synthetic image whose
    /// top half is known — see `NowcastTests`.
    static func rasterise(placements: [FieldTileGrid.Placement],
                          rectX: Double, rectY: Double,
                          width: Double, height: Double,
                          cells: Int,
                          image: (FieldTileGrid.Tile) -> CGImage?) -> IntensityGrid? {
        guard width > 0, height > 0, cells > 8, !placements.isEmpty else { return nil }

        // Square cells, so a shift of one cell means the same distance either way
        // and the motion vector does not need an aspect correction.
        let cellSize = width / Double(cells)
        let rows = max(8, Int((height / cellSize).rounded()))

        // ALPHA ONLY. The colour is a ramp over the same quantity the alpha
        // already encodes, so a grey or RGB context would cost four times the
        // memory to carry three redundant channels — and would then need the ramp
        // inverted to get the number back out.
        guard let context = CGContext(data: nil, width: cells, height: rows,
                                      bitsPerComponent: 8, bytesPerRow: cells,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return nil }

        for placement in placements {
            guard let tile = image(placement.tile) else { return nil }
            let span = FieldTileGrid.tileSpan(z: placement.tile.z)
            // A bitmap context counts y UPWARD from its bottom-left, and map space
            // counts it downward from the north edge, so a tile's map-space top is
            // its context-space bottom-plus-height.
            let drawRect = CGRect(x: (placement.mapX - rectX) / cellSize,
                                  y: Double(rows) - (placement.mapY - rectY + span) / cellSize,
                                  width: span / cellSize, height: span / cellSize)
            context.draw(tile, in: drawRect)
        }

        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: cells * rows)
        var values = [Float](repeating: 0, count: cells * rows)
        for row in 0..<rows {
            // THE BUFFER'S FIRST ROW IS THE CONTEXT'S TOP, which is north — the
            // same way round as the grid. This used to read `rows - 1 - row`,
            // mirroring the grid about its own middle and inverting every
            // north-south motion the estimator went on to find.
            let source = row * cells
            let destination = row * cells
            for x in 0..<cells {
                values[destination + x] = Float(bytes[source + x]) / 255
            }
        }
        return IntensityGrid(values: values, width: cells, height: rows, cellSize: cellSize)
    }
}

public extension FieldTileStore {

    /// Rasterise one scan into an intensity grid over a patch of map space.
    ///
    /// ALL OR NOTHING, DELIBERATELY. A missing tile would come out as a rectangle
    /// of clear sky, and a rectangle of clear sky in one scan and weather in the
    /// other is a huge correlation feature that has nothing to do with how the
    /// storms moved. Better no motion estimate than one anchored to a hole.
    func intensityGrid(source: FieldTileSource, stamp: String,
                       rectX: Double, rectY: Double,
                       width: Double, height: Double,
                       z: Int, cells: Int) -> IntensityGrid? {
        let placements = FieldTileGrid.placements(inRectX: rectX, y: rectY,
                                                  width: width, height: height, z: z)
        return IntensityGrid.rasterise(placements: placements,
                                       rectX: rectX, rectY: rectY,
                                       width: width, height: height, cells: cells) { tile in
            image(for: Key(source: source.id, stamp: stamp,
                           z: tile.z, x: tile.x, y: tile.y))
        }
    }
}
