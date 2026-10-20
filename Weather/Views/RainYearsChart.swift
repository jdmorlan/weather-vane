//
//  RainYearsChart.swift
//
//  The Rain page's record: every year on record, a row each, on the calendar.
//
//  A tick for each day it rained, as tall as the rain; a shaded band for each
//  stretch of two weeks or more without any; the year's total at the end of the
//  row. The five wettest days carry their amounts.
//
//  It replaced two ranked lists — the longest dry spells, the biggest days —
//  whose bars only restated their numbers. On the calendar the thing the lists
//  hid is the first thing you see: the big days crowd into late spring, the dry
//  spells into late summer and the holidays. See `RainYears`.
//

import SwiftUI
import WeatherKit

struct RainYearsChart: View {
    let record: RainYears

    @State private var pointer: CGPoint?
    @State private var width: CGFloat = 0

    static let rowHeight: CGFloat = 38
    static let top: CGFloat = 16
    static let left: CGFloat = 40
    private var rowHeight: CGFloat { Self.rowHeight }
    private var top: CGFloat { Self.top }
    private var left: CGFloat { Self.left }
    private func right(_ w: CGFloat) -> CGFloat { w < 560 ? 58 : 136 }
    private func plotWidth(_ w: CGFloat) -> CGFloat { max(1, w - left - right(w)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Canvas { context, size in draw(&context, size) }
                .frame(height: top + rowHeight * CGFloat(record.years.count) + 4)
                // The same measure the Explore chart uses. A GeometryReader in
                // the background read 0 inside the page's LazyVStack and never
                // updated, which drew every day of every year in one column.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .onContinuousHover { phase in
                    if case .active(let p) = phase { pointer = p } else { pointer = nil }
                }
                .overlay(alignment: .topLeading) { readout }
            legend
        }
    }

    // MARK: Geometry

    // Every measure takes the width it's drawn at. The canvas passes its own
    // size; only hover reads the stored `width`, which arrives a pass later.
    private func x(_ slot: Int, _ w: CGFloat) -> CGFloat {
        left + CGFloat(slot) / CGFloat(record.slotCount) * plotWidth(w)
    }
    private func slotWidth(_ w: CGFloat) -> CGFloat { plotWidth(w) / CGFloat(record.slotCount) }
    private func baseline(_ row: Int) -> CGFloat { top + rowHeight * CGFloat(row + 1) - 6 }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let W = size.width
        func x(_ slot: Int) -> CGFloat { self.x(slot, W) }
        let slotWidth = self.slotWidth(W), plotWidth = self.plotWidth(W)
        let barRoom = rowHeight - 14
        let monthNames = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]
        let fullNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

        for (m, start) in record.monthStarts.enumerated() {
            let px = x(start)
            if m > 0 {
                var rule = Path(); rule.move(to: CGPoint(x: px, y: top)); rule.addLine(to: CGPoint(x: px, y: size.height - 4))
                context.stroke(rule, with: .color(.primary.opacity(0.06)), lineWidth: 1)
            }
            context.draw(Text(W < 560 ? monthNames[m] : fullNames[m]).font(.system(size: 9)).foregroundStyle(.tertiary),
                         at: CGPoint(x: px + 2, y: 2), anchor: .topLeading)
        }

        for (row, year) in record.years.enumerated() {
            let base = baseline(row)

            // The biggest days' labels are placed first, so nothing else is
            // drawn where they'll sit. Each gets a solid backing: it has to read
            // over ticks and dry-spell bands alike.
            var taken: [CGRect] = []
            var bigLabels: [(text: GraphicsContext.ResolvedText, rect: CGRect)] = []
            for big in record.biggest where DayKey.year(of: big.day) == year.year {
                guard let slot = YearSlot.of(big.day) else { continue }
                let h = max(2, barRoom * CGFloat(min(1, big.amount / record.peak)))
                let text = context.resolve(Text(WeatherAlmanac.inches(big.amount))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit()).foregroundStyle(.primary))
                let size = text.measure(in: CGSize(width: 200, height: 40))
                let atEnd = x(slot) > left + plotWidth - size.width - 12
                let ox = atEnd ? x(slot) - 3 - size.width : x(slot) + slotWidth + 3
                let oy = min(base - size.height - 1, max(base - barRoom, base - h))
                let rect = CGRect(x: ox, y: oy, width: size.width, height: size.height).insetBy(dx: -3, dy: -1)
                taken.append(rect)
                bigLabels.append((text, rect))
            }

            // Long dry spells, behind everything.
            for spell in year.spells {
                let a = x(spell.slots.lowerBound), b = x(spell.slots.upperBound + 1)
                let rect = CGRect(x: a, y: base - barRoom, width: b - a, height: barRoom)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.orange.opacity(spell.isOpen ? 0.4 : 0.28)))
                if spell.isOpen {
                    context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(.orange.opacity(0.7)), lineWidth: 1)
                }
                // Its length, on the part of it that has room — once, on the longer half.
                let shown = spell.slots.count
                if b - a > 26, !spell.continues || shown * 2 >= spell.days {
                    let text = context.resolve(Text("\(spell.days)d")
                        .font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.orange))
                    let size = text.measure(in: CGSize(width: 100, height: 40))
                    let mid = base - barRoom / 2
                    // Centred if that's clear; else whichever end of the band is.
                    let spots = [(a + b) / 2, a + size.width / 2 + 4, b - size.width / 2 - 4]
                    let spot = spots.first { cx in
                        let r = CGRect(x: cx - size.width / 2, y: mid - size.height / 2, width: size.width, height: size.height)
                        return !taken.contains { $0.intersects(r) }
                    }
                    if let spot { context.draw(text, at: CGPoint(x: spot, y: mid), anchor: .center) }
                }
            }

            // The floor, only where the station watched.
            var watched: [ClosedRange<Int>] = []
            var runStart: Int?
            for i in 0...year.amounts.count {
                let on = i < year.amounts.count && year.amounts[i] != nil
                if on, runStart == nil { runStart = i }
                if !on, let s = runStart { watched.append(s...(i - 1)); runStart = nil }
            }
            for run in watched {
                var floor = Path(); floor.move(to: CGPoint(x: x(run.lowerBound), y: base)); floor.addLine(to: CGPoint(x: x(run.upperBound + 1), y: base))
                context.stroke(floor, with: .color(.primary.opacity(0.22)), lineWidth: 1)
            }

            // A tick per rain day.
            for (slot, amount) in year.amounts.enumerated() {
                guard let amount, amount >= Climatology.measurableRain else { continue }
                let h = max(2, barRoom * CGFloat(min(1, amount / record.peak)))
                let w = max(1, slotWidth * 0.8)
                let rect = CGRect(x: x(slot) + (slotWidth - w) / 2, y: base - h, width: w, height: h)
                context.fill(Path(rect), with: .color(.blue.opacity(0.85)))
            }

            // The biggest days, named, over everything in the row.
            for label in bigLabels {
                context.fill(Path(roundedRect: label.rect, cornerRadius: 3), with: .style(.background))
                context.stroke(Path(roundedRect: label.rect, cornerRadius: 3), with: .color(.primary.opacity(0.15)), lineWidth: 0.5)
                context.draw(label.text, at: CGPoint(x: label.rect.midX, y: label.rect.midY), anchor: .center)
            }

            // Where today is, on the running year.
            if year.isInProgress {
                let px = x(record.throughSlot + 1)
                var mark = Path(); mark.move(to: CGPoint(x: px, y: base - barRoom)); mark.addLine(to: CGPoint(x: px, y: base + 3))
                context.stroke(mark, with: .color(.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }

            context.draw(Text(String(year.year)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: 0, y: base - 4), anchor: .bottomLeading)
            let total = Text(WeatherAlmanac.inches(year.total)).font(.system(size: 11, weight: .medium).monospacedDigit())
            context.draw(total.foregroundStyle(.primary), at: CGPoint(x: left + plotWidth + 8, y: base - 4), anchor: .bottomLeading)
            if let note = note(year), W >= 560 {
                context.draw(Text(note).font(.system(size: 9)).foregroundStyle(.tertiary),
                             at: CGPoint(x: left + plotWidth + 64, y: base - 4), anchor: .bottomLeading)
            }
        }
    }

    private func note(_ year: RainYears.Year) -> String? {
        if year.isInProgress { return "so far" }
        if year.coverage < 0.9 { return "\(Int((year.coverage * 100).rounded()))% recorded" }
        return nil
    }

    // MARK: Hover

    @ViewBuilder private var readout: some View {
        if let pointer, let (year, slot) = hit(pointer) {
            let row = record.years[year]
            let label = readoutText(row, slot)
            Text(label)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .offset(x: min(max(0, pointer.x - 60), max(0, width - 220)),
                        y: max(0, baseline(year) - rowHeight - 18))
                .allowsHitTesting(false)
        }
    }

    private func hit(_ p: CGPoint) -> (Int, Int)? {
        guard p.x >= left, p.x < left + plotWidth(width), p.y >= top else { return nil }
        let row = Int((p.y - top) / rowHeight)
        let slot = Int((p.x - left) / slotWidth(width))
        guard record.years.indices.contains(row), (0..<record.slotCount).contains(slot) else { return nil }
        return (row, slot)
    }

    private func readoutText(_ year: RainYears.Year, _ slot: Int) -> String {
        let day = dayKey(year.year, slot)
        let label = WeatherAlmanac.dayLabel(day, includeYear: true)
        if let spell = year.spells.first(where: { $0.slots.contains(slot) }) {
            return "\(label) · \(spell.days) days without rain, \(WeatherAlmanac.dayLabel(spell.startDay)) – \(WeatherAlmanac.dayLabel(spell.endDay))\(spell.isOpen ? ", still going" : "")"
        }
        guard let amount = year.amounts[slot] else { return "\(label) · not recorded" }
        return amount >= Climatology.measurableRain ? "\(label) · \(WeatherAlmanac.inches(amount))" : "\(label) · dry"
    }

    private func dayKey(_ year: Int, _ slot: Int) -> String {
        let month = (record.monthStarts.lastIndex { $0 <= slot } ?? 0)
        let day = slot - record.monthStarts[month] + 1
        return String(format: "%04d-%02d-%02d", year, month + 1, day)
    }

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Rectangle().fill(Color.blue.opacity(0.85)).frame(width: 2, height: 10)
                Text("a day of rain, as tall as the rain").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity(0.28)).frame(width: 14, height: 10)
                Text("\(record.minSpell)+ days without rain").font(.caption2).foregroundStyle(.secondary)
            }
            Text("No floor line: not recorded").font(.caption2).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }
}

