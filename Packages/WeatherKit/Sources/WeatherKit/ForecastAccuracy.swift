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

/// One day graded: what was promised against what was measured, for one measure.
public struct ForecastCheck: Equatable, Sendable, Identifiable {
    public var day: String
    /// When the claim being graded was issued.
    public var issuedAt: Int
    /// Days ahead that claim was looking. 0 is the morning of; 1 means the app
    /// went unopened that morning and yesterday's word was still standing.
    public var leadDays: Int
    public var measure: DailyMeasure
    public var forecast: Double
    public var actual: Double

    public var id: String { day }

    public init(day: String, issuedAt: Int, leadDays: Int, measure: DailyMeasure = .high,
                forecast: Double, actual: Double) {
        self.day = day
        self.issuedAt = issuedAt
        self.leadDays = leadDays
        self.measure = measure
        self.forecast = forecast
        self.actual = actual
    }

    /// The high-only shape this began as.
    public init(day: String, issuedAt: Int, leadDays: Int, forecastHigh: Double, actualHigh: Double) {
        self.init(day: day, issuedAt: issuedAt, leadDays: leadDays, measure: .high,
                  forecast: forecastHigh, actual: actualHigh)
    }

    /// Signed, forecast minus actual. **Negative means the forecast ran COLD** —
    /// it promised less heat than the day delivered, which is the complaint this
    /// whole file exists to check. (Or ran LOW, for a gust or a dew point.)
    public var error: Double { forecast - actual }

    public func ranCold(tolerance: Double) -> Bool { error < -tolerance }
    public func ranWarm(tolerance: Double) -> Bool { error > tolerance }
    public func wasClose(tolerance: Double) -> Bool { abs(error) <= tolerance }
}

/// What a stretch of graded days adds up to.
public struct ForecastVerdict: Equatable, Sendable {
    public var checks: [ForecastCheck]
    public var measure: DailyMeasure { checks.first?.measure ?? .high }
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
        let u = measure.unit
        if abs(bias) > tolerance && isConsistent {
            return "Runs \(degrees)\(u) \(bias < 0 ? measure.underWord : measure.overWord) over \(dayCount) days"
        }
        if meanAbsoluteError > tolerance {
            return "Off \(ForecastAccuracy.format(meanAbsoluteError))\(u) either way over \(dayCount) days"
        }
        return "Within \(ForecastAccuracy.format(tolerance))\(u) on \(closeDays) of \(dayCount) days"
    }

    /// Whether the headline is good news, which is the only thing the icon
    /// beside it needs to know. A forecast inside tolerance most days has
    /// nothing to act on; anything else is worth a second look.
    public var isReassuring: Bool {
        abs(bias) <= tolerance && meanAbsoluteError <= tolerance
    }
    /// True when the misses point overwhelmingly one way — the case where the
    /// number is worth acting on rather than just noting.
    ///
    /// Counted among the MISSES, not among all days. Over every day it let the
    /// close ones dilute the direction: Sep 9–Oct 1, 2026 was 16 cold, 0 warm
    /// and 7 close — 16 of 23 is 69.6%, under the bar, and the verdict called a
    /// forecast that never once ran warm "off in both directions".
    public var isConsistent: Bool {
        let misses = coldDays + warmDays
        guard misses > 0 else { return false }
        return Double(max(coldDays, warmDays)) / Double(misses) >= 0.7
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
                             timeZone: TimeZone,
                             measure: DailyMeasure = .high) -> ForecastCheck? {
        guard let record, record.isReliable, let actual = record[keyPath: measure.record] else { return nil }
        guard let claim = try? gradedClaim(for: day, log: log, timeZone: timeZone, measure: measure),
              let promised = measure.value(claim) else { return nil }
        let lead = claim.leadDays(timeZone: timeZone) ?? 0
        return ForecastCheck(day: day, issuedAt: claim.issuedAt, leadDays: lead, measure: measure,
                             forecast: promised, actual: actual)
    }

    /// The claim a measure is graded against: the morning's, or for the low
    /// the one standing at local midnight (see `DailyMeasure.gradesNightBefore`).
    public static func gradedClaim(for day: String, log: ForecastLogStore, timeZone: TimeZone,
                                   measure: DailyMeasure) throws -> ForecastNote? {
        guard measure.gradesNightBefore else { return try log.morningClaim(for: day, timeZone: timeZone) }
        guard let midnight = DayKey.date(from: day, timeZone: timeZone) else { return nil }
        return try log.claim(for: day, asOf: midnight)
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
                               measure: DailyMeasure = .high,
                               tolerance: Double? = nil,
                               minimumDays: Int = minimumDays) -> ForecastVerdict? {
        let tolerance = tolerance ?? measure.tolerance
        let checks = days.sorted().compactMap {
            check(day: $0, log: log, record: records[$0], timeZone: timeZone, measure: measure)
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
        let m = v.measure
        let u = m.unit
        let degrees = format(abs(v.bias))
        let claim = "The \(m.claimName)"

        if abs(v.bias) > v.tolerance && v.isConsistent {
            let direction = v.bias < 0 ? m.underWord : m.overWord
            let side = v.bias < 0 ? "under" : "over"
            let missed = v.bias < 0 ? v.coldDays : v.warmDays
            return "\(claim) has run \(degrees)\(u) \(direction), "
                + "landing \(side) the actual \(m.noun) on \(missed) of the last \(n) days."
        }
        if v.meanAbsoluteError > v.tolerance {
            // "Both directions" only when it was. One-sided misses that aren't
            // big enough on average to call a bias are still one-sided.
            if v.coldDays == 0 || v.warmDays == 0 {
                let direction = v.coldDays > 0 ? m.underWord : m.overWord
                return "\(claim) has been off by \(format(v.meanAbsoluteError))\(u) on average "
                    + "over \(n) days, and every miss ran \(direction)."
            }
            return "\(claim) has been off by \(format(v.meanAbsoluteError))\(u) on average "
                + "over \(n) days, but in both directions — \(v.coldDays) \(m.underWord), \(v.warmDays) \(m.overWord)."
        }
        return "\(claim) has been within \(format(v.tolerance))\(u) of the actual \(m.noun) "
            + "on \(v.closeDays) of the last \(n) days."
    }

    /// The rival explanation. A station reading hot in the afternoon — full sun,
    /// a roof below it, weak aspiration — produces a forecast that looks
    /// consistently cold, and nothing in this comparison can tell the two apart,
    /// because the station is both the subject and the judge. Worth saying once,
    /// and only when the pattern is strong enough that someone might act on it.
    private static func caveat(for v: ForecastVerdict) -> String? {
        guard v.measure == .high, abs(v.bias) > v.tolerance, v.isConsistent else { return nil }
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
        /// What this claim said about the measure the curve is for.
        public var value: Double
        public var id: Int { issuedAt }
    }

    public var day: String
    /// One point per revision, newest lead last. Only revisions appear — a claim
    /// that stood unchanged for three days is one point, which is the honest
    /// picture of a forecast that didn't move.
    public var points: [Point]
    /// Nil until the day is over and reliably measured.
    public var actual: Double?

    public func error(at point: Point) -> Double? {
        actual.map { point.value - $0 }
    }
}

