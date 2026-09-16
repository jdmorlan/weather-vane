//
//  RainEvent.swift  (WeatherKit)
//
//  WHAT THE RAIN IS ACTUALLY DOING, which no daily total has ever said.
//
//  Until now the only place in this codebase that turned rain into words was
//  `rainAmountCharacter`, and it reads a FORECAST DAY TOTAL: "moderate, steady
//  rain" is a bucket on a quarter-inch expected over the next twenty-four hours.
//  That is a useful sentence in the morning and the wrong one entirely when it is
//  raining on you right now — it isn't describing what's falling, and nothing in
//  the app described a RATE at all. So the honest reaction to standing in it is
//  the one Jay had: the screen says heavy rain and you have no idea what that
//  means.
//
//  A rate is [[a-number-needs-a-referent]] in its purest form. "0.14 inches" is
//  not a thing anyone can feel. Two referents fix it and they are different in
//  kind, so this file carries both: what that rate DOES (spray off pavement,
//  gutters running) and how long an inch would take at it — a duration, which is
//  the unit people actually have intuition for.
//
//  ONE UNIT, TWO MOMENTS. "It's raining" and "it rained today" are not two
//  features. A rain EVENT is a projection over a day's samples; while the last
//  event is still taking samples you are looking at the live end of it, and once
//  it closes you are looking at the whole thing. That is what makes this testable
//  in the sun: the finder takes a day's samples, so it can be pointed at the
//  wettest day in the archive on an afternoon with no cloud in the sky. A card
//  that only ever renders during a storm can only ever be debugged during one.
//
//  RESOLUTION IS LOAD-BEARING, exactly as `StationSample` argues. A peak rate
//  found in a 30-minute bucket is not the same measurement as one found in
//  1-minute data — the bucket averages away the very minute you were trying to
//  report, and the harder the burst the worse it lies. So an event carries the
//  coarsest bucket that fed it and says so rather than quoting a diluted peak as
//  a measurement.
//
//  And the total is a FLOOR, for the reason `Rainfall.swift` already gives: an
//  interval the station missed may well have been the interval it rained, and
//  nothing about the surrounding minutes recovers it.
//

import Foundation

// MARK: - One reading

/// One rain reading, positioned by clock time so a day's rain can be drawn on a
/// single axis without anyone re-deriving hours from epochs.
public struct RainSample: Equatable, Sendable {
    public var timestamp: Int
    /// Minutes since local midnight, at the END of the interval this reading
    /// stands for — which is where the station timestamps it.
    public var minuteOfDay: Int
    /// Inches that fell during this sample's interval. Not a running day total.
    public var amount: Double
    /// Minutes the reading stands for.
    public var bucketMinutes: Int

    public init(timestamp: Int, minuteOfDay: Int, amount: Double, bucketMinutes: Int) {
        self.timestamp = timestamp
        self.minuteOfDay = minuteOfDay
        self.amount = amount
        self.bucketMinutes = bucketMinutes
    }

    /// Inches per hour — the measure a person is standing in, and the only one
    /// that can be compared between a 1-minute reading and a 30-minute one.
    public var rate: Double {
        guard bucketMinutes > 0 else { return 0 }
        return amount / Double(bucketMinutes) * 60
    }

    public var isWet: Bool { amount > 0 }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
}

// MARK: - What a rate means

/// How hard it is raining, on the conventional scale.
///
/// The thresholds are the standard meteorological ones, converted from the mm/h
/// they were written in — light below 2.5 mm/h, moderate to 7.6, heavy to 50.
/// They are a textbook, and this file is otherwise suspicious of textbooks: the
/// station's own record is the better referent everywhere it exists. It doesn't
/// exist yet for rate (the sample archive is new and empty), and unlike a
/// pressure reading a rain rate DOES have a felt meaning that transfers between
/// places — an inch an hour overwhelms a gutter in Oklahoma and in Oregon alike.
/// When the sample archive has years in it, the rank belongs alongside this, not
/// instead of it.
public enum RainIntensity: Int, CaseIterable, Comparable, Sendable {
    case trace, light, moderate, heavy, violent

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Inches per hour → where it sits on the scale.
    public static func of(rate: Double) -> RainIntensity {
        switch rate {
        case ..<0.01:  return .trace
        case ..<0.10:  return .light
        case ..<0.30:  return .moderate
        case ..<2.00:  return .heavy
        default:       return .violent
        }
    }

