//
//  DiurnalClimate.swift  (WeatherKit)
//
//  THE OTHER CYCLE. `YearRhythm` answers when things happen across a year; this
//  answers when they happen across a DAY, and how that shape changes month to
//  month.
//
//  Nothing in the app could say any of it until now, and the reason is worth
//  keeping: `DailyRecord` stores a day as its min, max and means, so "the
//  afternoon peaks at a quarter to four in July and two in January" is a
//  question the daily archive cannot express — a high of 96° says nothing about
//  WHEN. `DayWindows` got at the shape inside a day but only for the last month,
//  because it reads the live API. `SampleArchive` is what makes this possible:
//  every minute of every archived day, on disk, going back to the start of the
//  record.
//
//  IT FOLDS IN THE WIND'S PASS, NOT ITS OWN. The expensive part of any of this
//  is decoding roughly two million samples out of gzipped NDJSON — sixteen
//  seconds, measured, and the archive only grows. A separate diurnal cache would
//  pay that a second time for numbers drawn from the very same samples, which is
//  the mistake `WindClimate`'s header already named: "reading it twelve times to
//  slice it twelve ways would cost twelve times the disk." So the accumulator in
//  `SampleClimateCache` carries both, and the day is read once.
//
//  A SLOT IS FIFTEEN MINUTES. Fine enough that the seasonal swing in the peak —
//  an hour and a half at most stations — is several slots wide and reads as a
//  curve rather than as a step. Coarse enough that a slot in a given month holds
//  something like two thousand readings, so a quiet month is still a mean and
//  not an anecdote. Claiming the minute would be false precision: the peak of a
//  smoothed daily curve is flat near its top, and "3:45" states a resolution the
//  underlying shape does not have.
//
//  A SAMPLE COARSER THAN A SLOT IS DROPPED rather than smeared across the slots
//  it spans. A reading that stands for half an hour genuinely cannot say what a
//  quarter past three was like, and averaging it into one slot would put half an
//  hour of weight on a moment it only partly saw. In practice nothing is lost:
//  `SampleSync` fetches at `bucket=1` precisely because a reduction taken at
//  ingest can't be undone, and the UDP collector reports every minute.
//

import Foundation

/// Which reading a diurnal chart is drawn from.
///
/// These three and not others, because these are the three whose DAILY SHAPE is
/// the interesting thing. A daily high tells you about the afternoon; that the
/// dew point collapses at nine in the evening, or that the wind lies down at
/// dusk and gets up again at ten, is a fact with no home in a daily rollup at
/// all.
public enum DiurnalMeasure: String, CaseIterable, Codable, Sendable, Identifiable {
    case temperature, dewPoint, wind

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .temperature: return "Temperature"
        case .dewPoint: return "Dew point"
        case .wind: return "Wind"
        }
    }

    /// What one unit of this measure is called, for anything spelling a value out.
    public var unit: String {
        switch self {
        case .temperature, .dewPoint: return "°"
        case .wind: return " mph"
        }
    }

    /// Whether the interesting extreme is the high one. Temperature and dew
    /// point are read from their peaks; so is wind. All three, as it happens —
    /// but the question is asked rather than assumed, because the day's COLDEST
    /// moment is a headline fact and its calmest is not.
    public var readsFromPeak: Bool { true }
}

/// One day's shape for one measure, as a mean per slot.
///
/// `nil` where nothing was ever recorded in that slot — a station that came
/// online at noon has no 3am, and a zero there would draw as a cold snap.
public struct DiurnalProfile: Codable, Sendable, Equatable {
    public var temperature: [Double?]
    public var dewPoint: [Double?]
    public var wind: [Double?]
    /// Reading-minutes behind this profile, across every slot. The honesty
    /// check: a profile folded from four days is a shape, not a climate.
    public var minutes: Int

    public init(temperature: [Double?] = [], dewPoint: [Double?] = [],
                wind: [Double?] = [], minutes: Int = 0) {
        self.temperature = temperature
        self.dewPoint = dewPoint
        self.wind = wind
        self.minutes = minutes
    }

