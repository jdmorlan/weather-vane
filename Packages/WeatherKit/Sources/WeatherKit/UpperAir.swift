//
//  UpperAir.swift  (WeatherKit)
//
//  Reading the 500 mb pattern: finding the ridges and troughs in a field of
//  heights so they don't have to be picked out of contours by eye. Pure — no
//  networking (`UpperAirClient`), no drawing (the app). Everything here can be
//  checked against a field whose answer is known in advance.
//
//  THE PIPELINE, and each step is the one a forecaster does in their head:
//
//    1. DETREND. Heights fall steadily toward the pole, so a raw 588 dam means
//       nothing until it is compared with what is normal AT THAT LATITUDE. Each
//       row has a reference mean subtracted: positive = ridging, negative =
//       troughing, and a cell in Texas is now comparable with one in Montana.
//
//    2. COLLAPSE. The mid-latitude rows (35–45°N, where the jet lives) are
//       averaged into one number per longitude. That array is the jet-stream
//       wave, straightened out.
//
//    3. FIND the extrema, keeping only those that stand out from their
//       surroundings.
//
//    4. PLACE the home point in the wave: which side of the trough it is on.
//
//  THE REFERENCE MEAN IS THE WHOLE LATITUDE CIRCLE, NOT THE MAP. The textbook
//  definition of a ridge is "higher than this latitude elsewhere", which is the
//  ZONAL mean — every longitude around the globe. Averaging only the US columns
//  is cheaper but wrong in a way that matters: one broad western trough drags the
//  row mean down, and a ridge downstream of it reads as near zero — or below.
//  The regional mean is kept as a comparison (`WaveReference.regional`).
//
//  WHAT THE COMPARISON CAN AND CAN'T CHANGE. Switching reference shifts each row
//  by a constant, so the profile shifts by a constant too — and relief (step 3)
//  is blind to a shift. The NAMED ridges and troughs, their axes and your side of
//  the trough are therefore identical under both references, by construction.
//  What changes is everything read against ZERO: the colours in the table, the
//  shading under the wave, and your own deviation. Against the whole latitude,
//  the whole country can sit +5 dam high; against the US mean it never can. That
//  difference — "ridged relative to what?" — is the lesson the toggle teaches.
//
//  WHY NOT A CLIMATOLOGICAL MEAN. Subtracting the long-term normal for the date
//  gives an ANOMALY chart, which answers a different question ("is this unusual
//  for September?"). The normal already contains waves of its own — a mean ridge
//  over the Rockies, a mean trough over the East in the cool season — so anomaly
//  "troughs" disagree with the troughs on an ordinary height chart. That would be
//  the thing learned and then unlearned.
//

import Foundation

// MARK: - Grid

/// Where the field is sampled. Rows run north → south and columns west → east,
/// the way the chart is read. Longitudes are degrees EAST (west is negative).
public struct UpperAirGrid: Codable, Equatable, Sendable {
    public var west: Double
    public var east: Double
    public var north: Double
    public var south: Double
    public var step: Double
    /// The rows averaged into the wave profile. 25°N sits under the subtropical
    /// high and 50°N is often north of the jet; including either washes the wave
    /// out.
    public var midLatitudes: ClosedRange<Double>
    /// Spacing of the ring sampled around each latitude for the zonal mean. The
    /// waves that matter at 500 mb have wavelengths of thousands of kilometres —
    /// tens of degrees — so 36 samples per circle average them away cleanly.
    public var ringStep: Double

    public init(west: Double, east: Double, north: Double, south: Double, step: Double,
                midLatitudes: ClosedRange<Double>, ringStep: Double = 10) {
        self.west = west
        self.east = east
        self.north = north
        self.south = south
        self.step = step
        self.midLatitudes = midLatitudes
        self.ringStep = ringStep
    }

    /// The contiguous US: 125°W–70°W, 50°N–25°N, every 5°.
    public static let conus = UpperAirGrid(west: -125, east: -70, north: 50, south: 25,
                                           step: 5, midLatitudes: 35...45)

    /// North → south.
    public var latitudes: [Double] {
        let count = Int(((north - south) / step).rounded()) + 1
        return (0..<count).map { north - Double($0) * step }
    }

