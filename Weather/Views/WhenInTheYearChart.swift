//
//  WhenInTheYearChart.swift
//
//  One chart for "when in the year": how often it happens on each date, the
//  readings themselves on the same dates, or the count season by season.
//
//  THE PICTURE CARRIES THE ANSWER. The dates are written on their own marks — a
//  solid pair for the answer, a dashed pair for the other — so the chart can be
//  read without the sentence, and the gap between the two pairs is where the
//  weather comes and goes ("on and off": a 90° spike ahead of a front in March,
//  a cool morning in September and then the 90s again). No shaded bands: the
//  curve already shows where it becomes the norm.
//
//  ONE CANVAS. Every mark and label is drawn in one pass, and the readout is a
//  single overlay driven by where the pointer is — the same reason the old year
//  grid moved to a canvas: hundreds of small views cost more than the picture.
//

import SwiftUI
import WeatherKit

/// What the chart shows. A menu, not a segmented control — there will be more of these.
enum ExploreChartView: String, CaseIterable, Identifiable {
    case often = "How often"
    case readings = "Readings"
    case years = "Year by year"
    var id: String { rawValue }
}

struct WhenInTheYearChart: View {
    let shape: WhenInTheYear
    let question: ExploreQuestion
    let view: ExploreChartView
    /// The archive's last day — "today" for the year-by-year split.
    let recordEnd: String
    var openDay: (String) -> Void = { _ in }

    @State private var width: CGFloat = 0
    @State private var pointer: CGPoint?
    @State private var tipSize: CGSize = .zero

    private var narrow: Bool { width < 560 }

