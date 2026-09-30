//
//  ThreeDayTimeline.swift  (Weather, VaneTV)
//
//  The next three days as one figure — the heart of the Forecast page on the
//  Mac, the iPad and the TV. See `ForecastViews.swift` for the page around it
//  and [[forecast-page-is-practical]] for why it draws rather than explains.
//
//  Compiled into the TV from here rather than copied; see project.yml.
//

import SwiftUI
import WeatherKit

/// "Today", "Tomorrow", then the weekday — the one naming of the three days,
/// so a tile and the chart under it never call the same day two things.
enum ForecastDayTitle {
    static func title(index: Int, day: DayNote) -> String {
        switch index {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return day.weekday
        }
    }
}

// MARK: - The timeline

/// Seventy-odd hours as one figure: temperature, rain, wind and storms on a
/// shared clock, so "the rain lands Wednesday afternoon, with the gusts" is
/// read straight down a column rather than assembled from four cards.
///
/// ON THE TV TOO, drawn at `scale` — the same figure at ten-foot size rather
/// than a second chart that would drift from this one. At 1 it is exactly the
/// Mac's and iPad's. `textScale` is separate because a TV needs its words
/// larger than its shapes: at one scale for both, either the labels were too
/// small to read from the sofa or the figure was taller than the screen.
///
/// Same grammar as `HourlyRibbon`, which Now already taught: the curve is
/// labelled where it matters (here, each day's high and low), rain bars are
/// the chance in height and the water in fill, night is a wash.
struct ThreeDayTimeline: View {
    private struct DaySpan: Identifiable {
        var id: String { key }
        let key: String
        let title: String
        let first: Int
        let last: Int
        let high: Int?
        let low: Int?
    }

    private let hours: [HourSlice]
    private let spans: [DaySpan]
    private let risks: [String: StormRisk]
    private let agreement: [Int: (wet: Int, of: Int)]
    private let tempSpan: ClosedRange<Double>
    private let windMax: Double
    private let hasRain: Bool
    private let nowIndex: Double?
    private let localHours: [Int]
    private let scale: CGFloat
    private let textScale: CGFloat

    @State private var hover: Int?

    /// The same fixed referent as `HourlyRibbon`: a full bar is a tenth of an
    /// inch in the hour, so a filled bar means the same thing every day.
    private static let wetHour = 0.10
    /// Where a gust starts to be something you notice: umbrellas, trash cans.
    private static let gusty = 25.0

    init(hours: [HourSlice], timezone: TimeZone, precip: PrecipOutlook?,
         risks: [String: StormRisk], scale: CGFloat = 1, textScale: CGFloat? = nil,
         now: Date = Date()) {
        self.hours = hours
        self.scale = scale
        self.textScale = textScale ?? scale
        self.risks = risks
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let dates = hours.map { Date(timeIntervalSince1970: TimeInterval($0.epoch)) }
        self.localHours = dates.map { cal.component(.hour, from: $0) }

        let keys = dates.map { DayKey.string(for: $0, timeZone: timezone) }
        let weekday = DateFormatter()
        weekday.timeZone = timezone
        weekday.locale = Locale(identifier: "en_US")
        weekday.dateFormat = "EEEE"
        var spans: [DaySpan] = []
        var i = 0
        while i < hours.count {
            var j = i
            while j + 1 < hours.count, keys[j + 1] == keys[i] { j += 1 }
            let temps = hours[i...j].compactMap(\.temperature)
            let title: String
            switch spans.count {
            case 0:  title = "Today"
            case 1:  title = "Tomorrow"
            default: title = weekday.string(from: dates[i])
            }
            // An extreme is only labelled with enough of the day to find one:
            // at 10 PM, "today's low" is just the last hour.
            let whole = j - i >= 5
            let hi = whole ? hours[i...j].indices.max { (hours[$0].temperature ?? -999) < (hours[$1].temperature ?? -999) } : nil
            let lo = whole ? hours[i...j].indices.min { (hours[$0].temperature ?? 999) < (hours[$1].temperature ?? 999) } : nil
            spans.append(DaySpan(key: keys[i], title: title, first: i, last: j,
                                 high: temps.isEmpty ? nil : hi, low: temps.isEmpty ? nil : lo))
            i = j + 1
        }
        self.spans = spans

        let temps = hours.compactMap(\.temperature)
        let lo = temps.min() ?? 0, hi = temps.max() ?? 1
        let pad = Swift.max(3, (hi - lo) * 0.15)
        self.tempSpan = (lo - pad)...(hi + pad)
        self.windMax = Swift.max(30, (hours.compactMap(\.windGust) + hours.compactMap(\.windAvg)).max() ?? 0)
        self.hasRain = hours.contains { ($0.precipProbability ?? 0) >= 10 || ($0.precip ?? 0) > 0 }

        var agreement: [Int: (Int, Int)] = [:]
        if let precip {
            let index = Dictionary(hours.indices.map { (hours[$0].epoch, $0) }, uniquingKeysWith: { a, _ in a })
            for (j, t) in precip.times.enumerated() {
                if let i = index[Int(t.timeIntervalSince1970)] {
                    agreement[i] = (precip.agreement(atHour: j), precip.modelCount)
                }
            }
        }
        self.agreement = agreement

        if let first = hours.first {
            let idx = (now.timeIntervalSince1970 - TimeInterval(first.epoch)) / 3600
            self.nowIndex = (idx >= -0.5 && idx <= Double(hours.count) - 0.5) ? idx : nil
        } else {
            self.nowIndex = nil
        }
    }

