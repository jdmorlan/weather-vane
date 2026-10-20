//
//  RainYears.swift  (WeatherKit)
//
//  Every year on record as one row: each day it rained, each long dry spell,
//  and the year's total — the Rain page's record, drawn on the calendar.
//
//  WHY ONE PICTURE REPLACED TWO LISTS. The page used to rank the longest dry
//  spells and the biggest days as bars, and the bars only repeated the numbers
//  beside them. What the lists hid was WHEN: seven of the eight biggest days
//  fell in May through July, and the long spells sat in late summer and over
//  the holidays. Laid on a calendar, a row per year, that is the first thing you
//  see — and the rank survives as labels on the biggest marks.
//
//  A DAY THE STATION DIDN'T WATCH IS NOT A DRY DAY. It is nil here, drawn as a
//  gap, and it ends a dry spell rather than extending it (see
//  `Climatology.drySpells`).
//

import Foundation

public struct RainYears: Equatable, Sendable {

    public struct Spell: Equatable, Sendable, Identifiable {
        public var startDay: String
        public var endDay: String
        /// The whole spell's length, even where a row shows only part of it.
        public var days: Int
        public var isOpen: Bool
        /// This row's part of it.
        public var slots: ClosedRange<Int>
        /// The spell runs on into the next row (or came from the previous one).
        public var continues: Bool
        public var id: String { "\(startDay)|\(slots.lowerBound)" }
    }

    public struct Year: Equatable, Sendable, Identifiable {
        public var year: Int
        /// Rain per slot (see `YearSlot`). Nil for a day not watched, or not yet come.
        public var amounts: [Double?]
        /// In calendar order.
        public var spells: [Spell]
        public var total: Double
        /// Share of the year's elapsed days the station watched.
        public var coverage: Double
        public var isInProgress: Bool
        public var id: Int { year }
    }

    public struct Big: Equatable, Sendable, Identifiable {
        public var day: String
        public var amount: Double
        public var rank: Int
        public var id: String { day }
    }

    /// Newest first.
    public var years: [Year]
    /// The wettest days on record, wettest first.
    public var biggest: [Big]
    /// The rain that fills a row's height; the record's biggest day.
    public var peak: Double
    /// Spells this long or longer are drawn.
    public var minSpell: Int
    /// The slot of the last archived day in the newest row.
    public var throughSlot: Int

    public var monthStarts: [Int] { YearSlot.monthStarts }
    public var slotCount: Int { YearSlot.count }

    public var longest: Spell? { years.flatMap(\.spells).max { $0.days < $1.days } }
    public var isMeaningful: Bool { years.contains { !$0.isInProgress && $0.coverage >= 0.5 } }
}

extension Climatology {

    public func rainYears(asOf day: String, minSpell: Int = 14, biggest topN: Int = 5) -> RainYears {
        let threshold = Self.measurableRain
        let usable = all.filter { $0.isReliable && $0.precipTotal != nil && $0.day <= day }
        let currentYear = DayKey.year(of: day) ?? 0
        let through = YearSlot.of(day) ?? 0

        let spells = Self.drySpells(in: usable, threshold: threshold, topN: .max)
            .filter { $0.days >= minSpell }

        var rows: [RainYears.Year] = []
        for year in years.sorted(by: >) where year <= currentYear {
            // TOTALS COUNT EVERY RECORDED DAY, the same rule as `rainfallSummary`,
            // so a row's number is the number the rest of the page quotes. Only
            // the DRAWING is stricter: a partly watched day that saw rain still
            // rained at least that much, but one that saw none is a gap, not a
            // dry day.
            var amounts = [Double?](repeating: nil, count: YearSlot.count)
            var total = 0.0, recorded = 0
            for record in all where record.day.hasPrefix("\(year)-") && record.day <= day {
                guard let slot = YearSlot.of(record.day) else { continue }
                recorded += 1
                guard let p = record.precipTotal else { continue }
                total += p
                if record.isReliable || p >= threshold { amounts[slot] = (amounts[slot] ?? 0) + p }
            }
            let first = "\(year)-01-01", last = "\(year)-12-31"
            let rowSpells: [RainYears.Spell] = spells.compactMap { spell in
                guard spell.endDay >= first, spell.startDay <= last else { return nil }
                let a = spell.startDay < first ? 0 : (YearSlot.of(spell.startDay) ?? 0)
                let b = spell.endDay > last ? YearSlot.count - 1 : (YearSlot.of(spell.endDay) ?? 0)
                return .init(startDay: spell.startDay, endDay: spell.endDay, days: spell.days,
                             isOpen: spell.isOpen, slots: a...max(a, b),
                             continues: spell.startDay < first || spell.endDay > last)
            }.sorted { $0.slots.lowerBound < $1.slots.lowerBound }
            // Same rule as `rainfallSummary`: the running year counts only the
            // days elapsed before today, since the archive stops at yesterday.
            let expected = year == currentYear
                ? max(1, DayKey.distance(from: first, to: day) ?? 1)
                : (DayKey.distance(from: first, to: last) ?? 364) + 1
            rows.append(.init(year: year, amounts: amounts, spells: rowSpells,
                              total: total,
                              coverage: min(1, Double(recorded) / Double(expected)),
                              isInProgress: year == currentYear))
        }

        let big = usable
            .compactMap { r -> (String, Double)? in
                guard let p = r.precipTotal, p >= threshold else { return nil }
                return (r.day, p)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(topN)
            .enumerated()
            .map { RainYears.Big(day: $0.element.0, amount: $0.element.1, rank: $0.offset + 1) }

        return RainYears(years: rows, biggest: Array(big), peak: max(0.5, big.first?.amount ?? 0.5),
                         minSpell: minSpell, throughSlot: through)
    }
}
