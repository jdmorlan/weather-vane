//
//  WeatherOutlookRibbon.swift  (macOS)
//
//  The ten days as ONE figure — the week-scale twin of `HourlyRibbon`.
//
//  A grid of day boxes spends the same ink on every day and makes you do the
//  differencing yourself: ten cells each printing "88° / 66°", ten icons, ten
//  percentages. But nobody asks "what is Thursday's high"; they ask when it breaks,
//  when the muggy stretch ends, and which day the rain lands on. Those are questions
//  about the SHAPE of a week, and a shape has to be drawn as one continuous thing.
//
//  NO WEEKEND SHADING. Saturday and Sunday used to sit under a grey wash, on the
//  theory that finding the weekend should not cost a read of ten labels. It never
//  did: SAT and SUN are already printed along the axis, the wash said nothing
//  they didn't, and with no legend it read as a mystery region rather than a
//  convenience.
//
//  So: the highs and lows become a band (the day's swing is the thickness of it),
//  labelled only where it turns; the sky is drawn once per run of unchanging sky;
//  humidity is a wash of four stretches per day, so a muggy stretch is a block of
//  color you find without reading; and rain keeps the hourly lane's grammar —
//  height is the chance, fill is the water.
//

import SwiftUI
import WeatherKit

struct OutlookRibbon: View {
    private struct IconRun: Identifiable {
        var id: Int { first }
        var icon: String
        var first: Int
        var last: Int
    }

    private let days: [DayNote]
    private let iconRuns: [IconRun]
    private let highMarks: [Int]
    private let lowMarks: [Int]
    private let span: ClosedRange<Double>
    private let hasRain: Bool
    private let hasComfort: Bool
    private let labels: [(weekday: String, date: String)]
    private let rain: [(prob: Double, amount: Double?)]

    @State private var hover: Int?

    /// A day's water, before the bar reads as a wet day rather than a passing shower.
    private static let wetDay = 0.25    // inches

    private static let partSlots = ["Overnight", "Morning", "Afternoon", "Evening"]

    init(days: [DayNote], timezone: TimeZone?) {
        self.days = days

        let md = DateFormatter()
        md.timeZone = timezone
        md.locale = Locale(identifier: "en_US")
        md.dateFormat = "M/d"
        self.labels = days.enumerated().map { i, d in
            let date = Date(timeIntervalSince1970: TimeInterval(d.epoch))
            return (i == 0 ? "TODAY" : d.weekday.uppercased(),
                    md.string(from: date))
        }

        var runs: [IconRun] = []
        for i in days.indices {
            if runs.last?.icon == days[i].icon { runs[runs.count - 1].last = i }
            else { runs.append(IconRun(icon: days[i].icon, first: i, last: i)) }
        }
        self.iconRuns = runs

        let highs = days.map(\.high), lows = days.map(\.low)
        self.highMarks = HourlyRibbon.turningPoints(highs)
        self.lowMarks = HourlyRibbon.turningPoints(lows)
        let known = (highs + lows).compactMap { $0 }
        let lo = known.min() ?? 0, hi = known.max() ?? 1
        let pad = Swift.max(3, (hi - lo) * 0.12)
        self.span = (lo - pad)...(hi + pad)

        // A daily forecast reports the chance but not the total, so the water is the
        // sum of the day's parts. No parts (far out) means no amount — not zero.
        self.rain = days.map { d in
            (prob: d.precipProbability ?? 0,
             amount: d.parts.isEmpty ? nil : d.parts.reduce(0) { $0 + $1.precip })
        }
        self.hasRain = rain.contains { $0.prob >= 20 || ($0.amount ?? 0) > 0 }
        self.hasComfort = days.contains { !$0.parts.isEmpty || $0.dewPoint != nil }
    }

    // MARK: Lanes

    private var lanes: (icon: CGFloat, plot: CGFloat, dew: CGFloat, rain: CGFloat, axis: CGFloat) {
        (icon: 26, plot: 108, dew: hasComfort ? 10 : 0, rain: hasRain ? 26 : 0, axis: 26)
    }

    private var height: CGFloat {
        let l = lanes
        return l.icon + l.plot + (hasComfort ? l.dew + 8 : 0)
            + (hasRain ? l.rain + 4 : 0) + 4 + l.axis
    }