    // MARK: Lanes

    private struct Lanes {
        let hasModels: Bool
        let s: CGFloat
        var day: CGFloat { 18 * s }
        var icon: CGFloat { 24 * s }
        var temp: CGFloat { 120 * s }
        var rain: CGFloat { 40 * s }
        var models: CGFloat { 10 * s }
        var wind: CGFloat { 44 * s }
        var storm: CGFloat { 18 * s }
        var axis: CGFloat { 13 * s }
        var gap: CGFloat { 8 * s }

        var iconTop: CGFloat { day + 2 * s }
        var tempTop: CGFloat { iconTop + icon }
        var rainTop: CGFloat { tempTop + temp + gap }
        var modelsTop: CGFloat { rainTop + rain + 3 * s }
        var windTop: CGFloat { modelsTop + (hasModels ? models : 0) + gap }
        var stormTop: CGFloat { windTop + wind + gap }
        var axisTop: CGFloat { stormTop + storm + 4 * s }
        var height: CGFloat { axisTop + axis }
    }

    private var lanes: Lanes { Lanes(hasModels: !agreement.isEmpty, s: scale) }

    /// A length at this figure's scale.
    private func pt(_ points: CGFloat) -> CGFloat { points * scale }
    /// A type size, or a gap that makes room for type, at the text's scale.
    private func tx(_ points: CGFloat) -> CGFloat { points * textScale }

