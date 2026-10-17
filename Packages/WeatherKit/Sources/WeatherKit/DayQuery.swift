//
//  DayQuery.swift  (WeatherKit)
//
//  "Show me the days when…" — the archive as something you can interrogate,
//  rather than as a fixed set of questions somebody already thought to ask.
//
//  `Climatology.streak(before:matches:)` has always taken a `(DailyRecord) ->
//  Bool`, so the predicate shape was already here; it was just trapped in Swift
//  closures, where nothing can name it, save it, offer it in a menu, or seed it
//  from a card. Everything below is that same idea expressed as DATA.
//
//  Three things decide the design:
//
//  1. CONDITIONS ARE VALUES, NOT CLOSURES. A closure can't be a preset, can't be
//     built in a picker, and can't be handed from one card to another. So a
//     condition is `(measure, test)` — inspectable, comparable, printable.
//  2. A MEASURE CARRIES ITS OWN VOCABULARY. Asking for "dew point below 64" and
//     asking for "dew point that's Muggy" are the same question in two
//     languages, and the measure is what knows both — its unit, its formatter,
//     and its named bands.
//  3. A MISSING DAY IS NOT A NON-MATCHING DAY. This is the rule the whole file
//     bends around, and it is NOT symmetric — see `Reading` below. Getting it
//     wrong would let the station's downtime read as dry weather.
//

import Foundation

// MARK: - What a measure is

/// How an archived value relates to the truth of its day.
///
/// This is the crux of the honesty rule and the reason it can be applied
/// mechanically rather than case by case. A day the station only half-watched
/// still holds a real number — but a number that can only be wrong in ONE
/// direction, and which direction depends on how the value was rolled up.
public enum Reading: Sendable {
    /// The day's maximum (or its total). Missing hours can only have been
    /// HIGHER, so the stored value is a FLOOR.
    case floor
    /// The day's minimum. Missing hours can only have been LOWER, so the stored
    /// value is a CEILING.
    case ceiling
    /// A mean. Missing hours move it either way, so nothing can be concluded
    /// from a partial day.
    case central
}

/// A named band of a measure — the qualitative way to ask the same question.
public struct MeasureBand: Equatable, Sendable, Identifiable {
    public var name: String
    /// Half-open `lower ..< upper`; nil is unbounded on that side.
    public var lower: Double?
    public var upper: Double?
    public var id: String { name }

    public func contains(_ value: Double) -> Bool {
        if let lower, value < lower { return false }
        if let upper, value >= upper { return false }
        return true
    }
}

/// Something a day can be asked about.
public enum Measure: String, CaseIterable, Sendable, Identifiable, Codable {
    case high, low, meanTemp
    case dewPoint, dewPointPeak, humidity
    case rain, gust, wind, pressure, lightning, uv

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .high: return "High"
        case .low: return "Low"
        case .meanTemp: return "Mean temp"
        case .dewPoint: return "Dew point"
        case .dewPointPeak: return "Peak dew point"
        case .humidity: return "Humidity"
        case .rain: return "Rain"
        case .gust: return "Wind gust"
        case .wind: return "Wind"
        case .pressure: return "Pressure"
        case .lightning: return "Lightning"
        case .uv: return "UV"
        }
    }

    public var path: KeyPath<DailyRecord, Double?> {
        switch self {
        case .high: return \.tempMax
        case .low: return \.tempMin
        case .meanTemp: return \.tempMean
        case .dewPoint: return \.dewPointMean
        case .dewPointPeak: return \.dewPointMax
        case .humidity: return \.humidityMean
        case .rain: return \.precipTotal
        case .gust: return \.windGustMax
        case .wind: return \.windAvgMean
        case .pressure: return \.pressureMean
        case .lightning: return \.strikeCountValue
        case .uv: return \.uvMax
        }
    }

    public var reading: Reading {
        switch self {
        case .high, .dewPointPeak, .rain, .gust, .lightning, .uv: return .floor
        case .low: return .ceiling
        case .meanTemp, .dewPoint, .humidity, .wind, .pressure: return .central
        }
    }

    public var unit: String {
        switch self {
        case .high, .low, .meanTemp, .dewPoint, .dewPointPeak: return "°"
        case .humidity: return "%"
        case .rain: return "\""
        case .gust, .wind: return " mph"
        case .pressure: return " inHg"
        case .lightning: return " strikes"
        case .uv: return ""
        }
    }

    /// Whether adding this measure across days produces a real quantity.
    ///
    /// Rain and lightning are AMOUNTS: each day contributes its own share, and a season's total is a
    /// thing that happened. A temperature, a gust, a pressure, a humidity is a STATE the day was IN —
    /// summing them yields "7,412°", a number with no referent, and the only clue it's nonsense is that
    /// it looks silly. That's the same failure `Reading` guards against for predicates: a number the
    /// archive can produce is not automatically a number that means anything.
    ///
    /// So the sum isn't offered here rather than being offered and quietly meaningless.
    public var accumulates: Bool {
        switch self {
        case .rain, .lightning: return true
        case .high, .low, .meanTemp, .dewPoint, .dewPointPeak,
             .humidity, .gust, .wind, .pressure, .uv: return false
        }
    }

    /// The ways of reducing days to one number that this measure can answer for.
    public var reductions: [Aggregate.Reduction] {
        accumulates ? [.sum, .mean, .max, .min] : [.mean, .max, .min]
    }

    /// The reduction this measure is USUALLY asked for, which is exactly what its `Reading` already
    /// says: a floor measure is interesting at its peak, a ceiling one at its trough, a central one on
    /// average. Used when a question has to fall back — switching a total onto a measure that can't be
    /// totalled should land somewhere natural, not on an arbitrary survivor.
    public var defaultReduction: Aggregate.Reduction {
        if accumulates { return .sum }
        switch reading {
        case .floor: return .max
        case .ceiling: return .min
        case .central: return .mean
        }
    }

    public func format(_ value: Double) -> String {
        switch self {
        case .rain: return String(format: "%.2f\"", value)
        case .pressure: return String(format: "%.2f inHg", value)
        case .uv: return String(format: "%.1f", value)
        default: return "\(Int(value.rounded()))\(unit)"
        }
    }

    /// The span a threshold can be set across, and how finely.
    ///
    /// A short list of "sensible" values was the wrong shape: rain is
    /// interesting continuously — there is a real difference between 1.00" and
    /// 1.40" — and a menu of six can only offer someone else's opinion about
    /// which numbers matter. The range is bounded to what this instrument can
    /// actually record, so the control can't be dragged somewhere meaningless.
    public var range: ClosedRange<Double> {
        switch self {
        case .high: return 0...120
        case .low: return -10...90
        case .meanTemp: return 0...110
        case .dewPoint, .dewPointPeak: return 20...85
        case .humidity: return 0...100
        case .rain: return 0...3
        case .gust: return 0...80
        case .wind: return 0...30
        case .pressure: return 29...31
        case .lightning: return 0...300
        case .uv: return 0...14
        }
    }

    /// Granularity of the control. Fine enough that the number you have in mind
    /// is reachable; never so fine that it's fiddly to land on a round one.
    public var step: Double {
        switch self {
        case .rain, .pressure: return 0.01
        case .uv: return 0.5
        case .humidity: return 5
        default: return 1
        }
    }

    /// Spacing of the labelled ticks under the control.
    public var tickStep: Double {
        switch self {
        case .high, .meanTemp, .low, .gust: return 20
        case .dewPoint, .dewPointPeak, .wind: return 10
        case .humidity: return 25
        case .rain: return 0.5
        case .pressure: return 0.5
        case .lightning: return 100
        case .uv: return 2
        }
    }

    /// Where a freshly-chosen measure starts — the threshold most people mean
    /// when they first reach for it.
    public var defaultThreshold: Double {
        switch self {
        case .high: return 90
        case .low: return 32
        case .meanTemp: return 70
        case .dewPoint, .dewPointPeak: return 65
        case .humidity: return 60
        case .rain: return 0.01
        case .gust: return 40
        case .wind: return 15
        case .pressure: return 30
        case .lightning: return 1
        case .uv: return 8
        }
    }

    /// Where this measure's seasonal normal lives, where one exists.
    ///
    /// What turns a row of numbers into something readable: 71° is ordinary for
    /// an August dew point and remarkable for an April one, and a list that
    /// prints only the reading can't tell you which day you're looking at.
    public var normalPath: KeyPath<DailyNormal, Double?>? {
        switch self {
        case .high: return \.high
        case .low: return \.low
        case .meanTemp: return \.mean
        case .dewPoint: return \.dewPoint
        // The PEAK against the peak. This pointed at the mean dew-point normal
        // until the other normals were added, which silently inflated every
        // departure by the mean-to-peak gap — around 5° here, so an ordinary
        // muggy afternoon read as a notable one.
        case .dewPointPeak: return \.dewPointPeak
        case .rain: return \.precip
        case .humidity: return \.humidity
        case .wind: return \.wind
        case .gust: return \.gust
        case .pressure: return \.pressure
        case .uv: return \.uv
        // A "normal" strike count is 0.0 on almost every date; a departure from
        // it would just restate the count.
        case .lightning: return nil
        }
    }

    /// Keeps a threshold inside what the control can express — changing measure
    /// must never leave a value stranded off the end of its own scale.
    public func clamp(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// The qualitative vocabulary, where the measure has one. Dew point's bands
    /// are the same ones the comfort gauge and the forecast chips already use,
    /// so "Muggy" means one thing everywhere in the app.
    public var bands: [MeasureBand] {
        switch self {
        case .dewPoint, .dewPointPeak:
            return [MeasureBand(name: "Dry", lower: nil, upper: 55),
                    MeasureBand(name: "Comfortable", lower: 55, upper: 60),
                    MeasureBand(name: "Sticky", lower: 60, upper: 65),
                    MeasureBand(name: "Muggy", lower: 65, upper: 70),
                    MeasureBand(name: "Oppressive", lower: 70, upper: nil)]
        case .high:
            return [MeasureBand(name: "Freezing", lower: nil, upper: 32),
                    MeasureBand(name: "Cold", lower: 32, upper: 55),
                    MeasureBand(name: "Mild", lower: 55, upper: 80),
                    MeasureBand(name: "Warm", lower: 80, upper: 90),
                    MeasureBand(name: "Hot", lower: 90, upper: 100),
                    MeasureBand(name: "100° or more", lower: 100, upper: nil)]
        case .low:
            return [MeasureBand(name: "Hard freeze", lower: nil, upper: 28),
                    MeasureBand(name: "Frost", lower: 28, upper: 33),
                    MeasureBand(name: "Chilly", lower: 33, upper: 50),
                    MeasureBand(name: "Cool", lower: 50, upper: 65),
                    MeasureBand(name: "Warm night", lower: 65, upper: 75),
                    MeasureBand(name: "Very warm night", lower: 75, upper: nil)]
        case .rain:
            return [MeasureBand(name: "Dry", lower: nil, upper: 0.01),
                    MeasureBand(name: "Light", lower: 0.01, upper: 0.1),
                    MeasureBand(name: "Moderate", lower: 0.1, upper: 0.5),
                    MeasureBand(name: "Heavy", lower: 0.5, upper: 1),
                    MeasureBand(name: "Very heavy", lower: 1, upper: nil)]
        default:
            return []
        }
    }
}

