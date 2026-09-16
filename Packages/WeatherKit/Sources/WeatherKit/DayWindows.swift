//
//  DayWindows.swift  (WeatherKit)
//
//  Comparing the SAME STRETCH OF CLOCK across several recent days.
//
//  The archive can't answer this and never will: it stores a day as its min, max
//  and means, and "the morning felt better than the afternoon" is a question about
//  the shape INSIDE a day. A daily high can't distinguish a morning that stayed at
//  70° until ten from one that was through 80° by eight. Same wall chill hours hit
//  — some questions only exist while the individual samples are in hand.
//
//  So this reads raw observations rather than DailyRecords. That's affordable
//  because of an accident of the API: `bucket=30` caps a request at 30 days, so
//  ONE request holds every half-hourly reading of the last month. Ten mornings and
//  two mornings cost exactly the same fetch.
//
//  The window is a parameter, not "morning". Nothing here knows 6am is special —
//  the same engine answers the afternoon question by being asked a different
//  range.
//

import Foundation

/// One observation, positioned by clock time rather than by date, so samples from
/// different days can be laid over each other on one axis.
public struct WindowSample: Equatable, Sendable {
    /// Minutes since local midnight. The x-coordinate.
    public var minuteOfDay: Int
    public var temp: Double?
    /// Derived from temp + humidity — the station doesn't report it, and it's the
    /// measure that usually explains a felt difference the temperature doesn't.
    public var dewPoint: Double?
    public var windAvg: Double?
    public var solarRadiation: Double?

    public init(minuteOfDay: Int, temp: Double? = nil, dewPoint: Double? = nil,
                windAvg: Double? = nil, solarRadiation: Double? = nil) {
        self.minuteOfDay = minuteOfDay
        self.temp = temp
        self.dewPoint = dewPoint
        self.windAvg = windAvg
        self.solarRadiation = solarRadiation
    }
}

/// One day's samples inside the window.
public struct DayWindow: Identifiable, Equatable, Sendable {
    public var day: String
    public var id: String { day }
    public var samples: [WindowSample]
    /// Samples we'd expect for a fully-seen window at this bucket. A morning drawn
    /// from three readings shouldn't look like a measured one.
    public var expectedSamples: Int

    public init(day: String, samples: [WindowSample], expectedSamples: Int) {
        self.day = day
        self.samples = samples
        self.expectedSamples = expectedSamples
    }

    public var coverage: Double {
        guard expectedSamples > 0 else { return 0 }
        return Swift.min(1, Double(samples.count) / Double(expectedSamples))
    }

    /// Same 80% bar the daily archive uses, for the same reason: below it the
    /// numbers are a sample of the window, not a description of it.
    public var isReliable: Bool { coverage >= 0.8 }