    public func values(_ measure: DiurnalMeasure) -> [Double?] {
        switch measure {
        case .temperature: return temperature
        case .dewPoint: return dewPoint
        case .wind: return wind
        }
    }

    /// The slot this measure peaks in, and the slot it bottoms out in.
    ///
    /// Both, always, because the pair IS the answer for temperature: the day's
    /// low is not midnight, it is the minute before the sun comes up, and that
    /// is the single most surprising thing this chart has to say.
    ///
    /// NOT THE ARGMAX. A mean daily curve is nearly flat across its top, and
    /// picking the single highest slot off it reads noise as a finding. Measured
    /// on this station's own July: 91.6° at 4:45pm, 91.4° at 6pm, 91.8° at
    /// 6:30pm — two tenths of a degree deciding a date, and the argmax duly
    /// reported a July peak an hour and three quarters later than August's, from
    /// four years of averaged minutes that cannot support the distinction.
    ///
    /// So the curve is SMOOTHED first, over a window wide enough to swallow the
    /// wobble and far narrower than the feature being located. A threshold alone
    /// was tried and is the wrong instrument: on this July a 0.4° dip at 6pm
    /// split the plateau in two, and the half holding the nominal maximum was
    /// the later one — so the reported peak moved by an hour and a half on the
    /// strength of a dip well inside the noise. Smoothing removes the dip
    /// instead of arguing with it.
    ///
    /// The window WRAPS at midnight, because a day is a cycle: the readings
    /// either side of 11:45pm are 11:30pm and 12:00am, and treating the array's
    /// ends as the ends of anything would corrupt exactly the hours the
    /// overnight trough sits nearest.
    public func extremes(_ measure: DiurnalMeasure) -> (peak: Int, trough: Int)? {
        let series = Self.smoothed(values(measure), window: Self.smoothingSlots)
        let known = series.enumerated().compactMap { index, value in value.map { (index, $0) } }
        guard let high = known.max(by: { $0.1 < $1.1 }),
              let low = known.min(by: { $0.1 < $1.1 }) else { return nil }
        return (high.0, low.0)
    }

    /// Slots in the smoothing window — five, so an hour and a quarter centred on
    /// each slot. An order of magnitude under the seasonal swing the chart is
    /// drawn to show, and an order of magnitude over the quarter-hour wobble it
    /// is there to remove.
    static let smoothingSlots = 5

    /// A centred mean over a cyclic series. `nil` where too little of the window
    /// is known to stand for it — half, the same bar the rest of this codebase
    /// sets before it will call a partial window an answer.
    static func smoothed(_ series: [Double?], window: Int) -> [Double?] {
        guard series.count > window, window > 1 else { return series }
        let radius = window / 2
        return series.indices.map { index in
            var sum = 0.0
            var count = 0
            for offset in -radius...radius {
                let wrapped = ((index + offset) % series.count + series.count) % series.count
                if let value = series[wrapped] { sum += value; count += 1 }
            }
            guard count * 2 >= window else { return nil }
            return sum / Double(count)
        }
    }

    /// How far this measure travels between its low and its high across a day.
    ///
    /// The number a daily high and low already give you — and the point of
    /// having it here is that it can be asked per MONTH, where it is genuinely
    /// surprising: a humid August swings far less than a dry October.
    public func swing(_ measure: DiurnalMeasure) -> Double? {
        let series = values(measure).compactMap { $0 }
        guard let low = series.min(), let high = series.max() else { return nil }
        return high - low
    }

    public var isMeaningful: Bool { minutes >= 60 * 24 * 10 }
}

/// The shape of a day at this station, over the record and around the year.
public struct DiurnalClimate: Codable, Sendable, Equatable {
    /// Every archived minute, in one profile.
    public var overall: DiurnalProfile
    /// Keyed 1…12. A month with no archived days is absent rather than flat —
    /// same rule `WindClimate.byMonth` keeps, for the same reason.
    public var byMonth: [Int: DiurnalProfile]
    public var days: Int
    public var firstDay: String?
    public var lastDay: String?

