//
//  YearAxis.swift  (WeatherKit)
//
//  Day-of-year geometry: "how far across the year is March 4", in one
//  multiplication.
//
//  IT LIVES IN THE PACKAGE BECAUSE MORE THAN THE APP NEEDS IT. It was written
//  for the period brush, in the app target, where it was the only thing that
//  had to turn a `MM-dd` into a position on a strip. `WhenInTheYear` needs
//  exactly the same mapping, and the one thing worse than a calendar in the
//  wrong layer is two calendars that disagree about February — so it moved
//  rather than being copied. Nothing about it was ever app-shaped; it is
//  arithmetic on month lengths.
//
//  Deliberately a separate calendar from `DayKey`'s string stepping. `DayKey`
//  answers questions about real dates in a real year and pays a formatter for
//  it; this one answers questions about the SHAPE of a year and is meant to be
//  called sixty times a second inside a draw. `MM-dd` is the boundary — the
//  only thing that crosses in or out.
//

import Foundation

/// Day-of-year geometry, leap-year shaped.
public enum YearAxis {

    /// 366, matching the reference year the archive's periods walk, so a window
    /// touching the end of February contains the 29th.
    public static let dayCount = 366

    public static let months: [(name: String, length: Int)] = [
        ("Jan", 31), ("Feb", 29), ("Mar", 31), ("Apr", 30), ("May", 31), ("Jun", 30),
        ("Jul", 31), ("Aug", 31), ("Sep", 30), ("Oct", 31), ("Nov", 30), ("Dec", 31)
    ]

    public static let monthStart: [Int] = {
        var starts: [Int] = []
        var day = 0
        for month in months { starts.append(day); day += month.length }
        return starts
    }()

    public static func wrap(_ value: Int) -> Int {
        let r = value % dayCount
        return r < 0 ? r + dayCount : r
    }

    public static func monthAndDay(of day: Int) -> (month: Int, day: Int) {
        let day = wrap(day)
        var index = 11
        while index > 0 && monthStart[index] > day { index -= 1 }
        return (index, day - monthStart[index] + 1)
    }

    public static func day(of monthDay: String) -> Int? {
        let parts = monthDay.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]),
              (1...12).contains(month), (1...months[month - 1].length).contains(day)
        else { return nil }
        return monthStart[month - 1] + day - 1
    }

    public static func monthDay(of day: Int) -> String {
        let (month, dayOfMonth) = monthAndDay(of: day)
        return String(format: "%02d-%02d", month + 1, dayOfMonth)
    }

    /// The first slot of each month paired with its name — what a chart drawing
    /// gridlines or month labels walks. The brush built this inline from
    /// `monthStart`; the rhythm chart wanted the same pairing, which is a sign
    /// it belongs to the axis rather than to either drawing.
    public static var monthMarks: [(month: Int, start: Int, length: Int, name: String)] {
        months.enumerated().map { ($0.offset, monthStart[$0.offset], $0.element.length, $0.element.name) }
    }

    public static func label(_ day: Int) -> String {
        let (month, dayOfMonth) = monthAndDay(of: day)
        return "\(months[month].name) \(dayOfMonth)"
    }

    /// "Oct 3", "10-03", "October 3" — the forms someone actually types.
    public static func parse(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == " " })
        guard parts.count == 2, let dayOfMonth = Int(parts[1]) else { return nil }

        if let month = Int(parts[0]) {
            return day(of: String(format: "%02d-%02d", month, dayOfMonth))
        }
        let prefix = parts[0].prefix(3).lowercased()
        guard let month = months.firstIndex(where: { $0.name.lowercased() == prefix })
        else { return nil }
        return day(of: String(format: "%02d-%02d", month + 1, dayOfMonth))
    }
}