    /// West → east.
    public var longitudes: [Double] {
        let count = Int(((east - west) / step).rounded()) + 1
        return (0..<count).map { west + Double($0) * step }
    }

    /// Every longitude of the zonal ring, −180 up to (not including) +180.
    public var ringLongitudes: [Double] {
        let count = Int((360 / ringStep).rounded())
        return (0..<count).map { -180 + Double($0) * ringStep }
    }

    /// Indices of the rows that make up the wave profile.
    public var midRows: [Int] {
        latitudes.indices.filter { midLatitudes.contains(latitudes[$0]) }
    }
}

// MARK: - Field

/// One valid time's 500 mb heights, in decameters.
public struct HeightField: Codable, Equatable, Sendable {
    /// `[row][column]`, rows north → south, columns west → east.
    public var heights: [[Double]]
    /// One per row: the mean height around the entire latitude circle.
    public var zonalMeans: [Double]
    /// The height at the home point itself — sampled there rather than read off
    /// the nearest grid cell, which can be 2–3° away.
    public var home: Double?
    /// 1000–500 mb THICKNESS at home, dam — the depth of the lower half of the
    /// atmosphere, which its temperature sets. See `LayerTemperature`.
    public var homeThickness: Double?
    /// The model's own 500 mb wind at home.
    public var homeWind: UpperWind?

    public init(heights: [[Double]], zonalMeans: [Double], home: Double? = nil,
                homeThickness: Double? = nil, homeWind: UpperWind? = nil) {
        precondition(heights.count == zonalMeans.count, "one zonal mean per row")
        self.heights = heights
        self.zonalMeans = zonalMeans
        self.home = home
        self.homeThickness = homeThickness
        self.homeWind = homeWind
    }
}

/// What each row is compared against.
public enum WaveReference: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The whole latitude circle. The standard definition; the default.
    case zonal
    /// Only the grid's own columns. Kept for comparison.
    case regional

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .zonal:    return "Whole latitude"
        case .regional: return "US only"
        }
    }
}

// MARK: - Features

public struct WaveFeature: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case ridge, trough }

    public var kind: Kind
    /// The grid column the extremum was detected at.
    public var column: Int
    /// The axis longitude, estimated BETWEEN grid columns by fitting a parabola
    /// through the extremum and its two neighbours. On a 5° grid the raw column
    /// can be 2.5° from the real axis, which is the whole width of "on the axis".
    public var longitude: Double
    /// The profile's value at the estimated axis, dam.
    public var value: Double
    /// How far the feature stands out from the wave on either side of it, dam —
    /// see `WavePattern.relief`.
    public var relief: Double

    public init(kind: Kind, column: Int, longitude: Double, value: Double, relief: Double) {
        self.kind = kind
        self.column = column
        self.longitude = longitude
        self.value = value
        self.relief = relief
    }
}

/// Where the home point sits in the wave.
public struct WavePosition: Equatable, Sendable {
    public enum Side: Equatable, Sendable {
        /// Downstream of a trough (or upstream of a ridge): southwest flow aloft,
        /// the side that favours rising air and moisture return.
        case eastOfTrough
        /// Upstream of a trough (or downstream of a ridge): northwest flow aloft,
        /// sinking air, typically cooler and drier.
        case westOfTrough
        case troughAxis
        case ridgeAxis
        /// Nothing in the window stands out enough to name.
        case flat
    }

    public var side: Side
    /// The trough that `side` is measured against, when one is in the window.
    public var trough: WaveFeature?
    /// The ridge on the other side of the home point, when one is in the window.
    public var ridge: WaveFeature?
    /// The closest named feature of either kind.
    public var nearest: WaveFeature?

    public init(side: Side, trough: WaveFeature? = nil, ridge: WaveFeature? = nil,
                nearest: WaveFeature? = nil) {
        self.side = side
        self.trough = trough
        self.ridge = ridge
        self.nearest = nearest
    }
}

/// Everything the reader shows for one frame under one reference.
public struct WaveAnalysis: Equatable, Sendable {
    public var reference: WaveReference
    /// `[row][column]`, dam from the reference mean.
    public var deviations: [[Double]]
    /// One per longitude.
    public var profile: [Double]
    /// West → east.
    public var features: [WaveFeature]
    public var homeHeight: Double?
    public var homeDeviation: Double?
    public var position: WavePosition?
}

