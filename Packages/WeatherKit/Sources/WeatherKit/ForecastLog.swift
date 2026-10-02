//
//  ForecastLog.swift  (WeatherKit)
//
//  THE HALF OF THE RECORD NOBODY WAS KEEPING.
//
//  The archive holds what the station MEASURED, down to the minute, back to the
//  day it was installed. It holds nothing at all about what was PREDICTED.
//  `TempestClient.fetch()` pulls ten days of forecast every time the Weather
//  surface opens, `WeatherInterpreter` renders it, and then it is dropped on the
//  floor. So "the forecast said 94 and we hit 98" is a question this app could
//  not answer about yesterday, let alone about the last ten days — not because
//  the comparison is hard, but because one side of it was never written down.
//
//  WeatherFlow has no history endpoint for its own forecasts either. A forecast
//  is only observable at the moment it is issued, which makes it exactly like a
//  station reading and nothing like a fact you can look up later. That single
//  property decides everything below.
//
//  A FORECAST IS A CLAIM MADE AT A MOMENT ABOUT A DAY, and both halves are
//  load-bearing. "The high will be 94" is not a statement that can be right or
//  wrong on its own — it was right or wrong AS OF when it was said. Yesterday
//  morning's 94 and this morning's 97 are two different claims about the same
//  day, and scoring them as one number would blur the only interesting thing
//  here: forecasts get better as the day approaches, and where they stop
//  improving is where the model stops knowing. So the row is keyed by
//  `issuedAt`, and lead time is DERIVED at read time rather than stored — the
//  lead of a claim depends on when you're asking, not on when it was filed.
//
//  SHARDED BY THE DAY BEING PREDICTED, not by the day of the fetch. One capture
//  touches ten files, which looks backwards until you write the read: every
//  question here is "what did we say about the 14th", and that must be one small
//  read rather than a walk through ten days of captures looking for mentions.
//  It also lines the log up file-for-file with `SampleArchive`, so the forecast
//  for a day and the minutes of that day are the same key in two directories.
//
//  ONLY CHANGES ARE KEPT. Opening the Weather surface six times before lunch
//  produces six identical claims, and five of them carry no information. A row
//  is written only when the numbers differ from the standing claim, which turns
//  the file into a log of REVISIONS — "94 on Tuesday, 95 on Wednesday, 97 the
//  morning of" — which is the shape you actually want to read. The cost is that
//  "what were we saying at 4pm" is answered by the last row at or before 4pm
//  rather than by a row stamped 4pm, and every reader here does that.
//
//  Same NDJSON-gzip-per-day storage as the sample archive, for the same reason:
//  legible outside the app, greppable, nothing reduced on the way in.
//

import Foundation

/// One claim about one day, as captured at one moment.
///
/// Deliberately the daily forecast's fields and no interpretation. Everything
/// the ten-day card shows for a day is here, because the cheap mistake is to
/// keep only the high — the day the question becomes "does it over-promise
/// rain" there would be nothing on disk to answer it with, and a forecast, once
/// unobserved, cannot be re-fetched.
public struct ForecastNote: Codable, Equatable, Sendable {
    /// When we saw this claim. The identity of a row: two captures at the same
    /// second are the same observation of the forecast.
    public var issuedAt: Int
    /// The local day being predicted, `yyyy-MM-dd`. The shard key.
    public var validDay: String

    public var high: Double?
    public var low: Double?
    public var precipProbability: Double?
    public var conditions: String?
    public var icon: String?
    /// The strongest gust in that day's HOURLY forecast, mph. Logged from
    /// October 2026; earlier rows have none. The daily forecast carries no wind
    /// at all, so this is the only way a gust forecast can ever be graded.
    public var gust: Double?
    /// The muggiest hour's dew point in that day's hourly forecast, °F — Magnus
    /// from its temperature and humidity, the same function the archive uses
    /// on the station's own readings. Logged from October 2026.
    public var dewPoint: Double?

    public init(issuedAt: Int, validDay: String,
                high: Double? = nil, low: Double? = nil,
                precipProbability: Double? = nil,
                conditions: String? = nil, icon: String? = nil,
                gust: Double? = nil, dewPoint: Double? = nil) {
        self.issuedAt = issuedAt
        self.validDay = validDay
        self.high = high
        self.low = low
        self.precipProbability = precipProbability
        self.conditions = conditions
        self.icon = icon
        self.gust = gust
        self.dewPoint = dewPoint
    }

    public var issued: Date { Date(timeIntervalSince1970: TimeInterval(issuedAt)) }