    public var label: String {
        switch self {
        case .trace:    return "barely raining"
        case .light:    return "light rain"
        case .moderate: return "moderate rain"
        case .heavy:    return "heavy rain"
        case .violent:  return "torrential rain"
        }
    }

    /// What that rate DOES. Written to be checkable out a window — the test of
    /// this line is whether someone standing in it agrees.
    public var meaning: String {
        switch self {
        case .trace:
            return "just enough to darken the pavement. You'd walk to the car without thinking about it."
        case .light:
            return "you can stand in it. Individual drops, pavement wet through but puddles slow to form."
        case .moderate:
            return "steady enough to soak you crossing a parking lot. Puddles filling, gutters running."
        case .heavy:
            return "spray coming up off the pavement, wipers on fast — more water arriving than the ground can take."
        case .violent:
            return "you can't see far. This is the rate that fills low spots and ditches in minutes."
        }
    }

    /// The scale's own range, for a legend that lets you place the number
    /// yourself instead of trusting the word.
    public var range: String {
        switch self {
        case .trace:    return "under 0.01 in/hr"
        case .light:    return "0.01–0.1 in/hr"
        case .moderate: return "0.1–0.3 in/hr"
        case .heavy:    return "0.3–2 in/hr"
        case .violent:  return "over 2 in/hr"
        }
    }
}

// MARK: - One spell of rain

/// A continuous stretch of rain found in a day's samples.
public struct RainEvent: Identifiable, Equatable, Sendable {
    /// Minutes since local midnight. `start` is the beginning of the first wet
    /// interval, `end` the end of the last — a reading timestamped 2:31 with a
    /// one-minute bucket covers 2:30 to 2:31.
    public var startMinute: Int
    public var endMinute: Int
    /// Inches. A floor, like every total in this package.
    public var total: Double
    /// The hardest single reading in the spell.
    public var peak: RainSample
    /// Every reading inside the spell, wet and dry — the profile a chart draws.
    public var samples: [RainSample]
    /// The COARSEST bucket that fed this event. A peak drawn at 30 minutes and
    /// one drawn at 1 minute are different measurements, and this is what lets a
    /// reader (or a later comparison) tell them apart.
    public var bucketMinutes: Int
    /// Still going as of the moment it was found.
    public var isOpen: Bool

    public var id: Int { startMinute }

    public var minutes: Int { Swift.max(bucketMinutes, endMinute - startMinute) }

    /// Inches per hour averaged over the whole spell — the number that answers
    /// "was it like that the whole time", which the peak alone can't.
    public var meanRate: Double {
        guard minutes > 0 else { return 0 }
        return total / (Double(minutes) / 60)
    }

    public var peakIntensity: RainIntensity { .of(rate: peak.rate) }
    public var meanIntensity: RainIntensity { .of(rate: meanRate) }

    /// A peak averaged over a coarse bucket is a floor on the real peak, not a
    /// measurement of it. Five minutes is the line: a burst can hide inside a
    /// half-hour mean, and can't really hide inside five.
    public var peakIsDiluted: Bool { bucketMinutes > 5 }

    /// Minutes that actually saw rain, as opposed to the span the spell covers —
    /// the difference is the lulls inside it.
    public var wetMinutes: Int {
        samples.filter(\.isWet).reduce(0) { $0 + $1.bucketMinutes }
    }
}

// MARK: - A day's rain

/// Everything the station saw fall on one day.
public struct RainDay: Equatable, Sendable {
    public var day: String
    /// Spells big enough to name. Small enough stretches still count toward
    /// `total` — they're rain, they're just not a story.
    public var events: [RainEvent]
    /// Every drop the station reported, including what didn't make an event.
    public var total: Double
    /// Coarsest bucket in the day's samples.
    public var bucketMinutes: Int
    public var samplesSeen: Int
    /// What a fully-watched day (or the elapsed part of one) would have held.
    public var samplesExpected: Int

    public var didRain: Bool { total > 0 }
    /// The last spell hasn't closed — it's raining right now.
    public var isRaining: Bool { events.last?.isOpen ?? false }

    /// Enough happened to be worth a card. A day with three hundredths spread
    /// over a drizzle has nothing to explain.
    public var hasSomethingToSay: Bool { !events.isEmpty }

