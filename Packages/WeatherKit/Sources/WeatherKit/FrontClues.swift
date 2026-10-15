//
//  FrontClues.swift  (WeatherKit)
//
//  READING A FRONT THE WAY A FORECASTER DOES: not one number, but several that
//  change together along a line.
//
//  WHAT MARKS IT: THE WIND SHIFT. A point the front has JUST PASSED is one
//  where the wind now blows from the north and, three hours ago, didn't. That
//  is where forecasters draw a cold front, because it is where the cold air's
//  leading edge actually is. Those points form a band along the front, about
//  three hours deep, and the band is what the map and the headline use.
//
//  IT USED TO NEED A DEWPOINT DROP AS WELL, and that was wrong. On 2026-10-15
//  the HRRR had the wind at Pottsville flip north at 8 PM, gusts up to 31 mph,
//  the temperature down 9°F in an hour and the pressure climbing, while the
//  dewpoint sat at 65°F for five more hours. The first air behind a front is
//  often still humid; the dry air comes later. Requiring both put the front
//  six hours behind where it was.
//
//  THE OTHER FOUR ARE THE CHECK. Pressure, gusts, temperature and dewpoint play
//  no part in finding the band, so what they do inside it is independent
//  evidence, listed roughly in the order they tend to arrive. Each line says
//  whether it agrees, and some often don't YET: an afternoon sun holds the
//  temperature up, and the dewpoint can lag by hours. Showing that is the
//  point. Hiding it would teach that a front is a temperature drop, which is
//  the wrong lesson.
//

import Foundation

/// One of the things a front changes, in the order the checklist lists them:
/// the wind that finds it, then the four that confirm it, roughly in the order
/// they tend to show.
public enum FrontClue: String, CaseIterable, Sendable, Identifiable {
    case wind, pressure, gusts, temperature, dewPoint

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .wind:        return "Wind"
        case .dewPoint:    return "Dewpoint"
        case .pressure:    return "Pressure"
        case .gusts:       return "Gusts"
        case .temperature: return "Temperature"
        }
    }

    /// The one that finds the front. The others only confirm it.
    public var marksTheFront: Bool { self == .wind }

    /// What to look for and why it happens — the line's hint.
    public var mechanism: String {
        switch self {
        case .wind:
            return "Ahead of a cold front the wind blows in from the Gulf; behind it, from the north. The flip happens along the front itself, which is why it marks the front here."
        case .dewPoint:
            return "Dewpoint is how much water is in the air. The air behind the front came from the dry interior, so the dewpoint falls, often by 20°F or more. It can lag by hours: the first air behind the front is often still humid."
        case .pressure:
            return "Cold, dry air is heavier. As it slides in underneath, the pressure rises."
        case .gusts:
            return "The cold air pushes in like a wedge and the wind behind it is gusty while it settles."
        case .temperature:
            return "Depends on the time of day. At night it drops as soon as the front arrives. During the day, sunshine can hold it up for hours after the front passes."
        }
    }
}

/// What the clues say at one hour.
public struct FrontReading: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public var clue: FrontClue
        /// Plain numbers: "Down 14°F in 3 hours · 52°F behind it, 71°F ahead".
        public var statement: String
        /// Whether this clue agrees there's a front. Always true for the two
        /// that find it.
        public var agrees: Bool
        public var id: FrontClue { clue }
    }

    /// Per grid point: the front passed here in the last three hours.
    public var justPassed: [Bool]
    /// Empty when there is no front on the map.
    public var lines: [Line]
    /// From home to the front's edge: the nearest point it just passed while
    /// it's still coming, or the nearest point it hasn't reached once home is
    /// behind it.
    public var milesFromHome: Double?
    /// "north-northwest", from home.
    public var directionFromHome: String?
    /// Home is in the band: the front came through in the last three hours.
    public var passingHome: Bool
    /// The front is through home: home is in the band, or has the north wind
    /// that is still behind it. Either way the edge is somewhere ahead.
    public var throughHome: Bool

    public var found: Bool { !lines.isEmpty }
}

public enum FrontReader {
    /// °F the dewpoint must fall in three hours to count as agreeing.
    public static let dewpointDrop = 3.0
    /// Fewer points than this is a wobble, not a front.
    public static let minimumPoints = 6
    /// mph. The wind behind a front blows; a light wind turning is a wobble.
    public static let minimumWind = 8.0
    /// How far ahead of the band counts as "ahead of it", in miles.
    static let aheadReach = 150.0

