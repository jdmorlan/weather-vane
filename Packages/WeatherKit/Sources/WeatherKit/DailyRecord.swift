//
//  DailyRecord.swift  (WeatherKit)
//
//  One archived day at this station. This is the unit every historical feature
//  reads — "this day in past years", season transitions, percentile framing,
//  frost dates, days-since-rain. Raw observations get rolled up to this once and
//  then never re-fetched.
//
//  Two design points that matter more than the field list:
//
//  1. EVERY MEASURE IS OPTIONAL, and `coverage` says how much of the day we
//     actually saw. A station with a dead afternoon must not report that
//     afternoon's missing heat as a cool day. "No data" and "zero" are different
//     answers and the type refuses to conflate them.
//  2. DAYS ARE LOCAL. Bucketing by UTC would smear each day across two of yours
//     and quietly corrupt every daily min/max. The station's own timezone decides
//     where a day starts.
//

import Foundation

/// A rolled-up calendar day at the station.
public struct DailyRecord: Codable, Equatable, Sendable, Identifiable {
    /// Local calendar day, `yyyy-MM-dd`. Also the merge key and the sort order.
    public var day: String
    public var id: String { day }

    /// How many observations backed this day, and how many a complete day would
    /// have had at the bucket size we fetched.
    public var sampleCount: Int
    public var expectedSamples: Int

    public var tempMin: Double?
    public var tempMax: Double?
    public var tempMean: Double?

    /// Derived per-observation via Magnus-Tetens from temp + humidity, then rolled
    /// up — the same function the forecast side uses, so history and forecast
    /// speak the same comfort language.
    public var dewPointMin: Double?
    public var dewPointMax: Double?
    public var dewPointMean: Double?
    public var humidityMean: Double?

    public var pressureMin: Double?
    public var pressureMax: Double?
    public var pressureMean: Double?

    public var windAvgMean: Double?
    public var windGustMax: Double?

    public var precipTotal: Double?
    public var strikeCount: Int?
    public var uvMax: Double?
    public var solarMax: Double?

    // MARK: Time-in-band counters
    //
    // Hours the temperature spent inside a band, counted from the individual
    // samples at rollup. These CANNOT be recovered from a daily min/max later:
    // a day that ran 40° for fourteen hours and a day that dipped through 40°
    // twice have the same min and max and very different chill. Counting them
    // while the samples are in hand is the only honest way to get them, which is
    // why they're stored rather than derived.

    /// Hours in 32–45°F — the "chill hours" a fruit tree's dormancy requirement
    /// is quoted in (Weinberger). Below freezing doesn't count toward it.
    public var chillHours: Double?
    /// Utah-model chill units: the same idea, but warm afternoons subtract. More
    /// faithful where winter is interrupted by warm spells.
    public var chillUnitsUtah: Double?
    /// How long the freeze actually lasted — a 31° low at dawn and a night that
    /// sat at 28° for nine hours kill very different things.
    public var hoursBelow32: Double?
    public var hoursBelow28: Double?

    /// Which rollup produced this day. Days written before the counters existed
    /// carry no version, and the archive uses that to find what to re-fill.
    public var schemaVersion: Int?

    /// Bump when a rollup starts producing a field older days won't have — or,
    /// as at v3, when it starts producing a DIFFERENT value for a field it
    /// already had. A day filed under the old boundary is not missing anything;
    /// it is wrong, and the stale-day refill is the machinery that corrects it.
    public static let currentSchemaVersion = 3

    public init(day: String, sampleCount: Int = 0, expectedSamples: Int = 0) {
        self.day = day
        self.sampleCount = sampleCount
        self.expectedSamples = expectedSamples
    }

    /// Version this record was written at; absent means the original rollup.
    public var version: Int { schemaVersion ?? 1 }

    /// Predates the current rollup, so it's missing fields a re-fetch would add.
    public var isStale: Bool { version < DailyRecord.currentSchemaVersion }

    /// 0…1 fraction of the day we have observations for.
    public var coverage: Double {
        guard expectedSamples > 0 else { return 0 }
        return min(1, Double(sampleCount) / Double(expectedSamples))
    }

    /// Whether this day is solid enough to quote in a record, percentile, or
    /// average. A day we only half-saw can still be shown — clearly marked — but
    /// it must never set a "hottest ever" or move a climatology.
    public var isReliable: Bool { coverage >= 0.8 }
}

// MARK: - Day keys

