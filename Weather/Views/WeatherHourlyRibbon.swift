//
//  WeatherHourlyRibbon.swift  (macOS)
//
//  The rest of the day as ONE continuous figure rather than a row of boxes.
//
//  A cell grid spends the same ink on every hour, so a day that holds at 94° from
//  three to six prints "94° 94° 94° 94°" and sixteen identical suns — the strip
//  works hardest exactly where nothing is happening. An hour isn't a thing; it's a
//  position in a day. So: the temperature is a curve labelled only where it TURNS,
//  the sky is drawn once per stretch of sky, and repetition costs nothing.
//
//  Two measures, never two axes. Temperature owns the vertical scale; the dew point
//  is a color wash under it (the same bands the Comfort gauge teaches), because
//  mugginess is read as a state, not off a y-value. Rain and wind get their own
//  lanes and stay blank when there's nothing to say.
//

import SwiftUI
import WeatherKit

struct HourlyRibbon: View {
    /// One stretch of hours sharing a part of a day — the 6/12/18 boundaries the day
    /// summary already uses, drawn as a background region instead of a card.
    struct Band: Identifiable {
        var id: Int { first }
        var title: String
        var first: Int          // index into `hours`, inclusive
        var last: Int           // inclusive
        var dew: Double?        // muggiest hour in the stretch
    }

    /// A run of hours whose sky doesn't change. One icon per run, centred.
    private struct IconRun: Identifiable {
        var id: Int { first }
        var icon: String
        var first: Int
        var last: Int
    }

    private let hours: [HourSlice]
    private let bands: [Band]
    private let iconRuns: [IconRun]
    private let marks: [Int]              // temperature turning points worth labelling
    private let span: ClosedRange<Double> // temperature domain
    private let hasRain: Bool
    private let hasWind: Bool
    private let nowIndex: Double?         // fractional position of "right now"
    private let localHours: [Int]

    @State private var hover: Int?

    init(hours: [HourSlice], timezone: TimeZone?, now: Date = Date()) {
        self.hours = hours
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone ?? .current

        let dates = hours.map { Date(timeIntervalSince1970: TimeInterval($0.epoch)) }
        let clockHours = dates.map { cal.component(.hour, from: $0) }
        // `ordinality(of: .day, in: .era, ...)` ignores the calendar's time zone and
        // counts days in UTC, so west of Greenwich the "day" rolled over in the middle
        // of the evening — the strip printed EVENING and then WED EVENING for the same
        // evening. Local midnight is the only day boundary that means anything here.
        let days = dates.map { Int(cal.startOfDay(for: $0).timeIntervalSince1970) }
        self.localHours = clockHours

        // Bands
        let weekday = DateFormatter()
        weekday.timeZone = timezone
        weekday.locale = Locale(identifier: "en_US")
        weekday.dateFormat = "EEE"
        var bands: [Band] = []
        var key: (day: Int, start: Int)?
        var named: Set<Int> = []
        for i in hours.indices {
            guard let w = WeatherInterpreter.dayPartWindows
                .first(where: { ($0.start..<$0.end).contains(clockHours[i]) }) else { continue }
            if key?.day != days[i] || key?.start != w.start {
                key = (days[i], w.start)
                // The weekday appears once, on the first band of a new day; repeating
                // it over every band of tomorrow would be noise.
                var title = w.name.uppercased()
                if days[i] != days[0], !named.contains(days[i]) {
                    title = "\(weekday.string(from: dates[i]).uppercased()) \(title)"
                    named.insert(days[i])
                }
                bands.append(Band(title: title, first: i, last: i))
            } else {
                bands[bands.count - 1].last = i
            }
        }
        for i in bands.indices {
            bands[i].dew = hours[bands[i].first...bands[i].last].compactMap(\.dewPoint).max()
        }
        self.bands = bands

        // One icon per run of unchanging sky — the whole point of leaving the grid.
        //
        // A MEASURED hour has no icon, and that isn't a hole to paper over. The
        // station reports temperature, wind, rain and pressure; it does not
        // report "partly cloudy", and deriving a sky from solar radiation would
        // be a guess wearing a record's clothes. So the lane starts at the seam,
        // and an empty icon ENDS a run rather than joining the two sides.
        var runs: [IconRun] = []
        var open: String?
        for i in hours.indices {
            let icon = hours[i].icon
            guard !icon.isEmpty else { open = nil; continue }
            if open == icon, !runs.isEmpty { runs[runs.count - 1].last = i }
            else { runs.append(IconRun(icon: icon, first: i, last: i)) }
            open = icon
        }
        self.iconRuns = runs

        let temps = hours.map(\.temperature)
        self.marks = Self.turningPoints(temps)
        let known = temps.compactMap { $0 }
        let lo = known.min() ?? 0, hi = known.max() ?? 1
        let pad = Swift.max(3, (hi - lo) * 0.18)
        self.span = (lo - pad)...(hi + pad)

        self.hasRain = hours.contains { ($0.precipProbability ?? 0) >= 20 || ($0.precip ?? 0) > 0 }
        self.hasWind = hours.contains { ($0.windAvg ?? 0) >= 1 }

        if let first = hours.first, hours.count > 1 {
            let offset = now.timeIntervalSince1970 - TimeInterval(first.epoch)
            let idx = offset / 3600
            self.nowIndex = (idx >= -0.5 && idx <= Double(hours.count) - 0.5) ? idx : nil
        } else {
            self.nowIndex = nil
        }
    }