    var body: some View {
        GeometryReader { geo in
            let minWidth = CGFloat(days.count) * 56
            if geo.size.width >= minWidth {
                figure(width: geo.size.width)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    figure(width: minWidth).frame(width: minWidth)
                }
            }
        }
        .frame(height: height)
    }

    private func figure(width: CGFloat) -> some View {
        let colW = width / CGFloat(max(days.count, 1))
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in draw(ctx, size, colW) }
            ForEach(iconRuns) { run in
                Image(systemName: WeatherView.symbol(run.icon))
                    .font(.system(size: 17)).symbolRenderingMode(.multicolor)
                    .position(x: x(Double(run.first + run.last) / 2, colW), y: lanes.icon / 2)
            }
        }
        // Hover on a pointer, tap or scrub on a finger — same `hover` state and
        // the same `drawHover` readout either way. See `PointReadout`.
        .pointReadout($hover) { point in
            let i = Int((point.x / colW).rounded(.down))
            return days.indices.contains(i) ? i : nil
        }
    }

    private func x(_ index: Double, _ colW: CGFloat) -> CGFloat { (CGFloat(index) + 0.5) * colW }

    private func y(_ temp: Double, _ top: CGFloat, _ h: CGFloat) -> CGFloat {
        let t = (temp - span.lowerBound) / (span.upperBound - span.lowerBound)
        return top + h - CGFloat(t) * h
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ colW: CGFloat) {
        let l = lanes
        let plotTop = l.icon
        let dewTop = plotTop + l.plot + (hasComfort ? 8 : 0)
        let rainTop = dewTop + l.dew + (hasRain ? 4 : 0)
        let axisTop = rainTop + l.rain + 4

        drawBand(ctx, colW, top: plotTop, height: l.plot)
        if hasComfort { drawComfort(ctx, colW, top: dewTop, height: l.dew) }
        if hasRain { drawRain(ctx, colW, top: rainTop, height: l.rain) }
        drawAxis(ctx, colW, top: axisTop)
        drawHover(ctx, colW, size: size, plotTop: plotTop, plotHeight: l.plot, bottom: axisTop)
    }

    /// Highs and lows as one band: the line pair is the week's trend, the thickness
    /// between them is each day's swing. Numbers only where a curve turns.
    private func drawBand(_ ctx: GraphicsContext, _ colW: CGFloat, top: CGFloat, height: CGFloat) {
        let hiPts: [CGPoint?] = days.indices.map { i in
            days[i].high.map { CGPoint(x: x(Double(i), colW), y: y($0, top, height)) }
        }
        let loPts: [CGPoint?] = days.indices.map { i in
            days[i].low.map { CGPoint(x: x(Double(i), colW), y: y($0, top, height)) }
        }
        let hiLine = HourlyRibbon.smoothPath(hiPts)
        let loLine = HourlyRibbon.smoothPath(loPts)

        // The fill between the curves — drawn as the high curve out and the low curve
        // back, so the band closes on the data instead of on the lane's edges.
        let loBack = Array(loPts.compactMap { $0 }.reversed())
        if !hiPts.compactMap({ $0 }).isEmpty, !loBack.isEmpty {
            var fill = hiLine
            fill.addLine(to: loBack[0])
            Self.appendSmooth(&fill, loBack)
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [.orange.opacity(0.30), .blue.opacity(0.18)]),
                startPoint: CGPoint(x: 0, y: top),
                endPoint: CGPoint(x: 0, y: top + height)))
        }
        ctx.stroke(hiLine, with: .color(.orange.opacity(0.9)),
                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        ctx.stroke(loLine, with: .color(.blue.opacity(0.75)),
                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

        for i in highMarks {
            guard let t = days[i].high, let p = hiPts[i] else { continue }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                     with: .color(.orange))
            let above = p.y - top > 16
            ctx.draw(Text("\(Int(t.rounded()))°").font(.caption.weight(.semibold)),
                     at: CGPoint(x: p.x, y: above ? p.y - 11 : p.y + 12), anchor: .center)
        }
        for i in lowMarks {
            guard let t = days[i].low, let p = loPts[i] else { continue }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                     with: .color(.blue.opacity(0.85)))
            let below = top + height - p.y > 16
            ctx.draw(Text("\(Int(t.rounded()))°").font(.caption)
                        .foregroundStyle(.secondary),
                     at: CGPoint(x: p.x, y: below ? p.y + 12 : p.y - 11), anchor: .center)
        }
    }

    /// Continue an existing path smoothly through more points — the band's fill has to
    /// come back along the low curve as ONE subpath, so it can't just append a second.
    private static func appendSmooth(_ path: inout Path, _ pts: [CGPoint]) {
        guard pts.count > 1 else { return }
        for i in 1..<pts.count {
            let prev = pts[i - 1], cur = pts[i]
            let midX = (prev.x + cur.x) / 2
            path.addQuadCurve(to: CGPoint(x: midX, y: (prev.y + cur.y) / 2),
                              control: CGPoint(x: midX, y: prev.y))
            path.addQuadCurve(to: cur, control: CGPoint(x: midX, y: cur.y))
        }
    }

    /// Humidity as forty stretches, not ten verdicts — the same four-slot day the
    /// grid's comfort bar used, run end to end so a muggy spell is one block of color.
    private func drawComfort(_ ctx: GraphicsContext, _ colW: CGFloat, top: CGFloat, height: CGFloat) {
        let slotW = colW / CGFloat(Self.partSlots.count)
        for i in days.indices {
            for (s, name) in Self.partSlots.enumerated() {
                let part = days[i].parts.first { $0.name == name }
                let dew = part?.dewPoint ?? (days[i].parts.isEmpty ? days[i].dewPoint : nil)
                let rect = CGRect(x: CGFloat(i) * colW + CGFloat(s) * slotW + 0.75, y: top,
                                  width: slotW - 1.5, height: height)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2),
                         with: .color(dew.map { dewBandColor($0).opacity(0.8) }
                                      ?? .primary.opacity(0.06)))
            }
        }
    }

    /// The hourly lane's grammar at day scale: the bar's HEIGHT is the chance, how far
    /// it's FILLED is the water. A 40% day holding a hundredth of an inch is a tall
    /// hollow bar, which is the honest picture of it.
    private func drawRain(_ ctx: GraphicsContext, _ colW: CGFloat, top: CGFloat, height: CGFloat) {
        let usable = height - 11
        for i in days.indices {
            let (prob, amount) = rain[i]
            guard prob >= 20 || (amount ?? 0) > 0 else { continue }

            let h = max(2, CGFloat(prob / 100) * usable)
            let rect = CGRect(x: x(Double(i), colW) - colW * 0.16, y: top + usable - h + 11,
                              width: colW * 0.32, height: h)
            let bar = Path(roundedRect: rect, cornerRadius: 2)
            ctx.fill(bar, with: .color(.blue.opacity(0.18)))
            ctx.stroke(bar, with: .color(.blue.opacity(0.5)), lineWidth: 1)

            if let amount, amount > 0 {
                let fillH = max(1.5, CGFloat(min(1, amount / Self.wetDay)) * h)
                ctx.fill(Path(roundedRect: CGRect(x: rect.minX, y: rect.maxY - fillH,
                                                  width: rect.width, height: fillH),
                              cornerRadius: 2),
                         with: .color(.blue.opacity(0.85)))
            }
            // The chance is printed on days worth planning around; the amount rides
            // the hover, where there's room for it.
            if prob >= 40 {
                ctx.draw(Text("\(Int(prob.rounded()))%").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.blue),
                         at: CGPoint(x: x(Double(i), colW), y: top + 5), anchor: .center)
            }
        }
    }

    private func drawAxis(_ ctx: GraphicsContext, _ colW: CGFloat, top: CGFloat) {
        for i in days.indices {
            let cx = x(Double(i), colW)
            ctx.draw(Text(labels[i].weekday)
                        .font(.system(size: 10, weight: i == 0 ? .bold : .semibold))
                        .foregroundStyle(i == 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)),
                     at: CGPoint(x: cx, y: top), anchor: .top)
            ctx.draw(Text(labels[i].date).font(.system(size: 9)).foregroundStyle(.tertiary),
                     at: CGPoint(x: cx, y: top + 13), anchor: .top)
        }
    }

    /// Everything the ten boxes used to print, for the one day being pointed at.
    private func drawHover(_ ctx: GraphicsContext, _ colW: CGFloat, size: CGSize,
                           plotTop: CGFloat, plotHeight: CGFloat, bottom: CGFloat) {
        guard let i = hover, days.indices.contains(i) else { return }
        let d = days[i]
        let cx = x(Double(i), colW)

        var line = Path()
        line.move(to: CGPoint(x: cx, y: plotTop))
        line.addLine(to: CGPoint(x: cx, y: bottom))
        ctx.stroke(line, with: .color(.primary.opacity(0.25)), lineWidth: 1)
        for (temp, color) in [(d.high, Color.orange), (d.low, Color.blue)] {
            guard let temp else { continue }
            let p = CGPoint(x: cx, y: y(temp, plotTop, plotHeight))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                     with: .color(color))
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                       with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }

        var parts = [labels[i].weekday]
        if let hi = d.high, let lo = d.low { parts.append("\(Int(hi.rounded()))° / \(Int(lo.rounded()))°") }
        if !d.conditions.isEmpty, d.conditions != "—" { parts.append(d.conditions.lowercased()) }
        if let hi = d.dewPointHigh, let lo = d.dewPointLow {
            parts.append(abs(hi - lo) >= 4 ? "dew \(Int(lo.rounded()))–\(Int(hi.rounded()))°"
                                           : "dew \(Int(hi.rounded()))°")
        } else if let dew = d.dewPoint {
            parts.append("dew \(Int(dew.rounded()))°")
        }
        let (prob, amount) = rain[i]
        if prob >= 20 { parts.append("\(Int(prob.rounded()))% rain") }
        if let amount, amount > 0 {
            parts.append(amount >= 0.01 ? String(format: "%.2f\"", amount) : "trace")
        }

        let text = ctx.resolve(Text(parts.joined(separator: "  ·  "))
            .font(.system(size: 10, weight: .medium)))
        let s = text.measure(in: size)
        let bx = min(max(cx - s.width / 2 - 7, 2), max(2, size.width - s.width - 16))
        let box = CGRect(x: bx, y: plotTop + 2, width: s.width + 14, height: s.height + 8)
        ctx.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(.black.opacity(0.72)))
        ctx.draw(text, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }
}