extension DailyRecord {
    /// Strike count as a Double, so lightning can be queried through the same
    /// `KeyPath<DailyRecord, Double?>` machinery as everything else.
    var strikeCountValue: Double? {
        strikeCount.map(Double.init)
    }
}

// MARK: - What a condition is

/// How a measure is compared. A value type on purpose — this is what makes a
/// condition storable, presettable, and buildable in a menu.
public enum Test: Equatable, Sendable, Hashable {
    case atOrAbove(Double)
    case below(Double)
    /// Inclusive below — what a freeze is. 0.0°C reads as exactly 32.0°F, and
    /// "below 32" would miss every one of those nights.
    case atOrBelow(Double)
    case between(Double, Double)     // [lower, upper)
    case inBand(String)

    public func passes(_ value: Double, measure: Measure) -> Bool {
        switch self {
        case .atOrAbove(let threshold): return value >= threshold
        case .below(let threshold): return value < threshold
        case .atOrBelow(let threshold): return value <= threshold
        case .between(let lower, let upper): return value >= lower && value < upper
        case .inBand(let name):
            guard let band = measure.bands.first(where: { $0.name == name }) else { return false }
            return band.contains(value)
        }
    }

    /// Which way the test looks, for the coverage rule. A band or a range is
    /// bounded on both sides, so a partial day can never settle it.
    var direction: Reading? {
        switch self {
        case .atOrAbove: return .floor        // proving it needs a high enough reading
        case .below, .atOrBelow: return .ceiling   // proving it needs a low enough reading
        case .between, .inBand: return nil
        }
    }
}

public struct Condition: Equatable, Sendable, Hashable, Identifiable {
    public var measure: Measure
    public var test: Test
    public var id: String { "\(measure.rawValue)·\(describe)" }

    public init(_ measure: Measure, _ test: Test) {
        self.measure = measure
        self.test = test
    }

    public var describe: String {
        switch test {
        case .atOrAbove(let v): return "\(measure.name) \(measure.format(v)) or above"
        case .below(let v): return "\(measure.name) below \(measure.format(v))"
        case .atOrBelow(let v): return "\(measure.name) \(measure.format(v)) or below"
        case .between(let a, let b): return "\(measure.name) \(measure.format(a))–\(measure.format(b))"
        case .inBand(let name): return "\(measure.name) is \(name)"
        }
    }

    /// Whether a day can ANSWER this condition — the honesty rule, mechanized.
    ///
    /// A day the station watched throughout can answer anything. A partial day
    /// can still answer in the direction its value is trustworthy: its recorded
    /// high is a floor, so a reading of 97° proves "high at or above 95°" no
    /// matter how many hours were missed. The same day cannot prove "high below
    /// 90°", because the hour nobody saw is exactly where the afternoon peak
    /// would have been.
    ///
    /// This is "absence needs coverage, presence doesn't", generalized: the
    /// direction that only needs one observation is free; the direction that
    /// needs the whole day has to have watched the whole day.
    public func answerable(by record: DailyRecord) -> Bool {
        if record.isReliable { return true }
        guard let direction = test.direction else { return false }
        switch (measure.reading, direction) {
        case (.floor, .floor): return true      // recorded max is a floor; ≥ is provable
        case (.ceiling, .ceiling): return true  // recorded min is a ceiling; < is provable
        default: return false
        }
    }

    /// Nil when this day can't settle the condition either way — which is a
    /// third answer, and must never be collapsed into "no".
    public func evaluate(_ record: DailyRecord) -> Bool? {
        guard let value = record[keyPath: measure.path],
              answerable(by: record) else { return nil }
        return test.passes(value, measure: measure)
    }
}

// MARK: - The query

/// Which years to look at — the axis a `WeatherPeriod` deliberately doesn't
/// have. A period says WHICH DATES ("September", "Winter"); this says WHICH
/// YEARS. They're orthogonal, and one menu trying to be both is what made "the
/// whole year" read as a time range when it was really a date range.
public enum YearScope: Equatable, Sendable, Hashable {
    case all
    case year(Int)

    public var label: String {
        switch self {
        case .all: return "all years"
        case .year(let y): return String(y)
        }
    }
}

/// A condition on the days BEFORE a day, rather than on the day itself.
///
/// The predicate model is per-day by construction, which means "days after it
/// rained" can't be said at all — the fact you need lives in a different row.
public struct PrecedingClause: Equatable, Sendable, Hashable {
    public var conditions: [Condition]
    /// How far back to look. 1 is yesterday only; 3 means "at some point in the
    /// three days before".
    public var within: Int

    public init(conditions: [Condition], within: Int = 1) {
        self.conditions = conditions
        self.within = max(1, within)
    }

    public var describe: String {
        let clauses = conditions.map(\.describe).joined(separator: " and ")
        return within == 1 ? "the day before had \(clauses)"
                           : "one of the \(within) days before had \(clauses)"
    }
}