    /// Slots in a day. 96 × 15 minutes.
    public static let slotCount = 96
    public static var slotMinutes: Int { 24 * 60 / slotCount }

    /// Minutes since local midnight at the START of a slot.
    public static func minuteOfDay(ofSlot slot: Int) -> Int { slot * slotMinutes }

    /// The slot a minute-of-day falls in.
    public static func slot(ofMinute minute: Int) -> Int {
        min(slotCount - 1, max(0, minute / slotMinutes))
    }

    public var isMeaningful: Bool { overall.isMeaningful }

    /// How much later in the day the peak lands in high summer than in deep
    /// winter, in slots — the seasonal thermal lag, which is the one thing the
    /// matrix is really drawing.
    ///
    /// Taken between the months whose peaks are furthest apart rather than
    /// between July and January by name, because a station's calendar is its
    /// own and the extremes are what the record actually shows.
    public func peakSpread(_ measure: DiurnalMeasure) -> (earliest: (month: Int, slot: Int),
                                                          latest: (month: Int, slot: Int))? {
        let peaks = byMonth.compactMap { month, profile -> (month: Int, slot: Int)? in
            guard profile.isMeaningful, let extremes = profile.extremes(measure) else { return nil }
            return (month, extremes.peak)
        }
        guard peaks.count >= 2,
              let earliest = peaks.min(by: { $0.slot < $1.slot }),
              let latest = peaks.max(by: { $0.slot < $1.slot }) else { return nil }
        return (earliest, latest)
    }

    /// The ends of the colour ramp, taken across every month at once.
    ///
    /// One ramp for the whole matrix, never one per row. A per-row ramp would
    /// make every month's afternoon the same shade of hot and destroy the only
    /// comparison the chart exists to support.
    public func range(_ measure: DiurnalMeasure) -> (low: Double, high: Double)? {
        let values = byMonth.values.flatMap { $0.values(measure).compactMap { $0 } }
        guard let low = values.min(), let high = values.max(), high > low else { return nil }
        return (low, high)
    }
}

// MARK: - The mergeable state

/// Un-normalised sums, one set per slot. These ADD, which is what lets a warm
/// cache fold one new day in at the cost of one day.
///
/// Counts are in READING-MINUTES rather than in samples, so a series taken at
/// one resolution and a series taken at another can share a mean without the
/// finer one quietly outvoting the coarser. Every sample coarser than a slot is
/// refused at the door, so in practice the weight is always 1 — but the arithmetic
/// has to be right for the day it isn't.
public struct DiurnalSlotSums: Codable, Sendable, Equatable {
    public var temperature: Double = 0
    public var temperatureMinutes: Int = 0
    public var dewPoint: Double = 0
    public var dewPointMinutes: Int = 0
    public var wind: Double = 0
    public var windMinutes: Int = 0

    public init() {}

    mutating func add(temperature value: Double, minutes: Int) {
        temperature += value * Double(minutes)
        temperatureMinutes += minutes
    }
    mutating func add(dewPoint value: Double, minutes: Int) {
        dewPoint += value * Double(minutes)
        dewPointMinutes += minutes
    }
    mutating func add(wind value: Double, minutes: Int) {
        wind += value * Double(minutes)
        windMinutes += minutes
    }

    mutating func merge(_ other: DiurnalSlotSums) {
        temperature += other.temperature; temperatureMinutes += other.temperatureMinutes
        dewPoint += other.dewPoint; dewPointMinutes += other.dewPointMinutes
        wind += other.wind; windMinutes += other.windMinutes
    }
}

/// The accumulator behind one `DiurnalProfile`.
public struct DiurnalBuilder: Codable, Sendable, Equatable {
    public var slots: [DiurnalSlotSums]

    public init() {
        slots = Array(repeating: DiurnalSlotSums(), count: DiurnalClimate.slotCount)
    }

