//
//  When.swift  (WeatherKit)
//
//  EVERY MOMENT THE APP SHOWS CARRIES ITS DAY, and this is the one place that
//  decides how. A bare "6 PM" read at 1 AM leaves the reader to work out
//  whether it was last evening or is this evening, and a flood watch printed
//  "7 AM to 1 PM" that actually runs into Thursday is worse than no time at
//  all. So nothing that names a point in time prints a clock on its own:
//
//      today 4:02 PM · yesterday 6 PM · tomorrow 7 AM · Thu 7 AM · Sep 27, 6 PM
//
//  Weekday names are used only FORWARD, within the coming week, where "Thu"
//  can only mean one day. Backwards past yesterday a weekday is ambiguous (this
//  Monday or last?), so it becomes a date.
//
//  NOT FOR CLOCK POSITIONS. "Temperature peaks around 3pm" is an hour of the
//  day in a climatology, not a moment, and chart axes whose day is already
//  labelled are not moments either. Those keep `WeatherInterpreter.clock`.
//

import Foundation

public enum When {

    /// The day, in the words a person uses: "today", "yesterday", "tomorrow",
    /// "Thu" for the rest of the coming week, and a date otherwise.
    public static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: now)
        let then = calendar.startOfDay(for: date)
        let offset = calendar.dateComponents([.day], from: start, to: then).day ?? 0
        switch offset {
        case 0:  return "today"
        case -1: return "yesterday"
        case 1:  return "tomorrow"
        case 2...6: return formatter("EEE", calendar).string(from: date)
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return formatter(sameYear ? "MMM d" : "MMM d, yyyy", calendar).string(from: date)
        }
    }

    /// "7 AM", or "7:30 AM" when the minutes say something.
    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let onTheHour = calendar.component(.minute, from: date) == 0
        return formatter(onTheHour ? "h a" : "h:mm a", calendar).string(from: date)
    }

    /// "today 7 AM" · "yesterday 6 PM" · "Thu 7 AM" · "Sep 27, 6 PM".
    public static func moment(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = day(date, now: now, calendar: calendar)
        // A written date reads better with a comma before its time; a word does not.
        let joiner = day.first?.isNumber == false && day.last?.isNumber == true ? ", " : " "
        return day + joiner + time(date, calendar: calendar)
    }

    /// "today 1 PM – tomorrow 7 AM", or "today 1 PM – 7 PM" when both ends
    /// fall on the same day, so the day is said once and never left out.
    public static func range(_ from: Date, _ to: Date, now: Date = Date(),
                             calendar: Calendar = .current) -> String {
        let start = moment(from, now: now, calendar: calendar)
        let end = calendar.isDate(from, inSameDayAs: to)
            ? time(to, calendar: calendar)
            : moment(to, now: now, calendar: calendar)
        return "\(start) – \(end)"
    }

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let key = "\(format)|\(calendar.timeZone.identifier)|\(calendar.locale?.identifier ?? "")"
        return cache.withLock { cache in
            if let f = cache[key] { return f }
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            if let locale = calendar.locale { f.locale = locale }
            f.dateFormat = format
            cache[key] = f
            return f
        }
    }

    private static let cache = Locked<[String: DateFormatter]>([:])
}

/// A tiny lock around a value, so the formatter cache is safe from any thread.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Where a number came from, and when

/// WHO MADE A NUMBER, WHEN, AND WHEN THE NEXT ONE IS DUE — the line every
/// source in the app carries under what it shows.
///
/// The TIME IT WAS MADE, NOT THE TIME WE ASKED. A 1 AM model run fetched at
/// 10 AM is a 1 AM forecast; labelling it "10 AM" would hide the thing that
/// most explains why it missed the storm that formed at 6. Fetch time is only
/// printed when the source publishes nothing better, and then it says so.
public struct SourceStamp: Equatable, Sendable {
    public enum Made: Equatable, Sendable {
        /// A model run, named by the time it started from.
        case run(Date)
        /// A forecaster's product, named by when it was issued.
        case issued(Date)
        /// A measurement: a radar scan, a satellite image, a station reading.
        case observed(Date)
        /// The source says nothing about when it made this; all we know is
        /// when we fetched it.
        case fetched(Date)
        /// The source publishes a time and it is plainly wrong (Open-Meteo's
        /// GEM metadata still says May). Saying nothing beats a false date.
        case unpublished
    }

    public var source: String
    public var made: Made
    /// When the next one is expected — always an estimate, from a published
    /// schedule or the model's own cadence. Nil when nobody can say.
    public var next: Date?

    public init(source: String, made: Made, next: Date? = nil) {
        self.source = source; self.made = made; self.next = next
    }

    /// "run today 8 AM", "issued yesterday 9 PM", "fetched today 10:36 AM".
    public func madePhrase(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch made {
        case .run(let d):      return "run \(When.moment(d, now: now, calendar: calendar))"
        case .issued(let d):   return "issued \(When.moment(d, now: now, calendar: calendar))"
        case .observed(let d): return When.moment(d, now: now, calendar: calendar)
        case .fetched(let d):  return "fetched \(When.moment(d, now: now, calendar: calendar))"
        case .unpublished:     return "run time not published"
        }
    }

    /// "next expected today 11:30 AM", or "next one due since today 11:30 AM"
    /// when the schedule says it should be out and it isn't yet.
    public func nextPhrase(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let next else { return nil }
        let when = When.moment(next, now: now, calendar: calendar)
        return next > now ? "next expected \(when)" : "a newer one was due \(when)"
    }

    /// "SPC · issued today 8 AM · next expected today 11:30 AM".
    public func line(now: Date = Date(), calendar: Calendar = .current) -> String {
        ([source, madePhrase(now: now, calendar: calendar)]
            + [nextPhrase(now: now, calendar: calendar)].compactMap { $0 })
            .joined(separator: " · ")
    }
}