public enum DayKey {
    /// Fixed-format, timezone-explicit. `.current` locale would break under a
    /// non-Gregorian calendar preference, so the formatter pins POSIX.
    public static func formatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    public static func string(for date: Date, timeZone: TimeZone) -> String {
        formatter(timeZone: timeZone).string(from: date)
    }

    public static func date(from key: String, timeZone: TimeZone) -> Date? {
        formatter(timeZone: timeZone).date(from: key)
    }

    /// Year component of a `yyyy-MM-dd` key, for per-year file sharding.
    public static func year(of key: String) -> Int? {
        Int(key.prefix(4))
    }

    /// `(month, day)` — the anniversary axis "this day in past years" pivots on.
    public static func monthDay(of key: String) -> String {
        String(key.dropFirst(5))
    }

    // MARK: Key arithmetic
    //
    // Stepping between day keys is done in a FIXED zone, because it's arithmetic
    // on labels rather than on moments — the day after "2024-03-10" is
    // "2024-03-11" regardless of the reader's clock or a DST change in between.
    // Doing it in `.current` would let a spring-forward turn a step into a
    // no-op and silently stall every streak walk that uses it.

    static let keyZone = TimeZone(identifier: "UTC") ?? .current

    /// Built ONCE and shared. Constructing a DateFormatter costs on the order of
    /// a millisecond, and these helpers run in the innermost loop of every
    /// smoothing pass and streak walk — allocating per call put whole seconds on
    /// a single season-timeline build. Both types are documented as safe to read
    /// concurrently, and nothing here ever mutates them.
    static let keyFormatter: DateFormatter = formatter(timeZone: keyZone)

    static let keyCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = keyZone
        return calendar
    }()

    public static func step(_ key: String, by days: Int) -> String? {
        guard let date = keyFormatter.date(from: key),
              let moved = keyCalendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return keyFormatter.string(from: moved)
    }

    public static func next(_ key: String) -> String? { step(key, by: 1) }
    public static func previous(_ key: String) -> String? { step(key, by: -1) }

    /// Calendar days from one key to another; negative if `end` precedes `start`.
    public static func distance(from start: String, to end: String) -> Int? {
        guard let from = keyFormatter.date(from: start),
              let to = keyFormatter.date(from: end) else { return nil }
        return keyCalendar.dateComponents([.day], from: from, to: to).day
    }

    /// Contiguous runs of day keys — what turns a scattered list of days into
    /// fetchable windows.
    public static func runs(of keys: [String]) -> [(first: String, last: String)] {
        let sorted = keys.sorted()
        guard var first = sorted.first else { return [] }
        var last = first
        var runs: [(String, String)] = []

        for key in sorted.dropFirst() {
            if next(last) == key { last = key; continue }
            runs.append((first, last))
            first = key
            last = key
        }
        runs.append((first, last))
        return runs
    }
}

// MARK: - Rolling observations up into days

public enum DailyRollup {

    /// Group raw observations into local-day records.
    ///
    /// `bucketMinutes` is the sampling interval we requested; it sets how many
    /// samples a complete day should contain, which is what makes `coverage`
    /// meaningful rather than a guess.
    public static func records(from observations: StationObservations,
                               bucketMinutes: Int,
                               timeZone: TimeZone? = nil) -> [DailyRecord] {
        guard !observations.obs.isEmpty else { return [] }

        let zone = timeZone
            ?? observations.timezone.flatMap(TimeZone.init(identifier:))
            ?? .current
        let map = ObservationFieldMap(fields: observations.obFields)
        let formatter = DayKey.formatter(timeZone: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        /// Not every local day is 24 hours. On the DST transitions a day is 23 or
        /// 25 hours long, so a flat 1440/bucket would report the spring day as
        /// permanently incomplete and let the fall day exceed 100% coverage.
        func expectedSamples(forDay key: String) -> Int {
            guard bucketMinutes > 0 else { return 0 }
            guard let dayStart = DayKey.date(from: key, timeZone: zone),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                return max(1, (24 * 60) / bucketMinutes)
            }
            let minutes = Int(nextDay.timeIntervalSince(dayStart) / 60)
            return max(1, minutes / bucketMinutes)
        }

        // Accumulate per day, then reduce once at the end.
        //
        // A BUCKET IS STAMPED AT ITS END, so the row timestamped local midnight
        // covers the half hour BEFORE it and belongs to the day that just ended.
        // Filing it by its own timestamp handed every day the last bucket of the
        // day before — which for precipitation is not a rounding error but
        // invented rain, since that column is an accumulation rather than a
        // reading. Probed against 2025-07-12/13 at station 68737:
        //
        //   day        │ 1-min sum │ 30-min sum │ shifted │ station's own day total
        //   ───────────┼───────────┼────────────┼─────────┼────────────────────────
        //   2025-07-12 │   1.188   │   0.290    │  1.188  │  1.188
        //   2025-07-13 │   1.563   │   2.462    │  1.563  │  1.563
        //
        // The 12th was robbed of 0.9″ and the 13th inflated by it. One second
        // back is the whole fix: it lands every row inside the interval it
        // actually measured, at any bucket, and the shifted totals then agree
        // with both the minute-resolution record and the station's own running
        // `local_day_precip_accumulation`. Every other measure was off by one
        // bucket the same way; rain is only where it was loud enough to catch.
        var buckets: [String: [[Double?]]] = [:]
        for row in observations.obs {
            guard let ts = map.value(ObservationField.timestamp, in: row) else { continue }
            let key = formatter.string(from: Date(timeIntervalSince1970: ts - 1))
            buckets[key, default: []].append(row)
        }

        return buckets.keys.sorted().map { key in
            rollup(day: key, rows: buckets[key] ?? [], map: map,
                   expectedSamples: expectedSamples(forDay: key),
                   bucketMinutes: bucketMinutes)
        }
    }