    /// Fold one reading in, already placed on the local clock.
    mutating func add(slot: Int, minutes: Int, temperature: Double?,
                      dewPoint: Double?, wind: Double?) {
        guard slots.indices.contains(slot) else { return }
        if let temperature { slots[slot].add(temperature: temperature, minutes: minutes) }
        if let dewPoint { slots[slot].add(dewPoint: dewPoint, minutes: minutes) }
        if let wind { slots[slot].add(wind: wind, minutes: minutes) }
    }

    public mutating func merge(_ other: DiurnalBuilder) {
        for index in slots.indices where other.slots.indices.contains(index) {
            slots[index].merge(other.slots[index])
        }
    }

    public func build() -> DiurnalProfile {
        func mean(_ sum: KeyPath<DiurnalSlotSums, Double>,
                  _ weight: KeyPath<DiurnalSlotSums, Int>) -> [Double?] {
            slots.map { slot in
                let minutes = slot[keyPath: weight]
                return minutes > 0 ? slot[keyPath: sum] / Double(minutes) : nil
            }
        }
        return DiurnalProfile(temperature: mean(\.temperature, \.temperatureMinutes),
                              dewPoint: mean(\.dewPoint, \.dewPointMinutes),
                              wind: mean(\.wind, \.windMinutes),
                              minutes: slots.reduce(0) { $0 + $1.temperatureMinutes })
    }
}

/// Every month's builder plus the overall one — the shape the cache stores.
public struct DiurnalAccumulator: Codable, Sendable, Equatable {
    public var overall: DiurnalBuilder
    /// Keyed "01"…"12" for the same reason `WindClimateAccumulator.months` is:
    /// Swift encodes an integer-keyed dictionary as a flat array of alternating
    /// keys and values, which is legible to a decoder and to nobody else.
    public var months: [String: DiurnalBuilder]

    public init() {
        overall = DiurnalBuilder()
        months = [:]
    }

    /// Fold one archived day.
    ///
    /// `timeZone` is the wall clock the slots are read against, and it is the
    /// whole reason a diurnal fold is not just an arithmetic detail: minute of
    /// day is meaningless without one. Taken per sample via `secondsFromGMT`
    /// rather than as an offset from the day's midnight, so the two DST days a
    /// year land on the clock the station was actually keeping instead of an
    /// hour beside it.
    public mutating func fold(day: String, samples: [StationSample], timeZone: TimeZone) {
        guard let monthKey = SampleClimateAccumulator.monthKey(ofDay: day) else { return }
        var month = months[monthKey] ?? DiurnalBuilder()

        for sample in samples {
            // See the file header: a reading standing for longer than a slot
            // cannot say what a quarter of an hour was like.
            guard sample.bucketMinutes <= DiurnalClimate.slotMinutes else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(sample.timestamp))
            let local = sample.timestamp + timeZone.secondsFromGMT(for: date)
            let minuteOfDay = Int((local % 86_400 + 86_400) % 86_400) / 60
            let slot = DiurnalClimate.slot(ofMinute: minuteOfDay)

            let dew = sample.airTemp.flatMap { temp in
                sample.humidity.map { WeatherInterpreter.dewPointF(tempF: temp, humidity: $0) }
            }
            overall.add(slot: slot, minutes: sample.bucketMinutes, temperature: sample.airTemp,
                        dewPoint: dew, wind: sample.windAvg)
            month.add(slot: slot, minutes: sample.bucketMinutes, temperature: sample.airTemp,
                      dewPoint: dew, wind: sample.windAvg)
        }
        months[monthKey] = month
    }

    public func climate(days: [String]) -> DiurnalClimate {
        var byMonth: [Int: DiurnalProfile] = [:]
        for (key, builder) in months {
            guard let month = Int(key) else { continue }
            byMonth[month] = builder.build()
        }
        let sorted = days.sorted()
        return DiurnalClimate(overall: overall.build(), byMonth: byMonth,
                              days: sorted.count, firstDay: sorted.first, lastDay: sorted.last)
    }
}
