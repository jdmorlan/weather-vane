//
//  ForecastAccuracy.swift  (WeatherKit)
//
//  SCORING THE FORECAST AGAINST THE STATION THAT STOOD UNDER IT.
//
//  `ForecastLog` keeps what was promised and the daily archive keeps what
//  arrived, and this is the one place the two are put beside each other. The
//  comparison is unusually fair: WeatherFlow issues the forecast FOR the
//  station, and the station is what measures the outcome, so there is no
//  nearest-airport fudge in the middle. Same point, same units, same day
//  boundary.
//
//  THE SIGN IS THE ANSWER, not the size. "Off by three" describes a forecast
//  that is merely imprecise and one that is reliably three degrees cold in
//  exactly the same words, and only the second is worth knowing — you can
//  correct for a bias. So the error is kept signed all the way through and the
//  verdict leads with the direction. Mean absolute error is carried too, but as
//  the second number: it says how SCATTERED the misses are once the bias is
//  accounted for.
//
//  THE MORNING'S WORD IS WHAT GETS SCORED, because that's the claim that was
//  acted on. Scoring the whole ten-day series would flatter the forecast — its
//  last revision is always its best — and scoring the seven-day-out number would
//  damn it for a thing nobody read. `ForecastLogStore.morningClaim` picks the
//  claim that was standing before noon on the day itself, which is the number
//  that was on screen at breakfast.
//
//  A DAY MUST BE FULLY WATCHED TO BE SCORED. A half-covered day understates its
//  own high, and a forecast graded against it looks warm for a reason that has
//  nothing to do with the forecast. `DailyRecord.isReliable` is the same gate
//  records and normals already use, and it applies here for a sharper reason
//  than usual: this is the one calculation where a missing afternoon biases the
//  result in a specific, misleading direction.
//
//  AND THE VERDICT REFUSES TO SPEAK EARLY. Three days is a mood, not a pattern.
//  Below the minimum this returns nothing at all rather than a number with a
//  disclaimer next to it — the same posture the rest of WeatherKit takes when
//  the record is too thin to support a sentence.
//

import Foundation

/// One day graded: what was promised that morning against what was measured.
public struct ForecastCheck: Equatable, Sendable, Identifiable {
    public var day: String
    /// When the claim being graded was issued.
    public var issuedAt: Int
    /// Days ahead that claim was looking. 0 is the morning of; 1 means the app
    /// went unopened that morning and yesterday's word was still standing.
    public var leadDays: Int
    public var forecastHigh: Double
    public var actualHigh: Double

    public var id: String { day }

    /// Signed, forecast minus actual. **Negative means the forecast ran COLD** —
    /// it promised less heat than the day delivered, which is the complaint this
    /// whole file exists to check.
    public var error: Double { forecastHigh - actualHigh }

    public func ranCold(tolerance: Double) -> Bool { error < -tolerance }
    public func ranWarm(tolerance: Double) -> Bool { error > tolerance }
    public func wasClose(tolerance: Double) -> Bool { abs(error) <= tolerance }
}

/// What a stretch of graded days adds up to.
public struct ForecastVerdict: Equatable, Sendable {
    public var checks: [ForecastCheck]
    /// Degrees within which a miss isn't worth calling a miss.
    public var tolerance: Double
    /// Mean SIGNED error. Negative is a forecast that runs cold.
    public var bias: Double
    /// Mean absolute error — the scatter, once direction is set aside.
    public var meanAbsoluteError: Double
    public var coldDays: Int
    public var warmDays: Int
    public var closeDays: Int
    /// The worst single miss, whichever way it went.
    public var largestMiss: ForecastCheck?
    /// The finding, in a sentence.
    public var sentence: String
    /// The other explanation for the same pattern, when there is one. Shown
    /// smaller: it is a caution about what this measurement can and cannot
    /// separate, not a second finding.
    public var caveat: String?

    public var dayCount: Int { checks.count }

    /// The same finding, short enough to sit in another card's header.
    ///
    /// `sentence` is written to be read once, standing alone, and says the whole
    /// thing — which direction, how often, over how many days. This is the
    /// version that rides above the ten-day it grades, where the forecast is the
    /// subject and the grade is an annotation on it: one clause, no commas, and
    /// the number a reader would repeat.
    public var headline: String {
        let degrees = ForecastAccuracy.format(abs(bias))
        if abs(bias) > tolerance && isConsistent {
            return "Runs \(degrees)° \(bias < 0 ? "cold" : "warm") over \(dayCount) days"
        }
        if meanAbsoluteError > tolerance {
            return "Off \(ForecastAccuracy.format(meanAbsoluteError))° either way over \(dayCount) days"
        }
        return "Within \(ForecastAccuracy.format(tolerance))° on \(closeDays) of \(dayCount) days"
    }

    /// Whether the headline is good news, which is the only thing the icon
    /// beside it needs to know. A forecast inside tolerance most days has
    /// nothing to act on; anything else is worth a second look.
    public var isReassuring: Bool {
        abs(bias) <= tolerance && meanAbsoluteError <= tolerance
    }
    /// True when the misses point overwhelmingly one way — the case where the
    /// number is worth acting on rather than just noting.
    public var isConsistent: Bool {
        guard dayCount > 0 else { return false }
        return Double(max(coldDays, warmDays)) / Double(dayCount) >= 0.7
    }
}

public enum ForecastAccuracy {
    /// Degrees. Below this a forecast high is doing its job; a station's own
    /// reading moves more than this between one side of a yard and the other.
    public static let defaultTolerance: Double = 2

    /// Fewer graded days than this and there is no verdict to give.
    public static let minimumDays = 5