    static func rollup(day: String, rows: [[Double?]],
                       map: ObservationFieldMap, expectedSamples: Int,
                       bucketMinutes: Int = ArchiveSync.bucketMinutes) -> DailyRecord {
        var record = DailyRecord(day: day, sampleCount: rows.count, expectedSamples: expectedSamples)
        record.schemaVersion = DailyRecord.currentSchemaVersion

        func column(_ field: String) -> [Double] {
            rows.compactMap { map.value(field, in: $0) }
        }

        let temps = column(ObservationField.airTemp)
        record.tempMin = temps.min()
        record.tempMax = temps.max()
        record.tempMean = temps.mean

        let humidity = column(ObservationField.humidity)
        record.humidityMean = humidity.mean

        // Dew point has to be computed per observation and then rolled up — taking
        // it from the daily mean temp and mean humidity would be a different (and
        // wrong) number, since the relationship isn't linear.
        let dewPoints = rows.compactMap { row -> Double? in
            guard let t = map.value(ObservationField.airTemp, in: row),
                  let rh = map.value(ObservationField.humidity, in: row) else { return nil }
            return WeatherInterpreter.dewPointF(tempF: t, humidity: rh)
        }
        record.dewPointMin = dewPoints.min()
        record.dewPointMax = dewPoints.max()
        record.dewPointMean = dewPoints.mean

        let pressures = column(ObservationField.seaLevelPressure)
        record.pressureMin = pressures.min()
        record.pressureMax = pressures.max()
        record.pressureMean = pressures.mean

        record.windAvgMean = column(ObservationField.windAvg).mean
        record.windGustMax = column(ObservationField.windGust).max()

        // Prefer the corrected precip series; fall back only if it's absent.
        let corrected = column(ObservationField.precipCorrected)
        let raw = column(ObservationField.precip)
        let precip = corrected.isEmpty ? raw : corrected
        record.precipTotal = precip.isEmpty ? nil : precip.reduce(0, +)

        let strikes = column(ObservationField.strikeCount)
        record.strikeCount = strikes.isEmpty ? nil : Int(strikes.reduce(0, +))
        record.uvMax = column(ObservationField.uv).max()
        record.solarMax = column(ObservationField.solarRadiation).max()

        // Each sample stands for its bucket's worth of time. At 30-minute
        // sampling that's a half hour per reading — fine enough that a band
        // crossing costs at most a half hour of error either way.
        if !temps.isEmpty, bucketMinutes > 0 {
            let hoursPerSample = Double(bucketMinutes) / 60
            func hours(_ inBand: (Double) -> Bool) -> Double {
                Double(temps.filter(inBand).count) * hoursPerSample
            }
            record.chillHours = hours { $0 >= 32 && $0 <= 45 }
            record.hoursBelow32 = hours { $0 < 32 }
            record.hoursBelow28 = hours { $0 < 28 }
            record.chillUnitsUtah = temps.reduce(0) { $0 + ChillModel.utahUnit(forF: $1) } * hoursPerSample
        }

        return record
    }
}

extension Array where Element == Double {
    /// Nil rather than 0 for an empty series — the whole point of the optional
    /// fields above is that "we didn't measure" can't masquerade as a value.
    var mean: Double? {
        isEmpty ? nil : reduce(0, +) / Double(count)
    }
}
