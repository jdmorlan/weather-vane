//
//  ReportViews.swift
//
//  The answer to a "report a number" question: three tiles and the picture that
//  fits the question — running totals, a grid of months, a month of the year,
//  or the dated extreme of each season. See `ReportPicture` for which is which
//  and why none of them is a bar per year.
//

import SwiftUI
import WeatherKit

struct ReportCard: View {
    let picture: ReportPicture
    let query: DayQuery
    /// Open a day, or a month, in History.
    var open: (WeatherGrain, String) -> Void = { _, _ in }

    @State private var width: CGFloat = 0
    @State private var pointer: CGPoint?
    @State private var tipSize: CGSize = .zero

    private var narrow: Bool { width < 560 }
    private var measure: Measure { picture.measure }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(query.name.isEmpty ? query.describe : query.name).font(.system(size: 17, weight: .semibold))
            tiles
            if picture.kind != .single {
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        guard size.width > 0 else { return }
                        draw(&context, size.width)
                    }
                    tip
                }
                .frame(height: height)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let point) = phase { pointer = point } else { pointer = nil }
                }
                .onTapGesture(coordinateSpace: .local) { point in
                    if let target = hit(point)?.opens { open(target.0, target.1); return }
                    #if !os(macOS)
                    pointer = pointer == nil ? point : nil
                    #endif
                }
                legend
            }
            Text(note).font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }

    // MARK: Words

    private var highest: Bool { picture.aggregate.reduce != .min && picture.aggregate.rank != .lowest }

    /// "wettest", "windiest", "hottest" — the word for the top of this measure, or its bottom.
    private func superlative(_ top: Bool) -> String {
        switch measure {
        case .rain: return top ? "wettest" : "driest"
        case .gust, .wind: return top ? "windiest" : "calmest"
        case .high: return top ? "hottest" : "coolest"
        case .low: return top ? "warmest" : "coldest"
        case .lightning: return top ? "stormiest" : "quietest"
        default: return top ? "highest" : "lowest"
        }
    }

    private func value(_ v: Double) -> String {
        if picture.aggregate.reduce == .count { return "\(Int(v.rounded())) days" }
        if measure == .lightning { return "\(Int(v).formatted()) strikes" }
        return measure.format(v)
    }

    private func signed(_ v: Double) -> String {
        (v >= 0.05 ? "+" : v <= -0.05 ? "−" : "±") + String(format: "%.1f°", abs(v))
    }

    private static let months = ["January", "February", "March", "April", "May", "June", "July",
                                 "August", "September", "October", "November", "December"]
    private func monthName(_ m: Int, long: Bool = true) -> String {
        long ? Self.months[m - 1] : String(Self.months[m - 1].prefix(3))
    }
    private func day(_ key: String, year: Bool = false) -> String { WeatherAlmanac.dayLabel(key, includeYear: year) }

    // MARK: Tiles

    private struct Tile: Hashable { var value: String; var label: String; var detail: String? = nil }

    private var tiles: some View {
        let list = tileList
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: max(1, list.count)),
                         alignment: .leading, spacing: 10) {
            ForEach(list, id: \.self) { tile in
                VStack(alignment: .leading, spacing: 3) {
                    Text(tile.label.uppercased())
                        .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary).lineLimit(1)
                    Text(tile.value)
                        .font(.system(size: 21, weight: .light, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(tile.detail ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
            }
        }
    }

    private var tileList: [Tile] {
        let p = picture
        switch p.kind {
        case .single:
            return [Tile(value: p.single.map(value) ?? "—", label: picture.aggregate.describe,
                         detail: p.singleCoverage < 0.95 ? "\(Int((p.singleCoverage * 100).rounded()))% of days recorded" : nil)]

        case .yearToDate:
            guard let current = p.running.last else { return [] }
            let today = ReportPicture.dayOfYear(p.recordEnd)
            var out = [Tile(value: value(current.total), label: "\(current.year) so far", detail: "through \(day(p.recordEnd))")]
            if today < p.usualRunning.count {
                let usual = p.usualRunning[today], diff = current.total - usual
                out.append(Tile(value: (diff >= 0 ? "+" : "−") + value(abs(diff)), label: "vs usual by now",
                                detail: usual > 0 ? "\(Int((current.total / usual * 100).rounded()))% of the usual \(value(usual))" : nil))
            }
            if let end = p.usualRunning.last { out.append(Tile(value: value(end), label: "A usual year", detail: "the full years' average")) }
            return out

        case .monthOfYear:
            let ranked = p.usualByMonth.enumerated().compactMap { k, v in v.map { (k + 1, $0) } }.sorted { $0.1 > $1.1 }
            guard let top = ranked.first, let bottom = ranked.last else { return [] }
            let spread = (1...12).compactMap { m -> (Int, Double)? in
                let vs = p.months.filter { $0.month == m && $0.isWhole }.compactMap(\.value)
                guard let hi = vs.max(), let lo = vs.min() else { return nil }
                return (m, hi - lo)
            }.max { $0.1 < $1.1 }
            var out = [Tile(value: monthName(top.0), label: "\(superlative(true)) month", detail: "usually \(value(top.1))"),
                       Tile(value: monthName(bottom.0), label: "\(superlative(false)) month", detail: "usually \(value(bottom.1))")]
            if let spread { out.append(Tile(value: monthName(spread.0), label: "Least predictable", detail: "years \(value(spread.1)) apart")) }
            return out

        case .monthGrid:
            let ranked = rankedMonths
            guard let lead = ranked.first else { return [] }
            var out = [Tile(value: "\(monthName(lead.month)) \(lead.year)", label: "\(superlative(highest)) month",
                            detail: lead.value.map(value))]
            if measure.accumulates, let v = lead.value, let usual = p.usualByMonth[lead.month - 1], usual > 0 {
                out.append(Tile(value: String(format: "%.1f×", v / usual), label: "A usual \(monthName(lead.month))",
                                detail: "usually \(value(usual))"))
            } else if let d = lead.day {
                out.append(Tile(value: day(d, year: true), label: "The day of it", detail: lead.dayValue.map(value)))
            }
            if ranked.count > 1 {
                let next = ranked[1]
                out.append(Tile(value: "\(monthName(next.month)) \(next.year)", label: "Next \(superlative(highest))",
                                detail: next.value.map(value)))
            }
            return out

        case .departureGrid:
            var out: [Tile] = []
            if let current = p.years.last, let v = current.value {
                out.append(Tile(value: signed(v), label: "\(current.year)\(current.isWhole ? "" : " so far")",
                                detail: "\(measure.name.lowercased())s vs normal"))
            }
            if let last = p.years.dropLast().last(where: \.isWhole), let v = last.value {
                out.append(Tile(value: signed(v), label: String(last.year), detail: "\(measure.name.lowercased())s vs normal"))
            }
            if let month = p.months.last(where: { $0.isWhole && $0.departure != nil }), let v = month.departure {
                out.append(Tile(value: signed(v), label: "\(monthName(month.month)) \(month.year)", detail: "the last full month"))
            }
            return out

        case .extremes:
            let seen = p.seasons.filter { $0.isSeen && !$0.isRunning }
            guard let record = (highest ? seen.max { ($0.value ?? 0) < ($1.value ?? 0) } : seen.min { ($0.value ?? 0) < ($1.value ?? 0) }),
                  let rv = record.value, let rd = record.day else { return [] }
            var out = [Tile(value: value(rv), label: "\(superlative(highest)) on record", detail: day(rd, year: true))]
            let positions = seen.compactMap { s in s.day.flatMap { DayKey.distance(from: s.windowStart, to: $0) } }.sorted()
            if !positions.isEmpty, let anchor = seen.first?.windowStart {
                let at = { (i: Int) in DayKey.step(anchor, by: i).map { day($0) } ?? "" }
                out.append(Tile(value: "~" + at(positions[positions.count / 2]),
                                label: "Usually the \(superlative(highest))",
                                detail: positions.count > 1 ? "seasons from \(at(positions.first!)) to \(at(positions.last!))" : nil))
            }
            if let current = p.seasons.last {
                if current.isSeen, let v = current.value, let d = current.day {
                    out.append(Tile(value: value(v), label: current.label, detail: day(d) + (current.isRunning ? ", so far" : "")))
                } else {
                    out.append(Tile(value: "not yet", label: current.label))
                }
            }
            return out
        }
    }

    /// Whole months, in the order asked: wettest first, or driest.
    private var rankedMonths: [ReportPicture.Month] {
        let whole = picture.months.filter { $0.isWhole && $0.value != nil }
        return whole.sorted { highest ? ($0.value ?? 0) > ($1.value ?? 0) : ($0.value ?? 0) < ($1.value ?? 0) }
    }

    private var note: String {
        switch picture.kind {
        case .single: return "Every day on record that fits the question."
        case .yearToDate: return "Added up from January 1. Every year is read at the same date, so a year still running is compared with where the others were by now. A year the record opened partway through starts where the record does."
        case .monthOfYear: return "Each dot is one month in one year; the bar is the usual. Months the station didn't see whole are left out."
        case .monthGrid: return "Every month on record, darker for more. The three \(superlative(highest)) are outlined; dashed months the station didn't fully see."
        case .departureGrid: return "Each month against normal for the same dates, so a year missing its winter isn't read as a hot one. Warmer red, cooler blue. Grey year figures are partial years."
        case .extremes:
            let unit = picture.aggregate.reduce == .min ? "night" : "day"
            return "One row per season. The dot is the \(superlative(highest)) \(unit), on its date\(picture.line != nil ? "; the band runs from the first \(lineName) to the last" : "")."
        }
    }

    private var lineName: String {
        guard let line = picture.line else { return "" }
        return picture.aggregate.reduce == .min ? "freeze" : "\(Int(line))° day"
    }

    // MARK: Drawing

    private let ink = Color.primary
    private let ink2 = Color.secondary
    private let ink3 = Color.primary.opacity(0.42)
    private let rule = Color.primary.opacity(0.1)
    private let warm = Color(red: 0.86, green: 0.40, blue: 0.22)
    private let cool = Color.accentColor

    private func text(_ string: String, size: CGFloat = 11, weight: Font.Weight = .regular, color: Color? = nil) -> Text {
        Text(string).font(.system(size: size, weight: weight).monospacedDigit()).foregroundStyle(color ?? ink2)
    }

    private var gridYears: [Int] { Array(Set(picture.months.map(\.year))).sorted() }

    private var height: CGFloat {
        switch picture.kind {
        case .yearToDate: return 16 + (narrow ? 200 : 260) + 26
        case .monthOfYear: return 14 + (narrow ? 200 : 240) + 30
        case .monthGrid, .departureGrid: return 22 + CGFloat(gridYears.count) * (narrow ? 30 : 38) + 8
        case .extremes: return 26 + CGFloat(picture.seasons.count) * 44 + 6
        case .single: return 0
        }
    }

    private func draw(_ context: inout GraphicsContext, _ W: CGFloat) {
        switch picture.kind {
        case .yearToDate: drawRunning(&context, W)
        case .monthOfYear: drawMonthOfYear(&context, W)
        case .monthGrid, .departureGrid: drawGrid(&context, W)
        case .extremes: drawExtremes(&context, W)
        case .single: break
        }
    }

    private func hline(_ context: inout GraphicsContext, _ x1: CGFloat, _ x2: CGFloat, _ y: CGFloat,
                       _ color: Color, dash: [CGFloat] = [], width: CGFloat = 1) {
        var p = Path(); p.move(to: CGPoint(x: x1, y: y)); p.addLine(to: CGPoint(x: x2, y: y))
        context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, dash: dash))
    }

    // Running totals

    private struct RunningLayout { var L: CGFloat, R: CGFloat, top: CGFloat, ph: CGFloat, W: CGFloat, max: Double
        func x(_ day: Int) -> CGFloat { L + CGFloat(day) / 364 * (W - L - R) }
        func y(_ v: Double) -> CGFloat { top + CGFloat(1 - v / max) * ph }
    }

    private func runningLayout(_ W: CGFloat) -> RunningLayout {
        let peak = max(picture.running.map(\.total).max() ?? 1, picture.usualRunning.last ?? 0)
        let step = niceStep(peak / 5)
        return RunningLayout(L: 44, R: narrow ? 50 : 76, top: 16, ph: narrow ? 200 : 260, W: W,
                             max: max(step, (peak / step).rounded(.up) * step))
    }

    private func niceStep(_ rough: Double) -> Double {
        guard rough > 0 else { return 1 }
        let power = pow(10, log10(rough).rounded(.down))
        return [1.0, 2, 5, 10].map { $0 * power }.first { $0 >= rough } ?? power * 10
    }

    private func drawRunning(_ context: inout GraphicsContext, _ W: CGFloat) {
        let f = runningLayout(W)
        let step = niceStep(f.max / 5)
        for v in stride(from: 0, through: f.max + step * 0.01, by: step) {
            hline(&context, f.L, W - f.R, f.y(v), rule)
            context.draw(text(value(v).replacingOccurrences(of: ".00", with: ""), color: ink3), at: CGPoint(x: f.L - 6, y: f.y(v)), anchor: .trailing)
        }
        for (k, start) in YearAxis.monthStart.enumerated() where !narrow || k % 2 == 0 {
            context.draw(text(YearAxis.months[k].name, color: ink3), at: CGPoint(x: f.x(start) + 3, y: f.top + f.ph + 6), anchor: .topLeading)
        }
        if !picture.usualRunning.isEmpty {
            var p = Path()
            for (i, v) in picture.usualRunning.enumerated() {
                let pt = CGPoint(x: f.x(i), y: f.y(v)); if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            context.stroke(p, with: .color(ink3), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        let current = picture.running.last
        for run in picture.running where run.isComplete || run.id == current?.id {
            let isCurrent = run.id == current?.id
            var p = Path()
            for (i, v) in run.values.enumerated() {
                let pt = CGPoint(x: f.x(run.start + i), y: f.y(v)); if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            context.stroke(p, with: .color(isCurrent ? Color.accentColor : ink3.opacity(0.8)), lineWidth: isCurrent ? 2.5 : 1.2)
            let end = CGPoint(x: isCurrent ? f.x(run.start + run.values.count - 1) + 6 : W - f.R + 6, y: f.y(run.total))
            context.draw(text(isCurrent ? "\(run.year) · \(value(run.total))" : String(run.year),
                              weight: isCurrent ? .semibold : .regular, color: isCurrent ? ink : ink3),
                         at: end, anchor: .leading)
        }
        let today = ReportPicture.dayOfYear(picture.recordEnd)
        var t = Path(); t.move(to: CGPoint(x: f.x(today), y: f.top)); t.addLine(to: CGPoint(x: f.x(today), y: f.top + f.ph))
        context.stroke(t, with: .color(ink3), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        if let pointer, pointer.x >= f.L, pointer.x <= W - f.R {
            let d = Int(((pointer.x - f.L) / (W - f.L - f.R) * 364).rounded())
            var g = Path(); g.move(to: CGPoint(x: f.x(d), y: f.top)); g.addLine(to: CGPoint(x: f.x(d), y: f.top + f.ph))
            context.stroke(g, with: .color(ink3), lineWidth: 1)
        }
    }

    // Month of the year

    private func drawMonthOfYear(_ context: inout GraphicsContext, _ W: CGFloat) {
        let L: CGFloat = 40, R: CGFloat = 10, top: CGFloat = 14, ph: CGFloat = narrow ? 200 : 240
        let whole = picture.months.filter { $0.isWhole }
        let peak = whole.compactMap(\.value).max() ?? 1
        let step = niceStep(peak / 5), hi = max(step, (peak / step).rounded(.up) * step)
        let slot = (W - L - R) / 12
        let y = { (v: Double) in top + CGFloat(1 - v / hi) * ph }
        for v in stride(from: 0, through: hi + step * 0.01, by: step) {
            hline(&context, L, W - R, y(v), rule)
            context.draw(text(value(v).replacingOccurrences(of: ".00", with: ""), color: ink3), at: CGPoint(x: L - 6, y: y(v)), anchor: .trailing)
        }
        let currentYear = DayKey.year(of: picture.recordEnd)
        let years = gridYears
        for m in 1...12 {
            let cx = L + slot * (CGFloat(m) - 0.5), bw = min(40, slot * 0.62)
            if let usual = picture.usualByMonth[m - 1] {
                let rect = CGRect(x: cx - bw / 2, y: y(usual), width: bw, height: y(0) - y(usual))
                context.fill(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4).path(in: rect), with: .color(Color.accentColor.opacity(0.14)))
                hline(&context, cx - bw / 2, cx + bw / 2, y(usual), Color.accentColor, width: 2)
            }
            for cell in whole where cell.month == m {
                guard let v = cell.value else { continue }
                let isCurrent = cell.year == currentYear
                let spread = CGFloat((years.firstIndex(of: cell.year) ?? 0)) - CGFloat(years.count - 1) / 2
                let pt = CGPoint(x: cx + (isCurrent ? 0 : spread * bw / CGFloat(max(4, years.count + 2))), y: y(v))
                let r: CGFloat = isCurrent ? 4.5 : 3
                context.fill(Path(ellipseIn: CGRect(x: pt.x - r - 1.5, y: pt.y - r - 1.5, width: (r + 1.5) * 2, height: (r + 1.5) * 2)), with: .color(Color.windowBackground))
                context.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)), with: .color(isCurrent ? ink : ink3))
            }
            context.draw(text(narrow ? String(monthName(m).prefix(1)) : monthName(m, long: false)), at: CGPoint(x: cx, y: top + ph + 8), anchor: .top)
        }
    }

    // A grid of months

    private struct GridLayout { var L: CGFloat, R: CGFloat, top: CGFloat, rowH: CGFloat, cw: CGFloat }

    private func gridLayout(_ W: CGFloat) -> GridLayout {
        let L: CGFloat = 46, R: CGFloat = picture.kind == .departureGrid ? 64 : 10
        return GridLayout(L: L, R: R, top: 22, rowH: narrow ? 30 : 38, cw: (W - L - R) / 12)
    }

    private func cellColor(_ cell: ReportPicture.Month) -> Color {
        if picture.kind == .departureGrid {
            guard let d = cell.departure else { return .clear }
            return (d > 0 ? warm : cool).opacity(0.12 + 0.75 * min(1, abs(d) / 5))
        }
        let all = picture.months.filter(\.isWhole).compactMap(\.value)
        let lo = all.min() ?? 0, hi = all.max() ?? 1
        guard let v = cell.value, hi > lo else { return .clear }
        let t = measure.accumulates ? v / hi : (v - lo) / (hi - lo)
        return Color.accentColor.opacity(0.08 + 0.8 * min(1, max(0, t)))
    }

    private func cellLabel(_ cell: ReportPicture.Month) -> String {
        if picture.kind == .departureGrid { return cell.departure.map(signed) ?? "" }
        guard let v = cell.value else { return "" }
        if measure == .rain { return String(format: "%.1f", v) }
        if measure == .lightning { return Int(v).formatted() }
        return String(Int(v.rounded()))
    }

    private func drawGrid(_ context: inout GraphicsContext, _ W: CGFloat) {
        let f = gridLayout(W)
        let standouts = picture.kind == .departureGrid ? [] : Set(rankedMonths.prefix(3).map(\.id))
        for m in 1...12 {
            context.draw(text(narrow ? String(monthName(m).prefix(1)) : monthName(m, long: false), color: ink3),
                         at: CGPoint(x: f.L + f.cw * (CGFloat(m) - 0.5), y: f.top - 8), anchor: .center)
        }
        if picture.kind == .departureGrid {
            context.draw(text("year", color: ink3), at: CGPoint(x: W - f.R + 10, y: f.top - 8), anchor: .leading)
        }
        for (j, year) in gridYears.enumerated() {
            let yy = f.top + CGFloat(j) * f.rowH
            context.draw(text(String(year)), at: CGPoint(x: f.L - 8, y: yy + f.rowH / 2), anchor: .trailing)
            for cell in picture.months where cell.year == year {
                let rect = CGRect(x: f.L + f.cw * CGFloat(cell.month - 1) + 1.5, y: yy + 1.5, width: f.cw - 3, height: f.rowH - 3)
                let shape = RoundedRectangle(cornerRadius: 4).path(in: rect)
                if cell.isWhole {
                    context.fill(shape, with: .color(cellColor(cell)))
                    if standouts.contains(cell.id) { context.stroke(shape, with: .color(ink), lineWidth: 1.5) }
                } else {
                    context.stroke(shape, with: .color(rule), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
                if f.cw > 30 {
                    context.draw(text(cellLabel(cell), size: 10.5, color: cell.isWhole ? ink : ink3),
                                 at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                }
            }
            if picture.kind == .departureGrid, let summary = picture.years.first(where: { $0.year == year }), let v = summary.value {
                context.draw(text(signed(v), weight: .semibold, color: summary.isWhole ? ink : ink3),
                             at: CGPoint(x: W - f.R + 10, y: yy + f.rowH / 2), anchor: .leading)
            }
        }
    }

    // Season extremes

    private struct ExtremesLayout { var L: CGFloat, R: CGFloat, top: CGFloat, rowH: CGFloat, W: CGFloat, n: Int
        func x(_ i: Int) -> CGFloat { L + CGFloat(i) / CGFloat(max(1, n - 1)) * (W - L - R) }
    }

    private func extremesLayout(_ W: CGFloat) -> ExtremesLayout {
        let wide = picture.seasons.contains { $0.label.count > 4 }
        return ExtremesLayout(L: wide ? (narrow ? 112 : 132) : 60, R: narrow ? 92 : 112, top: 26, rowH: 44, W: W, n: picture.windowLength)
    }

    private func offset(_ season: ReportPicture.Season, _ key: String?) -> Int? {
        guard let key, let d = DayKey.distance(from: season.windowStart, to: key), d >= 0, d < picture.windowLength else { return nil }
        return d
    }

    private var extremeColor: Color { picture.aggregate.reduce == .min ? cool : warm }

    private func drawExtremes(_ context: inout GraphicsContext, _ W: CGFloat) {
        let f = extremesLayout(W)
        let rows = picture.seasons
        guard let anchor = rows.first?.windowStart else { return }
        let height = f.top + CGFloat(rows.count) * f.rowH
        // months across the top
        var cursor = anchor
        while let d = DayKey.distance(from: anchor, to: cursor), d < picture.windowLength {
            var line = Path(); line.move(to: CGPoint(x: f.x(d), y: f.top - 6)); line.addLine(to: CGPoint(x: f.x(d), y: height))
            context.stroke(line, with: .color(rule), lineWidth: 1)
            context.draw(text(monthName(Int(cursor.dropFirst(5).prefix(2)) ?? 1, long: false), color: ink3),
                         at: CGPoint(x: f.x(d) + 4, y: f.top - 10), anchor: .leading)
            guard let next = DayKey.step(cursor, by: 31).map({ String($0.prefix(7)) + "-01" }) else { break }
            cursor = next
        }
        for (j, season) in rows.enumerated() {
            let cy = f.top + CGFloat(j) * f.rowH + f.rowH / 2
            context.draw(text(season.label), at: CGPoint(x: f.L - 12, y: cy), anchor: .trailing)
            hline(&context, f.L, W - f.R, cy, rule)
            guard season.isSeen else {
                let words = picture.aggregate.reduce == .min ? "winter" : "summer"
                context.draw(text(season.isRunning ? "this \(words) hasn't started yet" : "this \(words) isn't on record", color: ink3),
                             at: CGPoint(x: f.L + 8, y: cy - 8), anchor: .leading)
                continue
            }
            if let a = offset(season, season.firstPast), let b = offset(season, season.lastPast) {
                let rect = CGRect(x: f.x(a) - 3, y: cy - 7, width: max(6, f.x(b) - f.x(a) + 6), height: 14)
                context.fill(RoundedRectangle(cornerRadius: 7).path(in: rect), with: .color(extremeColor.opacity(0.2)))
            }
            if let i = offset(season, season.day), let v = season.value, let d = season.day {
                let pt = CGPoint(x: f.x(i), y: cy)
                context.fill(Path(ellipseIn: CGRect(x: pt.x - 8, y: pt.y - 8, width: 16, height: 16)), with: .color(Color.windowBackground))
                context.fill(Path(ellipseIn: CGRect(x: pt.x - 6, y: pt.y - 6, width: 12, height: 12)), with: .color(extremeColor))
                let right = pt.x < W - f.R - 110
                context.draw(text("\(value(v)) \(day(d))\(season.isRunning ? " so far" : "")", weight: .semibold, color: ink),
                             at: CGPoint(x: pt.x + (right ? 11 : -11), y: cy), anchor: right ? .leading : .trailing)
            }
            if picture.line != nil {
                let n = season.pastCount
                let words = picture.aggregate.reduce == .min ? (n == 1 ? "freeze" : "freezes") : "at \(Int(picture.line ?? 0))°+"
                context.draw(text("\(n) \(words)", color: ink3), at: CGPoint(x: W - f.R + 12, y: cy), anchor: .leading)
            }
        }
    }

    // MARK: Pointing

    private struct Hit { var view: AnyView; var opens: (WeatherGrain, String)? }

    #if os(macOS)
    private static let tapWord = "click"
    #else
    private static let tapWord = "tap"
    #endif

    private func lines(_ strings: [String?], dim: Int = 1) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(strings.compactMap { $0 }.enumerated()), id: \.offset) { i, s in
                Text(s).font(i < dim ? .caption : .caption2).foregroundStyle(i < dim ? Color.primary : Color.secondary)
            }
        }.monospacedDigit())
    }

    private func hit(_ point: CGPoint) -> Hit? {
        let W = width
        switch picture.kind {
        case .yearToDate:
            let f = runningLayout(W)
            guard point.x >= f.L, point.x <= W - f.R else { return nil }
            let d = max(0, min(364, Int(((point.x - f.L) / (W - f.L - f.R) * 364).rounded())))
            let label = YearAxis.label(d)
            var rows: [String?] = ["by \(label)"]
            for run in picture.running where run.isComplete || run.id == picture.running.last?.id {
                if let v = run.value(onDay: d) { rows.append("\(run.year): \(value(v))") }
            }
            if d < picture.usualRunning.count { rows.append("usual \(value(picture.usualRunning[d]))") }
            return Hit(view: lines(rows, dim: 0), opens: nil)

        case .monthOfYear:
            let L: CGFloat = 40, R: CGFloat = 10
            let m = Int((point.x - L) / ((W - L - R) / 12)) + 1
            guard (1...12).contains(m), point.x >= L else { return nil }
            let cells = picture.months.filter { $0.month == m && $0.isWhole && $0.value != nil }
            var rows: [String?] = [monthName(m)]
            if let usual = picture.usualByMonth[m - 1] { rows.append("usually \(value(usual))") }
            for c in cells { rows.append("\(c.year): \(value(c.value!))" + (c.day.map { measure == .rain ? " · wettest \(day($0))" : " · \(day($0))" } ?? "")) }
            return Hit(view: lines(rows, dim: 1), opens: nil)

        case .monthGrid, .departureGrid:
            let f = gridLayout(W)
            let m = Int((point.x - f.L) / f.cw) + 1, j = Int((point.y - f.top) / f.rowH)
            guard point.x >= f.L, (1...12).contains(m), j >= 0, j < gridYears.count,
                  let cell = picture.months.first(where: { $0.year == gridYears[j] && $0.month == m }) else { return nil }
            var rows: [String?] = ["\(monthName(m)) \(cell.year)"]
            if picture.kind == .departureGrid {
                rows.append(cell.departure.map { "\(measure.name.lowercased())s \(signed($0)) vs normal" })
                rows.append(cell.value.map { "averaged \(value($0))" })
            } else {
                rows.append(cell.value.map { measure == .rain ? "\(value($0)) on \(cell.days) days" : value($0) })
                if let d = cell.day, let v = cell.dayValue { rows.append("\(superlative(highest)) day \(day(d)): \(value(v))") }
            }
            if !cell.isWhole { rows.append("only \(Int((cell.coverage * 100).rounded()))% of the month recorded") }
            rows.append("\(Self.tapWord) to open the month")
            return Hit(view: lines(rows, dim: 1), opens: (.month, String(format: "%04d-%02d-01", cell.year, m)))

        case .extremes:
            let f = extremesLayout(W)
            let j = Int((point.y - f.top) / f.rowH)
            guard picture.seasons.indices.contains(j), point.x >= f.L, point.x <= W - f.R else { return nil }
            let season = picture.seasons[j]
            guard season.isSeen else { return nil }
            if let i = offset(season, season.day), abs(f.x(i) - point.x) < 12, let d = season.day, let v = season.value {
                return Hit(view: lines(["\(day(d, year: true)) · \(value(v))",
                                        "the \(superlative(highest)) \(picture.aggregate.reduce == .min ? "night" : "day")\(season.isRunning ? " so far" : "")",
                                        "\(Self.tapWord) to open the day"], dim: 1), opens: (.day, d))
            }
            if let a = season.firstPast, let b = season.lastPast {
                return Hit(view: lines(["\(lineName.capitalized)s: \(day(a)) – \(day(b))", "\(season.pastCount) in all"], dim: 1), opens: nil)
            }
            return nil

        case .single:
            return nil
        }
    }

    @ViewBuilder private var tip: some View {
        if let pointer, width > 0, let h = hit(pointer) {
            let flip = pointer.x + 12 + tipSize.width > width - 8
            h.view
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.windowBackground)
                    .shadow(color: .black.opacity(0.18), radius: 7, y: 2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { tipSize = $0 }
                .offset(x: max(4, flip ? pointer.x - tipSize.width - 12 : pointer.x + 12),
                        y: min(max(0, pointer.y + 14), max(0, height - tipSize.height)))
                .allowsHitTesting(false)
        }
    }

    // MARK: Legend

    @ViewBuilder private var legend: some View {
        HStack(spacing: 16) {
            switch picture.kind {
            case .yearToDate:
                key(Capsule().fill(Color.accentColor).frame(width: 16, height: 3), picture.running.last.map { String($0.year) } ?? "")
                key(Capsule().fill(ink3).frame(width: 16, height: 2), "each full year")
                key(Capsule().stroke(ink3, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 16, height: 2), "usual")
            case .monthOfYear:
                key(RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.3)).frame(width: 14, height: 10), "usual")
                key(Circle().fill(ink3).frame(width: 7, height: 7), "each year")
                if let y = DayKey.year(of: picture.recordEnd) { key(Circle().fill(ink).frame(width: 9, height: 9), String(y)) }
            case .extremes:
                key(Circle().fill(extremeColor).frame(width: 10, height: 10), "the \(superlative(highest)) \(picture.aggregate.reduce == .min ? "night" : "day")")
                if picture.line != nil {
                    key(Capsule().fill(extremeColor.opacity(0.3)).frame(width: 22, height: 10), "first to last \(lineName)")
                }
            case .monthGrid, .departureGrid:
                Text("\(Self.tapWord) a month to open it").font(.caption2)
            case .single:
                EmptyView()
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func key<S: View>(_ mark: S, _ label: String) -> some View {
        HStack(spacing: 6) { mark; Text(label) }
    }
}
