//
//  UpperAirFlow.swift  (WeatherKit)
//
//  Three readings layered on the height field, each the way a forecaster reads a
//  real 500 mb chart:
//
//    · CONTOURS  — lines of equal height every 6 dam (…576, 582, 588…), the
//                  standard interval. The wave's shape on a map.
//    · FLOW      — which way the air moves. Above the friction of the ground, wind
//                  runs ALONG the height lines, lower heights on its left in the
//                  northern hemisphere, faster where the lines crowd together.
//                  That balance is the geostrophic wind, and it is computed here
//                  from the heights alone.
//    · TRACKS    — the same ridge or trough followed from one day to the next, so
//                  its speed and direction are something you can see rather than
//                  infer. The data behind a Hovmöller diagram.
//
//  And one conversion that makes "dam" physical: `LayerTemperature`.
//

import Foundation

// MARK: - Contours

/// A position in grid space: `column` 0 is the westmost longitude, `row` 0 the
/// northmost latitude. Fractions fall between grid points.
public struct GridPoint: Equatable, Sendable {
    public var column: Double
    public var row: Double

    public init(column: Double, row: Double) {
        self.column = column
        self.row = row
    }
}

public struct ContourSegment: Equatable, Sendable {
    public var a: GridPoint
    public var b: GridPoint
}

public struct ContourLine: Equatable, Sendable {
    public var level: Double
    public var segments: [ContourSegment]
}

public enum HeightContours {
    /// The interval every operational 500 mb chart uses.
    public static let interval = 6.0

    /// Every multiple of `interval` inside the field's range.
    public static func levels(_ heights: [[Double]], interval: Double = interval) -> [Double] {
        let all = heights.flatMap { $0 }
        guard let lo = all.min(), let hi = all.max() else { return [] }
        var level = (lo / interval).rounded(.up) * interval
        var out: [Double] = []
        while level <= hi {
            out.append(level)
            level += interval
        }
        return out
    }

    public static func lines(_ heights: [[Double]], interval: Double = interval) -> [ContourLine] {
        levels(heights, interval: interval)
            .map { ContourLine(level: $0, segments: segments(heights, level: $0)) }
            .filter { !$0.segments.isEmpty }
    }

    /// Marching squares. Each square of four neighbouring grid points is
    /// classified by which corners are at or above `level`, and the line crosses
    /// each edge where the level falls between that edge's two corners — placed by
    /// linear interpolation, not at the midpoint.
    ///
    /// The two SADDLE cases (diagonal corners high) are ambiguous from the corners
    /// alone and are settled by the square's centre value: whether the high corners
    /// connect through the middle or the low ones do.
    public static func segments(_ v: [[Double]], level: Double) -> [ContourSegment] {
        guard v.count >= 2, let cols = v.first?.count, cols >= 2 else { return [] }
        var out: [ContourSegment] = []
        for r in 0..<(v.count - 1) {
            for c in 0..<(cols - 1) {
                let tl = v[r][c], tr = v[r][c + 1], br = v[r + 1][c + 1], bl = v[r + 1][c]
                let index = (tl >= level ? 8 : 0) | (tr >= level ? 4 : 0)
                          | (br >= level ? 2 : 0) | (bl >= level ? 1 : 0)
                let R = Double(r), C = Double(c)
                func t(_ a: Double, _ b: Double) -> Double { (level - a) / (b - a) }
                let top    = { GridPoint(column: C + t(tl, tr), row: R) }
                let right  = { GridPoint(column: C + 1, row: R + t(tr, br)) }
                let bottom = { GridPoint(column: C + t(bl, br), row: R + 1) }
                let left   = { GridPoint(column: C, row: R + t(tl, bl)) }
                func add(_ a: GridPoint, _ b: GridPoint) { out.append(ContourSegment(a: a, b: b)) }
                let centreHigh = (tl + tr + br + bl) / 4 >= level

                switch index {
                case 0, 15: break
                case 1, 14: add(left(), bottom())
                case 2, 13: add(bottom(), right())
                case 3, 12: add(left(), right())
                case 4, 11: add(top(), right())
                case 6, 9:  add(top(), bottom())
                case 7, 8:  add(top(), left())
                case 5:  // tr + bl high
                    if centreHigh { add(top(), left()); add(bottom(), right()) }
                    else          { add(top(), right()); add(left(), bottom()) }
                case 10: // tl + br high
                    if centreHigh { add(top(), right()); add(left(), bottom()) }
                    else          { add(top(), left()); add(bottom(), right()) }
                default: break
                }
            }
        }
        return out
    }
}

// MARK: - Flow

/// A wind reported by the model: speed and the direction it blows FROM.
public struct UpperWind: Codable, Equatable, Sendable {
    public var speedMPH: Double
    public var fromDegrees: Double

    public init(speedMPH: Double, fromDegrees: Double) {
        self.speedMPH = speedMPH
        self.fromDegrees = fromDegrees
    }
}

public struct FlowVector: Equatable, Sendable {
    public var at: GridPoint
    /// Toward the east, m/s.
    public var east: Double
    /// Toward the north, m/s.
    public var north: Double

    public var speedMPH: Double { (east * east + north * north).squareRoot() * 2.236_94 }

    /// Meteorological convention: the direction the wind comes FROM, 0 = north.
    public var fromDegrees: Double {
        let d = atan2(-east, -north) * 180 / .pi
        return d < 0 ? d + 360 : d
    }

    /// "SW", "WNW" — sixteen points.
    public static func compass(_ degrees: Double) -> String {
        let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                     "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((degrees.truncatingRemainder(dividingBy: 360) / 22.5).rounded())
        return names[((index % 16) + 16) % 16]
    }
}