    #if os(macOS)
    private static let tapWord = "click"
    #else
    private static let tapWord = "tap"
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    guard size.width > 0 else { return }
                    switch view {
                    case .years: drawYears(&context, layout(size.width))
                    default: drawDates(&context, layout(size.width))
                    }
                }
                tip
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): pointer = point
                case .ended: pointer = nil
                @unknown default: pointer = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in tapped(at: point) }
            #if !os(macOS)
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { drag in
                guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                pointer = drag.location
            })
            #endif
            legend
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(question.asks) \(view == .years ? "Count by season" : view == .readings ? "Daily readings by date" : "Share of nearby days that matched, by date")")
    }

    /// Opens the day under a dot. Without a pointer to hover, a tap elsewhere
    /// holds the readout, and a second tap there lets it go.
    private func tapped(at point: CGPoint) {
        if view == .readings, let dot = nearestDot(to: point, layout(width)) {
            openDay(dot.day)
            return
        }
        #if !os(macOS)
        if let held = pointer, abs(held.x - point.x) < 6 { pointer = nil } else { pointer = point }
        #endif
    }

    // MARK: Layout

    private var height: CGFloat {
        switch view {
        case .often: return 52 + (narrow ? 140 : 160) + 24
        case .readings: return 52 + (narrow ? 140 : 210) + 24
        case .years: return 22 + (narrow ? 150 : 190) + 34
        }
    }

    fileprivate struct Layout {
        var W: CGFloat, L: CGFloat, R: CGFloat, top: CGFloat, ph: CGFloat
        var count: Int
        var axisY: CGFloat { top + ph }
        func x(_ slot: Double) -> CGFloat { L + CGFloat(slot / Double(max(1, count - 1))) * (W - L - R) }
        func slot(at px: CGFloat) -> Int {
            let raw = (px - L) / max(1, W - L - R) * CGFloat(count - 1)
            return max(0, min(count - 1, Int(raw.rounded())))
        }
    }

    private func layout(_ W: CGFloat) -> Layout {
        let narrow = W < 560
        switch view {
        case .years:
            return Layout(W: W, L: 40, R: 10, top: 22, ph: narrow ? 150 : 190, count: shape.counts.count)
        case .readings:
            return Layout(W: W, L: narrow ? 34 : 46, R: 10, top: 52, ph: narrow ? 140 : 210, count: shape.slotCount)
        case .often:
            return Layout(W: W, L: narrow ? 34 : 64, R: 10, top: 52, ph: narrow ? 140 : 160, count: shape.slotCount)
        }
    }

    // MARK: Colours

    private let ink = Color.primary
    private let ink2 = Color.secondary
    private let ink3 = Color.primary.opacity(0.42)
    private let rule = Color.primary.opacity(0.1)
    private var accent: Color { .accentColor }
    private var accentFill: Color { Color.accentColor.opacity(0.14) }

    private func text(_ string: String, size: CGFloat = 11, weight: Font.Weight = .regular,
                      color: Color? = nil, italic: Bool = false) -> Text {
        var t = Text(string).font(.system(size: size, weight: weight).monospacedDigit())
        if italic { t = t.italic() }
        return t.foregroundStyle(color ?? ink2)
    }

    // MARK: How often and Readings

    /// The readings' vertical scale, or nil under How often.
    private struct Scale {
        var lo: Double, hi: Double, step: Double
        func y(_ v: Double, _ f: Layout) -> CGFloat { f.top + CGFloat(1 - (v - lo) / max(0.0001, hi - lo)) * f.ph }
    }

    private func readingScale(_ r: WhenInTheYear.Readings) -> Scale {
        var values: [Double] = []
        for series in [r.low, r.high, r.current, r.previous] { values += series.compactMap { $0 } }
        if let threshold = r.threshold { values.append(threshold) }
        let minimum: Double = values.min() ?? 0
        let maximum: Double = values.max() ?? 1
        if r.measure.unit == "°" {
            let lo = (minimum / 10).rounded(.down) * 10, hi = max(lo + 10, (maximum / 10).rounded(.up) * 10)
            return Scale(lo: lo, hi: hi, step: hi - lo > 60 && narrow ? 20 : 10)
        }
        if r.measure == .rain {
            let hi = max(0.5, (maximum * 2).rounded(.up) / 2)
            return Scale(lo: 0, hi: hi, step: hi > 3 ? 1 : 0.5)
        }
        let floor: Double = r.measure.accumulates ? 0 : minimum
        let rough: Double = max(0.0001, (maximum - floor) / 4)
        let power: Double = pow(10, log10(rough).rounded(.down))
        let steps: [Double] = [power, power * 2, power * 5, power * 10]
        let step: Double = steps.first { $0 >= rough } ?? power * 10
        let lo = r.measure.accumulates ? 0 : (minimum / step).rounded(.down) * step
        return Scale(lo: lo, hi: max(lo + step, (maximum / step).rounded(.up) * step), step: step)
    }

    private func tickLabel(_ v: Double, _ measure: Measure) -> String {
        switch measure {
        case .rain: return String(format: v == v.rounded() ? "%.0f\"" : "%.1f\"", v)
        case .lightning: return Int(v).formatted()
        default: return measure.format(v)
        }
    }

    private struct Dot { var point: CGPoint; var day: String; var value: Double }

    private func dots(_ f: Layout) -> [Dot] {
        guard view == .readings, let r = shape.readings else { return [] }
        let scale = readingScale(r)
        var out: [Dot] = []
        for (values, season) in [(r.previous, shape.previous), (r.current, shape.current)] {
            guard let season else { continue }
            for (slot, value) in values.enumerated() {
                // A rain chart draws only the days it rained; a dry day at 0" is every other dot.
                guard let value, !(r.measure.accumulates && value <= 0.0),
                      let day = shape.day(slot, season: season.year) else { continue }
                out.append(Dot(point: CGPoint(x: f.x(Double(slot)), y: scale.y(value, f)), day: day, value: value))
            }
        }
        return out
    }

    private func nearestDot(to point: CGPoint, _ f: Layout) -> Dot? {
        dots(f).filter { hypot($0.point.x - point.x, $0.point.y - point.y) < 8 }
            .min { hypot($0.point.x - point.x, $0.point.y - point.y) < hypot($1.point.x - point.x, $1.point.y - point.y) }
    }

    /// The two pairs of dates, and which one answers.
    private enum PairKey { case outer, inner }

    private var answerPair: (dates: ClosedRange<Int>, answer: ExploreQuestion.Answer)? { shape.answer(to: question) }

    private var pairs: [(key: PairKey, dates: ClosedRange<Int>, isAnswer: Bool)] {
        guard shape.kind == .season else { return [] }
        let answeredBy: PairKey? = answerPair.map { $0.answer == .possible ? .outer : .inner }
        return [(PairKey.outer, shape.outer), (.inner, shape.inner)].compactMap { key, dates in
            dates.map { (key, $0, key == answeredBy) }
        }
    }

    private func drawDates(_ context: inout GraphicsContext, _ f: Layout) {
        let readings = view == .readings ? shape.readings : nil
        let scale = readings.map(readingScale)
        let y: (Double) -> CGFloat = { v in scale.map { $0.y(v, f) } ?? (f.top + CGFloat(1 - v) * f.ph) }

        // The question's own dates, under everything.
        if shape.kind == .scoped, let scope = shape.scope {
            let a = f.x(Double(scope.lowerBound)), b = f.x(Double(scope.upperBound))
            context.fill(Path(CGRect(x: a, y: f.top, width: b - a, height: f.ph)), with: .color(Color.accentColor.opacity(0.07)))
            context.draw(text(question.query.scope?.name ?? "", weight: .semibold, color: ink),
                         at: CGPoint(x: (a + b) / 2, y: f.top - 6), anchor: .bottom)
        }

        // Gridlines. Under How often the axis is a share of days, in words.
        let ticks: [Double]
        if let scale {
            ticks = Array(stride(from: scale.lo, through: scale.hi + scale.step * 0.01, by: scale.step))
        } else {
            ticks = [0, 0.25, 0.5, 0.75, 1]
        }
        for v in ticks {
            let half = scale == nil && v == 0.5
            var line = Path(); line.move(to: CGPoint(x: f.L, y: y(v))); line.addLine(to: CGPoint(x: f.W - f.R, y: y(v)))
            context.stroke(line, with: .color(half ? ink3 : rule), style: StrokeStyle(lineWidth: 1, dash: half ? [4, 4] : []))
            let label: String
            if let readings {
                label = tickLabel(v, readings.measure)
            } else {
                label = (narrow ? [0: "0", 0.25: "¼", 0.5: "½", 0.75: "¾", 1: "all"]
                                : [0: "never", 0.25: "1 in 4", 0.5: "half", 0.75: "3 in 4", 1: "every day"])[v] ?? ""
            }
            context.draw(text(label, color: ink3), at: CGPoint(x: f.L - 6, y: y(v)), anchor: .trailing)
        }

        if let readings, let scale {
            drawReadings(&context, f, readings, scale)
        } else {
            // The curve, filled to the floor.
            var area = Path()
            area.move(to: CGPoint(x: f.x(0), y: y(0)))
            for (i, v) in shape.share.enumerated() { area.addLine(to: CGPoint(x: f.x(Double(i)), y: y(v ?? 0))) }
            area.addLine(to: CGPoint(x: f.x(Double(f.count - 1)), y: y(0)))
            area.closeSubpath()
            context.fill(area, with: .color(accentFill))
            context.stroke(polyline(shape.share, f, y), with: .color(accent), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }

        // Months.
        for (k, mark) in shape.monthMarks.enumerated() {
            let px = f.x(Double(mark.slot))
            var tick = Path(); tick.move(to: CGPoint(x: px, y: f.axisY)); tick.addLine(to: CGPoint(x: px, y: f.axisY + 4))
            context.stroke(tick, with: .color(ink3), lineWidth: 1)
            if (!narrow || f.count < 220 || k % 2 == 0) && px < f.W - f.R - 24 {
                context.draw(text(mark.name, color: ink3), at: CGPoint(x: px + 3, y: f.axisY + 6), anchor: .topLeading)
            }
        }
        var axis = Path(); axis.move(to: CGPoint(x: f.L, y: f.axisY)); axis.addLine(to: CGPoint(x: f.W - f.R, y: f.axisY))
        context.stroke(axis, with: .color(ink3), lineWidth: 1)

        drawAnswer(&context, f)

        // The pointer's date.
        if let pointer, pointer.x >= f.L, pointer.x <= f.W - f.R {
            let px = f.x(Double(f.slot(at: pointer.x)))
            var guide = Path(); guide.move(to: CGPoint(x: px, y: f.top)); guide.addLine(to: CGPoint(x: px, y: f.axisY))
            context.stroke(guide, with: .color(ink3), lineWidth: 1)
        }
    }

    private func polyline(_ values: [Double?], _ f: Layout, _ y: (Double) -> CGFloat) -> Path {
        var path = Path()
        var on = false
        for (i, v) in values.enumerated() {
            guard let v else { on = false; continue }
            let point = CGPoint(x: f.x(Double(i)), y: y(v))
            if on { path.addLine(to: point) } else { path.move(to: point); on = true }
        }
        return path
    }

    private func drawReadings(_ context: inout GraphicsContext, _ f: Layout, _ r: WhenInTheYear.Readings, _ scale: Scale) {
        let y: (Double) -> CGFloat = { scale.y($0, f) }
        if !r.mean.isEmpty {
            // The middle 80%, drawn in pieces wherever the record is too thin for one.
            var band = Path()
            var run: [Int] = []
            func close() {
                guard run.count > 1 else { run = []; return }
                band.move(to: CGPoint(x: f.x(Double(run[0])), y: y(r.high[run[0]]!)))
                for i in run.dropFirst() { band.addLine(to: CGPoint(x: f.x(Double(i)), y: y(r.high[i]!))) }
                for i in run.reversed() { band.addLine(to: CGPoint(x: f.x(Double(i)), y: y(r.low[i]!))) }
                band.closeSubpath()
                run = []
            }
            for i in r.low.indices { if r.low[i] != nil && r.high[i] != nil { run.append(i) } else { close() } }
            close()
            context.fill(band, with: .color(accentFill))
            context.stroke(polyline(r.mean, f, y), with: .color(accent), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        if let threshold = r.threshold {
            var line = Path(); line.move(to: CGPoint(x: f.L, y: y(threshold))); line.addLine(to: CGPoint(x: f.W - f.R, y: y(threshold)))
            context.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: 1.25, dash: [5, 3]))
            context.draw(text(tickLabel(threshold, r.measure), weight: .semibold, color: ink),
                         at: CGPoint(x: f.W - f.R, y: y(threshold) - 3), anchor: .bottomTrailing)
        }
        let drawn = dots(f)
        for dot in drawn {
            let isCurrent = WhenInTheYearChart.season(of: dot.day, in: shape) == shape.current?.year
            let radius: CGFloat = isCurrent ? (narrow ? 1.7 : 2.2) : (narrow ? 1.4 : 1.8)
            context.fill(Path(ellipseIn: CGRect(x: dot.point.x - radius, y: dot.point.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(isCurrent ? ink : ink3))
        }
        // The last one on record, ringed and dated.
        if let last = shape.lastEver, let dot = drawn.last(where: { $0.day == last }) {
            context.stroke(Path(ellipseIn: CGRect(x: dot.point.x - 5, y: dot.point.y - 5, width: 10, height: 10)),
                           with: .color(ink), lineWidth: 1.5)
            let atEnd = dot.point.x > f.W - 130
            context.draw(text("\(short(DayKey.monthDay(of: last))) · \(r.measure == .lightning ? Int(dot.value).formatted() : r.measure.format(dot.value))", color: ink),
                         at: CGPoint(x: dot.point.x + (atEnd ? -8 : 8), y: dot.point.y - 6),
                         anchor: atEnd ? .bottomTrailing : .bottomLeading)
        }
    }

    static func season(of day: String, in shape: WhenInTheYear) -> Int? {
        guard let year = DayKey.year(of: day), let month = Int(day.dropFirst(5).prefix(2)) else { return nil }
        return month >= shape.startMonth ? year : year - 1
    }

    /// The pairs of dates, or the likeliest date, written on their own lines.
    private func drawAnswer(_ context: inout GraphicsContext, _ f: Layout) {
        func labelAt(_ px: CGFloat, _ y: CGFloat, _ string: String, bold: Bool) {
            let anchor: UnitPoint = px > f.W - f.R - 80 ? .bottomTrailing : px < f.L + 80 ? .bottomLeading : .bottom
            context.draw(text(string, weight: bold ? .semibold : .regular, color: bold ? ink : ink2),
                         at: CGPoint(x: px, y: y + 3), anchor: anchor)
        }
        switch shape.kind {
        case .season:
            let today = shape.through
            for pair in pairs {
                let ly = pair.key == .outer ? f.top - 26 : f.top - 10
                for slot in [pair.dates.lowerBound, pair.dates.upperBound] {
                    var line = Path(); line.move(to: CGPoint(x: f.x(Double(slot)), y: ly + 4)); line.addLine(to: CGPoint(x: f.x(Double(slot)), y: f.axisY))
                    context.stroke(line, with: .color(pair.isAnswer ? ink : ink2),
                                   style: StrokeStyle(lineWidth: pair.isAnswer ? 2 : 1.25, dash: pair.isAnswer ? [] : [3, 3]))
                }
                let approx = pair.key == .outer ? "~" : ""
                let a = short(shape.monthDay(pair.dates.lowerBound)), b = short(shape.monthDay(pair.dates.upperBound))
                let upcoming = today < pair.dates.lowerBound ? 0 : today < pair.dates.upperBound ? 1 : 0
                let xa = f.x(Double(pair.dates.lowerBound)), xb = f.x(Double(pair.dates.upperBound))
                if xb - xa < (narrow ? 90 : 170) {
                    let lead = pair.key == .outer ? (narrow ? "" : "possible ") : (narrow ? "most " : "most \(shape.noun) ")
                    labelAt((xa + xb) / 2, ly, "\(lead)\(approx)\(a)–\(approx)\(b)", bold: pair.isAnswer)
                } else {
                    let words = narrow ? ["", ""] : pair.key == .outer ? ["possible from ", "until "] : ["most \(shape.noun) from ", "until "]
                    labelAt(xa, ly, words[0] + approx + a, bold: pair.isAnswer && upcoming == 0)
                    labelAt(xb, ly, words[1] + approx + b, bold: pair.isAnswer && upcoming == 1)
                }
            }
            // Between the pairs, it comes and goes.
            if let inner = shape.inner, let outer = shape.outer, !narrow {
                for (a, b) in [(outer.lowerBound, inner.lowerBound), (inner.upperBound, outer.upperBound)]
                where f.x(Double(b)) - f.x(Double(a)) > 70 {
                    context.draw(text("on and off", size: 10, color: ink3, italic: true),
                                 at: CGPoint(x: (f.x(Double(a)) + f.x(Double(b))) / 2, y: f.top + 14), anchor: .center)
                }
            }
        case .yearRound:
            let px = f.x(Double(shape.peak))
            var line = Path(); line.move(to: CGPoint(x: px, y: f.top - 6)); line.addLine(to: CGPoint(x: px, y: f.axisY))
            context.stroke(line, with: .color(ink), lineWidth: 2)
            labelAt(px, f.top - 12, "likeliest ~\(short(shape.monthDay(shape.peak)))", bold: true)
        case .scoped:
            break
        }
    }

    // MARK: Year by year

    /// How many per season. Each finished season splits at today's date, so this
    /// season's "so far" has something to stand beside.
    private func drawYears(_ context: inout GraphicsContext, _ f: Layout) {
        let counts = shape.counts
        guard !counts.isEmpty else { return }
        let peak = max(1, counts.map(\.matched).max() ?? 1)
        let step = peak > 100 ? 50 : peak > 40 ? 20 : peak > 15 ? 5 : 2
        let hi = Int((Double(peak) / Double(step)).rounded(.up)) * step
        let y: (Int) -> CGFloat = { f.top + CGFloat(1 - Double($0) / Double(hi)) * f.ph }
        for v in stride(from: 0, through: hi, by: step) {
            var line = Path(); line.move(to: CGPoint(x: f.L, y: y(v))); line.addLine(to: CGPoint(x: f.W - f.R, y: y(v)))
            context.stroke(line, with: .color(rule), lineWidth: 1)
            context.draw(text("\(v)", color: ink3), at: CGPoint(x: f.L - 6, y: y(v)), anchor: .trailing)
        }
        let slot = (f.W - f.L - f.R) / CGFloat(counts.count), bw = min(64, slot * 0.6)
        let split = shape.kind != .scoped
        let hovered = pointer.map { Int((($0.x - f.L) / slot).rounded(.down)) }
        for (k, count) in counts.enumerated() {
            let cx = f.L + slot * (CGFloat(k) + 0.5), bx = cx - bw / 2
            let ongoing = !count.isComplete && k == counts.count - 1
            let partialStart = !count.isComplete && k == 0
            func bar(_ v0: Int, _ v1: Int, _ fill: Color, top: Bool) {
                guard v1 > v0 else { return }
                let rect = CGRect(x: bx, y: y(v1), width: bw, height: max(1, y(v0) - y(v1)))
                let r: CGFloat = top ? 4 : 0
                context.fill(UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r).path(in: rect), with: .color(fill))
            }
            if split, let byToday = count.byToday, !partialStart {
                bar(0, byToday, accent, top: ongoing || byToday == count.matched)
                if !ongoing { bar(byToday, count.matched, accentFill, top: true) }
            } else {
                bar(0, count.matched, partialStart ? accentFill : accent, top: true)
            }
            if hovered == k {
                context.stroke(Path(CGRect(x: bx - 2, y: y(count.matched) - 2, width: bw + 4, height: f.axisY - y(count.matched) + 2)),
                               with: .color(ink3), lineWidth: 1)
            }
            context.draw(text("\(count.matched)", weight: .semibold, color: ink), at: CGPoint(x: cx, y: y(count.matched) - 4), anchor: .bottom)
            context.draw(text(count.label, color: ink2), at: CGPoint(x: cx, y: f.axisY + 5), anchor: .top)
            if ongoing || partialStart {
                context.draw(text(ongoing ? "so far" : "record starts", size: 10, color: ink3),
                             at: CGPoint(x: cx, y: f.axisY + 19), anchor: .top)
            }
        }
        var axis = Path(); axis.move(to: CGPoint(x: f.L, y: f.axisY)); axis.addLine(to: CGPoint(x: f.W - f.R, y: f.axisY))
        context.stroke(axis, with: .color(ink3), lineWidth: 1)
    }

    // MARK: The readout

    @ViewBuilder private var tip: some View {
        if let pointer, width > 0, let content = readout(at: pointer, layout(width)) {
            let f = layout(width)
            let flip = pointer.x + 12 + tipSize.width > width - 8
            content
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.windowBackground)
                    .shadow(color: .black.opacity(0.18), radius: 7, y: 2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { tipSize = $0 }
                .offset(x: max(4, flip ? pointer.x - tipSize.width - 12 : pointer.x + 12), y: f.top)
                .allowsHitTesting(false)
        }
    }

    private func readout(at point: CGPoint, _ f: Layout) -> AnyView? {
        guard point.x >= f.L - 4, point.x <= f.W - f.R + 4 else { return nil }
        if view == .years { return yearsReadout(at: point, f) }
        let slot = f.slot(at: point.x)
        let noun = shape.noun

        if view == .readings, let dot = nearestDot(to: point, f), let r = shape.readings {
            return AnyView(VStack(alignment: .leading, spacing: 1) {
                Text("\(WeatherAlmanac.dayLabel(dot.day, includeYear: true)) · \(r.measure == .lightning ? "\(Int(dot.value).formatted()) strikes" : r.measure.format(dot.value))")
                    .font(.caption.monospacedDigit())
                Text("\(Self.tapWord) to open the day").font(.caption2).foregroundStyle(.secondary)
            })
        }

        // A line of the answer: the dates behind it.
        let near = pairs.flatMap { pair in [(pair, 0, pair.dates.lowerBound), (pair, 1, pair.dates.upperBound)] }
            .first { abs(f.x(Double($0.2)) - point.x) < 7 }
        if let (pair, end, _) = near {
            if pair.key == .outer {
                let list = end == 0 ? shape.firsts : shape.lasts
                return AnyView(VStack(alignment: .leading, spacing: 3) {
                    Text(end == 0 ? "First each season" : "Last each season").font(.caption.weight(.medium))
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 1) {
                        ForEach(list, id: \.season) { item in
                            GridRow {
                                Text(WhenInTheYear.label(season: item.season, startMonth: shape.startMonth))
                                Text(short(DayKey.monthDay(of: item.day))).gridColumnAlignment(.trailing)
                            }
                        }
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Text("the line is the middle of these").font(.caption2).foregroundStyle(.tertiary)
                })
            }
            return AnyView(Text("\(end == 0 ? "From here" : "Until here"), more \(noun) match than don't")
                .font(.caption))
        }

        if view == .readings, let r = shape.readings {
            func v(_ values: [Double?]) -> String {
                guard slot < values.count, let value = values[slot] else { return "—" }
                return r.measure == .lightning ? Int(value).formatted() : r.measure.format(value)
            }
            return AnyView(VStack(alignment: .leading, spacing: 1) {
                Text(short(shape.monthDay(slot))).font(.caption2).foregroundStyle(.secondary)
                if !r.mean.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("average \(v(r.mean))").font(.caption.monospacedDigit())
                        Text("most \(v(r.low))–\(v(r.high))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text([shape.previous.map { "\($0.label) \(v(r.previous))" }, shape.current.map { "\($0.label) \(v(r.current))" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            })
        }

        guard slot < shape.share.count else { return nil }
        let share = shape.share[slot]
        let rows = shape.seasons.filter { slot < $0.window.count && $0.window[slot].answered > 0 }
        return AnyView(VStack(alignment: .leading, spacing: 2) {
            Text(short(shape.monthDay(slot))).font(.caption2).foregroundStyle(.secondary)
            Text(share.map { "\(shareInWords($0)) \(noun) \(question.matched)" } ?? "no answer").font(.caption)
            Text("\(short(shape.monthDay(max(0, slot - 7)))) – \(short(shape.monthDay(min(shape.slotCount - 1, slot + 7)))), each year:")
                .font(.caption2).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 1) {
                ForEach(rows) { season in
                    GridRow {
                        Text(season.label)
                        Text("\(season.window[slot].matched) of \(season.window[slot].answered)").gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        })
    }

    private func yearsReadout(at point: CGPoint, _ f: Layout) -> AnyView? {
        let counts = shape.counts
        guard !counts.isEmpty else { return nil }
        let slot = (f.W - f.L - f.R) / CGFloat(counts.count)
        let k = Int(((point.x - f.L) / slot).rounded(.down))
        guard counts.indices.contains(k) else { return nil }
        let count = counts[k]
        let ongoing = !count.isComplete && k == counts.count - 1
        let partialStart = !count.isComplete && k == 0
        let today = short(DayKey.monthDay(of: recordEnd))
        return AnyView(VStack(alignment: .leading, spacing: 1) {
            Text("\(count.label): \(count.matched) \(shape.noun) \(question.matched)").font(.caption)
            if shape.kind != .scoped, let byToday = count.byToday, !ongoing, !partialStart {
                Text("\(byToday) of them by \(today)").font(.caption2).foregroundStyle(.secondary)
            }
            Text("\(count.answerable) of \(count.span) days could answer").font(.caption2).foregroundStyle(.secondary)
        })
    }

    // MARK: Legend

    @ViewBuilder private var legend: some View {
        switch view {
        case .readings:
            if let r = shape.readings {
                HStack(spacing: 16) {
                    if !r.mean.isEmpty {
                        swatch(Capsule().fill(accent).frame(width: 16, height: 2), "average")
                        swatch(RoundedRectangle(cornerRadius: 2).fill(accentFill).frame(width: 14, height: 10), "middle 80%")
                    }
                    if let previous = shape.previous { swatch(Circle().fill(ink3).frame(width: 6, height: 6), previous.label) }
                    if let current = shape.current { swatch(Circle().fill(ink).frame(width: 6, height: 6), current.label) }
                    Text("\(Self.tapWord) a dot to open that day")
                    if r.measure.accumulates { Text("only days with \(r.measure == .rain ? "rain" : "lightning") are drawn") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        case .years:
            if shape.kind != .scoped {
                HStack(spacing: 16) {
                    swatch(RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 10, height: 10),
                           "by \(short(DayKey.monthDay(of: recordEnd)))")
                    swatch(RoundedRectangle(cornerRadius: 2).fill(accentFill).frame(width: 10, height: 10), "rest of the season")
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        case .often:
            EmptyView()
        }
    }

    private func swatch<S: View>(_ mark: S, _ label: String) -> some View {
        HStack(spacing: 6) { mark; Text(label) }
    }
}

/// The answer to one "when in the year" question: the dates in three numbers, the
/// chart with its views, and the longest run. Explore shows one; Rhythms shows one
/// per season.
struct WhenInTheYearCard<Accessory: View>: View {
    let shape: WhenInTheYear
    let question: ExploreQuestion
    /// The question as asked — its year pin or first/last rule gets its own answer first.
    let query: DayQuery
    let recordEnd: String
    var openDay: (String) -> Void = { _ in }
    /// Something at the card's foot, like Rhythms' way into Explore.
    @ViewBuilder var accessory: Accessory

    /// Always opens on How often.
    @State private var chartView: ExploreChartView = .often


    var body: some View {
        let views = ExploreChartView.allCases.filter { $0 != .readings || shape.readings != nil }
        return VStack(alignment: .leading, spacing: 10) {
            heading(views)
            numbers(shape)
            WhenInTheYearChart(shape: shape, question: question, view: chartView,
                               recordEnd: recordEnd, openDay: openDay)
            HStack(alignment: .firstTextBaseline) {
                if let runs = runSentence(shape) {
                    Text(runs).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                accessory
            }
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }

    private func heading(_ views: [ExploreChartView]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(question.asks).font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Text("Show").font(.caption).foregroundStyle(.tertiary)
                Picker("Show", selection: $chartView) {
                    ForEach(views) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .controlSize(.small)
            }
        }
    }

    /// One tile: what it is, the answer, and what qualifies it.
    private struct Number: Hashable {
        var value: String
        var label: String
        var detail: String? = nil
    }

    /// Equal tiles with a border, label on top — the same shape as the records below, so they read
    /// as answers rather than as stray text.
    private func numbers(_ shape: WhenInTheYear) -> some View {
        let list = numberList(shape)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: list.count),
                         alignment: .leading, spacing: 10) {
            ForEach(list, id: \.self) { number in
                VStack(alignment: .leading, spacing: 3) {
                    Text(number.label.uppercased())
                        .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text(number.value)
                        .font(.system(size: 21, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(number.detail ?? " ")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
            }
        }
    }

    /// The answer in three numbers, in the kind the question asked for.
    private func numberList(_ shape: WhenInTheYear) -> [Number] {
        let out = standardNumbers(shape)
        // A question with a year pinned, or asking for the first or the last, gets its own answer first.
        if let lead = askedNumber(shape) { return [lead] + out.prefix(2) }
        return out
    }

    private func standardNumbers(_ shape: WhenInTheYear) -> [Number] {
        func dates(_ range: ClosedRange<Int>?, approx: Bool) -> String {
            guard let range else { return "never" }
            let mark = approx ? "~" : ""
            return "\(mark)\(short(shape.monthDay(range.lowerBound))) – \(mark)\(short(shape.monthDay(range.upperBound)))"
        }
        switch shape.kind {
        case .season:
            let answer = shape.answer(to: question)
            let possibleAnswers = answer?.answer == .possible
            let other = possibleAnswers ? shape.inner : shape.outer
            var out = [
                Number(value: answer.map { dates($0.dates, approx: possibleAnswers) } ?? "—",
                       label: possibleAnswers ? question.possibleName : question.mostDaysName,
                       detail: possibleAnswers ? "typical first and last" : "more \(shape.noun) than not"),
                Number(value: dates(other, approx: !possibleAnswers),
                       label: possibleAnswers ? question.mostDaysName : question.possibleName,
                       detail: possibleAnswers ? "more \(shape.noun) than not" : "typical first and last"),
            ]
            if let current = shape.current {
                let hits = shape.currentHits
                let value = hits.first.flatMap { first in hits.last.map { last in
                    "\(short(shape.monthDay(first))) – \(short(shape.monthDay(last)))"
                } } ?? "none yet"
                let detail = hits.isEmpty
                    ? shape.lastEver.map { "last was \(WeatherAlmanac.dayLabel($0, includeYear: true))" }
                    : (shape.through < shape.slotCount - 1 ? "so far" : nil)
                out.append(Number(value: value, label: "This season · \(current.label)", detail: detail))
            }
            return out
        case .yearRound:
            let share = shape.peak < shape.share.count ? shape.share[shape.peak] ?? 0 : 0
            return [
                Number(value: "~\(short(shape.monthDay(shape.peak)))", label: "Likeliest",
                       detail: "\(shareInWords(share, capital: false).replacingOccurrences(of: " the", with: "")) \(shape.noun)"),
                Number(value: "All year", label: "Can happen", detail: "no off season"),
                Number(value: shape.lastEver.map { WeatherAlmanac.dayLabel($0, includeYear: true) } ?? "—",
                       label: "Last time"),
            ]
        case .scoped:
            let name = query.scope?.name ?? "these dates"
            let complete = shape.counts.filter(\.isComplete)
            let with = complete.filter { $0.matched > 0 }.count
            let days = complete.reduce(0) { $0 + $1.matched }, answerable = complete.reduce(0) { $0 + $1.answerable }
            var out = [
                Number(value: with * 2 > complete.count ? "Usually" : "Not usually", label: "Every \(name)?",
                       detail: "\(with) of \(complete.count) \(question.matched)"),
                Number(value: answerable > 0 ? "\(shareInWords(Double(days) / Double(answerable), capital: true).replacingOccurrences(of: " the", with: "")) \(shape.noun)" : "—",
                       label: "How often", detail: "of \(name)"),
            ]
            if let latest = shape.counts.last {
                out.append(Number(value: "\(latest.matched) \(shape.noun)", label: latest.label,
                                  detail: latest.isComplete ? nil : "so far"))
            }
            return out
        }
    }

    /// "When was the last cool night this year?" answered as a date, before anything else.
    private func askedNumber(_ shape: WhenInTheYear) -> Number? {
        let noun = shape.noun
        if case .year(let year) = query.years {
            let inYear = shape.matchedDays.filter { DayKey.year(of: $0) == year }
            let running = DayKey.year(of: recordEnd) == year
            switch query.sequence {
            case .lastEachYear:
                return Number(value: inYear.last.map { WeatherAlmanac.dayLabel($0) } ?? "none", label: "Last in \(year)")
            case .firstEachYear:
                return Number(value: inYear.first.map { WeatherAlmanac.dayLabel($0) } ?? "none", label: "First in \(year)")
            case .inRunOfAtLeast(let n):
                let runs = DayKey.runs(of: inYear).filter { (DayKey.distance(from: $0.first, to: $0.last) ?? 0) + 1 >= n }
                return Number(value: "\(runs.count)", label: "Runs in \(year)", detail: "of \(n) or more \(noun)")
            case nil:
                return Number(value: "\(inYear.count) \(noun)", label: "In \(year)", detail: running ? "so far" : nil)
            }
        }
        switch query.sequence {
        case .firstEachYear:
            guard let first = WhenInTheYear.Median.of(shape.firsts) else { return nil }
            return Number(value: "~\(short(shape.monthDay(first)))", label: "Usually the first")
        case .lastEachYear:
            guard let last = WhenInTheYear.Median.of(shape.lasts) else { return nil }
            return Number(value: "~\(short(shape.monthDay(last)))", label: "Usually the last")
        case .inRunOfAtLeast(let n):
            let runs = DayKey.runs(of: shape.matchedDays).filter { (DayKey.distance(from: $0.first, to: $0.last) ?? 0) + 1 >= n }
            return Number(value: "\(runs.count)", label: "Runs", detail: "of \(n) or more \(noun)")
        case nil:
            return nil
        }
    }

    private func runSentence(_ shape: WhenInTheYear) -> String? {
        guard let longest = shape.longest else { return nil }
        guard longest.length >= 2 else { return "No two \(shape.noun) in a row on record." }
        var text = "Longest run: \(longest.length) \(shape.noun) in a row, "
            + "\(WeatherAlmanac.dayLabel(longest.firstDay)) – \(WeatherAlmanac.dayLabel(longest.lastDay, includeYear: true))"
        if shape.runsOfThree > 1 { text += " · \(shape.runsOfThree) runs of 3 or more" }
        return text + "."
    }

}

extension WhenInTheYearCard where Accessory == EmptyView {
    init(shape: WhenInTheYear, question: ExploreQuestion, query: DayQuery, recordEnd: String,
         openDay: @escaping (String) -> Void = { _ in }) {
        self.init(shape: shape, question: question, query: query, recordEnd: recordEnd, openDay: openDay) { EmptyView() }
    }
}

/// "Jun 10" from an `MM-dd`.
func short(_ monthDay: String) -> String {
    "\(WeatherAlmanac.monthName(String(monthDay.prefix(2)), long: false)) \(Int(monthDay.suffix(2)) ?? 1)"
}

/// A share as the fraction a person would say: "About 1 in 4".
func shareInWords(_ share: Double, capital: Bool = true) -> String {
    let words: [(Double, String)] = [(0, "No"), (0.1, "About 1 in 10"), (0.167, "About 1 in 6"), (0.25, "About 1 in 4"),
                                     (1.0 / 3, "About 1 in 3"), (0.5, "About half the"), (2.0 / 3, "About 2 in 3"),
                                     (0.75, "About 3 in 4"), (0.9, "About 9 in 10"), (1, "All the")]
    var best = words.min { abs($0.0 - share) < abs($1.0 - share) } ?? words[0]
    if best.0 == 0 && share > 0 { best = (0, "Hardly any") }
    if best.0 == 1 && share < 1 { best = (1, "Nearly all the") }
    return capital ? best.1 : best.1.prefix(1).lowercased() + best.1.dropFirst()
}