/// Builds the record off the main thread, once per day, and holds the card's
/// place while it does.
struct RainYearsCard: View {
    let climate: Climatology
    let today: String

    @State private var record: RainYears?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let record, record.isMeaningful {
                RainYearsChart(record: record)
            } else if record != nil {
                Text("A year of record makes a row worth reading. It fills in as the archive grows.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                skeleton
            }
        }
        .task(id: "\(today)|\(climate.dayCount)") {
            let c = climate, d = today
            record = await Task.detached(priority: .userInitiated) { c.rainYears(asOf: d) }.value
        }
    }

    /// The chart's outline while it's built: its rows, its height, its year
    /// labels — so the card is plainly the record, still coming, and the page
    /// doesn't jump when it arrives.
    private var skeleton: some View {
        let years = climate.years.filter { $0 <= (DayKey.year(of: today) ?? .max) }.sorted(by: >)
        return VStack(alignment: .leading, spacing: 10) {
            ZStack {
                VStack(spacing: 0) {
                    Color.clear.frame(height: RainYearsChart.top)
                    ForEach(years, id: \.self) { year in
                        HStack(alignment: .bottom, spacing: 0) {
                            Text(String(year)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                                .frame(width: RainYearsChart.left, alignment: .leading)
                            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                                .padding(.bottom, 6)
                        }
                        .frame(height: RainYearsChart.rowHeight, alignment: .bottom)
                    }
                    Color.clear.frame(height: 4)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the years behind you").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.background, in: Capsule())
            }
            // The legend's line, held empty.
            Text(" ").font(.caption2)
        }
    }
}