    var body: some View {
        GeometryReader { geo in
            let minWidth = CGFloat(hours.count) * pt(11)
            if geo.size.width >= minWidth {
                figure(width: geo.size.width)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    figure(width: minWidth).frame(width: minWidth)
                }
            }
        }
        .frame(height: lanes.height)
    }

    private func figure(width: CGFloat) -> some View {
        let colW = width / CGFloat(max(hours.count, 1))
        return readable(ZStack(alignment: .topLeading) {
            Canvas { ctx, size in draw(ctx, size, colW) }
            ForEach(iconMarks, id: \.self) { i in
                Image(systemName: WeatherSymbol.name(hours[i].icon))
                    .font(.system(size: tx(14))).symbolRenderingMode(.multicolor)
                    .position(x: x(Double(i), colW), y: lanes.iconTop + lanes.icon / 2)
            }
        }, colW: colW)
    }

    /// Point at the figure to read any hour — except on a TV, where there is
    /// no pointer and no touch, a remote's swipe belongs to the focus engine,
    /// and the figure is read whole from across the room.
    @ViewBuilder private func readable(_ figure: some View, colW: CGFloat) -> some View {
        #if os(tvOS)
        figure
        #else
        figure.pointReadout($hover) { point in
            let i = Int((point.x / colW).rounded(.down))
            return hours.indices.contains(i) ? i : nil
        }
        #endif
    }

    /// One sky icon per six hours, on the hour of the day's parts — seventy
    /// icons would be a row of noise, and the sky rarely changes faster.
    private var iconMarks: [Int] {
        hours.indices.filter { localHours[$0] % 6 == 3 && !hours[$0].icon.isEmpty }
    }

    private func x(_ index: Double, _ colW: CGFloat) -> CGFloat { (CGFloat(index) + 0.5) * colW }

    private func yTemp(_ t: Double) -> CGFloat {
        let f = (t - tempSpan.lowerBound) / (tempSpan.upperBound - tempSpan.lowerBound)
        return lanes.tempTop + lanes.temp - CGFloat(f) * lanes.temp
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ colW: CGFloat) {
        drawNight(ctx, colW)
        drawDays(ctx, colW, size: size)
        drawLaneLabels(ctx)
        drawTemperature(ctx, colW)
        drawRain(ctx, colW)
        drawModels(ctx, colW)
        drawWind(ctx, colW)
        drawStorms(ctx, colW)
        drawAxis(ctx, colW)
        drawNow(ctx, colW)
        drawHover(ctx, colW, size: size)
    }

    private func drawNight(_ ctx: GraphicsContext, _ colW: CGFloat) {
        let top = lanes.tempTop, bottom = lanes.stormTop - lanes.gap / 2
        var i = 0
        while i < hours.count {
            guard hours[i].isNight else { i += 1; continue }
            var j = i
            while j + 1 < hours.count, hours[j + 1].isNight { j += 1 }
            ctx.fill(Path(CGRect(x: CGFloat(i) * colW, y: top,
                                 width: CGFloat(j - i + 1) * colW, height: bottom - top)),
                     with: .color(.primary.opacity(0.045)))
            i = j + 1
        }
    }

    /// Day names across the top and a rule at each midnight, full height — the
    /// three days are the page's unit, so where one ends has to be unmissable.
    private func drawDays(_ ctx: GraphicsContext, _ colW: CGFloat, size: CGSize) {
        for span in spans {
            let x0 = CGFloat(span.first) * colW
            ctx.draw(Text(span.title.uppercased()).font(.system(size: tx(10), weight: .bold))
                        .foregroundStyle(.secondary),
                     at: CGPoint(x: x0 + pt(4), y: pt(2)), anchor: .topLeading)
            if span.first > 0 {
                var rule = Path()
                rule.move(to: CGPoint(x: x0, y: 0))
                rule.addLine(to: CGPoint(x: x0, y: lanes.axisTop - pt(2)))
                ctx.stroke(rule, with: .color(.primary.opacity(0.18)), lineWidth: pt(1))
            }
        }
    }

    private func drawLaneLabels(_ ctx: GraphicsContext) {
        func label(_ s: String, _ y: CGFloat) {
            ctx.draw(Text(s).font(.system(size: tx(8), weight: .bold)).foregroundStyle(.tertiary),
                     at: CGPoint(x: pt(3), y: y), anchor: .topLeading)
        }
        label("RAIN", lanes.rainTop)
        if lanes.hasModels { label("MODELS", lanes.modelsTop) }
        label("WIND", lanes.windTop)
        label("STORMS", lanes.stormTop + pt(4))
    }

    /// Where the storm lane's own label ends. A bar under it centres its label
    /// in what is left, or drops it.
    private func stormLabelEnd(_ ctx: GraphicsContext) -> CGFloat {
        pt(3) + ctx.resolve(Text("STORMS").font(.system(size: tx(8), weight: .bold)))
            .measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width + pt(6)
    }

    private func drawTemperature(_ ctx: GraphicsContext, _ colW: CGFloat) {
        let pts: [CGPoint?] = hours.indices.map { i in
            hours[i].temperature.map { CGPoint(x: x(Double(i), colW), y: yTemp($0)) }
        }
        let line = SmoothCurve.path(pts)
        guard !line.isEmpty else { return }
        let bottom = lanes.tempTop + lanes.temp
        if let first = pts.compactMap({ $0 }).first, let last = pts.compactMap({ $0 }).last {
            var fill = line
            fill.addLine(to: CGPoint(x: last.x, y: bottom))
            fill.addLine(to: CGPoint(x: first.x, y: bottom))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [.orange.opacity(0.26), .orange.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: lanes.tempTop), endPoint: CGPoint(x: 0, y: bottom)))
        }
        ctx.stroke(line, with: .color(.orange.opacity(0.9)),
                   style: StrokeStyle(lineWidth: pt(2), lineCap: .round, lineJoin: .round))

        for span in spans {
            for (index, isHigh) in [(span.high, true), (span.low, false)] {
                guard let i = index, let t = hours[i].temperature, let p = pts[i] else { continue }
                let r = pt(3)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(isHigh ? .orange : .blue.opacity(0.8)))
                let above = isHigh ? p.y - lanes.tempTop > tx(16) : !(bottom - p.y > tx(16))
                ctx.draw(Text("\(Int(t.rounded()))°").font(scale == 1 ? .caption.weight(.semibold)
                                                              : .system(size: tx(11), weight: .semibold))
                            .foregroundStyle(isHigh ? Color.primary : Color.secondary),
                         at: CGPoint(x: p.x, y: above ? p.y - tx(11) : p.y + tx(12)), anchor: .center)
            }
        }
    }

    private func drawRain(_ ctx: GraphicsContext, _ colW: CGFloat) {
        let top = lanes.rainTop + tx(10), usable = lanes.rain - tx(10)
        // A baseline so a dry stretch reads as "no rain" rather than as nothing drawn.
        var base = Path()
        base.move(to: CGPoint(x: 0, y: top + usable))
        base.addLine(to: CGPoint(x: CGFloat(hours.count) * colW, y: top + usable))
        ctx.stroke(base, with: .color(.blue.opacity(0.15)), lineWidth: pt(1))

        for i in hours.indices {
            let prob = hours[i].precipProbability ?? 0
            let amount = hours[i].precip ?? 0
            guard prob >= 10 || amount > 0 else { continue }
            let h = max(2, CGFloat(prob / 100) * usable)
            let rect = CGRect(x: x(Double(i), colW) - colW * 0.3, y: top + usable - h,
                              width: colW * 0.6, height: h)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.blue.opacity(0.18)))
            let wet = min(1, amount / Self.wetHour)
            if wet > 0 {
                let fh = max(1.5, CGFloat(wet) * h)
                ctx.fill(Path(roundedRect: CGRect(x: rect.minX, y: rect.maxY - fh,
                                                  width: rect.width, height: fh), cornerRadius: 1.5),
                         with: .color(.blue.opacity(0.85)))
            }
        }
        // Each day's total, over its likeliest hour.
        for span in spans {
            let range = span.first...span.last
            let total = hours[range].compactMap(\.precip).reduce(0, +)
            guard let peak = range.max(by: { (hours[$0].precipProbability ?? 0) < (hours[$1].precipProbability ?? 0) }),
                  let prob = hours[peak].precipProbability, prob >= 20 else { continue }
            var label = "\(Int(prob.rounded()))%"
            if total >= 0.01 { label += " · \(WeatherAlmanac.inches(total))" }
            ctx.draw(Text(label).font(.system(size: tx(9), weight: .semibold)).foregroundStyle(.blue),
                     at: CGPoint(x: x(Double(peak), colW), y: lanes.rainTop + tx(4)), anchor: .center)
        }
    }

    /// How many of the models have rain in that hour, as a strip that darkens
    /// with agreement — only where the models reach (about eighteen hours).
    private func drawModels(_ ctx: GraphicsContext, _ colW: CGFloat) {
        guard lanes.hasModels else { return }
        let rowH = lanes.models - pt(2)
        for (i, a) in agreement where a.of > 0 {
            let rect = CGRect(x: CGFloat(i) * colW, y: lanes.modelsTop + pt(1), width: colW, height: rowH)
            let share = Double(a.wet) / Double(a.of)
            ctx.fill(Path(rect), with: .color(share > 0 ? .blue.opacity(0.1 + 0.8 * share)
                                                         : .primary.opacity(0.05)))
        }
    }

    private func drawWind(_ ctx: GraphicsContext, _ colW: CGFloat) {
        let top = lanes.windTop + tx(8), h = lanes.wind - tx(8)
        func y(_ mph: Double) -> CGFloat { top + h - CGFloat(min(mph, windMax) / windMax) * h }

        // The gusty line, so "windy" is a place on the chart rather than a judgement.
        var ref = Path()
        ref.move(to: CGPoint(x: 0, y: y(Self.gusty)))
        ref.addLine(to: CGPoint(x: CGFloat(hours.count) * colW, y: y(Self.gusty)))
        ctx.stroke(ref, with: .color(.primary.opacity(0.18)),
                   style: StrokeStyle(lineWidth: pt(1), dash: [pt(3), pt(3)]))
        ctx.draw(Text("\(Int(Self.gusty)) mph").font(.system(size: tx(8))).foregroundStyle(.tertiary),
                 at: CGPoint(x: CGFloat(hours.count) * colW - pt(2), y: y(Self.gusty) - pt(1)), anchor: .bottomTrailing)

        // Sustained wind as a filled area, gusts as the line above it.
        let avg: [CGPoint?] = hours.indices.map { i in hours[i].windAvg.map { CGPoint(x: x(Double(i), colW), y: y($0)) } }
        let avgLine = SmoothCurve.path(avg)
        if let first = avg.compactMap({ $0 }).first, let last = avg.compactMap({ $0 }).last {
            var area = avgLine
            area.addLine(to: CGPoint(x: last.x, y: top + h))
            area.addLine(to: CGPoint(x: first.x, y: top + h))
            area.closeSubpath()
            ctx.fill(area, with: .color(.teal.opacity(0.3)))
        }
        let gust: [CGPoint?] = hours.indices.map { i in hours[i].windGust.map { CGPoint(x: x(Double(i), colW), y: y($0)) } }
        ctx.stroke(SmoothCurve.path(gust), with: .color(.teal.opacity(0.9)),
                   style: StrokeStyle(lineWidth: pt(1.4), lineCap: .round, lineJoin: .round))

        // Each day's strongest gust.
        for span in spans {
            let range = span.first...span.last
            guard let peak = range.max(by: { (hours[$0].windGust ?? 0) < (hours[$1].windGust ?? 0) }),
                  let g = hours[peak].windGust, g >= 1 else { continue }
            let dir = hours[peak].windDirectionCardinal.map { "\($0) " } ?? ""
            ctx.draw(Text("\(dir)\(Int(g.rounded()))").font(.system(size: tx(9), weight: .semibold))
                        .foregroundStyle(g >= Self.gusty ? Color.primary : Color.secondary),
                     at: CGPoint(x: x(Double(peak), colW), y: max(lanes.windTop, y(g) - tx(7))), anchor: .center)
        }
    }

    /// One bar per day in the storm category's own colour. A day with no
    /// outlook loaded is grey and says so, rather than looking quiet.
    private func drawStorms(_ ctx: GraphicsContext, _ colW: CGFloat) {
        for span in spans {
            let rect = CGRect(x: CGFloat(span.first) * colW + pt(2), y: lanes.stormTop,
                              width: CGFloat(span.last - span.first + 1) * colW - pt(4), height: lanes.storm)
            let label: String
            let fill: Color
            if let risk = risks[span.key] {
                if let c = risk.category {
                    fill = c.fill.color.opacity(c.level > 0 ? 0.75 : 0.45)
                    label = c.level > 0 ? c.name : "Thunder possible"
                } else {
                    fill = .primary.opacity(0.04)
                    label = "None expected"
                }
                if let top = risk.notable.first, top.hazard != .any {
                    ctx.fill(Path(roundedRect: rect, cornerRadius: pt(4)), with: .color(fill))
                    drawFitting(ctx, Text("\(label) · \(top.hazard.label.lowercased()) \(Int((top.probability * 100).rounded()))%")
                                .font(.system(size: tx(9), weight: .semibold)), in: rect)
                    continue
                }
            } else {
                fill = .primary.opacity(0.04)
                label = "No outlook"
            }
            ctx.fill(Path(roundedRect: rect, cornerRadius: pt(4)), with: .color(fill))
            drawFitting(ctx, Text(label).font(.system(size: tx(9), weight: .semibold)).foregroundStyle(.secondary),
                        in: rect)
        }
    }

    /// A bar's label only where it fits. Late in the day, today's bar is a few
    /// hours wide, and its label ran out over the lane's own "STORMS".
    private func drawFitting(_ ctx: GraphicsContext, _ text: Text, in rect: CGRect) {
        var room = rect
        let clear = stormLabelEnd(ctx)
        if room.minX < clear { room = CGRect(x: clear, y: rect.minY, width: rect.maxX - clear, height: rect.height) }
        let resolved = ctx.resolve(text)
        guard resolved.measure(in: CGSize(width: .infinity, height: rect.height)).width <= room.width - pt(6)
        else { return }
        ctx.draw(resolved, at: CGPoint(x: room.midX, y: room.midY), anchor: .center)
    }

    private func drawAxis(_ ctx: GraphicsContext, _ colW: CGFloat) {
        for i in hours.indices where localHours[i] % 6 == 0 && localHours[i] != 0 {
            ctx.draw(Text(hours[i].clock.uppercased()).font(.system(size: tx(9))).foregroundStyle(.tertiary),
                     at: CGPoint(x: x(Double(i), colW), y: lanes.axisTop), anchor: .top)
        }
    }

    private func drawNow(_ ctx: GraphicsContext, _ colW: CGFloat) {
        guard let nowIndex else { return }
        var line = Path()
        line.move(to: CGPoint(x: x(nowIndex, colW), y: lanes.tempTop))
        line.addLine(to: CGPoint(x: x(nowIndex, colW), y: lanes.axisTop - pt(2)))
        ctx.stroke(line, with: .color(.primary.opacity(0.35)),
                   style: StrokeStyle(lineWidth: pt(1), dash: [pt(2), pt(3)]))
    }

    private func drawHover(_ ctx: GraphicsContext, _ colW: CGFloat, size: CGSize) {
        guard let i = hover, hours.indices.contains(i) else { return }
        let h = hours[i]
        let cx = x(Double(i), colW)
        var line = Path()
        line.move(to: CGPoint(x: cx, y: lanes.tempTop))
        line.addLine(to: CGPoint(x: cx, y: lanes.axisTop - 2))
        ctx.stroke(line, with: .color(.primary.opacity(0.25)), lineWidth: 1)
        if let t = h.temperature {
            let p = CGPoint(x: cx, y: yTemp(t))
            let dot = Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            ctx.fill(dot, with: .color(.orange))
            ctx.stroke(dot, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }

        let day = spans.first { (($0.first)...($0.last)).contains(i) }?.title ?? ""
        var parts = ["\(day) \(h.clock)"]
        if let t = h.temperature { parts.append("\(Int(t.rounded()))°") }
        if let p = h.precipProbability, p >= 10 { parts.append("\(Int(p.rounded()))% rain") }
        if let amt = h.precip, amt > 0 { parts.append(amt >= 0.01 ? String(format: "%.2f\"", amt) : "trace") }
        if let a = agreement[i] { parts.append("\(a.wet)/\(a.of) models wet") }
        let wind = [h.windDirectionCardinal, h.windAvg.map { "\(Int($0.rounded()))" },
                    h.windGust.map { "g\(Int($0.rounded()))" }].compactMap { $0 }.joined(separator: " ")
        if !wind.isEmpty { parts.append(wind + " mph") }

        let text = ctx.resolve(Text(parts.joined(separator: "  ·  ")).font(.system(size: tx(10), weight: .medium)))
        let s = text.measure(in: size)
        let bx = min(max(cx - s.width / 2 - 7, 2), size.width - s.width - 16)
        let box = CGRect(x: bx, y: lanes.tempTop + 2, width: s.width + 14, height: s.height + 8)
        ctx.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(.black.opacity(0.72)))
        ctx.draw(text, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }
}


// MARK: - Curves

/// The smoothed line every forecast chart draws its temperature and wind with.
/// Here rather than on `HourlyRibbon` so the TV compiles it without the Mac's
/// ribbon.
enum SmoothCurve {
    static func path(_ pts: [CGPoint?]) -> Path {
        let p = pts.compactMap { $0 }
        var path = Path()
        guard let first = p.first else { return path }
        path.move(to: first)
        guard p.count > 1 else { return path }
        for i in 1..<p.count {
            let prev = p[i - 1], cur = p[i]
            let midX = (prev.x + cur.x) / 2
            path.addQuadCurve(to: CGPoint(x: midX, y: (prev.y + cur.y) / 2),
                              control: CGPoint(x: midX, y: prev.y))
            path.addQuadCurve(to: cur, control: CGPoint(x: midX, y: cur.y))
        }
        return path
    }
}