    /// Whether this says anything different from `other`. `issuedAt` is excluded
    /// on purpose — that is the whole point of the comparison.
    public func statesSameAs(_ other: ForecastNote) -> Bool {
        high == other.high && low == other.low
            && precipProbability == other.precipProbability
            && conditions == other.conditions && icon == other.icon
            && gust == other.gust && dewPoint == other.dewPoint
    }

    /// How many local days ahead this claim was looking.
    ///
    /// 0 is a claim made during the day it describes; 1 is yesterday's word on
    /// today. Counted in calendar days rather than by dividing seconds, because
    /// a fall-back day is 25 hours long and would otherwise round to the wrong
    /// lead once a year.
    public func leadDays(timeZone: TimeZone) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let valid = DayKey.date(from: validDay, timeZone: timeZone) else { return nil }
        let issuedDay = calendar.startOfDay(for: issued)
        return calendar.dateComponents([.day], from: issuedDay, to: valid).day
    }
}

extension ForecastNote {
    /// Read a `better_forecast` payload into one claim per day it covers.
    ///
    /// The day key comes from `day_start_local` through the payload's own
    /// timezone, never from `day_num`: the number is a day-of-month with no year
    /// and no month, and using it as a key would collide every 28 to 31 days.
    public static func notes(from forecast: BetterForecast,
                             issuedAt: Date = Date()) -> [ForecastNote] {
        let tz = forecast.timezone.flatMap { TimeZone(identifier: $0) } ?? .current
        let keyOf = DayKey.formatter(timeZone: tz)
        let stamp = Int(issuedAt.timeIntervalSince1970)

        // The hours, grouped by the same local day key, for what the daily
        // forecast doesn't carry: the day's strongest gust and muggiest air.
        var gusts: [String: Double] = [:]
        var dews: [String: Double] = [:]
        for hour in forecast.forecast?.hourly ?? [] {
            guard let time = hour.time else { continue }
            let key = keyOf.string(from: Date(timeIntervalSince1970: TimeInterval(time)))
            if let gust = hour.windGust { gusts[key] = max(gusts[key] ?? gust, gust) }
            if let t = hour.airTemperature, let rh = hour.relativeHumidity {
                let dew = WeatherInterpreter.dewPointF(tempF: t, humidity: rh)
                dews[key] = max(dews[key] ?? dew, dew)
            }
        }

        return (forecast.forecast?.daily ?? []).compactMap { day in
            guard let start = day.dayStartLocal else { return nil }
            let validDay = keyOf.string(from: Date(timeIntervalSince1970: TimeInterval(start)))
            return ForecastNote(issuedAt: stamp,
                                validDay: validDay,
                                high: day.airTempHigh,
                                low: day.airTempLow,
                                precipProbability: day.precipProbability,
                                conditions: day.conditions,
                                icon: day.icon,
                                gust: gusts[validDay].map { ($0 * 10).rounded() / 10 },
                                dewPoint: dews[validDay].map { ($0 * 10).rounded() / 10 })
        }
    }
}

// MARK: - Store

public protocol ForecastLogStore: Sendable {
    /// Every claim on file about one day, ascending by issue time. Empty when
    /// the day was never captured — never an error, since "we weren't watching"
    /// is an answer.
    func claims(for day: String) throws -> [ForecastNote]
    /// Which predicted days the log holds, ascending.
    func loggedDays() throws -> [String]
    /// Record a capture. Returns the day keys that actually gained a row —
    /// empty when nothing had changed, which is the common case.
    @discardableResult
    func record(_ notes: [ForecastNote]) throws -> [String]
}

extension ForecastLogStore {
    /// The claim standing at `instant` — the last one issued at or before it.
    ///
    /// This is the read that the change-only write rule requires. A forecast
    /// that went unrevised for three days is on file once, and it was still
    /// what the app was telling you the whole time.
    public func claim(for day: String, asOf instant: Date) throws -> ForecastNote? {
        let stamp = Int(instant.timeIntervalSince1970)
        return try claims(for: day).last { $0.issuedAt <= stamp }
    }

    /// The word you were given on the MORNING of a day.
    ///
    /// Anchored at local noon rather than at a particular hour, because the
    /// ritual it models is "opening the app some time before lunch" and pinning
    /// it to 7am would miss a 9am read entirely. When the app went unopened that
    /// morning this falls back — correctly, not as a failure — to whatever the
    /// last standing claim was, which is usually yesterday's; `leadDays` on the
    /// returned note says which happened.
    public func morningClaim(for day: String, timeZone: TimeZone) throws -> ForecastNote? {
        guard let start = DayKey.date(from: day, timeZone: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let noon = calendar.date(byAdding: .hour, value: 12, to: start) ?? start.addingTimeInterval(43_200)
        return try claim(for: day, asOf: noon)
    }
}

public final class FileForecastLog: ForecastLogStore, @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    /// Orders writes against the OTHER app sharing this archive; see `ArchiveFileLock`.
    private let fileLock: ArchiveFileLock