    public var coverage: Double {
        guard samplesExpected > 0 else { return 0 }
        return Swift.min(1, Double(samplesSeen) / Double(samplesExpected))
    }

    /// Same 80% bar the rest of the package uses. Below it the total is a sample
    /// of the day rather than a measure of it, and the card must say so.
    public var isReliable: Bool { coverage >= 0.8 }

    /// The hardest reading anywhere in the day.
    public var peak: RainSample? {
        events.map(\.peak).max { $0.rate < $1.rate }
    }

    public var wetMinutes: Int { events.reduce(0) { $0 + $1.wetMinutes } }

    public var firstMinute: Int? { events.first?.startMinute }
    public var lastMinute: Int? { events.last?.endMinute }
}

// MARK: - Finding the events

public enum RainEvents {

    /// A dry stretch this long ends a spell. Under it, rain that eases off for a
    /// few minutes and comes back is still the same rain — splitting it would
    /// report one shower as nine.
    public static let gapTolerance = 30

    /// Below this a "spell" is a sensor tick or a two-minute spit. It still
    /// counts toward the day's total; it just doesn't get named.
    public static let minimumEventTotal = 0.01

    /// Read one day's samples into the spells of rain inside it.
    ///
    /// `asOf` decides only one thing: whether the last spell is still open, and
    /// how much of the day we should have seen. Pass nil for a finished day in
    /// the archive.
    public static func find(in samples: [StationSample],
                            day: String,
                            timeZone: TimeZone,
                            gapTolerance: Int = RainEvents.gapTolerance,
                            minimumTotal: Double = RainEvents.minimumEventTotal,
                            asOf: Date? = nil) -> RainDay {
        let readings = samples
            .sorted { $0.timestamp < $1.timestamp }
            .map { sample in
                RainSample(timestamp: sample.timestamp,
                           minuteOfDay: sample.minuteOfDay(timeZone: timeZone),
                           // Prefer the near-cast-corrected series exactly as the
                           // daily rollup does, so an event's total and the day's
                           // archived total are computed off the same column.
                           amount: Swift.max(0, sample.precipCorrected ?? sample.precip ?? 0),
                           bucketMinutes: Swift.max(1, sample.bucketMinutes))
            }

        let bucket = readings.map(\.bucketMinutes).max() ?? 1
        let total = readings.reduce(0) { $0 + $1.amount }

        // How much of the day we should have seen. Today is measured against the
        // minutes ELAPSED — counting the evening as missing would report every
        // morning shower as a 60%-covered day.
        let elapsed = elapsedMinutes(day: day, timeZone: timeZone, asOf: asOf)
        let expected = bucket > 0 ? elapsed / bucket : 0

        // MARK: Group the wet readings into spells
        var runs: [[RainSample]] = []
        var current: [RainSample] = []
        for reading in readings where reading.isWet {
            if let previous = current.last {
                let apart = Double(reading.timestamp - previous.timestamp) / 60
                // Measured end-of-interval to start-of-interval, so a coarse
                // bucket isn't counted as its own gap.
                if apart - Double(reading.bucketMinutes) > Double(gapTolerance) {
                    runs.append(current)
                    current = []
                }
            }
            current.append(reading)
        }
        if !current.isEmpty { runs.append(current) }

        var events: [RainEvent] = []
        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            let runTotal = run.reduce(0) { $0 + $1.amount }
            guard runTotal >= minimumTotal else { continue }
            guard let peak = run.max(by: { $0.rate < $1.rate }) else { continue }

            let runBucket = run.map(\.bucketMinutes).max() ?? bucket
            let start = Swift.max(0, first.minuteOfDay - first.bucketMinutes)
            // Every reading between the ends, including the dry lulls — the shape
            // of a shower easing and picking back up is the thing worth drawing.
            let span = readings.filter {
                $0.timestamp >= first.timestamp && $0.timestamp <= last.timestamp
            }

            events.append(RainEvent(startMinute: start,
                                    endMinute: Swift.max(start + runBucket, last.minuteOfDay),
                                    total: runTotal,
                                    peak: peak,
                                    samples: span,
                                    bucketMinutes: runBucket,
                                    isOpen: isOpen(lastSample: last, asOf: asOf,
                                                   gapTolerance: gapTolerance)))
        }