public enum GeostrophicFlow {
    static let gravity = 9.806_65
    static let earthRotation = 7.2921e-5
    static let metersPerDegree = 111_195.0

    /// The geostrophic wind at the CORNERS where four grid cells meet — the
    /// centre of each square of neighbouring heights, which is where a finite
    /// difference across the square is actually centred.
    ///
    ///     east  = −(g / f) · ∂Z/∂y        north = (g / f) · ∂Z/∂x
    ///
    /// with Z in metres, x and y in metres along the ground, and f = 2Ω·sin(latitude).
    /// Heights falling toward the pole give a wind from the west; heights rising
    /// toward the east give a wind from the south.
    public static func corners(_ heights: [[Double]], grid: UpperAirGrid) -> [FlowVector] {
        let lats = grid.latitudes
        guard heights.count == lats.count, heights.count >= 2,
              let cols = heights.first?.count, cols >= 2 else { return [] }
        var out: [FlowVector] = []
        for r in 0..<(heights.count - 1) {
            let latitude = (lats[r] + lats[r + 1]) / 2
            let f = 2 * earthRotation * sin(latitude * .pi / 180)
            guard abs(f) > 1e-6 else { continue }
            let dy = grid.step * metersPerDegree
            let dx = grid.step * metersPerDegree * cos(latitude * .pi / 180)
            for c in 0..<(cols - 1) {
                let (nw, ne) = (heights[r][c] * 10, heights[r][c + 1] * 10)
                let (sw, se) = (heights[r + 1][c] * 10, heights[r + 1][c + 1] * 10)
                let dZdx = ((ne - nw) + (se - sw)) / 2 / dx
                let dZdy = ((nw - sw) + (ne - se)) / 2 / dy
                out.append(FlowVector(at: GridPoint(column: Double(c) + 0.5, row: Double(r) + 0.5),
                                      east: -(gravity / f) * dZdy,
                                      north: (gravity / f) * dZdx))
            }
        }
        return out
    }
}

// MARK: - Tracks

public struct TrackPoint: Equatable, Sendable {
    public var frame: Int
    public var longitude: Double
}

public struct FeatureTrack: Equatable, Sendable {
    public var kind: WaveFeature.Kind
    public var points: [TrackPoint]

    /// Average eastward motion over the track. Positive = moving east; negative =
    /// retrogressing west. Nil for a feature seen on only one day.
    public var degreesPerDay: Double? {
        guard let first = points.first, let last = points.last, last.frame > first.frame else { return nil }
        return (last.longitude - first.longitude) / Double(last.frame - first.frame)
    }
}

public enum FeatureTracks {
    /// The furthest a feature is followed in one day, degrees. A progressive
    /// short-wave trough can cover 15–20° a day; the long waves move a few.
    public static let maxDailyJump = 20.0

    /// Link each day's features to the previous day's, same kind only, closest
    /// pairs first. Frames are assumed to be consecutive days. A feature with no
    /// partner starts a new track, and a track with no partner ends — the wave
    /// left the window, or weakened below the relief threshold.
    public static func build(_ byFrame: [[WaveFeature]], maxJump: Double = maxDailyJump) -> [FeatureTrack] {
        var tracks: [FeatureTrack] = []
        var open: [Int] = []
        for (frame, features) in byFrame.enumerated() {
            var pairs: [(distance: Double, track: Int, feature: Int)] = []
            for ti in open {
                guard let last = tracks[ti].points.last else { continue }
                for (fi, feature) in features.enumerated() where feature.kind == tracks[ti].kind {
                    let distance = abs(feature.longitude - last.longitude)
                    if distance <= maxJump { pairs.append((distance, ti, fi)) }
                }
            }
            pairs.sort { $0.distance < $1.distance }

            var usedTracks = Set<Int>(), usedFeatures = Set<Int>(), nextOpen: [Int] = []
            for pair in pairs where !usedTracks.contains(pair.track) && !usedFeatures.contains(pair.feature) {
                tracks[pair.track].points.append(TrackPoint(frame: frame, longitude: features[pair.feature].longitude))
                usedTracks.insert(pair.track)
                usedFeatures.insert(pair.feature)
                nextOpen.append(pair.track)
            }
            for (fi, feature) in features.enumerated() where !usedFeatures.contains(fi) {
                tracks.append(FeatureTrack(kind: feature.kind,
                                           points: [TrackPoint(frame: frame, longitude: feature.longitude)]))
                nextOpen.append(tracks.count - 1)
            }
            open = nextOpen
        }
        return tracks
    }
}

// MARK: - Temperature

/// What a height MEANS, physically.
///
/// The 1000–500 mb THICKNESS is the depth of the lower half of the atmosphere, and
/// by the hypsometric equation that depth is set by one thing — the layer's mean
/// temperature:
///
///     thickness = (R · T̄ / g) · ln(1000 / 500)
///
/// Warm air is less dense, so the same half of the atmosphere's mass takes up
/// more height. This is the conversion behind the forecaster's 540 line (5,400 m
/// thickness ≈ a layer averaging −7 °C, the classic rain/snow boundary).
///
/// Strictly T̄ is the VIRTUAL temperature, which runs a degree or two above the
/// actual temperature in humid air. Near enough for reading a chart.
public enum LayerTemperature {
    static let gasConstant = 287.05

    public static func kelvin(thicknessDam: Double) -> Double {
        thicknessDam * 10 * GeostrophicFlow.gravity / (gasConstant * log(2))
    }

    public static func fahrenheit(thicknessDam: Double) -> Double {
        (kelvin(thicknessDam: thicknessDam) - 273.15) * 9 / 5 + 32
    }

    /// How many °F of layer temperature one dam of thickness represents (≈ 0.89).
    public static var fahrenheitPerDam: Double { kelvin(thicknessDam: 1) * 9 / 5 }
}