    /// Which points the front passed in the three hours to `index`. Nil when the
    /// run doesn't reach three hours before it.
    ///
    /// A point only counts with a neighbour that also does. A front is a line
    /// hundreds of miles long; one point on its own whose wind turned is a
    /// light wind wandering, and on 2026-10-15 those were what put a "front"
    /// 240 miles away on the Saturday after it had gone.
    public static func justPassed(_ run: SurfaceRun, at index: Int) -> [Bool]? {
        guard let back = run.index(index, minusHours: 3) else { return nil }
        let now = run.hours[index].readings, then = run.hours[back].readings
        let turned: [Bool] = zip(now, then).map { pair in
            guard let n = pair.0, let t = pair.1 else { return false }
            return n.isNortherly && n.windSpeed >= minimumWind && !t.isNortherly
        }
        let grid = run.grid
        return turned.indices.map { i in
            guard turned[i] else { return false }
            let r = i / grid.cols, c = i % grid.cols
            for dr in -1...1 {
                for dc in -1...1 where dr != 0 || dc != 0 {
                    let rr = r + dr, cc = c + dc
                    if (0..<grid.rows).contains(rr), (0..<grid.cols).contains(cc),
                       turned[grid.index(row: rr, col: cc)] { return true }
                }
            }
            return false
        }
    }

    public static func read(_ run: SurfaceRun, at index: Int, home: GeoPoint?) -> FrontReading? {
        guard let band = justPassed(run, at: index), let back = run.index(index, minusHours: 3) else { return nil }
        let grid = run.grid
        let now = run.hours[index].readings, then = run.hours[back].readings
        let inBand = band.indices.filter { band[$0] }
        var reading = FrontReading(justPassed: band, lines: [], milesFromHome: nil,
                                   directionFromHome: nil, passingHome: false, throughHome: false)

        if let home, let h = nearest(grid, to: home) {
            reading.passingHome = band[h]
            // Behind it from an earlier hour: the north wind is still there and
            // the front did pass. The second half matters — a north wind at
            // home BEFORE the front is a morning wobble, not the front.
            reading.throughHome = band[h] || ((now[h]?.isNortherly ?? false)
                && (passage(run, home: home).map { $0 <= run.hours[index].valid } ?? false))
        }
        guard inBand.count >= minimumPoints else { return reading }

        // AHEAD: Gulf air within reach of the band, not yet reached.
        let bandPoints = inBand.map(grid.point)
        let ahead = band.indices.filter { i in
            guard !band[i], let r = now[i], r.isSoutherly else { return false }
            let p = grid.point(i)
            return bandPoints.contains { miles(p, $0) <= aheadReach }
        }

        func values(_ indices: [Int], _ f: (SurfaceReading) -> Double?) -> [Double] {
            indices.compactMap { now[$0].flatMap(f) }
        }
        func changes(_ f: (SurfaceReading) -> Double?) -> [Double] {
            inBand.compactMap { i in
                guard let n = now[i].flatMap(f), let t = then[i].flatMap(f) else { return nil }
                return n - t
            }
        }

        // Wind.
        let behindFrom = circularMean(values(inBand) { $0.windFrom })
        let aheadFrom = circularMean(values(ahead) { $0.windFrom })
        var wind = "From the \(behindFrom.map(compass8) ?? "north") where it just passed"
        if let aheadFrom { wind += ", from the \(compass8(aheadFrom)) ahead of it" }
        reading.lines.append(.init(clue: .wind, statement: wind, agrees: true))

        // Pressure.
        if let rise = median(changes { $0.pressure }) {
            let whole = Int(rise.rounded())
            let text = whole == 0 ? "Steady, within 1 mb in 3 hours"
                : whole > 0 ? "Up \(whole) mb in 3 hours" : "Down \(-whole) mb in 3 hours"
            reading.lines.append(.init(clue: .pressure, statement: text, agrees: rise >= 0.75))
        } else {
            reading.lines.append(.init(clue: .pressure, statement: "No pressure in this run", agrees: false))
        }

        // Gusts.
        let behindGust = median(values(inBand) { $0.gust ?? $0.windSpeed })
        let aheadGust = median(values(ahead) { $0.gust ?? $0.windSpeed })
        if let behindGust {
            var text = "\(Int(behindGust.rounded())) mph behind it"
            if let aheadGust { text += ", \(Int(aheadGust.rounded())) mph ahead" }
            reading.lines.append(.init(clue: .gusts, statement: text,
                                       agrees: behindGust - (aheadGust ?? 0) >= 5))
        }

        // Temperature.
        let cooled = median(changes { $0.temperature }) ?? 0
        let whole = Int(cooled.rounded())
        let temp = abs(whole) < 3 ? "About the same, within 3°F in 3 hours"
            : whole < 0 ? "Down \(-whole)°F in 3 hours" : "Up \(whole)°F in 3 hours"
        reading.lines.append(.init(clue: .temperature, statement: temp, agrees: cooled <= -3))

        // Dewpoint.
        let dewDrop = median(changes { $0.dewPoint }) ?? 0
        let dewWhole = Int(dewDrop.rounded())
        var dew = abs(dewWhole) < 3 ? "About the same, within 3°F in 3 hours"
            : dewWhole < 0 ? "Down \(-dewWhole)°F in 3 hours" : "Up \(dewWhole)°F in 3 hours"
        if let behind = median(values(inBand) { $0.dewPoint }), let front = median(values(ahead) { $0.dewPoint }) {
            dew += " · \(Int(behind.rounded()))°F behind it, \(Int(front.rounded()))°F ahead"
        }
        reading.lines.append(.init(clue: .dewPoint, statement: dew, agrees: dewDrop <= -dewpointDrop))

        // Where its edge is from home: the band while it's coming, the air it
        // hasn't reached yet once it's through.
        let edge = reading.passingHome ? ahead.map(grid.point) : bandPoints
        if let home, let closest = edge.min(by: { miles(home, $0) < miles(home, $1) }) {
            reading.milesFromHome = miles(home, closest)
            reading.directionFromHome = compass16(bearing(from: home, to: closest))
        }
        return reading
    }