    // MARK: Lanes

    private var lanes: (band: CGFloat, icon: CGFloat, plot: CGFloat, dew: CGFloat,
                        rain: CGFloat, wind: CGFloat, axis: CGFloat) {
        (band: 14, icon: 24, plot: 106, dew: 15,
         rain: hasRain ? 26 : 0, wind: hasWind ? 15 : 0, axis: 13)
    }

    private var height: CGFloat {
        let l = lanes
        return l.band + 6 + l.icon + l.plot + 6 + l.dew
            + (hasRain ? l.rain + 4 : 0) + (hasWind ? l.wind + 2 : 0) + 4 + l.axis
    }

    var body: some View {
        GeometryReader { geo in
            let minWidth = CGFloat(hours.count) * 40
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
        let colW = width / CGFloat(max(hours.count, 1))
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in draw(ctx, size, colW) }
            // SF Symbols keep their multicolor rendering only as real views, so the
            // sky lane sits above the canvas rather than inside it.
            ForEach(iconRuns) { run in
                Image(systemName: WeatherView.symbol(run.icon))
                    .font(.system(size: 15)).symbolRenderingMode(.multicolor)
                    .position(x: x(Double(run.first + run.last) / 2, colW),
                              y: lanes.band + 6 + lanes.icon / 2)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let i = Int((p.x / colW).rounded(.down))
                hover = hours.indices.contains(i) ? i : nil
            case .ended: hover = nil
            @unknown default: hover = nil
            }
        }
    }

    private func x(_ index: Double, _ colW: CGFloat) -> CGFloat {
        (CGFloat(index) + 0.5) * colW
    }

    private func y(_ temp: Double, _ top: CGFloat, _ h: CGFloat) -> CGFloat {
        let t = (temp - span.lowerBound) / (span.upperBound - span.lowerBound)
        return top + h - CGFloat(t) * h
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ colW: CGFloat) {
        let l = lanes
        let plotTop = l.band + 6 + l.icon
        let dewTop = plotTop + l.plot + 6
        let rainTop = dewTop + l.dew + (hasRain ? 4 : 0)
        let windTop = rainTop + l.rain + (hasWind ? 2 : 0)
        let axisTop = windTop + l.wind + 4

        drawNight(ctx, colW, top: plotTop, height: l.plot)
        drawBands(ctx, colW, size: size, plotTop: plotTop, plotHeight: l.plot)
        drawTemperature(ctx, colW, top: plotTop, height: l.plot)
        drawDew(ctx, colW, top: dewTop, height: l.dew)
        if hasRain { drawRain(ctx, colW, top: rainTop, height: l.rain) }
        if hasWind { drawWind(ctx, colW, top: windTop, height: l.wind) }
        drawAxis(ctx, colW, top: axisTop)
        drawNow(ctx, colW, top: plotTop, bottom: axisTop)
        drawHover(ctx, colW, size: size, plotTop: plotTop, plotHeight: l.plot, bottom: axisTop)
    }

    /// Night as a wash behind the plot — the reason the curve falls, stated once.
    private func drawNight(_ ctx: GraphicsContext, _ colW: CGFloat, top: CGFloat, height: CGFloat) {
        var i = 0
        while i < hours.count {
            guard hours[i].isNight else { i += 1; continue }
            var j = i
            while j + 1 < hours.count, hours[j + 1].isNight { j += 1 }
            let rect = CGRect(x: CGFloat(i) * colW, y: top,
                              width: CGFloat(j - i + 1) * colW, height: height)
            ctx.fill(Path(rect), with: .color(.primary.opacity(0.05)))
            i = j + 1
        }
    }

    /// The day's parts as regions, not cards: a name, a hairline where one ends, and
    /// the stretch's muggiest hour as the color of its rule.
    private func drawBands(_ ctx: GraphicsContext, _ colW: CGFloat, size: CGSize,
                           plotTop: CGFloat, plotHeight: CGFloat) {
        for band in bands {
            let x0 = CGFloat(band.first) * colW
            let x1 = CGFloat(band.last + 1) * colW
            let color = band.dew.map { dewBandColor($0) } ?? Color.secondary
            let rule = CGRect(x: x0 + 1, y: lanes.band - 3, width: x1 - x0 - 2, height: 2.5)
            ctx.fill(Path(roundedRect: rule, cornerRadius: 1.25),
                     with: .color(color.opacity(0.55)))
            ctx.draw(Text(band.title).font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary),
                     at: CGPoint(x: x0 + 3, y: 0), anchor: .topLeading)
            if band.first > 0 {
                var sep = Path()
                sep.move(to: CGPoint(x: x0, y: plotTop))
                sep.addLine(to: CGPoint(x: x0, y: plotTop + plotHeight))
                ctx.stroke(sep, with: .color(.primary.opacity(0.08)), lineWidth: 1)
            }
        }
    }

    /// The curve, labelled only where it turns. A flat afternoon prints one number.
    private func drawTemperature(_ ctx: GraphicsContext, _ colW: CGFloat,
                                 top: CGFloat, height: CGFloat) {
        let pts: [CGPoint?] = hours.indices.map { i in
            hours[i].temperature.map { CGPoint(x: x(Double(i), colW), y: y($0, top, height)) }
        }
        let line = Self.smoothPath(pts)
        guard !line.isEmpty else { return }

        var fill = line
        if let last = pts.compactMap({ $0 }).last, let first = pts.compactMap({ $0 }).first {
            fill.addLine(to: CGPoint(x: last.x, y: top + height))
            fill.addLine(to: CGPoint(x: first.x, y: top + height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [.orange.opacity(0.28), .orange.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: top),
                endPoint: CGPoint(x: 0, y: top + height)))
        }
        // WHAT HAPPENED AND WHAT IS EXPECTED ARE NOT THE SAME CLAIM. Behind the
        // seam the station measured this; ahead of it a model guessed, and it
        // will move before the day is out. One continuous curve stroked one way
        // would quietly assert we'd measured tonight — so the fact is solid and
        // the guess is dashed, joined at the shared point so the shape survives.
        let seam = hours.lastIndex { $0.isObserved }
        if let seam, seam < hours.count - 1 {
            ctx.stroke(Self.smoothPath(Array(pts[0...seam])),
                       with: .color(.orange.opacity(0.95)),
                       style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            ctx.stroke(Self.smoothPath(Array(pts[seam...])),
                       with: .color(.orange.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round,
                                          dash: [4, 3]))
        } else {
            ctx.stroke(line, with: .color(.orange.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }

        for i in marks {
            guard let t = hours[i].temperature, let p = pts[i] else { continue }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                     with: .color(.orange))
            // Above the point unless that would clip the top of the lane.
            let above = p.y - top > 18
            ctx.draw(Text("\(Int(t.rounded()))°").font(.caption.weight(.semibold)),
                     at: CGPoint(x: p.x, y: above ? p.y - 12 : p.y + 13), anchor: .center)
        }
    }

    /// Humidity as a wash, not a second axis: the comfort bands the gauge teaches,
    /// blended hour to hour so the moment it eases off is a color change.
    private func drawDew(_ ctx: GraphicsContext, _ colW: CGFloat, top: CGFloat, height: CGFloat) {
        let dews = hours.map(\.dewPoint)
        guard dews.contains(where: { $0 != nil }) else { return }
        let stops = hours.indices.compactMap { i -> Gradient.Stop? in
            guard let d = dews[i] else { return nil }
            return Gradient.Stop(color: dewBandColor(d).opacity(0.75),
                                 location: Double(i) / Double(max(hours.count - 1, 1)))
        }
        let rect = CGRect(x: 0, y: top, width: CGFloat(hours.count) * colW, height: height)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 4),
                 with: .linearGradient(Gradient(stops: stops),
                                       startPoint: CGPoint(x: x(0, colW), y: 0),
                                       endPoint: CGPoint(x: x(Double(hours.count - 1), colW), y: 0)))

        // Two labels: where it starts and where it settles. The wash carries the rest.
        let known = dews.enumerated().compactMap { pair in pair.element.map { (pair.offset, $0) } }
        if let first = known.first {
            ctx.draw(Text("DEW \(Int(first.1.rounded()))°")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white),
                     at: CGPoint(x: x(Double(first.0), colW) - 4, y: top + height / 2),
                     anchor: .leading)
        }
        if let last = known.last, let first = known.first, abs(last.1 - first.1) >= 3 {
            ctx.draw(Text("\(Int(last.1.rounded()))°")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white),
                     at: CGPoint(x: x(Double(last.0), colW) + 4, y: top + height / 2),
                     anchor: .trailing)
        }
    }

    /// How much rain a bar has to hold before it reads as "raining" rather than
    /// "damp" — a fixed referent, so a filled bar means the same thing every day.
    private static let wetHour = 0.10   // inches in one hour

    /// Columns only where rain is actually possible — the lane is blank on a dry day.
    ///
    /// A bar's HEIGHT is the chance; how far it's FILLED is how much water is coming.
    /// The two are different questions and they disagree constantly: a 30% hour with
    /// 0.01" is a tall hollow bar (it probably won't, and if it does it's nothing),
    /// while 30% with a quarter inch is a tall solid one. Filling to a fixed 0.10"/hr
    /// keeps that reading stable from day to day.
    private func drawRain(_ ctx: GraphicsContext, _ colW: CGFloat, top: CGFloat, height: CGFloat) {
        let usable = height - 11
        var peak: (x: CGFloat, prob: Double)?
        var total = 0.0
        for i in hours.indices {
            let prob = hours[i].precipProbability ?? 0
            let amount = hours[i].precip ?? 0
            guard prob >= 20 || amount > 0 else { continue }
            total += amount

            let h = max(2, CGFloat(prob / 100) * usable)
            let rect = CGRect(x: x(Double(i), colW) - colW * 0.22, y: top + usable - h + 11,
                              width: colW * 0.44, height: h)
            let bar = Path(roundedRect: rect, cornerRadius: 2)
            ctx.fill(bar, with: .color(.blue.opacity(0.18)))
            ctx.stroke(bar, with: .color(.blue.opacity(0.5)), lineWidth: 1)

            // The water, poured into the bar from the bottom.
            let wet = min(1, amount / Self.wetHour)
            if wet > 0 {
                let fillH = max(1.5, CGFloat(wet) * h)
                let fill = CGRect(x: rect.minX, y: rect.maxY - fillH,
                                  width: rect.width, height: fillH)
                ctx.fill(Path(roundedRect: fill, cornerRadius: 2), with: .color(.blue.opacity(0.85)))
            }
            // A CHANCE ONLY EXISTS AHEAD OF THE SEAM. A measured hour's bar is
            // full because it rained, not because it was likely to, so it can't
            // compete to carry a "likeliest hour" label — quoting 100% for a
            // morning that's already over says nothing and reads as a forecast.
            if !hours[i].isObserved, peak == nil || prob > peak!.prob {
                peak = (x(Double(i), colW), prob)
            }
        }
        // Nothing ahead to be likely, but rain already in the day still wants its
        // total said — hang it on the wettest hour instead.
        let anchor = peak ?? hours.indices
            .filter { (hours[$0].precip ?? 0) > 0 }
            .max { (hours[$0].precip ?? 0) < (hours[$1].precip ?? 0) }
            .map { (x: x(Double($0), colW), prob: Double.nan) }
        guard let anchor else { return }
        // One label, on the likeliest hour: the chance, and the day's water beside it,
        // because a chance without an amount is the thing that misleads.
        let amount = total >= 0.01 ? String(format: "%.2f\"", total)
                   : (total > 0 ? "trace" : nil)
        let chance = anchor.prob.isNaN ? nil : String(Int(anchor.prob.rounded())) + "%"
        let label = [chance, amount].compactMap { $0 }.joined(separator: "  ·  ")
        guard !label.isEmpty else { return }
        ctx.draw(Text(label).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.blue),
                 at: CGPoint(x: anchor.x, y: top + 5), anchor: .center)
    }

    /// Sparse arrows pointing where the wind is GOING, every third hour.
    private func drawWind(_ ctx: GraphicsContext, _ colW: CGFloat, top: CGFloat, height: CGFloat) {
        let mid = top + height / 2
        for i in hours.indices where localHours[i] % 3 == 0 {
            guard let speed = hours[i].windAvg, speed >= 1 else { continue }
            let cx = x(Double(i), colW)
            let bearing = hours[i].windDirection
                ?? hours[i].windDirectionCardinal.flatMap(Compass.degrees)
            if let from = bearing {
                ctx.drawLayer { layer in
                    layer.translateBy(x: cx - 9, y: mid)
                    layer.rotate(by: .degrees(from + 180))
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: 0, y: 4.5))
                    arrow.addLine(to: CGPoint(x: 0, y: -4.5))
                    arrow.move(to: CGPoint(x: -2.5, y: -2))
                    arrow.addLine(to: CGPoint(x: 0, y: -4.5))
                    arrow.addLine(to: CGPoint(x: 2.5, y: -2))
                    layer.stroke(arrow, with: .color(.secondary),
                                 style: StrokeStyle(lineWidth: 1.2, lineCap: .round,
                                                    lineJoin: .round))
                }
            }
            ctx.draw(Text("\(Int(speed.rounded()))").font(.system(size: 9))
                        .foregroundStyle(.secondary),
                     at: CGPoint(x: cx + 1, y: mid), anchor: .leading)
        }
    }

    private func drawAxis(_ ctx: GraphicsContext, _ colW: CGFloat, top: CGFloat) {
        for i in hours.indices where localHours[i] % 3 == 0 {
            ctx.draw(Text(hours[i].clock.uppercased()).font(.system(size: 9))
                        .foregroundStyle(.tertiary),
                     at: CGPoint(x: x(Double(i), colW), y: top), anchor: .top)
        }
    }

    private func drawNow(_ ctx: GraphicsContext, _ colW: CGFloat, top: CGFloat, bottom: CGFloat) {
        guard let nowIndex else { return }
        let cx = x(nowIndex, colW)
        var line = Path()
        line.move(to: CGPoint(x: cx, y: top))
        line.addLine(to: CGPoint(x: cx, y: bottom))
        ctx.stroke(line, with: .color(.primary.opacity(0.35)),
                   style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
    }

    /// The readout the cells used to hold. It appears under the cursor instead of
    /// being printed sixteen times.
    private func drawHover(_ ctx: GraphicsContext, _ colW: CGFloat, size: CGSize,
                           plotTop: CGFloat, plotHeight: CGFloat, bottom: CGFloat) {
        guard let i = hover, hours.indices.contains(i) else { return }
        let h = hours[i]
        let cx = x(Double(i), colW)

        var line = Path()
        line.move(to: CGPoint(x: cx, y: plotTop))
        line.addLine(to: CGPoint(x: cx, y: bottom))
        ctx.stroke(line, with: .color(.primary.opacity(0.25)), lineWidth: 1)
        if let t = h.temperature {
            let p = CGPoint(x: cx, y: y(t, plotTop, plotHeight))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                     with: .color(.orange))
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                       with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }

        var parts = [h.clock.uppercased()]
        if let t = h.temperature { parts.append("\(Int(t.rounded()))°") }
        if let d = h.dewPoint { parts.append("dew \(Int(d.rounded()))°") }
        // A measured hour has no chance left in it, only an amount.
        if !h.isObserved, let p = h.precipProbability, p >= 20 {
            parts.append("\(Int(p.rounded()))% rain")
        }
        if let amt = h.precip, amt > 0 {
            parts.append(amt >= 0.01 ? String(format: "%.2f\"", amt) : "trace")
        }
        let wind = [h.windDirectionCardinal, h.windAvg.map { "\(Int($0.rounded()))" }]
            .compactMap { $0 }.joined(separator: " ")
        if !wind.isEmpty { parts.append(wind) }

        let text = ctx.resolve(Text(parts.joined(separator: "  ·  "))
            .font(.system(size: 10, weight: .medium)))
        let s = text.measure(in: size)
        let bx = min(max(cx - s.width / 2 - 7, 2), size.width - s.width - 16)
        let box = CGRect(x: bx, y: plotTop + 2, width: s.width + 14, height: s.height + 8)
        ctx.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(.black.opacity(0.72)))
        ctx.draw(text, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }

    // MARK: Shape helpers

    /// Where the temperature actually changes direction — the only places a number
    /// earns a label. A plateau is labelled once, at its middle.
    static func turningPoints(_ temps: [Double?]) -> [Int] {
        let known = temps.enumerated().compactMap { i, t in t.map { (i, $0) } }
        guard known.count > 2 else { return known.map(\.0) }
        var out = [known[0].0]
        var i = 1
        while i < known.count - 1 {
            var j = i
            while j + 1 < known.count, abs(known[j + 1].1 - known[i].1) < 0.5 { j += 1 }
            let before = known[i - 1].1
            let after = j + 1 < known.count ? known[j + 1].1 : known[j].1
            if (known[i].1 > before && known[i].1 > after)
                || (known[i].1 < before && known[i].1 < after) {
                out.append(known[(i + j) / 2].0)
            }
            i = j + 1
        }
        out.append(known[known.count - 1].0)
        // Two labels three hours apart just collide; keep the first of a close pair.
        var kept: [Int] = []
        for idx in out where kept.last.map({ idx - $0 >= 3 }) ?? true { kept.append(idx) }
        return kept
    }

    static func smoothPath(_ pts: [CGPoint?]) -> Path {
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