extension ForecastAccuracy {
    /// Every claim ever made about one day, with its lead.
    public static func curve(day: String,
                             log: ForecastLogStore,
                             record: DailyRecord?,
                             timeZone: TimeZone,
                             measure: DailyMeasure = .high) -> ForecastCurve {
        let claims = (try? log.claims(for: day)) ?? []
        let points = claims.compactMap { note -> ForecastCurve.Point? in
            guard let value = measure.value(note) else { return nil }
            return ForecastCurve.Point(leadDays: note.leadDays(timeZone: timeZone) ?? 0,
                                       issuedAt: note.issuedAt, value: value)
        }
        let actual = (record?.isReliable ?? false) ? record?[keyPath: measure.record] : nil
        return ForecastCurve(day: day, points: points, actual: actual)
    }
}

// MARK: - How far out it's worth reading

/// The typical miss at one lead, over every day that was both forecast that far
/// out and reliably measured.
public struct LeadSkill: Equatable, Sendable, Identifiable {
    public var leadDays: Int
    /// Mean of |forecast − actual|.
    public var typicalMiss: Double
    /// Mean of forecast − actual. Negative: ran cold.
    public var bias: Double
    public var days: Int
    public var id: Int { leadDays }
}

extension ForecastAccuracy {

    /// What the forecast said about a day `lead` days ahead: the claim that was
    /// STANDING then — the newest one issued at least `lead` days out.
    ///
    /// The log keeps only revisions, so a high that held at 94° from five days
    /// out to two is a single note with a lead of five. Asking for exactly
    /// lead 3 would find nothing, when the honest answer is "94°, unchanged".
    public static func standingClaim(_ curve: ForecastCurve, lead: Int) -> ForecastCurve.Point? {
        curve.points.filter { $0.leadDays >= lead }.max { $0.issuedAt < $1.issuedAt }
    }

    /// Typical miss by lead, 0 (the morning of) through `maxLead`.
    ///
    /// A lead appears only when at least `minimumDays` days can speak for it —
    /// a young log has plenty of morning-of grades and only a few from a week
    /// out, and an average of two is not a skill.
    public static func leadSkill(days: [String],
                                 log: ForecastLogStore,
                                 records: [String: DailyRecord],
                                 timeZone: TimeZone,
                                 measure: DailyMeasure = .high,
                                 maxLead: Int = 7,
                                 minimumDays: Int = minimumDays) -> [LeadSkill] {
        let curves = days.map { curve(day: $0, log: log, record: records[$0], timeZone: timeZone, measure: measure) }
            .filter { $0.actual != nil }
        return (0...maxLead).compactMap { lead in
            let errors = curves.compactMap { c in standingClaim(c, lead: lead).flatMap(c.error(at:)) }
            guard errors.count >= minimumDays else { return nil }
            return LeadSkill(leadDays: lead,
                             typicalMiss: errors.map(abs).reduce(0, +) / Double(errors.count),
                             bias: errors.reduce(0, +) / Double(errors.count),
                             days: errors.count)
        }
    }