    /// Grade one day, if both halves of it are on file and trustworthy.
    ///
    /// Returns nil when the forecast was never captured, when the day has no
    /// measured high, or when the day was only partly watched — three different
    /// reasons that all mean the same thing here: this day cannot be scored.
    public static func check(day: String,
                             log: ForecastLogStore,
                             record: DailyRecord?,
                             timeZone: TimeZone) -> ForecastCheck? {
        guard let record, record.isReliable, let actual = record.tempMax else { return nil }
        guard let claim = try? log.morningClaim(for: day, timeZone: timeZone),
              let promised = claim.high else { return nil }
        let lead = claim.leadDays(timeZone: timeZone) ?? 0
        return ForecastCheck(day: day, issuedAt: claim.issuedAt, leadDays: lead,
                             forecastHigh: promised, actualHigh: actual)
    }

    /// Grade a stretch of days.
    ///
    /// `records` is keyed by day; the caller holds the archive and this stays a
    /// pure function of what it hands over. Days that can't be scored are
    /// silently absent from `checks` rather than counted as zero error — the
    /// count of what WAS graded is part of the answer, which is why the verdict
    /// carries it.
    public static func verdict(days: [String],
                               log: ForecastLogStore,
                               records: [String: DailyRecord],
                               timeZone: TimeZone,
                               tolerance: Double = defaultTolerance,
                               minimumDays: Int = minimumDays) -> ForecastVerdict? {
        let checks = days.sorted().compactMap {
            check(day: $0, log: log, record: records[$0], timeZone: timeZone)
        }
        guard checks.count >= minimumDays else { return nil }

        let errors = checks.map(\.error)
        let bias = errors.reduce(0, +) / Double(errors.count)
        let mae = errors.map(abs).reduce(0, +) / Double(errors.count)
        let cold = checks.filter { $0.ranCold(tolerance: tolerance) }.count
        let warm = checks.filter { $0.ranWarm(tolerance: tolerance) }.count
        let close = checks.filter { $0.wasClose(tolerance: tolerance) }.count
        let largest = checks.max { abs($0.error) < abs($1.error) }

        var verdict = ForecastVerdict(checks: checks, tolerance: tolerance,
                                      bias: bias, meanAbsoluteError: mae,
                                      coldDays: cold, warmDays: warm, closeDays: close,
                                      largestMiss: largest, sentence: "", caveat: nil)
        verdict.sentence = sentence(for: verdict)
        verdict.caveat = caveat(for: verdict)
        return verdict
    }

    // MARK: - Saying it

    private static func sentence(for v: ForecastVerdict) -> String {
        let n = v.dayCount
        let degrees = format(abs(v.bias))

        if abs(v.bias) > v.tolerance && v.isConsistent {
            let direction = v.bias < 0 ? "cold" : "warm"
            let side = v.bias < 0 ? "under" : "over"
            let missed = v.bias < 0 ? v.coldDays : v.warmDays
            return "The morning forecast has run \(degrees)° \(direction), "
                + "landing \(side) the actual high on \(missed) of the last \(n) days."
        }
        if v.meanAbsoluteError > v.tolerance {
            return "The morning forecast has been off by \(format(v.meanAbsoluteError))° on average "
                + "over \(n) days, but in both directions — \(v.coldDays) cold, \(v.warmDays) warm."
        }
        return "The morning forecast has been within \(format(v.tolerance))° of the actual high "
            + "on \(v.closeDays) of the last \(n) days."
    }

    /// The rival explanation. A station reading hot in the afternoon — full sun,
    /// a roof below it, weak aspiration — produces a forecast that looks
    /// consistently cold, and nothing in this comparison can tell the two apart,
    /// because the station is both the subject and the judge. Worth saying once,
    /// and only when the pattern is strong enough that someone might act on it.
    private static func caveat(for v: ForecastVerdict) -> String? {
        guard abs(v.bias) > v.tolerance, v.isConsistent else { return nil }
        return v.bias < 0
            ? "A station that reads warm in the afternoon looks exactly like this. "
                + "The comparison can't separate a cold forecast from a hot thermometer."
            : "A station that reads cool in the afternoon looks exactly like this. "
                + "The comparison can't separate a warm forecast from a shaded thermometer."
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - How the claim moved

/// One day's forecast history: what was said about it, at each lead, against
/// what happened.
///
/// The reason the log keeps all ten days rather than just today's. A verdict
/// says whether the forecast is biased; this says how far out it stops being
/// worth reading, which is the more useful thing and costs the same disk.
public struct ForecastCurve: Equatable, Sendable {
    public struct Point: Equatable, Sendable, Identifiable {
        public var leadDays: Int
        public var issuedAt: Int
        public var high: Double
        public var id: Int { issuedAt }
    }

    public var day: String
    /// One point per revision, newest lead last. Only revisions appear — a claim
    /// that stood unchanged for three days is one point, which is the honest
    /// picture of a forecast that didn't move.
    public var points: [Point]
    /// Nil until the day is over and reliably measured.
    public var actualHigh: Double?

    public func error(at point: Point) -> Double? {
        actualHigh.map { point.high - $0 }
    }
}

extension ForecastAccuracy {
    /// Every claim ever made about one day, with its lead.
    public static func curve(day: String,
                             log: ForecastLogStore,
                             record: DailyRecord?,
                             timeZone: TimeZone) -> ForecastCurve {
        let claims = (try? log.claims(for: day)) ?? []
        let points = claims.compactMap { note -> ForecastCurve.Point? in
            guard let high = note.high else { return nil }
            return ForecastCurve.Point(leadDays: note.leadDays(timeZone: timeZone) ?? 0,
                                       issuedAt: note.issuedAt, high: high)
        }
        let actual = (record?.isReliable ?? false) ? record?.tempMax : nil
        return ForecastCurve(day: day, points: points, actualHigh: actual)
    }
}