// MARK: - The algorithm

public enum WavePattern {
    /// How far a ridge or trough must stand out from the wave around it to be
    /// named, dam. At 40°N the long waves run ±10–20 dam; below about 2.5 a bump
    /// is within what a 5° grid can't distinguish from noise.
    public static let reliefThreshold = 2.5

    /// Within this many degrees of an axis, the home point is ON it rather than
    /// to one side. Half a grid step.
    public static let onAxisDegrees = 2.5

    /// Step 1. Each row minus its reference mean.
    public static func deviations(_ field: HeightField, reference: WaveReference) -> [[Double]] {
        field.heights.enumerated().map { row, heights in
            let mean = reference == .zonal ? field.zonalMeans[row] : average(heights)
            return heights.map { $0 - mean }
        }
    }

    /// Step 2. The mean deviation down each column, over `rows` only.
    public static func profile(_ deviations: [[Double]], rows: [Int]) -> [Double] {
        guard let columns = deviations.first?.count, !rows.isEmpty else { return [] }
        return (0..<columns).map { column in
            average(rows.map { deviations[$0][column] })
        }
    }

    /// Step 3. Local extrema that stand out by at least `threshold`.
    ///
    /// A CANDIDATE is the rule a chart reader uses: higher than the column to the
    /// west and at least as high as the one to the east (a ridge), or the mirror
    /// image (a trough). The first and last columns can't be candidates, because
    /// the wave beyond the window is unseen — an edge value may be the shoulder of
    /// a feature, not its axis.
    ///
    /// A candidate is KEPT by its RELIEF, not by its sign. Against the zonal mean
    /// the whole US can sit high — a hot late summer puts every column at +5 or
    /// more — and a real trough can bottom out at +1. Asking "is it below −2.5"
    /// would never name it; asking "does it dip 2.5 below the wave on both sides"
    /// does, and that is what makes it a trough on a chart.
    public static func features(profile: [Double], longitudes: [Double],
                                threshold: Double = reliefThreshold) -> [WaveFeature] {
        guard profile.count >= 3, profile.count == longitudes.count else { return [] }
        let step = longitudes[1] - longitudes[0]
        var found: [WaveFeature] = []
        for j in 1..<(profile.count - 1) {
            let (a, b, c) = (profile[j - 1], profile[j], profile[j + 1])
            let kind: WaveFeature.Kind
            if b > a && b >= c { kind = .ridge }
            else if b < a && b <= c { kind = .trough }
            else { continue }

            let r = relief(profile, at: j, kind: kind)
            guard r >= threshold else { continue }

            let (offset, peak) = vertex(a, b, c)
            found.append(WaveFeature(kind: kind, column: j,
                                     longitude: longitudes[j] + offset * step,
                                     value: peak, relief: r))
        }
        return found
    }

    /// How far the extremum at `j` stands above (ridge) or below (trough) the
    /// wave on its flanks. Walk outward on each side for as long as the profile
    /// keeps moving away from the extremum; where it turns (or the window ends) is
    /// that side's floor. Relief is measured to the HIGHER floor for a ridge — the
    /// shallower side — so a bump on the shoulder of a larger feature isn't
    /// credited with the larger feature's depth.
    static func relief(_ p: [Double], at j: Int, kind: WaveFeature.Kind) -> Double {
        // Moving away from a ridge means descending; from a trough, climbing.
        func continues(_ from: Double, _ to: Double) -> Bool {
            kind == .ridge ? to <= from : to >= from
        }
        var left = j - 1
        while left > 0, continues(p[left], p[left - 1]) { left -= 1 }
        var right = j + 1
        while right < p.count - 1, continues(p[right], p[right + 1]) { right += 1 }

        switch kind {
        case .ridge:  return p[j] - max(p[left], p[right])
        case .trough: return min(p[left], p[right]) - p[j]
        }
    }

    /// The vertex of the parabola through three evenly spaced values: its offset
    /// from the middle sample in steps (clamped to ±½), and its value.
    static func vertex(_ a: Double, _ b: Double, _ c: Double) -> (offset: Double, value: Double) {
        let curvature = a - 2 * b + c
        guard abs(curvature) > 1e-9 else { return (0, b) }
        let offset = min(0.5, max(-0.5, 0.5 * (a - c) / curvature))
        return (offset, b - 0.25 * (a - c) * offset)
    }