    /// "The morning-of forecast misses by 1.8° on a typical day; from 3 days
    /// out, 3.4°; from 7 days out, 5.1°."
    public static func leadSentence(_ skill: [LeadSkill], measure: DailyMeasure = .high) -> String? {
        guard let first = skill.first, skill.count >= 2 else { return nil }
        func when(_ s: LeadSkill) -> String {
            switch s.leadDays {
            case 0: return "the morning of"
            case 1: return "the day before"
            default: return "\(s.leadDays) days out"
            }
        }
        let picks = [skill.first { $0.leadDays == 3 }, skill.last].compactMap { $0 }
            .filter { $0.leadDays != first.leadDays }
        var unique: [LeadSkill] = []
        for p in picks where !unique.contains(where: { $0.leadDays == p.leadDays }) { unique.append(p) }
        let u = measure.unit
        let rest = unique.map { "made \(when($0)), \(format(rounded($0.typicalMiss)))\(u)" }.joined(separator: "; ")
        return "Made \(when(first)), the forecast \(measure.noun) misses by \(format(rounded(first.typicalMiss)))\(u) on a typical day; \(rest)."
    }

    private static func rounded(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}


// MARK: - Rain: a chance, graded the only way a chance can be

/// One day: the morning's chance of rain, and whether it rained.
public struct RainCheck: Equatable, Sendable, Identifiable {
    public var day: String
    /// Percent, as the forecast gives it.
    public var chance: Double
    public var rained: Bool
    public var amount: Double
    public var id: String { day }
}

/// Days grouped by what the forecast said, against how often it rained.
///
/// A 30% chance can't be right or wrong on any one day — it rains or it
/// doesn't. Over many 30% days it should rain on about three in ten, and that
/// is the only test a percentage has. Grouped coarsely, because Tempest speaks
/// in tens and a young log has a handful of days in each.
public struct RainCalibration: Equatable, Sendable {
    public struct Bucket: Equatable, Sendable, Identifiable {
        public var lower: Int
        public var upper: Int
        public var days: Int
        public var wetDays: Int
        public var id: Int { lower }
        public var label: String { lower == upper ? "\(lower)%" : "\(lower)–\(upper)%" }
        public var share: Double { days == 0 ? 0 : Double(wetDays) / Double(days) }
    }

    public var checks: [RainCheck]
    public var buckets: [Bucket]

    /// "When it said 50% or more, it rained on 5 of 8 days. When it said 10% or
    /// less, it rained on 1 of 14."
    public var sentence: String? {
        guard checks.count >= ForecastAccuracy.minimumDays else { return nil }
        func line(_ days: [RainCheck], _ said: String) -> String? {
            guard !days.isEmpty else { return nil }
            let wet = days.filter(\.rained).count
            return "When it said \(said), it rained on \(wet) of \(days.count) \(days.count == 1 ? "day" : "days")."
        }
        let likely = line(checks.filter { $0.chance >= 50 }, "50% or more")
        let unlikely = line(checks.filter { $0.chance <= 10 }, "10% or less")
        let middling = line(checks.filter { $0.chance > 10 && $0.chance < 50 }, "20–40%")
        let parts = [likely, middling, unlikely].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

extension ForecastAccuracy {
    public static func rainCalibration(days: [String], log: ForecastLogStore,
                                       records: [String: DailyRecord],
                                       timeZone: TimeZone) -> RainCalibration {
        let checks = days.sorted().compactMap { day -> RainCheck? in
            // A partly watched day can prove rain but not its absence, so it
            // can't grade a chance either way.
            guard let record = records[day], record.isReliable, let amount = record.precipTotal,
                  let claim = try? log.morningClaim(for: day, timeZone: timeZone),
                  let chance = claim.precipProbability else { return nil }
            return RainCheck(day: day, chance: chance, rained: amount >= 0.01, amount: amount)
        }
        let ranges = [(0, 10), (20, 40), (50, 70), (80, 100)]
        let buckets = ranges.map { lower, upper in
            let inside = checks.filter { Int($0.chance.rounded()) >= lower && Int($0.chance.rounded()) <= upper }
            return RainCalibration.Bucket(lower: lower, upper: upper, days: inside.count,
                                          wetDays: inside.filter(\.rained).count)
        }
        return RainCalibration(checks: checks, buckets: buckets)
    }
}