    public func mean(_ measure: KeyPath<WindowSample, Double?>) -> Double? {
        let values = samples.compactMap { $0[keyPath: measure] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public func min(_ measure: KeyPath<WindowSample, Double?>) -> Double? {
        samples.compactMap { $0[keyPath: measure] }.min()
    }

    public func max(_ measure: KeyPath<WindowSample, Double?>) -> Double? {
        samples.compactMap { $0[keyPath: measure] }.max()
    }
}

/// A stretch of the clock, in local hours.
public struct ClockWindow: Equatable, Sendable {
    /// Inclusive start hour, 0–23.
    public var startHour: Int
    /// Exclusive end hour, 1–24.
    public var endHour: Int

    public init(startHour: Int, endHour: Int) {
        self.startHour = startHour
        self.endHour = endHour
    }

    /// 6am until 10am: after sunrise, before the afternoon has taken over.
    public static let morning = ClockWindow(startHour: 6, endHour: 10)
    public static let afternoon = ClockWindow(startHour: 13, endHour: 17)

    public func contains(minuteOfDay: Int) -> Bool {
        minuteOfDay >= startHour * 60 && minuteOfDay < endHour * 60
    }

    public var hours: Int { Swift.max(0, endHour - startHour) }
}

public enum DayWindows {

    /// Slice raw observations into one entry per day, keeping only the samples
    /// that fall inside `window`.
    ///
    /// Bucketing is done in the STATION's timezone for the same reason the archive
    /// is: "6am" means 6am where the station stands, not where the laptop is.
    public static func slice(_ observations: StationObservations,
                             window: ClockWindow = .morning,
                             bucketMinutes: Int = ArchiveSync.bucketMinutes,
                             timeZone: TimeZone? = nil) -> [DayWindow] {
        let zone = timeZone
            ?? observations.timezone.flatMap(TimeZone.init(identifier:))
            ?? .current
        let map = ObservationFieldMap(fields: observations.obFields)
        let formatter = DayKey.formatter(timeZone: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        var byDay: [String: [WindowSample]] = [:]
        for row in observations.obs {
            guard let ts = map.value(ObservationField.timestamp, in: row) else { continue }
            let date = Date(timeIntervalSince1970: ts)
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            guard let hour = parts.hour, let minute = parts.minute else { continue }
            let minuteOfDay = hour * 60 + minute
            guard window.contains(minuteOfDay: minuteOfDay) else { continue }

            let temp = map.value(ObservationField.airTemp, in: row)
            let humidity = map.value(ObservationField.humidity, in: row)
            let dew = temp.flatMap { t in
                humidity.map { WeatherInterpreter.dewPointF(tempF: t, humidity: $0) }
            }
            byDay[formatter.string(from: date), default: []].append(
                WindowSample(minuteOfDay: minuteOfDay,
                             temp: temp,
                             dewPoint: dew,
                             windAvg: map.value(ObservationField.windAvg, in: row),
                             solarRadiation: map.value(ObservationField.solarRadiation, in: row)))
        }

        // Expected count is derived from the window and the bucket, not counted
        // from the data — the whole point is to notice when samples are MISSING.
        let expected = bucketMinutes > 0 ? (window.hours * 60) / bucketMinutes : 0
        return byDay.keys.sorted().map { day in
            DayWindow(day: day,
                      samples: byDay[day]!.sorted { $0.minuteOfDay < $1.minuteOfDay },
                      expectedSamples: expected)
        }
    }

    /// The most recent `count` days, oldest first — the tail of a slice, sized to
    /// what a reader can actually distinguish on one chart.
    public static func recent(_ windows: [DayWindow], count: Int) -> [DayWindow] {
        Array(windows.suffix(Swift.max(0, count)))
    }
}

/// Whether one day stands apart from the others in the same window, on one
/// measure.
///
/// This exists because the honest answer to "did yesterday morning actually feel
/// different" is often NO, and an eye reading ten overlapping lines will find a
/// difference whether or not one is there. Sitting a day against the spread of
/// its neighbours is the check.
public struct WindowStandout: Equatable, Sendable {
    public var day: String
    public var measure: String
    /// The subject day's mean across the window.
    public var value: Double
    /// Mean of the OTHER days' means.
    public var othersMean: Double
    /// Standard deviation of the other days' means. Zero when there's one other.
    public var othersDeviation: Double
    public var daysCompared: Int

    public init(day: String, measure: String, value: Double,
                othersMean: Double, othersDeviation: Double, daysCompared: Int) {
        self.day = day
        self.measure = measure
        self.value = value
        self.othersMean = othersMean
        self.othersDeviation = othersDeviation
        self.daysCompared = daysCompared
    }

    public var difference: Double { value - othersMean }

    /// How far out the day sits, in standard deviations. Nil when the spread is
    /// too small to divide by — with everything piled at one value, "how many
    /// sigmas" isn't a question with an answer.
    public var zScore: Double? {
        guard othersDeviation > 0.01 else { return nil }
        return difference / othersDeviation
    }

    /// One standard deviation out, with at least a handful of days to define
    /// "usual". Deliberately a low bar: this decides whether we SAY anything, and
    /// the sentence itself carries the size.
    public var isStandout: Bool {
        guard daysCompared >= 4, let z = zScore else { return false }
        return abs(z) >= 1
    }

    /// The comparison in words, INCLUDING when the answer is "it didn't stand
    /// out". That negative is the useful half here — the question was whether a
    /// remembered difference is in the numbers at all, and "no" is an answer.
    public func sentence(subject: String) -> String {
        let gap = abs(difference)
        let direction = difference < 0 ? "cooler" : "warmer"
        let size = gap < 1 ? "about the same"
                           : "\(Int(gap.rounded()))° \(direction)"

        if isStandout {
            return "\(subject) ran \(size) than the other \(daysCompared) on \(measure) — "
                 + "clearly apart from them, not a near thing."
        }
        if gap < 1 {
            return "\(subject) was \(size) as the other \(daysCompared) on \(measure)."
        }
        return "\(subject) ran \(size) than the other \(daysCompared) on \(measure) — "
             + "inside their usual spread, not apart from them."
    }
}

public extension DayWindows {

    /// Compare one day's window mean against the other days in the set.
    static func standout(_ windows: [DayWindow],
                         day: String,
                         measure: KeyPath<WindowSample, Double?>,
                         measureName: String) -> WindowStandout? {
        // Thin windows can't set the baseline OR be the subject — a morning seen
        // three times has a mean of whichever three half-hours were recorded.
        let usable = windows.filter { $0.isReliable }
        guard let subject = usable.first(where: { $0.day == day }),
              let value = subject.mean(measure) else { return nil }

        let others = usable.filter { $0.day != day }.compactMap { $0.mean(measure) }
        guard others.count >= 2 else { return nil }

        let mean = others.reduce(0, +) / Double(others.count)
        let variance = others.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(others.count)
        return WindowStandout(day: day, measure: measureName, value: value,
                              othersMean: mean, othersDeviation: variance.squareRoot(),
                              daysCompared: others.count)
    }
}
