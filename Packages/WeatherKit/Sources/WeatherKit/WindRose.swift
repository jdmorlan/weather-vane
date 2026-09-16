//
//  WindRose.swift  (WeatherKit)
//
//  WHICH WAY THE WIND COMES FROM HERE, and whether "prevailing" is even a word
//  that applies to this place.
//
//  Every other measure in this kit reduces to a number you can average. Direction
//  does not: the mean of 350° and 10° is 180°, which is the exact opposite of the
//  truth. That is why `DailyRecord` has `windAvgMean` and `windGustMax` and no
//  direction at all — the daily rollup was right to refuse rather than store a
//  meaningless number, and the cost of being right is that the question "what is
//  the prevailing wind" could not be asked of the archive at all. It can be asked
//  of SAMPLES, where direction needs no reduction, which is the concrete payoff
//  [[samples-are-the-record]] was written in anticipation of.
//
//  TWO ANSWERS, AND THEY DISAGREE ON PURPOSE.
//
//  The MODE — the sector the wind occupies for the most minutes — is what a person
//  means by "the wind here comes from the south". The RESULTANT — the vector sum of
//  every reading — is what the air actually did on net. A place whose wind alternates
//  between two opposed sectors (a valley that drains downhill at night and breathes
//  back up by day; a coast with a sea breeze) has a strong mode and a resultant near
//  zero, and reporting either one alone would be a lie about the place. So both are
//  kept, and `constancy` — the resultant's length over the mean speed, the standard
//  steadiness ratio — is a THIRD fact rather than a referee between them: it says how
//  reliably the wind holds whatever direction it favours.
//
//  Whether a place HAS a prevailing wind is `dominantArc` and `isSplit`, not
//  constancy. This station scores 0.31 — restless, on net going almost nowhere — and
//  is nonetheless southerly 39% of the time, which is as clear a prevailing wind as
//  a station gets. Gating the word on constancy produced exactly that denial, and
//  the arc is what replaced it.
//
//  WEIGHTED BY MINUTES, NEVER BY SAMPLE COUNT. The archive holds 30-minute buckets
//  from the original backfill next to 1-minute readings from the collector, and
//  counting rows would let one well-sampled month outvote a year. `bucketMinutes`
//  travels with the sample precisely so a duration can be recovered, and a rose is
//  a statement about TIME — "a third of the year the wind is from the south" — so
//  minutes are the only honest weight.
//
//  CALM IS NOT A DIRECTION. A station reporting 0.0 mph reports a direction anyway,
//  usually a stale one or a hard zero, and letting those in stacks a spike on north
//  that is pure instrument artefact. Calm minutes are counted and set aside; every
//  fraction here is a fraction of the MOVING minutes, and `calmFraction` says how
//  much of the record that left out.
//

import Foundation

/// A speed class, in mph. Roughly Beaufort, named the way a person would say it —
/// the bands exist so a rose can show that the south wind is a pleasant daily breeze
/// while the rarer north wind is what actually knocks the fence over.
public struct WindBand: Codable, Equatable, Sendable {
    public var lower: Double
    public var upper: Double?
    public var name: String

    public init(lower: Double, upper: Double?, name: String) {
        self.lower = lower
        self.upper = upper
        self.name = name
    }

    public func contains(_ speed: Double) -> Bool {
        speed >= lower && (upper.map { speed < $0 } ?? true)
    }

    /// The default ladder. `calmThreshold` is the bottom of the first band, so the
    /// bands and the calm cut can never drift apart.
    public static let standard: [WindBand] = [
        WindBand(lower: 1,  upper: 4,  name: "light"),
        WindBand(lower: 4,  upper: 8,  name: "gentle"),
        WindBand(lower: 8,  upper: 13, name: "moderate"),
        WindBand(lower: 13, upper: 19, name: "fresh"),
        WindBand(lower: 19, upper: 25, name: "strong"),
        WindBand(lower: 25, upper: nil, name: "gale"),
    ]

    /// Below this the reading is calm and its direction is noise.
    public static let calmThreshold: Double = 1
}

