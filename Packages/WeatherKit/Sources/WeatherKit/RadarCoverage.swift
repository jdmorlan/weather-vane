//
//  RadarCoverage.swift  (WeatherKit)
//
//  What one radar can see, as rings on the map: the edge of its reach, and how
//  high its lowest beam has climbed by each distance.
//
//  BOTH ARE READ FROM THE SCAN, NOT ASSUMED. The site's position comes from the
//  volume's own "RVOL" block and the reach from the last gate of the sweep —
//  so the boundary is exactly where this radar's data stops, and if a site
//  runs a shorter pattern the ring moves with it.
//
//  WHY HEIGHT RINGS AND NOT PLAIN DISTANCE RINGS. An old scope's rings said how
//  far away; that is the less useful half. The beam leaves at 0.5° and the
//  Earth curves away beneath it, so by 230 km it is passing 5 km over the
//  ground — above the base of most rain and far above drizzle. A storm that
//  looks weak out there may be a strong one seen from above its heaviest
//  part, and light rain under the beam can be invisible altogether. A ring
//  that says "beam 10,000 ft" is what lets someone read that off the map
//  instead of having to know it.
//

import Foundation

public struct RadarCoverage: Equatable, Sendable {
    public let site: String
    public let latitude: Double
    public let longitude: Double
    /// The lowest tilt, degrees. The rings describe this beam.
    public let elevation: Double
    /// Furthest ground distance the sweep reaches, metres.
    public let reach: Double

    public init(site: String, latitude: Double, longitude: Double, elevation: Double, reach: Double) {
        self.site = site; self.latitude = latitude; self.longitude = longitude
        self.elevation = elevation; self.reach = reach
    }

    /// From a decoded sweep. The reach is the last gate's slant range brought
    /// down to the ground.
    public init(site: String, latitude: Double, longitude: Double, sweep: Level2Sweep) {
        self.init(site: site, latitude: latitude, longitude: longitude,
                  elevation: sweep.elevationAngle,
                  reach: RadarGeometry.groundRange(slant: sweep.maxRange, elevation: sweep.elevationAngle))
    }

    public struct Ring: Equatable, Sendable, Identifiable {
        public enum Kind: Sendable { case reach, beamHeight }
        public let kind: Kind
        /// Ground distance from the site, metres.
        public let radius: Double
        /// Beam centre height above the radar at that distance, feet.
        public let beamFeet: Double
        public var id: String { "\(kind)-\(Int(radius))" }

        public var miles: Int { Int((radius / 1609.344).rounded()) }

        /// What the ring says on the map.
        public var label: String {
            switch kind {
            case .reach:      return "edge of coverage · \(miles) mi"
            case .beamHeight: return "beam \(Int(beamFeet).formatted()) ft up · \(miles) mi"
            }
        }
    }

    /// The altitudes that get a ring. 5,000 ft is about where rain begins in a
    /// summer storm's cloud base; 10,000 ft is above most light rain; 20,000 ft
    /// is into the upper half of a thunderstorm. Past each one the radar is
    /// seeing a different part of the weather than the part that reaches you.
    public static let ringAltitudes: [Double] = [5_000, 10_000, 20_000]

    public var rings: [Ring] {
        let heights = Self.ringAltitudes.compactMap { feet -> Ring? in
            let ground = groundDistance(whereBeamReachesMeters: feet * 0.3048)
            guard ground < reach * 0.97 else { return nil }
            return Ring(kind: .beamHeight, radius: ground, beamFeet: feet)
        }
        let edge = Ring(kind: .reach, radius: reach, beamFeet: beamFeet(atGround: reach))
        return heights + [edge]
    }

    public func beamFeet(atGround ground: Double) -> Double {
        let slant = RadarGeometry.slantRange(ground: ground, elevation: elevation)
        return RadarGeometry.beamHeight(slantRange: slant, elevation: elevation) / 0.3048
    }

    /// Bisection: beam height rises monotonically with range, so this is exact
    /// to a metre in a few dozen steps and never needs the closed form.
    func groundDistance(whereBeamReachesMeters target: Double) -> Double {
        var lo = 0.0, hi = 1_000_000.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if beamFeet(atGround: mid) * 0.3048 < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}