    public init(root: URL) {
        self.root = root
        self.fileLock = ArchiveFileLock(root: root)
    }

    /// `<root>/2026/2026-09-14.ndjson.gz`
    private func url(forDay day: String) -> URL {
        root.appendingPathComponent(String(day.prefix(4)))
            .appendingPathComponent("\(day).ndjson.gz")
    }

    public func claims(for day: String) throws -> [ForecastNote] {
        lock.lock(); defer { lock.unlock() }
        return try read(day: day)
    }

    private func read(day: String) throws -> [ForecastNote] {
        let url = url(forDay: day)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let raw = try Data(contentsOf: url)
        guard !raw.isEmpty else { return [] }
        let lines = try Gzip.decompress(raw).split(separator: UInt8(ascii: "\n"))
        let decoder = JSONDecoder()
        let notes = try lines.compactMap { line in
            line.isEmpty ? nil : try decoder.decode(ForecastNote.self, from: Data(line))
        }
        return notes.sorted { $0.issuedAt < $1.issuedAt }
    }

    public func loggedDays() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        var days: [String] = []
        for yearDir in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard Int(yearDir.lastPathComponent) != nil else { continue }
            let files = (try? fm.contentsOfDirectory(at: yearDir, includingPropertiesForKeys: nil)) ?? []
            days += files.compactMap { file in
                let name = file.lastPathComponent
                guard name.hasSuffix(".ndjson.gz") else { return nil }
                return String(name.dropLast(".ndjson.gz".count))
            }
        }
        return days.sorted()
    }

    @discardableResult
    public func record(_ notes: [ForecastNote]) throws -> [String] {
        guard !notes.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        return try fileLock.withLock {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]

            var written: [String] = []
            for (day, incoming) in Dictionary(grouping: notes, by: \.validDay) {
                var existing = try read(day: day)
                var changed = false
                for note in incoming.sorted(by: { $0.issuedAt < $1.issuedAt }) {
                    guard ForecastLogMerge.shouldKeep(note, given: existing) else { continue }
                    existing.append(note)
                    existing.sort { $0.issuedAt < $1.issuedAt }
                    changed = true
                }
                guard changed else { continue }

                var body = Data()
                for note in existing {
                    body.append(try encoder.encode(note))
                    body.append(UInt8(ascii: "\n"))
                }
                let url = url(forDay: day)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Gzip.compress(body).write(to: url, options: .atomic)
                written.append(day)
            }
            return written.sorted()
        }
    }
}

public enum ForecastLogMerge {
    /// Keep a claim only when it SAYS something new.
    ///
    /// "New" is measured against the claim standing at that instant, not against
    /// the newest row on file, so a capture that arrives out of order — a
    /// backfill, a clock correction — is judged against what it actually
    /// revised. A re-capture at an instant already on file is dropped: the
    /// forecast at a given second is a fact, and a second reading of it is the
    /// same fact.
    public static func shouldKeep(_ note: ForecastNote, given existing: [ForecastNote]) -> Bool {
        if existing.contains(where: { $0.issuedAt == note.issuedAt }) { return false }
        guard let standing = existing.last(where: { $0.issuedAt <= note.issuedAt }) else { return true }
        return !note.statesSameAs(standing)
    }
}

/// In-memory log for tests and previews.
public final class MemoryForecastLog: ForecastLogStore, @unchecked Sendable {
    private var storage: [String: [ForecastNote]] = [:]
    private let lock = NSLock()

    public init() {}

    public func claims(for day: String) throws -> [ForecastNote] {
        lock.lock(); defer { lock.unlock() }
        return storage[day] ?? []
    }

    public func loggedDays() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storage.keys.sorted()
    }

    @discardableResult
    public func record(_ notes: [ForecastNote]) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        var written: Set<String> = []
        for note in notes.sorted(by: { $0.issuedAt < $1.issuedAt }) {
            var day = storage[note.validDay] ?? []
            guard ForecastLogMerge.shouldKeep(note, given: day) else { continue }
            day.append(note)
            day.sort { $0.issuedAt < $1.issuedAt }
            storage[note.validDay] = day
            written.insert(note.validDay)
        }
        return written.sorted()
    }
}