/// One of the sixteen compass points, as the record saw it.
public struct WindSector: Codable, Equatable, Sendable {
    /// 0 = N, stepping clockwise by 22.5°.
    public var index: Int
    /// The bin's centre bearing — the direction the wind comes FROM.
    public var degrees: Double
    public var compass: String
    /// Minutes the wind blew from this sector, calm excluded.
    public var minutes: Double
    /// Share of all moving minutes, 0…1.
    public var fraction: Double
    /// Mean speed while it blew from here. A sector can be rare and vicious.
    public var meanSpeed: Double
    /// Strongest gust ever recorded out of this sector.
    public var peakGust: Double?
    /// Minutes per band, parallel to the rose's `bands` — the stack a drawn rose needs.
    public var bandMinutes: [Double]
}

/// Where the wind comes from at one station, over whatever span was fed in.
public struct WindRose: Codable, Equatable, Sendable {
    /// Always sixteen, in compass order starting at N, including empty ones — a
    /// drawn rose needs the gaps as much as the spokes.
    public var sectors: [WindSector]
    public var bands: [WindBand]

    public var movingMinutes: Double
    public var calmMinutes: Double
    /// Minutes of readings that carried a speed but no direction. Usually zero;
    /// non-zero means something is wrong with the vane, which is worth seeing.
    public var undirectedMinutes: Double

    /// Mean speed across moving minutes.
    public var meanSpeed: Double
    /// The vector-sum bearing: what the air did on net.
    public var resultantDegrees: Double
    /// Resultant length over mean speed, 0…1. 1 = the wind never varies; 0 = it
    /// cancels itself out entirely.
    ///
    /// This says how STEADY the wind is, not whether it has a prevailing direction —
    /// those are different facts and reading this one as the other is a mistake this
    /// file made once already. A station can favour one quarter decisively and still
    /// score 0.2 because the minority blows from the opposite side and cancels the
    /// net. `dominantArc` answers "which way"; this answers "how reliably".
    public var constancy: Double
    public var peakGust: WindPeak?

    public var totalMinutes: Double { movingMinutes + calmMinutes + undirectedMinutes }
    public var calmFraction: Double { totalMinutes > 0 ? calmMinutes / totalMinutes : 0 }

    /// The sector the wind spent the most time in.
    public var prevailing: WindSector? {
        sectors.max { $0.minutes < $1.minutes }
    }

    /// The sector the strongest wind comes out of, which is often not the prevailing
    /// one and is the half of the answer that matters when you're siting a tree.
    public var strongest: WindSector? {
        sectors.filter { $0.minutes > 0 }.max { ($0.peakGust ?? 0) < ($1.peakGust ?? 0) }
    }

    /// THE PREVAILING WIND IS AN ARC, NOT A POINT, and mistaking one for the other
    /// is the single easiest way to misread a rose.
    ///
    /// Sixteen bins is the right resolution to DRAW at and the wrong one to speak
    /// from. A station with a thoroughly southerly wind splits it across SSE, S and
    /// SSW, and each of those can come in near 14% while the southerly quarter
    /// together owns nearly 40% — so the mode reports "S, 14%, more than any other
    /// direction", which is true, sounds weak, and buries the actual fact. Worse,
    /// the two top bins then look like a two-way split when they're adjacent halves
    /// of one broad maximum. Summing a contiguous window fixes both.
    ///
    /// Three bins (67.5°) is the default because it's about the width of a quarter
    /// of the compass as people say it — "out of the south" covers SSE to SSW.
    /// Ties break toward the arc whose CENTRE bin is heaviest, and that is not a
    /// detail: a broad maximum with a flat shoulder produces several windows holding
    /// identical minutes, and without an explicit rule the answer would be decided
    /// by which index the loop happened to reach first — so a wind squarely out of
    /// the south could be reported as south-southeast on a coin flip. The centred
    /// window is the better description of the same minutes.
    public func dominantArc(width: Int = 3) -> WindArc? {
        guard movingMinutes > 0 else { return nil }
        return (0..<16).map { arc(startingAt: $0, width: width) }.max {
            ($0.minutes, sectors[$0.sectors[$0.sectors.count / 2]].minutes)
                < ($1.minutes, sectors[$1.sectors[$1.sectors.count / 2]].minutes)
        }
    }

