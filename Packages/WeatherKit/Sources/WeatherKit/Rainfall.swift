//
//  Rainfall.swift  (WeatherKit)
//
//  Rain read two ways at once: how it's distributed THROUGH a year, and how the
//  years compare to each other.
//
//  Those are the two questions and they need each other. A bare annual total
//  can't tell you whether 30 inches arrived in a wet spring or spread evenly,
//  and a monthly average can't tell you this year is running dry. So the summary
//  below carries both, on one set of numbers.
//
//  EVERY TOTAL HERE IS A FLOOR. Precipitation is the measure least forgiving of
//  a gap: an hour the station missed may well have been the hour it rained, and
//  unlike a temperature — where the neighbouring hours bracket the answer —
//  nothing about the surrounding days recovers it. So a month with holes reports
//  the rain it SAW and says how much of the month it watched, rather than
//  quietly presenting an undercount as a measurement.
//

import Foundation

/// One calendar month of rain, this year against the usual.
public struct MonthlyRainfall: Equatable, Sendable, Identifiable {
    public var month: Int
    /// Median of that month's totals across the years with near-complete cover.
    public var typical: Double?
    /// This year's total, once the month has begun.
    public var thisYear: Double?
    /// Years contributing to `typical`.
    public var years: Int
    /// Share of this year's month the station watched.
    public var coverage: Double
    /// The month is still running, so its total is not yet comparable.
    public var isInProgress: Bool

    public var id: Int { month }

    public var name: String { WeatherAlmanac.monthName(String(format: "%02d", month), long: false) }
    /// Enough of the month watched to compare against the usual.
    public var isTrustworthy: Bool { coverage >= 0.9 }
}

/// One year's rain, with how much of the year backs the number.
public struct AnnualRainfall: Equatable, Sendable, Identifiable {
    public var year: Int
    public var total: Double
    public var daysCovered: Int
    public var daysExpected: Int
    public var isInProgress: Bool

    public var id: Int { year }

    public var coverage: Double {
        guard daysExpected > 0 else { return 0 }
        return min(1, Double(daysCovered) / Double(daysExpected))
    }
    public var isTrustworthy: Bool { !isInProgress && coverage >= 0.9 }
}

public struct RainfallSummary: Equatable, Sendable {
    public var months: [MonthlyRainfall]
    public var years: [AnnualRainfall]
    /// This year so far.
    public var yearToDate: Double
    /// What prior years had by this same date — compared to-date, never against a
    /// whole-year normal, or every January looks like a drought.
    public var typicalToDate: Double?
    /// Median of the complete years on record.
    public var typicalYear: Double?
    public var wettestYear: AnnualRainfall?
    public var driestYear: AnnualRainfall?
    /// Days of this year the station missed — the size of the undercount.
    public var daysMissedThisYear: Int

    /// Two comparable years is the floor for "typical".
    public var isMeaningful: Bool { years.filter(\.isTrustworthy).count >= 2 }

    /// Year-to-date minus what's usual by now. Positive is wetter.
    public var departureToDate: Double? {
        guard let typicalToDate else { return nil }
        return yearToDate - typicalToDate
    }
}

extension Climatology {

    /// Rain by month and by year, as of a given day.
    public func rainfallSummary(asOf day: String) -> RainfallSummary {
        guard let currentYear = DayKey.year(of: day) else {
            return RainfallSummary(months: [], years: [], yearToDate: 0, daysMissedThisYear: 0)
        }
        let monthDay = DayKey.monthDay(of: day)
        let currentMonth = Int(monthDay.prefix(2)) ?? 1

        // MARK: By month
        var months: [MonthlyRainfall] = []
        for month in 1...12 {
            let key = String(format: "%02d", month)
            var totals: [Double] = []
            for year in years {
                let span = Climatology.monthBounds(year: year, month: month)
                let (total, days) = precipTotal(from: span.start, through: span.end)
                // A month we only half-watched can't inform the usual — it would
                // pull it down by exactly the rain we failed to see.
                guard days >= Int(Double(span.days) * 0.9), year != currentYear else { continue }
                totals.append(total)
            }

            let span = Climatology.monthBounds(year: currentYear, month: month)
            let (thisYearTotal, thisYearDays) = precipTotal(from: span.start, through: min(span.end, day))
            let started = month <= currentMonth
            // Days ELAPSED, and today is not one of them: the archive stops at
            // yesterday on purpose, so counting today as a day the station missed
            // would report every running month as 3% incomplete for no reason.
            let expected = month == currentMonth
                ? (DayKey.distance(from: span.start, to: day) ?? 0)
                : span.days
            let coverage = expected > 0 ? min(1, Double(thisYearDays) / Double(expected)) : 1

            months.append(MonthlyRainfall(
                month: month,
                typical: totals.sorted().median,
                thisYear: started ? thisYearTotal : nil,
                years: totals.count,
                coverage: started ? coverage : 0,
                isInProgress: month == currentMonth))
        }

        // MARK: By year
        let annual: [AnnualRainfall] = years.map { year in
            let end = year == currentYear ? day : "\(year)-12-31"
            let (total, days) = precipTotal(from: "\(year)-01-01", through: end)
            // Same rule: a finished year runs through Dec 31 inclusive, the running
            // one only through yesterday.
            let span = DayKey.distance(from: "\(year)-01-01", to: end) ?? 364
            let expected = year == currentYear ? max(1, span) : span + 1
            return AnnualRainfall(year: year, total: total, daysCovered: days,
                                  daysExpected: expected, isInProgress: year == currentYear)
        }.sorted { $0.year > $1.year }

        // MARK: To date
        let thisYear = precipTotal(from: "\(currentYear)-01-01", through: day)
        let priorToDate = years.filter { $0 < currentYear }.compactMap { year -> Double? in
            let end = "\(year)-\(monthDay)"
            let (total, days) = precipTotal(from: "\(year)-01-01", through: end)
            let expected = (DayKey.distance(from: "\(year)-01-01", to: end) ?? 0) + 1
            // Only years that actually watched the same stretch.
            guard Double(days) >= Double(expected) * 0.9 else { return nil }
            return total
        }

        let complete = annual.filter(\.isTrustworthy).map(\.total).sorted()
        let elapsed = DayKey.distance(from: "\(currentYear)-01-01", to: day) ?? 0

        return RainfallSummary(
            months: months,
            years: annual,
            yearToDate: thisYear.total,
            typicalToDate: priorToDate.count >= 2 ? priorToDate.sorted().median : nil,
            typicalYear: complete.median,
            wettestYear: annual.filter(\.isTrustworthy).max { $0.total < $1.total },
            driestYear: annual.filter(\.isTrustworthy).min { $0.total < $1.total },
            daysMissedThisYear: max(0, elapsed - thisYear.days))
    }

    /// First and last day keys of a month, and its length.
    static func monthBounds(year: Int, month: Int) -> (start: String, end: String, days: Int) {
        let start = String(format: "%04d-%02d-01", year, month)
        let nextMonth = month == 12
            ? String(format: "%04d-01-01", year + 1)
            : String(format: "%04d-%02d-01", year, month + 1)
        let days = DayKey.distance(from: start, to: nextMonth) ?? 30
        let end = DayKey.previous(nextMonth) ?? start
        return (start, end, days)
    }
}
