//
//  RainLog.swift  (WeatherKit)
//
//  WHAT YOUR OWN RAIN GAUGE CAUGHT — the referee the station never had.
//
//  A Tempest finds rain by feeling drops hit its top. Light, steady rain often
//  doesn't hit hard enough, and a station saving battery stops listening for it
//  altogether; on Oct 2, 2026 it recorded nothing through an afternoon of rain.
//  WeatherFlow's correction field never differs from the gauge in this archive
//  (all 1.97 million minutes checked), so a missed rain stays missed — unless
//  someone with a real gauge says how much fell.
//
//  A READING COVERS A SPAN, BECAUSE A GAUGE DOES. You empty it when you read it,
//  so one number can cover two days. Rather than invent a split, the reading is
//  resolved day by day by the person who knows: for each day, keep what the
//  station measured, or take yours. Days kept are subtracted from the gauge's
//  total; the remainder goes to the days not kept — typed per day where the
//  person knows, or, left blank, all to the last of them (and said so).
//
//  NOTHING HERE TOUCHES THE STATION'S MINUTES. A gauge day is a second source,
//  laid over the daily record when totals are built, and named wherever it shows.
//

import Foundation

/// One reading from the gauge, resolved to days.
public struct GaugeReading: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// First and last day the reading covers, `yyyy-MM-dd`.
    public var from: String
    public var to: String
    /// What the gauge held, inches.
    public var total: Double
    /// The day-by-day result: every day in the span, with where its number
    /// came from.
    public var days: [Day]
    public var note: String
    public var created: Date
    /// For merging between devices: the newer edit of a reading wins.
    public var modified: Date
    /// A deletion, kept so it travels to the other devices instead of the
    /// reading reappearing from one that still has it.
    public var deleted: Bool

    public struct Day: Codable, Equatable, Sendable, Identifiable {
        public var day: String
        public var amount: Double
        /// What the station measured that day, when the reading was made — the
        /// other half of the pair the sensor check is built from.
        public var station: Double?
        public var source: Source
        public var id: String { day }

        public init(day: String, amount: Double, station: Double?, source: Source) {
            self.day = day
            self.amount = amount
            self.station = station
            self.source = source
        }
    }

    public enum Source: String, Codable, Sendable {
        /// The station's figure, kept because the person agreed with it.
        case station
        /// Typed for this day by the person.
        case gauge
        /// The rest of the gauge's total after the kept and typed days.
        case remainder
    }

    public init(id: UUID = UUID(), from: String, to: String, total: Double, days: [Day],
                note: String = "", created: Date = Date(), modified: Date = Date(), deleted: Bool = false) {
        self.id = id
        self.from = from
        self.to = to
        self.total = total
        self.days = days
        self.note = note
        self.created = created
        self.modified = modified
        self.deleted = deleted
    }
}

/// Splitting a gauge total across its days.
public enum GaugeSplit {
    public enum Problem: Error, Equatable, Sendable {
        /// The days kept and typed already add up to more than the gauge held.
        case keptExceedTotal(kept: Double, total: Double)
        /// Every day is kept, so there is nowhere for a remainder to go, and the
        /// kept days don't add up to the total.
        case nothingLeftToAssign(difference: Double)
        case emptySpan
    }

    /// Resolve a reading into days.
    ///
    /// - `station`: what the station measured on each day of the span, in order.
    /// - `keep`: days to keep at the station's figure.
    /// - `typed`: days the person gave an amount for themselves.
    /// Every other day is a remainder day; the remainder goes to the last of
    /// them, and the rest of them get zero — never an invented split.
    public static func resolve(total: Double, station: [(day: String, amount: Double?)],
                               keep: Set<String>, typed: [String: Double]) -> Result<[GaugeReading.Day], Problem> {
        guard !station.isEmpty else { return .failure(.emptySpan) }
        var days: [GaugeReading.Day] = []
        var assigned = 0.0
        var open: [Int] = []
        for (i, entry) in station.enumerated() {
            if keep.contains(entry.day) {
                let a = max(0, entry.amount ?? 0)
                assigned += a
                days.append(.init(day: entry.day, amount: a, station: entry.amount, source: .station))
            } else if let t = typed[entry.day] {
                assigned += max(0, t)
                days.append(.init(day: entry.day, amount: max(0, t), station: entry.amount, source: .gauge))
            } else {
                open.append(i)
                days.append(.init(day: entry.day, amount: 0, station: entry.amount, source: .remainder))
            }
        }
        let left = (total - assigned).rounded(toPlaces: 2)
        if left < -0.005 { return .failure(.keptExceedTotal(kept: assigned, total: total)) }
        guard let last = open.last else {
            return abs(left) < 0.005 ? .success(days) : .failure(.nothingLeftToAssign(difference: left))
        }
        days[last].amount = max(0, left)
        return .success(days)
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10, Double(places))
        return (self * f).rounded() / f
    }
}