        return RainDay(day: day,
                       events: events,
                       total: total,
                       bucketMinutes: bucket,
                       samplesSeen: readings.count,
                       samplesExpected: expected)
    }

    /// Still raining: the newest wet reading is recent enough that a spell ending
    /// wouldn't have been noticed yet. The same tolerance that joins a lull —
    /// anything else would let one number mean two things.
    private static func isOpen(lastSample: RainSample, asOf: Date?, gapTolerance: Int) -> Bool {
        guard let asOf else { return false }
        let silence = asOf.timeIntervalSince1970 - TimeInterval(lastSample.timestamp)
        return silence >= 0 && silence <= TimeInterval(gapTolerance * 60)
    }

    /// Minutes of `day` that have happened, from the station's midnight.
    static func elapsedMinutes(day: String, timeZone: TimeZone, asOf: Date?) -> Int {
        guard let start = DayKey.date(from: day, timeZone: timeZone) else { return 1_440 }
        guard let asOf else { return 1_440 }
        let elapsed = Int(asOf.timeIntervalSince(start) / 60)
        return Swift.max(0, Swift.min(1_440, elapsed))
    }

    // MARK: Clock

    /// "2:40 pm" from minutes since midnight. Local by construction: the minutes
    /// were converted in the station's zone on the way in, so nothing here can
    /// drift by re-interpreting an epoch.
    public static func clock(_ minuteOfDay: Int) -> String {
        let minutes = ((minuteOfDay % 1_440) + 1_440) % 1_440
        let hour24 = minutes / 60
        let minute = minutes % 60
        let hour = hour24 % 12 == 0 ? 12 : hour24 % 12
        let suffix = hour24 < 12 ? "am" : "pm"
        return String(format: "%d:%02d %@", hour, minute, suffix)
    }

    /// A span of minutes as something a person would say out loud.
    public static func duration(_ minutes: Int) -> String {
        switch minutes {
        case ..<1:   return "under a minute"
        case ..<60:  return "\(minutes) minutes"
        default:
            // Half-hours up to a few hours, whole hours past that — the precision
            // people actually use for a duration, said the way they'd say it.
            let hours = Double(minutes) / 60
            guard hours < 4 else { return "\(Int(hours.rounded())) hours" }
            let halves = (hours * 2).rounded() / 2
            let whole = Int(halves)
            switch halves {
            case ..<1.25:              return "an hour"
            case 1.5:                  return "an hour and a half"
            case _ where halves == Double(whole): return "\(whole) hours"
            default:                   return "\(whole) and a half hours"
            }
        }
    }

    /// How long an inch would take at this rate — a rate re-expressed as a
    /// duration, which is the form the number becomes feelable in. Nil below a
    /// drizzle, where the honest answer is "days" and says nothing.
    public static func timeForAnInch(atRate rate: Double) -> String? {
        guard rate >= 0.02 else { return nil }
        return duration(Int((60 / rate).rounded()))
    }
}

// MARK: - Saying it

extension RainEvent {

    /// One spell in a sentence: how much, how long, and when.
    public var sentence: String {
        let when = startMinute == endMinute
            ? RainEvents.clock(startMinute)
            : "\(RainEvents.clock(startMinute))–\(RainEvents.clock(endMinute))"
        if isOpen {
            return "\(WeatherAlmanac.inches(total)) since \(RainEvents.clock(startMinute)), still falling."
        }
        return "\(WeatherAlmanac.inches(total)) over \(RainEvents.duration(minutes)), \(when)."
    }

    /// What the hardest part of it was like — the line that answers "heavy
    /// compared to what".
    public var peakSentence: String {
        let rate = String(format: "%.2f", peak.rate)
        var text = "Hardest at \(RainEvents.clock(peak.minuteOfDay)): \(rate) in/hr — "
            + "\(peakIntensity.label), \(peakIntensity.meaning)"
        if let inch = RainEvents.timeForAnInch(atRate: peak.rate) {
            text += " At that rate an inch takes \(inch)."
        }
        if peakIsDiluted {
            text += " Read from \(bucketMinutes)-minute readings, so the true peak minute was harder than this."
        }
        return text
    }
}

extension RainDay {