    /// The best arc that is genuinely ELSEWHERE — disjoint from `other` and not
    /// merely leaning against it. A bin of clear air on each side is what separates
    /// "a second wind regime" from "the shoulder of the first one".
    public func secondaryArc(to other: WindArc, width: Int = 3) -> WindArc? {
        let excluded = Set(other.sectors.flatMap { [($0 + 15) % 16, $0, ($0 + 1) % 16] })
        return (0..<16)
            .map { arc(startingAt: $0, width: width) }
            .filter { $0.sectors.allSatisfy { !excluded.contains($0) } }
            .max { $0.minutes < $1.minutes }
    }

    public func arc(startingAt start: Int, width: Int) -> WindArc {
        let w = max(1, min(16, width))
        let indices = (0..<w).map { (start + $0) % 16 }
        let minutes = indices.reduce(0.0) { $0 + sectors[$1].minutes }
        let speedMinutes = indices.reduce(0.0) { $0 + sectors[$1].meanSpeed * sectors[$1].minutes }
        return WindArc(sectors: indices,
                       minutes: minutes,
                       fraction: movingMinutes > 0 ? minutes / movingMinutes : 0,
                       meanSpeed: minutes > 0 ? speedMinutes / minutes : 0,
                       peakGust: indices.compactMap { sectors[$0].peakGust }.max(),
                       centerDegrees: sectors[indices[w / 2]].degrees,
                       from: sectors[indices[0]].compass,
                       to: sectors[indices[w - 1]].compass)
    }

    /// True when the wind genuinely ALTERNATES between two separated quarters —
    /// the sea-breeze, valley-drainage signature — rather than favouring one.
    ///
    /// This used to compare the mode against the resultant, which conflated two
    /// different things: a wind can favour one quarter decisively and still have a
    /// weak resultant, because a minority from the opposite side cancels it on net.
    /// That is a VARIABLE wind, not a split one, and the rose should say so.
    public var isSplit: Bool {
        guard let dominant = dominantArc(),
              let secondary = secondaryArc(to: dominant) else { return false }
        return secondary.fraction >= dominant.fraction * 0.7
    }

    /// Whether there are enough minutes to say anything. A rose over a week is a
    /// picture of last week's weather wearing a climatology's clothes.
    public func isRepresentative(minimumDays: Double = 30) -> Bool {
        totalMinutes >= minimumDays * 24 * 60
    }
}

/// A contiguous run of sectors, summed — the unit a person speaks in.
public struct WindArc: Codable, Equatable, Sendable {
    /// Sector indices in compass order, wrapping past N.
    public var sectors: [Int]
    public var minutes: Double
    public var fraction: Double
    public var meanSpeed: Double
    public var peakGust: Double?
    /// The middle sector's bearing.
    public var centerDegrees: Double
    public var from: String
    public var to: String

    public var compass: String { WindRose.compass(centerDegrees) }
}

public struct WindPeak: Codable, Equatable, Sendable {
    public var speed: Double
    public var timestamp: Int
    public var degrees: Double?
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
}

// MARK: - Building

/// Accumulates samples into a rose without ever holding them all.
///
/// The archive is one gzipped file per day and the span worth asking about is
/// years — 1,400 files and some two million samples. Decoding those into an array
/// to reduce it once would cost hundreds of megabytes of residency for a result
/// that is sixteen numbers wide. So the rose is built by streaming: read a day,
/// fold it in, drop it. It also makes the month-by-month build a single pass over
/// the archive instead of twelve.
public struct WindRoseBuilder: Codable, Sendable {
    public let bands: [WindBand]
    public let calmThreshold: Double

    private var sectorMinutes = [Double](repeating: 0, count: 16)
    private var sectorSpeedMinutes = [Double](repeating: 0, count: 16)
    private var sectorPeakGust = [Double?](repeating: nil, count: 16)
    private var bandMinutes: [[Double]]

    private var calmMinutes: Double = 0
    private var undirectedMinutes: Double = 0
    private var eastMinutes: Double = 0   // vector sum, speed-weighted, in minutes·mph
    private var northMinutes: Double = 0
    private var peak: WindPeak?

    public init(bands: [WindBand] = WindBand.standard,
                calmThreshold: Double = WindBand.calmThreshold) {
        self.bands = bands
        self.calmThreshold = calmThreshold
        self.bandMinutes = Array(repeating: [Double](repeating: 0, count: bands.count), count: 16)
    }

    public mutating func add(_ samples: [StationSample]) {
        for sample in samples { add(sample) }
    }