/// Every reading, and the day amounts they add up to.
public struct RainLog: Codable, Equatable, Sendable {
    public var readings: [GaugeReading]

    public init(readings: [GaugeReading] = []) { self.readings = readings }

    public var live: [GaugeReading] {
        readings.filter { !$0.deleted }.sorted { $0.to > $1.to || ($0.to == $1.to && $0.created > $1.created) }
    }

    /// Day → inches, from every live reading. Where two readings cover the
    /// same day, the newer one wins — a re-reading corrects, it doesn't add.
    public var dailyAmounts: [String: Double] {
        var out: [String: (amount: Double, at: Date)] = [:]
        for reading in readings where !reading.deleted {
            for day in reading.days {
                if let held = out[day.day], held.at > reading.modified { continue }
                out[day.day] = (day.amount, reading.modified)
            }
        }
        return out.mapValues(\.amount)
    }

    /// Days the person overrode — gauge or remainder, not "kept the station's".
    public var overriddenDays: Set<String> {
        Set(readings.filter { !$0.deleted }.flatMap { $0.days.filter { $0.source != .station }.map(\.day) })
    }

    /// Two devices' logs as one: every reading from either, the newer edit of
    /// each winning, deletions included so they propagate.
    public func merged(with other: RainLog) -> RainLog {
        var byID: [UUID: GaugeReading] = [:]
        for r in readings + other.readings {
            if let held = byID[r.id], held.modified >= r.modified { continue }
            byID[r.id] = r
        }
        return RainLog(readings: byID.values.sorted { $0.created < $1.created })
    }

    public mutating func upsert(_ reading: GaugeReading) {
        var r = reading
        r.modified = Date()
        readings.removeAll { $0.id == r.id }
        readings.append(r)
    }

    public mutating func delete(_ id: UUID) {
        guard let i = readings.firstIndex(where: { $0.id == id }) else { return }
        readings[i].deleted = true
        readings[i].modified = Date()
    }

    /// The sensor check: across every day the gauge corrected, how much of
    /// what the gauge caught the station caught too. Nil until there's a day
    /// with rain in the gauge to compare against.
    public var stationShare: (station: Double, gauge: Double, days: Int)? {
        let pairs = readings.filter { !$0.deleted }.flatMap(\.days)
            .filter { $0.source != .station && $0.amount >= 0.01 }
        guard !pairs.isEmpty else { return nil }
        return (pairs.reduce(0) { $0 + max(0, $1.station ?? 0) },
                pairs.reduce(0) { $0 + $1.amount }, pairs.count)
    }
}

extension DailyRecord {
    /// The daily record with the gauge's days laid over it: a day the gauge
    /// covers takes the gauge's rain, and a day the station missed entirely
    /// gains a record holding only that rain. Never written back to the archive.
    public static func applying(gauge: [String: Double], to records: [DailyRecord]) -> [DailyRecord] {
        guard !gauge.isEmpty else { return records }
        var byDay = Dictionary(records.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        for (day, amount) in gauge {
            var r = byDay[day] ?? DailyRecord(day: day)
            r.precipTotal = amount
            r.precipFromGauge = true
            byDay[day] = r
        }
        return byDay.values.sorted { $0.day < $1.day }
    }
}

extension TempestClient {
    /// What the station measured each day of a short span, inches — summed
    /// from its observations, the same way the archive sums them. For the
    /// gauge sheet, which has to show the station's figure for every day of a
    /// reading on any device, including the phone, which keeps no archive.
    public func dailyRain(days: [String], timeZone: TimeZone) async throws -> [String: Double] {
        var out: [String: Double] = [:]
        for day in days {
            var total = 0.0
            var any = false
            for window in SampleSync.windows(ofDay: day, timeZone: timeZone) {
                let response = try await observations(start: window.start, end: window.end,
                                                      bucketMinutes: SampleSync.bucketMinutes)
                for sample in StationSample.samples(from: response, bucketMinutes: SampleSync.bucketMinutes)
                where DayKey.string(for: sample.date, timeZone: timeZone) == day {
                    if let p = sample.precipCorrected ?? sample.precip { total += max(0, p); any = true }
                }
            }
            if any { out[day] = (total * 100).rounded() / 100 }
        }
        return out
    }
}