/// A filter over the ORDER of the matching days, applied after they're found.
///
/// Each of these is a question about a day's place in a sequence, which no
/// amount of per-day predicate can reach.
public enum SequenceRule: Equatable, Sendable, Hashable {
    /// The earliest match in each year (or each instance of the date scope).
    case firstEachYear
    /// The latest.
    case lastEachYear
    /// Only days belonging to a run of at least this many consecutive matches.
    case inRunOfAtLeast(Int)

    public var describe: String {
        switch self {
        case .firstEachYear: return "only the first each year"
        case .lastEachYear: return "only the last each year"
        case .inRunOfAtLeast(let n): return "only in a run of \(n)+ days"
        }
    }
}

public struct DayQuery: Equatable, Sendable, Hashable {
    public var name: String
    /// ANDed. Not OR, deliberately: "either 64° or Muggy" is two ways of
    /// phrasing ONE condition, which `Test` already covers, and a mixed
    /// and/or builder is a lot of interface for a question nobody has asked yet.
    public var conditions: [Condition]
    /// Which DATES. Nil is any date in the year.
    public var scope: WeatherPeriod?
    /// Which YEARS.
    public var years: YearScope
    /// A condition on the days before — see `PrecedingClause`.
    public var precededBy: PrecedingClause?
    /// A filter on a day's place in the sequence of matches.
    public var sequence: SequenceRule?
    /// WHAT TO REPORT about the selected days, instead of listing them. Present ⇒ the question is a
    /// reduction ("total rain by month") rather than a selection ("which days it rained"). See
    /// `Aggregate` — this is the clause that made the History tab expressible.
    public var aggregate: Aggregate?

    public init(name: String = "", conditions: [Condition],
                scope: WeatherPeriod? = nil, years: YearScope = .all,
                precededBy: PrecedingClause? = nil, sequence: SequenceRule? = nil,
                aggregate: Aggregate? = nil) {
        self.name = name
        self.conditions = conditions
        self.scope = scope
        self.years = years
        self.precededBy = precededBy
        self.sequence = sequence
        self.aggregate = aggregate
    }

    /// A day-level condition isn't required once another clause carries the
    /// question — "days after it rained" says nothing about the day itself.
    public var isEmpty: Bool { conditions.isEmpty && precededBy == nil }