    public mutating func add(_ sample: StationSample) {
        let minutes = Double(max(1, sample.bucketMinutes))

        // A gust is a maximum and survives the calm cut: the whole point of the
        // peak is that it happened, even in an otherwise still hour.
        if let gust = sample.windGust, gust > (peak?.speed ?? -1) {
            peak = WindPeak(speed: gust, timestamp: sample.timestamp, degrees: sample.windDirection)
        }

        guard let speed = sample.windAvg else { return }
        guard speed >= calmThreshold else { calmMinutes += minutes; return }
        guard let direction = sample.windDirection else { undirectedMinutes += minutes; return }

        let degrees = Self.normalize(direction)
        let index = Int((degrees / 22.5).rounded()) % 16

        sectorMinutes[index] += minutes
        sectorSpeedMinutes[index] += speed * minutes
        if let gust = sample.windGust, gust > (sectorPeakGust[index] ?? -1) {
            sectorPeakGust[index] = gust
        }
        if let band = bands.firstIndex(where: { $0.contains(speed) }) {
            bandMinutes[index][band] += minutes
        }

        // Speed-weighted so the resultant answers "where did the air go", not
        // "where did the vane point" — a weak wind should not cancel a strong one.
        let radians = degrees * .pi / 180
        northMinutes += speed * minutes * cos(radians)
        eastMinutes  += speed * minutes * sin(radians)
    }

    public func build() -> WindRose {
        let moving = sectorMinutes.reduce(0, +)
        let speedMinutes = sectorSpeedMinutes.reduce(0, +)
        let meanSpeed = moving > 0 ? speedMinutes / moving : 0

        let resultantMagnitude = moving > 0
            ? (northMinutes * northMinutes + eastMinutes * eastMinutes).squareRoot() / moving
            : 0
        var resultant = moving > 0 ? atan2(eastMinutes, northMinutes) * 180 / .pi : 0
        resultant = Self.normalize(resultant)

        let sectors = (0..<16).map { i in
            WindSector(index: i,
                       degrees: Double(i) * 22.5,
                       compass: Self.points[i],
                       minutes: sectorMinutes[i],
                       fraction: moving > 0 ? sectorMinutes[i] / moving : 0,
                       meanSpeed: sectorMinutes[i] > 0 ? sectorSpeedMinutes[i] / sectorMinutes[i] : 0,
                       peakGust: sectorPeakGust[i],
                       bandMinutes: bandMinutes[i])
        }

        return WindRose(sectors: sectors,
                        bands: bands,
                        movingMinutes: moving,
                        calmMinutes: calmMinutes,
                        undirectedMinutes: undirectedMinutes,
                        meanSpeed: meanSpeed,
                        resultantDegrees: resultant,
                        constancy: meanSpeed > 0 ? min(1, resultantMagnitude / meanSpeed) : 0,
                        peakGust: peak)
    }

    static let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                         "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    /// 0…<360, and the upper bound is load-bearing. A resultant that lands on due
    /// north comes out of `atan2` as a hair BELOW zero, and `-1e-15 + 360` rounds
    /// to exactly 360.0 — so the naive wrap reports a bearing no compass has, and
    /// the sector index derived from it wraps to N by luck rather than by rule.
    static func normalize(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        let wrapped = d < 0 ? d + 360 : d
        return wrapped >= 360 ? 0 : wrapped
    }
}

extension WindRose {
    /// The sixteen points, and the bearing→name rounding that goes with them.
    /// Public because the resultant is a bearing like any other and anything
    /// showing it has to name it — without this every caller re-derives the
    /// rounding, which is how `DayStrip` and the app's `Compass` ended up with
    /// two copies of it already.
    public static let points = WindRoseBuilder.points

    public static func compass(_ degrees: Double) -> String {
        points[Int((WindRoseBuilder.normalize(degrees) / 22.5).rounded()) % 16]
    }

    /// What the record says on net, named.
    public var resultantCompass: String { Self.compass(resultantDegrees) }

    /// A rose over one set of samples. The convenience shape; anything spanning
    /// more than a day or two should stream through `WindRoseBuilder` instead.
    public static func over(_ samples: [StationSample],
                            bands: [WindBand] = WindBand.standard) -> WindRose {
        var builder = WindRoseBuilder(bands: bands)
        builder.add(samples)
        return builder.build()
    }
}