    /// The card's opening line. Two moments, one sentence — raining now, or
    /// what fell today.
    public var headline: String {
        guard let last = events.last else {
            return didRain ? "A trace of rain today — not enough to measure."
                           : "No rain today."
        }
        if isRaining {
            let intensity = RainIntensity.of(rate: last.samples.last?.rate ?? last.meanRate)
            return "Raining now — \(intensity.label). \(WeatherAlmanac.inches(total)) so far today."
        }
        let spells = events.count == 1 ? "one spell" : "\(events.count) spells"
        return "\(WeatherAlmanac.inches(total)) of rain today, in \(spells) "
             + "totalling \(RainEvents.duration(wetMinutes)) of actual rain."
    }

    /// What it's doing this minute, said in terms of what that rate does. Nil
    /// when it isn't raining — the meaning of a rate you aren't standing in is
    /// the event's peak, not the last reading.
    public var nowSentence: String? {
        guard isRaining, let reading = events.last?.samples.last(where: \.isWet) else { return nil }
        let intensity = RainIntensity.of(rate: reading.rate)
        var text = String(format: "%.2f in/hr — ", reading.rate) + intensity.meaning
        if let inch = RainEvents.timeForAnInch(atRate: reading.rate) {
            text += " At this rate an inch would take \(inch)."
        }
        return text
    }

    /// Said when the station only watched part of the day. Rain is the measure
    /// least forgiving of a gap: the interval it missed may be the interval it
    /// poured, and nothing recovers it.
    public var coverageNote: String? {
        guard samplesExpected > 0, !isReliable else { return nil }
        return "The station reported \(Int((coverage * 100).rounded()))% of this day. "
             + "Everything here is a floor — an hour it missed may be the hour it rained hardest."
    }
}

// MARK: - Against the record

/// Where one day's rain sits among the days this station has actually seen.
public struct RainDayRank: Equatable, Sendable {
    public var total: Double
    /// Days on record that saw MORE than this.
    public var wetterDays: Int
    /// Days that saw any rain at all — the pool worth ranking against, since
    /// ranking a shower against three hundred dry days says only that it rained.
    public var rainyDays: Int
    public var daysOnRecord: Int
    public var wettest: WeatherExtreme?

    /// Share of rainy days this one beat.
    public var percentile: Double {
        guard rainyDays > 1 else { return 0 }
        return Double(rainyDays - wetterDays - 1) / Double(rainyDays - 1)
    }

    /// The rank in words, stated against the record actually held — never as a
    /// bare superlative, for the reason `DayInstanceCard` already gives: "the
    /// wettest day ever" off four years is a true sentence doing a much bigger
    /// one's work.
    public var sentence: String {
        let amount = WeatherAlmanac.inches(total)
        if wetterDays == 0 {
            return "\(amount) is the most this station has recorded in a day, over \(daysOnRecord.formatted()) days of record."
        }
        if wetterDays < 5 {
            return "\(amount) — wetter than all but \(wetterDays) of the \(rainyDays) rainy days on record here."
        }
        let pct = Int((percentile * 100).rounded())
        if pct >= 50 {
            return "\(amount) — a wetter day than \(pct)% of the \(rainyDays) rainy days this station has seen."
        }
        return "\(amount) — an ordinary rainy day here; \(100 - pct)% of the \(rainyDays) on record brought more."
    }
}

extension Climatology {

    /// Rank a day's rain against the station's own record.
    ///
    /// Nil under half a year: a "wettest day" drawn from a couple of months is a
    /// sentence with nothing behind it, the same floor `pressureBand` insists on.
    public func rainDayRank(_ total: Double,
                            excludingDay day: String? = nil,
                            minimumDays: Int = 180) -> RainDayRank? {
        guard total > 0 else { return nil }
        let pool = reliable.filter { $0.day != day }
        guard pool.count >= minimumDays else { return nil }

        let rainy = pool.compactMap(\.precipTotal).filter { $0 > 0 }
        guard rainy.count >= 20 else { return nil }

        var wettest: WeatherExtreme?
        for record in pool {
            if let value = record.precipTotal, value > (wettest?.value ?? 0) {
                wettest = WeatherExtreme(day: record.day, value: value)
            }
        }

        return RainDayRank(total: total,
                           wetterDays: rainy.filter { $0 > total }.count,
                           rainyDays: rainy.count + 1,
                           daysOnRecord: pool.count,
                           wettest: wettest)
    }
}