    /// The hour the front reaches home in this run, or nil if it never does.
    /// Can be in the past: the run starts a few hours back.
    ///
    /// The band is three hours deep, so the first hour home is IN it can be up
    /// to three hours after the front arrived. The arrival is the hour the wind
    /// turned north and stayed there, found by walking back from that point.
    public static func passage(_ run: SurfaceRun, home: GeoPoint) -> Date? {
        guard let h = nearest(run.grid, to: home) else { return nil }
        for index in run.hours.indices {
            guard let band = justPassed(run, at: index), band[h] else { continue }
            var arrived = index
            while arrived > 0, index - (arrived - 1) <= 3,
                  run.hours[arrived - 1].readings[h]?.isNortherly == true {
                arrived -= 1
            }
            return run.hours[arrived].valid
        }
        return nil
    }

    // MARK: Geometry

    /// The grid point nearest `p`, if `p` is inside the grid.
    static func nearest(_ grid: SurfaceGrid, to p: GeoPoint) -> Int? {
        guard let lat0 = grid.latitudes.first, let lon0 = grid.longitudes.first,
              grid.rows > 1, grid.cols > 1 else { return nil }
        let r = Int(((p.latitude - lat0) / (grid.latitudes[1] - lat0)).rounded())
        let c = Int(((p.longitude - lon0) / (grid.longitudes[1] - lon0)).rounded())
        guard (0..<grid.rows).contains(r), (0..<grid.cols).contains(c) else { return nil }
        return grid.index(row: r, col: c)
    }

    public static func miles(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let rad = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * rad, dLon = (b.longitude - a.longitude) * rad
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * rad) * cos(b.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 3958.8 * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let rad = Double.pi / 180
        let y = sin((b.longitude - a.longitude) * rad) * cos(b.latitude * rad)
        let x = cos(a.latitude * rad) * sin(b.latitude * rad)
            - sin(a.latitude * rad) * cos(b.latitude * rad) * cos((b.longitude - a.longitude) * rad)
        return (atan2(y, x) / rad + 360).truncatingRemainder(dividingBy: 360)
    }

    static func compass8(_ degrees: Double) -> String {
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        return names[Int((degrees / 45).rounded()) % 8]
    }

    static func compass16(_ degrees: Double) -> String {
        let names = ["north", "north-northeast", "northeast", "east-northeast",
                     "east", "east-southeast", "southeast", "south-southeast",
                     "south", "south-southwest", "southwest", "west-southwest",
                     "west", "west-northwest", "northwest", "north-northwest"]
        return names[Int((degrees / 22.5).rounded()) % 16]
    }

    // MARK: Averages

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Directions averaged as directions: 350° and 10° average to north, not south.
    static func circularMean(_ degrees: [Double]) -> Double? {
        guard !degrees.isEmpty else { return nil }
        let rad = Double.pi / 180
        let s = degrees.reduce(0) { $0 + sin($1 * rad) }, c = degrees.reduce(0) { $0 + cos($1 * rad) }
        guard abs(s) + abs(c) > 1e-9 else { return nil }
        return (atan2(s, c) / rad + 360).truncatingRemainder(dividingBy: 360)
    }
}