    /// Step 4. Where `longitude` sits among the features.
    ///
    /// Judged by the features that BRACKET the point, not simply the nearest
    /// trough. Weather moves west to east, so what governs the flow over you is
    /// the axis immediately upstream or downstream. The nearest trough can be on
    /// the far side of a ridge that is directly over you, and "west of that
    /// trough" would then describe the wrong half of the wave.
    ///
    /// Of the two bracketing features, the nearer one decides. A trough to your
    /// west or a ridge to your east both put you in southwest flow ahead of the
    /// trough; a ridge to your west or a trough to your east both put you in
    /// northwest flow behind it.
    public static func position(of longitude: Double, among features: [WaveFeature],
                                onAxis: Double = onAxisDegrees) -> WavePosition {
        let nearest = features.min { abs($0.longitude - longitude) < abs($1.longitude - longitude) }
        guard let nearest else { return WavePosition(side: .flat) }

        if abs(nearest.longitude - longitude) <= onAxis {
            return WavePosition(side: nearest.kind == .trough ? .troughAxis : .ridgeAxis,
                                trough: nearest.kind == .trough ? nearest : nil,
                                ridge: nearest.kind == .ridge ? nearest : nil,
                                nearest: nearest)
        }

        let upstream = features.last { $0.longitude < longitude }
        let downstream = features.first { $0.longitude > longitude }
        let upstreamIsNearer = nearest == upstream

        func of(_ kind: WaveFeature.Kind, _ f: WaveFeature?) -> WaveFeature? {
            f?.kind == kind ? f : nil
        }

        let governing = upstreamIsNearer ? upstream! : downstream!
        let ahead = (upstreamIsNearer && governing.kind == .trough)
                 || (!upstreamIsNearer && governing.kind == .ridge)
        if ahead {
            return WavePosition(side: .eastOfTrough,
                                trough: of(.trough, upstream), ridge: of(.ridge, downstream),
                                nearest: nearest)
        } else {
            return WavePosition(side: .westOfTrough,
                                trough: of(.trough, downstream), ridge: of(.ridge, upstream),
                                nearest: nearest)
        }
    }

    /// The reference mean at an arbitrary latitude, interpolated between rows.
    /// Clamped at the grid's north and south edges rather than extrapolated.
    public static func referenceMean(atLatitude latitude: Double, field: HeightField,
                                     grid: UpperAirGrid, reference: WaveReference) -> Double? {
        let lats = grid.latitudes
        guard !lats.isEmpty, field.heights.count == lats.count else { return nil }
        let means = reference == .zonal ? field.zonalMeans : field.heights.map(average)
        if latitude >= lats[0] { return means[0] }
        if latitude <= lats[lats.count - 1] { return means[lats.count - 1] }
        for i in 0..<(lats.count - 1) where latitude <= lats[i] && latitude >= lats[i + 1] {
            let t = (lats[i] - latitude) / (lats[i] - lats[i + 1])
            return means[i] + t * (means[i + 1] - means[i])
        }
        return nil
    }

    /// Steps 1–4 for one frame.
    public static func analyze(_ field: HeightField, grid: UpperAirGrid,
                               reference: WaveReference = .zonal, home: GeoPoint?,
                               threshold: Double = reliefThreshold,
                               onAxis: Double = onAxisDegrees) -> WaveAnalysis {
        let dev = deviations(field, reference: reference)
        let prof = profile(dev, rows: grid.midRows)
        let found = features(profile: prof, longitudes: grid.longitudes, threshold: threshold)

        var homeDeviation: Double?
        if let home, let height = field.home,
           let mean = referenceMean(atLatitude: home.latitude, field: field, grid: grid,
                                    reference: reference) {
            homeDeviation = height - mean
        }
        return WaveAnalysis(reference: reference, deviations: dev, profile: prof,
                            features: found, homeHeight: field.home,
                            homeDeviation: homeDeviation,
                            position: home.map { position(of: $0.longitude, among: found, onAxis: onAxis) })
    }

    static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