    public var describe: String {
        var parts: [String] = []
        // With an aggregate the REDUCTION is the question and the conditions only narrow which days feed
        // it — "Total rain by month" reads right; "Any day, total rain by month" reads like a bug.
        if let aggregate {
            parts.append(conditions.isEmpty
                ? aggregate.describe
                : "\(aggregate.describe) on days with \(conditions.map(\.describe).joined(separator: " and "))")
        } else if conditions.isEmpty {
            parts.append("Any day")
        } else {
            parts.append(conditions.map(\.describe).joined(separator: " and "))
        }
        if let precededBy { parts.append(precededBy.describe) }
        switch (scope, years) {
        case (nil, .all): break
        case (nil, .year(let y)): parts.append("in \(y)")
        case (let period?, .all): parts.append("in \(period.name) of any year")
        case (let period?, .year(let y)): parts.append("in \(period.name) \(y)")
        }
        if let sequence { parts.append(sequence.describe) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - What comes back

public struct MatchedDay: Equatable, Sendable, Identifiable {
    public var record: DailyRecord
    /// The values that satisfied the query, in condition order.
    public var values: [Double]
    /// How far the FIRST condition's measure sat from what's normal for that
    /// date. Nil where the measure has no seasonal normal, or the record is too
    /// thin around that date to have one worth quoting.
    public var departure: Double?
    public var id: String { record.day }
    public var day: String { record.day }
}

/// One measure on the matching days, against what those DATES usually do.
///
/// The baseline used to be every day the question could have looked at, and it
/// was worse than useless — comparing late-August days to a year containing
/// January. "101° against 80° across all days" is arithmetic, not a finding.
/// Averaging the same-date normals instead makes the comparison date-matched by
/// construction: it doesn't care whether the days cluster in a fortnight or
/// scatter across four months, and it needs no date window to be correct.
public struct MeasureAverage: Equatable, Sendable, Identifiable {
    public var measure: Measure
    /// Across the matching days.
    public var matched: Double
    /// What these dates usually do — the mean of their normals. Nil where the
    /// record is too thin for a normal worth quoting, never zero.
    public var usual: Double?
    /// Days that carried this reading.
    public var matchedDays: Int
    /// Whether this measure was named in the query.
    ///
    /// It makes the box nearly tautological — days selected for a high at or
    /// above 100 will of course average above normal — so it has to be marked.
    /// Not removed: how far PAST the threshold they ran is real information, and
    /// hiding what you asked about would read as a bug.
    public var wasAsked: Bool
    public var id: String { measure.rawValue }

    /// How far from usual, when there's a usual to be far from.
    public var departure: Double? { usual.map { matched - $0 } }

    /// Rain and lightning read as a SHARE of days, not a daily mean. Mean daily
    /// rainfall across a dry fortnight is a true number that describes no day
    /// that happened — 0.03" is not a drizzle, it's a downpour divided by the
    /// days it didn't rain.
    public var isShare: Bool { measure == .rain || measure == .lightning }

    public var name: String {
        switch measure {
        case .rain: return "Days with rain"
        case .lightning: return "Days with lightning"
        default: return measure.name
        }
    }

    public func format(_ value: Double) -> String {
        isShare ? "\(Int((value * 100).rounded()))%" : measure.format(value)
    }

    public var matchedLabel: String { format(matched) }
    public var usualLabel: String? { usual.map(format) }

    /// A signed departure, in the measure's own units — "+7°", "−4 mph". Shares
    /// read in points, not percent: a jump from 16% to 27% is eleven POINTS, and
    /// calling it 11% would be a different and wrong number.
    public var departureLabel: String? {
        guard let departure, abs(departure) >= smallestWorthSaying else { return nil }
        let sign = departure > 0 ? "+" : "−"
        let size = abs(departure)
        if isShare { return "\(sign)\(Int((size * 100).rounded())) pts" }
        return "\(sign)\(measure.format(size))"
    }

    /// Below this the difference is rounding, and a "+0°" reads as a claim.
    private var smallestWorthSaying: Double {
        switch measure {
        case .rain, .lightning: return 0.01
        case .pressure: return 0.005
        case .uv: return 0.05
        default: return 0.5
        }
    }
}

/// What the weather was actually LIKE — as opposed to how often it did the one
/// thing you asked about.
public struct WeatherProfile: Equatable, Sendable {
    public var averages: [MeasureAverage]
    /// Days that matched and were solid enough to average.
    public var matchedDays: Int

    public var isEmpty: Bool { averages.isEmpty }

    public static let none = WeatherProfile(averages: [], matchedDays: 0)
}

/// One year's version of a date — the evidence UNDER a calendar cell.
///
/// The counts say how often a date did the thing; they can't say how nearly the other years did it, and
/// "97° on a query for 100°" is the difference between a date that almost always delivers and one that
/// never comes close. Every year in scope is carried, matched or not, with its readings — the archive
/// already holds them, and a square that stands for four real days should be able to name them.
public struct CalendarYear: Equatable, Sendable, Identifiable {
    public enum Outcome: Equatable, Sendable {
        case matched
        /// Answerable, and the answer was no.
        case missed
        /// The station didn't watch enough of the day to settle it either way.
        case unanswerable
        /// Recorded a matching reading it couldn't stand behind — never counted, never dropped.
        case setAside
        /// Matched the conditions but a sequence rule didn't select it — "the FIRST 100° day" leaves
        /// every later one on the floor, and calling those a miss would be false.
        case notSelected
    }

    public var year: Int
    public var day: String
    public var outcome: Outcome
    /// The queried measures on that day, in condition order. Nil where the day has no such reading.
    public var values: [Double?]
    public var high: Double?
    public var low: Double?
    /// The station watched the day through.
    public var isReliable: Bool
    public var id: Int { year }

    public var isMatch: Bool { outcome == .matched }
}

/// One `MM-dd` across every year — the cell of the pattern view.
public struct QueryCalendarCell: Equatable, Sendable, Identifiable {
    public var monthDay: String
    public var yearsMatched: Int
    /// Years whose version of this date could ANSWER the query at all.
    public var yearsAnswered: Int
    /// Every year's version of this date, oldest first.
    public var years: [CalendarYear] = []
    public var id: String { monthDay }

    /// Share of answerable years that matched. Nil where nothing could answer —
    /// which renders as "unknown", never as zero.
    public var rate: Double? {
        yearsAnswered > 0 ? Double(yearsMatched) / Double(yearsAnswered) : nil
    }
}

public struct QueryMonth: Equatable, Sendable, Identifiable {
    public var month: Int
    /// Days that matched across EVERY year on record — four Mays, not one.
    public var matched: Int
    /// Days across every year that could settle the question.
    public var answered: Int
    public var id: Int { month }
    public var name: String { WeatherAlmanac.monthName(String(format: "%02d", month), long: false) }
    public var rate: Double? { answered > 0 ? Double(matched) / Double(answered) : nil }

    private static let lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    /// Nominal length of a month, for judging how much of one was watched.
    /// February is 28 — the leap day moves this by a thirtieth of a percent and
    /// nothing here is that precise.
    public static func length(of month: Int) -> Int {
        lengths[max(0, min(11, month - 1))]
    }

    /// What a single one of these months looks like, ACROSS THE RECORD — the
    /// number the eye expects when a bar is labelled "May".
    ///
    /// A raw total across the record can EXCEED the month (48 rainy days in a
    /// 31-day May), which reads as an error and undermines the chart. Derived
    /// from the rate rather than from `matched ÷ years` because the years
    /// aren't equally watched: the archive opens in October 2022 and the
    /// current year is partial, so dividing by a year count would quietly
    /// report every month short.
    ///
    /// ONLY MEANINGFUL POOLED ACROSS YEARS. Pinned to one year this becomes an
    /// extrapolation — a May watched for twenty days with eight rainy ones
    /// would report twelve — so a single-year view must show `matched` instead.
    public var typicalDays: Double? {
        rate.map { $0 * Double(QueryMonth.length(of: month)) }
    }
}

/// One year's answer to the query. The third grouping axis, alongside
/// month-of-year and date-of-year.
public struct QueryYear: Equatable, Sendable, Identifiable {
    public var year: Int
    public var matched: Int
    public var answered: Int
    /// Days of this year's scope that had ELAPSED — not days scheduled, so a
    /// running year isn't reported as having missed its own future.
    public var expected: Int
    public var id: Int { year }

    public var coverage: Double {
        expected > 0 ? min(1, Double(answered) / Double(expected)) : 0
    }
    /// Whether this year's count can sit in a row beside the others. A year the
    /// station watched half of will always look calm, and comparing it to a
    /// full one is comparing the station's uptime, not the weather.
    public var isComparable: Bool { coverage >= 0.9 }
    public var rate: Double? { answered > 0 ? Double(matched) / Double(answered) : nil }
}

/// How many years saw this AT ALL — "rain in 3 of the 4 Septembers".
///
/// A different question from every other count here, and one nothing could ask.
/// The calendar answers per DATE ("Sep 12 was wet in 2 of 4 years") and the year
/// bars answer how MUCH ("2023: 14 days"); neither says whether a September, as
/// a unit, is normally a wet one. That's the shape of most questions about a
/// month — you want to know if it happens, not how often it happens.
///
/// Only comparable years vote. A September the station watched half of will
/// always look dry, and letting it into the denominator reports the station's
/// uptime as a fact about the weather.
public struct YearRate: Equatable, Sendable {
    public var yearsWith: Int
    public var yearsComparable: Int
    /// Watched years left out because a running or half-missed instance can't
    /// be counted either way — surfaced, never silently dropped.
    public var yearsUncounted: Int

    public var isMeaningful: Bool { yearsComparable >= 2 }
    /// True when it happens in more years than not.
    public var isUsual: Bool { yearsWith * 2 > yearsComparable }
}

/// How often the query is true at each point in the year — and therefore WHEN
/// the conditions it describes usually arrive and leave.
///
/// This is the inverse of "show me the days": rather than listing occurrences,
/// it asks what fraction of years had one on each date. That turns any query at
/// all into a seasonal answer, including ones no smoothed-measure crossing
/// could express — "storms", "hot but dry", anything with several conditions.
public struct SeasonalFrequency: Equatable, Sendable {
    /// Smoothed share of years that matched, per `MM-dd`. Nil where too little
    /// of the window could answer to draw a rate.
    public var points: [String: Double]
    /// Calendar order, so the curve can be drawn and the runs walked.
    public var monthDays: [String]
    /// Where the smoothed rate rises past the threshold and stays, and where it
    /// falls back. Nil when it never gets there.
    public var begins: String?
    public var ends: String?
    /// Length of the above-threshold season, in days.
    public var seasonLength: Int?
    public var threshold: Double

    /// The wider window where this happens AT ALL, at a much lower bar.
    ///
    /// Without it the headline overclaims: freezing nights are the norm for a
    /// fortnight in late January, but they happen from November through March,
    /// and a sentence naming only the fortnight reads as a claim that the rest
    /// of winter is safe. "When is it the norm" and "when does it happen" are
    /// different questions and this curve is where they come apart.
    public var activeBegins: String?
    public var activeEnds: String?
    public var activeLength: Int?
    public var activeThreshold: Double
    /// Dates where this is essentially absent. What proves there's an off
    /// season at all — see `hasUsefulActiveWindow`.
    public var quietDays: Int = 0
    public var peak: (monthDay: String, rate: Double)?
    /// Most years contributing to any one date.
    public var yearsOfRecord: Int

    public var isMeaningful: Bool { points.count >= 200 && yearsOfRecord >= 3 }
    /// It crosses the threshold at some point in the year.
    public var hasSeason: Bool { begins != nil && ends != nil }

    /// Whether "happens from X through Y" is a true sentence.
    ///
    /// It needs a genuine OFF SEASON. Found against real data: rain here runs
    /// year-round at a low winter rate, and a fixed 10% bar carved it into
    /// "happens March 20 through July 23" — which reads as a claim that it
    /// doesn't rain in November. A window is only honest when the curve
    /// actually falls to nothing for a real stretch outside it; otherwise the
    /// truthful answer is just the peak.
    public var hasUsefulActiveWindow: Bool {
        guard let activeLength, activeBegins != nil else { return false }
        return quietDays >= 30
            && activeLength < (monthDays.count * 9) / 10
            && activeLength > (seasonLength ?? 0) + 14
    }

    public static func == (a: SeasonalFrequency, b: SeasonalFrequency) -> Bool {
        a.points == b.points && a.monthDays == b.monthDays && a.begins == b.begins
            && a.ends == b.ends && a.threshold == b.threshold
            && a.activeBegins == b.activeBegins && a.activeEnds == b.activeEnds
            && a.peak?.monthDay == b.peak?.monthDay && a.yearsOfRecord == b.yearsOfRecord
    }
}

/// One instance of the scope, and the date it delivered.
public struct Occurrence: Equatable, Sendable, Identifiable {
    /// The year the scope's instance OPENED in — a wrapping winter is filed
    /// under its December.
    public var year: Int
    public var day: String
    public var monthDay: String { DayKey.monthDay(of: day) }
    public var id: Int { year }
}

/// What a first/last query actually answers: not "how many days" but "which
/// date, and how much does it move".
///
/// The same shape the frost-date and season-transition summaries use, because
/// it's the same kind of claim — a typical date is a lie of precision without
/// the window it moves in.
public struct OccurrenceSpread: Equatable, Sendable {
    public var occurrences: [Occurrence]
    /// `MM-dd` of the median.
    public var typical: String?
    public var earliest: String?
    public var latest: String?
    /// Days between the earliest and the latest.
    public var spreadDays: Int?
    /// The calendar order these are read in — a wrapping scope runs December
    /// before January, and sorting the raw month-days would reverse it.
    public var axis: [String]

    /// Two dates is an anecdote.
    public var isMeaningful: Bool { occurrences.count >= 2 }
}

public struct QueryResult: Equatable, Sendable {
    public var query: DayQuery
    /// Newest first.
    public var days: [MatchedDay]
    public var calendar: [QueryCalendarCell]
    public var months: [QueryMonth]
    /// Newest first.
    public var years: [QueryYear]
    /// Only computed for an unscoped, all-years query — see `seasonalFrequency`.
    public var season: SeasonalFrequency?
    /// Only for a first/last query, where the answer is a date per instance
    /// rather than a set of days.
    public var spread: OccurrenceSpread?
    /// When the pattern OPENS and CLOSES each year — computed whether or not
    /// anyone asked for it.
    ///
    /// "The first one usually turns up in June" is a fact about the pattern, not
    /// a different question about it, and it shouldn't cost you your day list to
    /// find out. Nil under a sequence rule, where the result already IS a set of
    /// openings and asking when they opened is circular.
    public var opens: OccurrenceSpread?
    public var closes: OccurrenceSpread?
    /// Runs of consecutive matching days, longest first.
    public var streaks: [Streak]
    /// What the weather was actually LIKE — on the matching days, and across
    /// the window they came from.
    public var profile: WeatherProfile

    /// Days that RECORDED a matching reading but weren't watched closely enough
    /// to prove it, newest first.
    ///
    /// The honesty rule is right and these still can't be counted: a day seen
    /// for 17% of its hours can't guarantee its high stayed below anything.
    /// But dropping them silently produced a result that was formally correct
    /// and obviously wrong — a January cold snap that ran 17° to 19° all day
    /// reported as zero, because the station was struggling in the cold that
    /// made it interesting. So they're kept aside and labelled, never counted.
    public var unconfirmed: [MatchedDay]
    /// Days in scope the archive holds at all.
    public var daysInScope: Int
    /// Days that could settle the query either way.
    public var daysAnswered: Int
    /// Days that couldn't — never counted as misses.
    public var daysUnanswerable: Int { max(0, daysInScope - daysAnswered) }

    public var matchCount: Int { days.count }

    /// In how many of the years did this happen at all — see `YearRate`.
    ///
    /// Computed off `years`, which already carries the comparability rule, so
    /// this can't drift from the year-by-year lens sitting beside it.
    public var yearRate: YearRate? {
        let comparable = years.filter(\.isComparable)
        guard comparable.count >= 2 else { return nil }
        return YearRate(yearsWith: comparable.filter { $0.matched > 0 }.count,
                        yearsComparable: comparable.count,
                        yearsUncounted: years.count - comparable.count)
    }

    /// Share of the answerable days that matched.
    ///
    /// Withheld under a sequence rule. "The first 100° day of each year" is four
    /// days out of fourteen hundred, and 0.3% is a true fraction that means
    /// nothing — the denominator stopped corresponding to the thing counted the
    /// moment the rule threw days away.
    public var rate: Double? {
        guard query.sequence == nil, daysAnswered > 0 else { return nil }
        return Double(matchCount) / Double(daysAnswered)
    }

    /// The count is a FLOOR whenever days went unanswered: one of them may well
    /// have matched. Any surface quoting the number has to be able to say so.
    public var isFloor: Bool { daysUnanswerable > 0 }

    /// `days` is newest first, so the ends read backwards from the array.
    public var earliest: MatchedDay? { days.last }
    public var latest: MatchedDay? { days.first }

    /// Typical date in the year, as a `MM-dd` — meaningful only for something
    /// that happens in one season. Nil when the matches are scattered across
    /// the calendar, where a "typical date" would be an artifact of averaging
    /// January and July.
    public var typicalMonthDay: String? {
        let matched = calendar.filter { $0.yearsMatched > 0 }.map(\.monthDay).sorted()
        guard matched.count >= 3 else { return nil }
        // Spread across more than half the year means there's no season to name.
        guard let first = matched.first, let last = matched.last,
              (DayKey.distance(from: "2001-\(first)", to: "2001-\(last)") ?? 365) < 183
        else { return nil }
        return matched[matched.count / 2]
    }
}

// MARK: - Running it

extension Climatology {

    /// Every day matching the query, plus the shapes that make a list of days
    /// into a pattern.
    public func run(_ query: DayQuery) -> QueryResult {
        let scoped = daysInScope(of: query)

        var tally = evaluate(query, over: scoped)
        // A sequence rule prunes the matches, so every grouping built from them
        // has to be rebuilt — the calendar and the month profile describe the
        // days that SURVIVED, not the ones that got as far as being candidates.
        if let sequence = query.sequence {
            tally.rematch(applySequence(sequence, to: tally.matches, query: query))
        }

        // YEAR BY YEAR ALWAYS SPANS EVERY YEAR, even when the query is pinned
        // to one. The card's entire job is cross-year comparison, and a single
        // bar answers nothing — "how does this year stack up" is precisely the
        // question you have while looking at one year. The DATE scope still
        // applies, so pinning September 2025 compares Septembers.
        let acrossYears: Tally
        if case .year = query.years {
            var unpinned = query
            unpinned.years = .all
            var across = evaluate(unpinned, over: daysInScope(of: unpinned))
            if let sequence = query.sequence {
                across.rematch(applySequence(sequence, to: across.matches, query: unpinned))
            }
            acrossYears = across
        } else {
            acrossYears = tally
        }

        let cells = calendarCells(matched: tally.matchedByMonthDay,
                                  answered: tally.answeredByMonthDay, scope: query.scope,
                                  years: calendarYears(query, over: scoped, tally: tally))
        return QueryResult(
            query: query,
            days: withDepartures(tally.matches, from: query.conditions.first?.measure)
                .sorted { $0.day > $1.day },
            calendar: cells,
            months: monthTotals(matched: tally.matchedByMonthDay,
                                answered: tally.answeredByMonthDay),
            years: yearTotals(matched: acrossYears.matchedByYear,
                              answered: acrossYears.answeredByYear, query: query),
            season: seasonalCurve(for: query, unscopedCells: cells),
            spread: spread(of: tally.matches, query: query),
            opens: edges(.firstEachYear, of: tally.matches, query: query),
            closes: edges(.lastEachYear, of: tally.matches, query: query),
            streaks: runs(of: tally.matches.map(\.day)),
            profile: profile(matching: tally.matches.map(\.record), query: query),
            unconfirmed: tally.unconfirmed.sorted { $0.day > $1.day },
            daysInScope: scoped.count,
            daysAnswered: tally.answered)
    }

    /// The order the boxes read in: temperature first, because that's what
    /// "what was it like" means to most people, then the air, then the sky.
    /// Peak dew point is left out — beside the mean it's a second number about
    /// the same thing, and this card is for the shape of a day, not its extremes.
    private static let profiled: [Measure] = [
        .high, .low, .meanTemp, .dewPoint, .humidity, .wind, .gust, .rain, .pressure, .uv, .lightning
    ]

    /// What the weather was LIKE on the matching days, against what those DATES
    /// usually do.
    ///
    /// Only reliable days are averaged. A day seen for a third of its hours has
    /// a "mean temperature" the same way a half-read sentence has a meaning —
    /// the number exists and it isn't the one you want.
    private func profile(matching matched: [DailyRecord], query: DayQuery) -> WeatherProfile {
        let solid = matched.filter(\.isReliable)
        guard !solid.isEmpty else { return .none }

        // One normal per DATE, not per day — a fortnight-long heatwave asks for
        // the same fourteen normals a dozen times over.
        let normals = Dictionary(uniqueKeysWithValues: Set(solid.map { DayKey.monthDay(of: $0.day) })
            .map { ($0, normal(monthDay: $0)) })
        let asked = Set(query.conditions.map(\.measure))

        let averages = Climatology.profiled.compactMap { measure -> MeasureAverage? in
            guard let (value, days) = average(measure, over: solid) else { return nil }
            return MeasureAverage(measure: measure,
                                  matched: value,
                                  usual: usual(measure, across: solid, normals: normals),
                                  matchedDays: days,
                                  wasAsked: asked.contains(measure))
        }
        return WeatherProfile(averages: averages, matchedDays: solid.count)
    }

    /// What these dates usually do: the mean of their normals, weighted by how
    /// often each date turned up — so a measure is judged against the part of
    /// the calendar the matches actually came from.
    ///
    /// A normal built from one year is last year's weather, so thin ones are
    /// dropped rather than averaged in. That can leave nothing, which is an
    /// honest answer and reads as no baseline rather than as a zero.
    private func usual(_ measure: Measure, across records: [DailyRecord],
                       normals: [String: DailyNormal]) -> Double? {
        guard let path = Climatology.normalPath(for: measure) else { return nil }
        let values = records.compactMap { record -> Double? in
            guard let normal = normals[DayKey.monthDay(of: record.day)],
                  normal.isMeaningful else { return nil }
            return normal[keyPath: path]
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Which field of a normal a measure is judged against.
    ///
    /// Rain and lightning divert to the FREQUENCY normals: the profile reads
    /// them as a share of days, and comparing a share against a mean amount
    /// would put two different quantities in the same box.
    private static func normalPath(for measure: Measure) -> KeyPath<DailyNormal, Double?>? {
        switch measure {
        case .rain: return \.rainFrequency
        case .lightning: return \.lightningFrequency
        default: return measure.normalPath
        }
    }

    /// A mean, or — for the measures where a mean lies — the share of days that
    /// saw the thing at all. Nil when nothing recorded it.
    private func average(_ measure: Measure,
                         over records: [DailyRecord]) -> (value: Double, days: Int)? {
        let values = records.compactMap { $0[keyPath: measure.path] }
        guard !values.isEmpty else { return nil }
        switch measure {
        case .rain:
            let wet = values.filter { $0 >= 0.01 }.count
            return (Double(wet) / Double(values.count), values.count)
        case .lightning:
            let struck = values.filter { $0 >= 1 }.count
            return (Double(struck) / Double(values.count), values.count)
        default:
            return (values.reduce(0, +) / Double(values.count), values.count)
        }
    }

    /// The curve of when these conditions arrive, across the WHOLE calendar —
    /// deliberately ignoring the query's date window.
    ///
    /// This used to be withheld the moment a scope was set, and the reasoning
    /// was sound as far as it went: a curve built from September's days is a
    /// 30-day fragment that can't say when anything begins. But withholding it
    /// answered the wrong objection. Narrowing to a window is exactly when you
    /// want to know whether the days you found are the shoulder of something
    /// larger or a fluke of the fortnight you picked, and that question can
    /// only be answered by the days OUTSIDE the window. So the conditions are
    /// re-run scope-free and the curve covers the year; the caller shades the
    /// window on top of it.
    ///
    /// The other two suppressions stand. Pinned to one year there is nothing to
    /// pool. Under a sequence rule there is one date per year, which draws a
    /// flat line at 4% and reports "never becomes the norm" — technically true
    /// of a first-freeze query and a useless thing to say about it.
    private func seasonalCurve(for query: DayQuery,
                               unscopedCells cells: [QueryCalendarCell]) -> SeasonalFrequency? {
        guard query.years == .all, query.sequence == nil else { return nil }
        // Unscoped already: the cells the caller built ARE the whole year.
        guard query.scope != nil else { return seasonalFrequency(from: cells) }

        var unscoped = query
        unscoped.scope = nil
        let tally = evaluate(unscoped, over: daysInScope(of: unscoped))
        return seasonalFrequency(from: calendarCells(matched: tally.matchedByMonthDay,
                                                     answered: tally.answeredByMonthDay,
                                                     scope: nil))
    }

    /// Was this stretch watched throughout, counting BOTH ends?
    ///
    /// `hasCoverage` measures a span exclusively, which is fine for the
    /// month-long windows it was written for and wrong here. Real data caught
    /// it: 2024's and 2025's first freeze both landed on January 1, giving a
    /// span of zero days — read as "no window to cover" and the occurrence
    /// withheld, when a candidate on the window's opening day has nothing
    /// before it that could have been missed.
    private func watchedThroughout(_ from: String, _ to: String, minimum: Double = 0.9) -> Bool {
        guard from <= to, let span = DayKey.distance(from: from, to: to) else { return false }
        let held = all.filter { $0.day >= from && $0.day <= to }.count
        return Double(held) / Double(span + 1) >= minimum
    }

    /// The dates a first/last query landed on, and how far they move.
    ///
    /// Ordered along the SCOPE, not along the calendar. For a winter query the
    /// dates run December, January, February — sorting the month-days would put
    /// January first and report the season's end as its beginning.
    private func spread(of days: [MatchedDay], query: DayQuery) -> OccurrenceSpread? {
        switch query.sequence {
        case .firstEachYear, .lastEachYear: break
        default: return nil
        }
        return spread(over: days, query: query)
    }

    /// Where the pattern opens or closes each year, for a query that didn't ask.
    ///
    /// It runs the same rule the SHOW filter runs — including the honesty check
    /// that a "first" is only a first if everything before it was watched — so
    /// the dates on the chart and the dates behind the filter can never disagree.
    /// A wrapping window files each instance under the year it OPENED in, so a
    /// winter that only froze in January still counts as that winter.
    private func edges(_ rule: SequenceRule, of days: [MatchedDay],
                       query: DayQuery) -> OccurrenceSpread? {
        guard query.sequence == nil, !days.isEmpty else { return nil }
        let picked = applySequence(rule, to: days, query: query)
        guard !picked.isEmpty else { return nil }
        return spread(over: picked, query: query)
    }

    /// The same shape, computed for a set of dates that were picked out
    /// deliberately rather than being what the query asked for.
    private func spread(over days: [MatchedDay], query: DayQuery) -> OccurrenceSpread? {
        let axis = (query.scope ?? WeatherPeriod(name: "", start: "01-01",
                                                 endExclusive: "01-01")).monthDays
        let order = Dictionary(uniqueKeysWithValues: axis.enumerated().map { ($1, $0) })

        let occurrences = days
            .compactMap { match -> Occurrence? in
                guard let year = DayKey.year(of: match.day) else { return nil }
                // A wrapping scope files its instance under the year it opened,
                // so a January date belongs to the previous year's window.
                let monthDay = DayKey.monthDay(of: match.day)
                let opensLater = query.scope?.wrapsYearEnd == true
                    && monthDay < (query.scope?.start ?? "01-01")
                return Occurrence(year: opensLater ? year - 1 : year, day: match.day)
            }
            .sorted { $0.year < $1.year }

        let positions = occurrences.compactMap { order[$0.monthDay] }.sorted()
        var result = OccurrenceSpread(occurrences: occurrences, axis: axis)
        if !positions.isEmpty {
            result.typical = axis[positions[positions.count / 2]]
            result.earliest = axis[positions.first!]
            result.latest = axis[positions.last!]
            result.spreadDays = positions.last! - positions.first!
        }
        return result
    }

    /// Did any of the days before this one satisfy the preceding clause?
    ///
    /// Three answers, not two, and the third is why this can't be a plain Bool:
    /// a day the archive doesn't hold, or can't settle, means we don't KNOW
    /// what came before — and "we don't know if it rained yesterday" must never
    /// be recorded as "it didn't rain yesterday".
    private func precedingVerdict(_ clause: PrecedingClause, before day: String) -> Bool? {
        var sawUnknown = false
        for step in 1...clause.within {
            guard let key = DayKey.step(day, by: -step) else { return nil }
            guard let record = record(on: key) else {
                // A missing day could have been the one that matched.
                sawUnknown = true
                continue
            }
            let verdicts = clause.conditions.map { $0.evaluate(record) }
            if verdicts.allSatisfy({ $0 == true }) { return true }   // found one, done
            if verdicts.contains(nil) { sawUnknown = true }
        }
        // Nothing matched — but "none of them matched" is only a NO if every
        // one of them could be checked.
        return sawUnknown ? nil : false
    }

    /// Apply the sequence rule to the days that matched.
    ///
    /// Each rule carries its own coverage gate, because each makes a claim
    /// about days it may never have seen. "The first 100° day of 2022" is not a
    /// fact this archive can state — it opens in October, and the real first
    /// one was in July.
    private func applySequence(_ rule: SequenceRule, to days: [MatchedDay],
                               query: DayQuery) -> [MatchedDay] {
        let ordered = days.sorted { $0.day < $1.day }
        switch rule {
        case .firstEachYear, .lastEachYear:
            let first = rule == .firstEachYear
            var picked: [MatchedDay] = []
            // Every year the ARCHIVE holds, not every year the matches fall in.
            // A wrapping scope breaks the shortcut: winter 2024 runs into
            // February 2025, so a winter whose only freezes landed in January
            // has no matched day stamped 2024 at all — and iterating the
            // matches' own years would skip that winter entirely.
            for year in years {
                let bounds = query.scope?.bounds(inYear: year) ?? ("\(year)-01-01", "\(year)-12-31")
                let inYear = ordered.filter { $0.day >= bounds.start && $0.day <= bounds.end }
                guard let candidate = first ? inYear.first : inYear.last else { continue }
                // A "first" is only a first if everything before it was
                // watched; a "last", if everything after it was.
                let watched = first
                    ? watchedThroughout(bounds.start, candidate.day)
                    : watchedThroughout(candidate.day, bounds.end)
                guard watched else { continue }
                picked.append(candidate)
            }
            return picked

        case .inRunOfAtLeast(let length):
            // Runs come from the archive's own run-finder, so a run only
            // continues across genuinely adjacent days — a hole in the record
            // ends it rather than being stepped over.
            let byDay = Dictionary(ordered.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
            return DayKey.runs(of: ordered.map(\.day))
                .filter { ((DayKey.distance(from: $0.first, to: $0.last) ?? 0) + 1) >= length }
                .flatMap { run -> [MatchedDay] in
                    var out: [MatchedDay] = []
                    var cursor: String? = run.first
                    while let key = cursor, key <= run.last {
                        if let match = byDay[key] { out.append(match) }
                        cursor = DayKey.next(key)
                    }
                    return out
                }
        }
    }

    /// Tag each matched day with how far it sat from normal for its date.
    ///
    /// Normals are memoized by month-day: the pooled ±7-day window is the same
    /// calculation for every August 14 in the record, and a query matching
    /// nine hundred days would otherwise rebuild it nine hundred times.
    private func withDepartures(_ days: [MatchedDay], from measure: Measure?) -> [MatchedDay] {
        guard let measure, let normalPath = measure.normalPath else { return days }
        var cache: [String: Double?] = [:]
        return days.map { matched in
            var day = matched
            let monthDay = DayKey.monthDay(of: matched.day)
            let usual = cache[monthDay] ?? {
                let computed = normal(monthDay: monthDay)
                // A "normal" from one year is last year's weather; comparing to
                // it would manufacture departures out of coincidence.
                let value = computed.isMeaningful ? computed[keyPath: normalPath] : nil
                cache[monthDay] = value
                return value
            }()
            if let usual, let actual = matched.record[keyPath: measure.path] {
                day.departure = actual - usual
            }
            return day
        }
    }

    /// Would the reading this day DID record satisfy every condition, setting
    /// aside whether the day watched enough hours to prove it?
    private func wouldMatch(_ query: DayQuery, _ record: DailyRecord) -> Bool {
        guard !query.conditions.isEmpty else { return false }
        return query.conditions.allSatisfy { condition in
            guard let value = record[keyPath: condition.measure.path] else { return false }
            return condition.test.passes(value, measure: condition.measure)
        }
    }

    /// The accumulators one pass over a day set fills in.
    private struct Tally {
        var matches: [MatchedDay] = []
        var answered = 0
        var matchedByMonthDay: [String: Int] = [:]
        var answeredByMonthDay: [String: Int] = [:]
        var matchedByYear: [Int: Int] = [:]
        var answeredByYear: [Int: Int] = [:]
        var unconfirmed: [MatchedDay] = []
        /// Which days could settle the question — the per-day form of `answered`, for surfaces that show
        /// a day at a time rather than a count.
        var answeredDays: Set<String> = []

        /// Replace the matches and rebuild every count derived from them. The
        /// ANSWERED counts are untouched: which days could settle the question
        /// doesn't change because a sequence rule discarded some that did.
        mutating func rematch(_ survivors: [MatchedDay]) {
            matches = survivors
            matchedByMonthDay = [:]
            matchedByYear = [:]
            for match in survivors {
                matchedByMonthDay[DayKey.monthDay(of: match.day), default: 0] += 1
                if let year = DayKey.year(of: match.day) { matchedByYear[year, default: 0] += 1 }
            }
        }
    }

    /// One day's answer to the query's day-level clauses: yes, no, or nil when the day can't settle it.
    ///
    /// A single unanswerable condition makes the whole day unanswerable — unless another condition
    /// already proved a definite NO, which settles it regardless of what the rest couldn't say.
    /// Internal, not private: `WhenInTheYear` reads the same verdicts a day at a time, and a second copy
    /// of this rule is exactly the kind of duplicate that drifts.
    func verdict(_ query: DayQuery, on record: DailyRecord) -> Bool? {
        var verdicts = query.conditions.map { $0.evaluate(record) }
        if let clause = query.precededBy {
            verdicts.append(precedingVerdict(clause, before: record.day))
        }
        if verdicts.contains(false) { return false }
        if verdicts.contains(nil) { return nil }
        return true
    }

    private func evaluate(_ query: DayQuery, over days: [DailyRecord]) -> Tally {
        var tally = Tally()
        for record in days {
            let answer = verdict(query, on: record)
            guard let answer else {
                // Unsettleable — but if what it DID record reads as a match,
                // say so rather than let it vanish.
                if wouldMatch(query, record) {
                    let values = query.conditions.compactMap { record[keyPath: $0.measure.path] }
                    tally.unconfirmed.append(MatchedDay(record: record, values: values))
                }
                continue
            }

            let monthDay = DayKey.monthDay(of: record.day)
            let year = DayKey.year(of: record.day) ?? 0
            tally.answered += 1
            tally.answeredDays.insert(record.day)
            tally.answeredByMonthDay[monthDay, default: 0] += 1
            tally.answeredByYear[year, default: 0] += 1
            guard answer else { continue }

            let values = query.conditions.compactMap { record[keyPath: $0.measure.path] }
            tally.matches.append(MatchedDay(record: record, values: values))
            tally.matchedByMonthDay[monthDay, default: 0] += 1
            tally.matchedByYear[year, default: 0] += 1
        }
        return tally
    }

    private func yearTotals(matched: [Int: Int], answered: [Int: Int],
                            query: DayQuery) -> [QueryYear] {
        let lastDay = all.last?.day ?? ""
        return answered.keys.sorted(by: >).map { year in
            // How much of this year's scope had actually elapsed and been
            // archivable — the same "never count the future as missed" rule the
            // period summaries use.
            let bounds = query.scope?.bounds(inYear: year)
                ?? ("\(year)-01-01", "\(year)-12-31")
            let end = min(bounds.end, lastDay)
            let expected = max(0, (DayKey.distance(from: bounds.start, to: end) ?? -1) + 1)
            return QueryYear(year: year, matched: matched[year] ?? 0,
                             answered: answered[year] ?? 0, expected: expected)
        }
    }

    /// The days a query is allowed to look at, from both scope axes.
    ///
    /// Pinning a year to a WRAPPING period is the case worth care: "Winter
    /// 2025" is December 2025 through February 2026, one continuous season —
    /// not December, January and February of 2025, which is three disjoint
    /// months and not a winter. So a year-pinned query resolves the period to
    /// CONCRETE BOUNDS (which already file a wrapping window under the year it
    /// opened in) rather than matching on month-days.
    /// Internal, not private: `Aggregate` reduces over the same selection, and a second copy of this
    /// switch is exactly the kind of duplicate that drifts.
    func daysInScope(of query: DayQuery) -> [DailyRecord] {
        switch (query.scope, query.years) {
        case (nil, .all):
            return all
        case (nil, .year(let year)):
            return all.filter { DayKey.year(of: $0.day) == year }
        case (let period?, .all):
            return all.filter { period.contains(monthDay: DayKey.monthDay(of: $0.day)) }
        case (let period?, .year(let year)):
            guard let bounds = period.bounds(inYear: year) else { return [] }
            return all.filter { $0.day >= bounds.start && $0.day <= bounds.end }
        }
    }

    /// One cell per calendar date in scope, whether or not anything matched —
    /// the empty stretches are half of what a pattern view says.
    private func calendarCells(matched: [String: Int], answered: [String: Int],
                               scope: WeatherPeriod?,
                               years: [String: [CalendarYear]] = [:]) -> [QueryCalendarCell] {
        let keys = scope?.monthDays ?? WeatherPeriod(name: "", start: "01-01",
                                                    endExclusive: "01-01").monthDays
        return keys.map { monthDay in
            QueryCalendarCell(monthDay: monthDay,
                              yearsMatched: matched[monthDay] ?? 0,
                              yearsAnswered: answered[monthDay] ?? 0,
                              years: years[monthDay] ?? [])
        }
    }

    /// Every day in scope, filed under its date and labelled with what became of it.
    ///
    /// One pass over the same records the tally just walked — the outcome is read off the sets it filled
    /// rather than re-deciding anything, so a cell's years can never disagree with its counts.
    private func calendarYears(_ query: DayQuery, over scoped: [DailyRecord],
                               tally: Tally) -> [String: [CalendarYear]] {
        let matched = Set(tally.matches.map(\.day))
        let setAside = Set(tally.unconfirmed.map(\.day))
        var out: [String: [CalendarYear]] = [:]

        for record in scoped {
            let outcome: CalendarYear.Outcome
            if matched.contains(record.day) {
                outcome = .matched
            } else if setAside.contains(record.day) {
                outcome = .setAside
            } else if !tally.answeredDays.contains(record.day) {
                outcome = .unanswerable
            } else if wouldMatch(query, record) {
                // Answerable, and it DID read as a match — so only a sequence rule can have dropped it.
                outcome = .notSelected
            } else {
                outcome = .missed
            }
            out[DayKey.monthDay(of: record.day), default: []].append(
                CalendarYear(year: DayKey.year(of: record.day) ?? 0,
                             day: record.day,
                             outcome: outcome,
                             values: query.conditions.map { record[keyPath: $0.measure.path] },
                             high: record.tempMax,
                             low: record.tempMin,
                             isReliable: record.isReliable))
        }
        for key in out.keys { out[key]?.sort { $0.year < $1.year } }
        return out
    }

    private func monthTotals(matched: [String: Int], answered: [String: Int]) -> [QueryMonth] {
        (1...12).map { month in
            let prefix = String(format: "%02d-", month)
            return QueryMonth(
                month: month,
                matched: matched.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +),
                answered: answered.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +))
        }
    }

    /// The seasonal profile of a query, and the dates it turns on and off.
    ///
    /// The raw material is already in the calendar: each date knows how many
    /// years matched it and how many could answer. That ratio IS the seasonal
    /// signal — it just needs smoothing before it can be read, because with a
    /// handful of years a single date is a coin flip with four tosses.
    ///
    /// Two rules carried over from the season-transition engine, both learned
    /// the hard way:
    ///
    /// - The smoothing window is CENTERED. A trailing mean reports every
    ///   transition several days late, in the same direction every time, and
    ///   here the output IS a date.
    /// - The year is CIRCULAR. Freezing nights begin in November and end in
    ///   March; a curve that stops at December 31 would cut that season in half
    ///   and report two short ones.
    func seasonalFrequency(from cells: [QueryCalendarCell],
                           threshold: Double = 0.5,
                           activeThreshold: Double = 0.1,
                           window: Int = 15,
                           minYears: Int = 2) -> SeasonalFrequency {
        let ordered = cells.sorted { $0.monthDay < $1.monthDay }
        let count = ordered.count
        guard count > window else {
            return SeasonalFrequency(points: [:], monthDays: [], threshold: threshold,
                                     activeThreshold: activeThreshold, yearsOfRecord: 0)
        }
        let half = window / 2

        // A date only contributes if enough years could answer it; otherwise
        // one thin year's coin flip would steer the curve.
        let usable = ordered.map { $0.yearsAnswered >= minYears ? $0.rate : nil }

        var points: [String: Double] = [:]
        for index in 0..<count {
            var total = 0.0, seen = 0
            for offset in -half...half {
                // Wrap: the calendar is a ring, not a line.
                let wrapped = ((index + offset) % count + count) % count
                if let rate = usable[wrapped] { total += rate; seen += 1 }
            }
            // Most of the window has to be present, or the "rate" is really a
            // statement about the few days that happened to be watched.
            guard seen >= (window * 6) / 10 else { continue }
            points[ordered[index].monthDay] = total / Double(seen)
        }

        var result = SeasonalFrequency(points: points,
                                       monthDays: ordered.map(\.monthDay),
                                       threshold: threshold,
                                       activeThreshold: activeThreshold,
                                       yearsOfRecord: ordered.map(\.yearsAnswered).max() ?? 0)
        result.peak = points.max { $0.value < $1.value }.map { ($0.key, $0.value) }
        result.quietDays = points.values.filter { $0 < 0.02 }.count

        // The season is the longest CIRCULAR run above the threshold. A run is
        // broken by a date under it or by a date the curve couldn't reach.
        let curve = ordered.map { points[$0.monthDay] }
        if let run = longestCircularRun(over: curve, threshold: threshold) {
            result.begins = ordered[run.start].monthDay
            result.ends = ordered[(run.start + run.length - 1) % count].monthDay
            result.seasonLength = run.length
        }
        // Same walk at a much lower bar — where it happens at all, rather than
        // where it's the norm.
        if let run = longestCircularRun(over: curve, threshold: activeThreshold) {
            result.activeBegins = ordered[run.start].monthDay
            result.activeEnds = ordered[(run.start + run.length - 1) % count].monthDay
            result.activeLength = run.length
        }
        return result
    }

    /// Longest wrap-around run of values at or above a threshold.
    private func longestCircularRun(over values: [Double?],
                                    threshold: Double) -> (start: Int, length: Int)? {
        let count = values.count
        guard count > 0 else { return nil }
        // STRICTLY above. At exactly half the years it isn't "more often than
        // not", it's even — and the sentence this feeds says "more often than
        // not" in so many words.
        let above = values.map { $0.map { $0 > threshold } ?? false }
        // All-year case: a run can't be found by scanning, and "begins" would be
        // arbitrary — report the whole year rather than an invented date.
        if above.allSatisfy({ $0 }) { return (0, count) }

        var best: (start: Int, length: Int)?
        var index = 0
        // Two laps, so a run spanning December into January is walked whole.
        while index < count {
            guard above[index] else { index += 1; continue }
            var length = 0
            while length < count, above[(index + length) % count] { length += 1 }
            if length > (best?.length ?? 0) { best = (index, length) }
            index += max(1, length)
        }
        return best
    }

    /// Consecutive matching days, longest first.
    ///
    /// Uses the archive's own run-finder, so a run only continues across days
    /// that are genuinely adjacent — a match on the 3rd and a match on the 6th
    /// is two streaks, never one of length two.
    private func runs(of days: [String]) -> [Streak] {
        DayKey.runs(of: days)
            .map { run in
                Streak(length: (DayKey.distance(from: run.first, to: run.last) ?? 0) + 1,
                       firstDay: run.first, lastDay: run.last, endedAtGap: false)
            }
            .filter { $0.length > 1 }
            .sorted { $0.length > $1.length }
    }
}

// MARK: - Presets

extension DayQuery {

    /// Starting points, seeded from questions the app already answers elsewhere.
    /// A preset is just a query someone wrote down — there's nothing privileged
    /// about them, and editing one is the point.
    public static var presets: [DayQuery] {
        [DayQuery(name: "Days it rained", conditions: [Condition(.rain, .atOrAbove(0.01))]),
         DayQuery(name: "Half an inch of rain or more", conditions: [Condition(.rain, .atOrAbove(0.5))]),
         DayQuery(name: "Highs of 100° or more", conditions: [Condition(.high, .atOrAbove(100))]),
         DayQuery(name: "Lows of 75° or more", conditions: [Condition(.low, .atOrAbove(75))]),
         DayQuery(name: "Freezing nights", conditions: [Condition(.low, .below(32))]),
         DayQuery(name: "Dew point 70° or more", conditions: [Condition(.dewPointPeak, .inBand("Oppressive"))]),
         DayQuery(name: "Hot but dry", conditions: [Condition(.high, .atOrAbove(90)),
                                                    Condition(.dewPoint, .below(60))]),
         DayQuery(name: "Lows under 68°", conditions: [Condition(.low, .below(68))]),
         DayQuery(name: "Storms", conditions: [Condition(.lightning, .atOrAbove(1)),
                                               Condition(.rain, .atOrAbove(0.1))]),
         DayQuery(name: "Windy", conditions: [Condition(.gust, .atOrAbove(40))])]
    }
}
