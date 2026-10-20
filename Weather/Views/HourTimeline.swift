//
//  HourTimeline.swift  (Weather, VaneTV)
//
//  Hours as one figure: temperature, dew point, rain, the models, wind and
//  storms on a shared clock — today on Now, the next three days on Forecast,
//  a past day in History, and the three days at ten-foot size on the TV.
//
//  ONE CHART, NOT TWO. Now's ribbon and Forecast's timeline were drawn with
//  the same grammar (a curve labelled where it matters, rain bars whose height
//  is the chance and whose fill is the water, night as a wash) and had drifted
//  apart only because each grew its own features: Now had the dew point and the
//  measured-versus-forecast seam, Forecast had the models, storms and a wind
//  line. Each page now gets all of them.
//
//  A LANE IS DRAWN ONLY WHEN IT HAS SOMETHING TO SAY. Temperature and the dew
//  point always; rain when an hour has a real chance or measured water; the
//  models when one of them has rain; storms when an outlook names one; wind as a
//  full lane when it gusts to something you'd notice, and otherwise as a row of
//  arrows. What's left out is NOT left unsaid — a missing lane looks exactly
//  like a chart that never had one — so the lanes that stood down are named in
//  one line above the figure: "Dry · no storms expected · gusts under 20 mph".
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

/// The color for a dew point, matching the Comfort gauge's bands. One function so the
/// hourly chips, the day-part track and the week bars all say the same thing. Here
/// rather than with the gauge so the TV, which draws the timeline, compiles it.
func dewBandColor(_ dew: Double) -> Color {
    switch dew {
    case ..<55: return .teal
    case ..<60: return .green
    case ..<65: return .yellow
    case ..<70: return .orange
    default:    return .red
    }
}

// MARK: - The timeline

struct HourTimeline: View {
    private struct DaySpan: Identifiable {
        var id: String { key }
        let key: String
        let title: String
        let first: Int
        let last: Int
        let high: Int?
        let low: Int?
    }

    /// A part of a day — the 6/12/18 boundaries the day summary uses — drawn as a
    /// region on a single-day figure, its rule coloured by the stretch's muggiest hour.
    private struct Band: Identifiable {
        var id: Int { first }
        var title: String
        var first: Int
        var last: Int
        var dew: Double?
    }

    private let hours: [HourSlice]
    private let spans: [DaySpan]
    private let bands: [Band]
    /// A single day is read closer: its parts named, its sky drawn per stretch,
    /// its curve labelled wherever it turns rather than only at the extremes.
    private let isSingleDay: Bool
    private let turningPoints: [Int]
    /// Nil when nobody asked for an outlook (History, a Now with none loaded).
    private let risks: [String: StormRisk]?
    private let agreement: [Int: (wet: Int, of: Int)]
    private let tempSpan: ClosedRange<Double>
    private let windMax: Double
    private let peakGust: Double
    private let nowIndex: Double?
    private let localHours: [Int]
    private let calendar: Calendar
    private let scale: CGFloat
    private let textScale: CGFloat
    /// Read from across a room: the lane names get a column of their own, and
    /// the hours with rain are numbered under their bars. See `init`.
    private let isTenFoot: Bool

    // Which lanes speak.
    private let showsRain: Bool
    private let showsModels: Bool
    private let showsStorms: Bool
    private let showsWindLine: Bool
    private let showsWindArrows: Bool
    private let showsDew: Bool

    @State private var hover: Int?

    /// A fixed referent: a full bar is a tenth of an inch in the hour, so a
    /// filled bar means the same thing every day.
    private static let wetHour = 0.10
    /// Where a gust starts to be something you notice: umbrellas, trash cans.
    private static let gusty = 25.0
    /// Below this the wind gets arrows, not a lane of its own.
    private static let windWorthALane = 20.0
    /// The chance an hour needs before rain gets a lane.
    private static let rainChance = 20.0

    init(hours: [HourSlice], timezone: TimeZone?, precip: PrecipOutlook? = nil,
         risks: [String: StormRisk]? = nil, scale: CGFloat = 1, textScale: CGFloat? = nil,
         isTenFoot: Bool = false, now: Date = Date()) {
        self.hours = hours
        self.scale = scale
        self.textScale = textScale ?? scale
        // ON THE TV the words are drawn larger than the shapes, and at that size
        // the lane names sat on the data: "RAIN" over the first bars and the
        // day's rain total, the gust line straight through "WIND". So there they
        // get a column the plot doesn't enter. And with no pointer to read an
        // hour off, the rain bars are numbered — otherwise "which hour is that
        // bar" means counting ticks from the last axis label.
        self.isTenFoot = isTenFoot
        self.risks = risks
        let zone = timezone ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        self.calendar = cal
        let dates = hours.map { Date(timeIntervalSince1970: TimeInterval($0.epoch)) }
        let clockHours = dates.map { cal.component(.hour, from: $0) }
        self.localHours = clockHours

        // MARK: Days
        let keys = dates.map { DayKey.string(for: $0, timeZone: zone) }
        let weekday = DateFormatter()
        weekday.timeZone = zone
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
        // Today's midnight-to-midnight strip, or a past day: up to a day and a bit.
        let single = hours.count <= 26
        self.isSingleDay = single

        // MARK: Parts of the day (single day only)
        var bands: [Band] = []
        if single {
            let short = DateFormatter()
            short.timeZone = zone
            short.locale = Locale(identifier: "en_US")
            short.dateFormat = "EEE"
            var open: (day: String, start: Int)?
            var named: Set<String> = []
            for i in hours.indices {
                guard let w = WeatherInterpreter.dayPartWindows
                    .first(where: { ($0.start..<$0.end).contains(clockHours[i]) }) else { continue }
                if open?.day != keys[i] || open?.start != w.start {
                    open = (keys[i], w.start)
                    // The weekday appears once, on the first band of a new day.
                    var title = w.name.uppercased()
                    if keys[i] != keys[0], !named.contains(keys[i]) {
                        title = "\(short.string(from: dates[i]).uppercased()) \(title)"
                        named.insert(keys[i])
                    }
                    bands.append(Band(title: title, first: i, last: i))
                } else {
                    bands[bands.count - 1].last = i
                }
            }
            for k in bands.indices {
                bands[k].dew = hours[bands[k].first...bands[k].last].compactMap(\.dewPoint).max()
            }
        }
        self.bands = bands
        self.turningPoints = single ? Self.turningPoints(hours.map(\.temperature)) : []

        // MARK: Scales
        let temps = hours.compactMap(\.temperature)
        let lo = temps.min() ?? 0, hi = temps.max() ?? 1
        let pad = Swift.max(3, (hi - lo) * 0.15)
        self.tempSpan = (lo - pad)...(hi + pad)
        let gusts = hours.compactMap(\.windGust) + hours.compactMap(\.windAvg)
        self.peakGust = gusts.max() ?? 0
        self.windMax = Swift.max(30, peakGust)

        // MARK: Models
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

        // MARK: Which lanes speak
        self.showsRain = hours.contains { h in
            (!h.isObserved && (h.precipProbability ?? 0) >= Self.rainChance) || (h.precip ?? 0) > 0
        }
        self.showsModels = agreement.values.contains { $0.0 > 0 }
        self.showsStorms = risks.map { r in spans.contains { r[$0.key]?.category != nil } } ?? false
        self.showsWindLine = peakGust >= Self.windWorthALane
        self.showsWindArrows = !showsWindLine && hours.contains { ($0.windAvg ?? 0) >= 1 }
        self.showsDew = hours.contains { $0.dewPoint != nil }

        if let first = hours.first {
            let idx = (now.timeIntervalSince1970 - TimeInterval(first.epoch)) / 3600
            self.nowIndex = (idx >= -0.5 && idx <= Double(hours.count) - 0.5) ? idx : nil
        } else {
            self.nowIndex = nil
        }
    }

    // MARK: What stood down

    /// The lanes that had nothing to say, said in one line.
    private var quietLanes: String? {
        var parts: [String] = []
        if !showsRain { parts.append(hours.allSatisfy(\.isObserved) ? "No rain" : "Dry") }
        if let risks {
            if !showsStorms {
                let missing = spans.contains { risks[$0.key] == nil }
                parts.append(missing ? "no storm outlook for some days" : "no storms expected")
            }
        }
        if !showsWindLine, peakGust > 0 {
            parts.append("gusts under \(Int(Self.windWorthALane)) mph")
        }
        guard !parts.isEmpty else { return nil }
        var line = parts.joined(separator: " · ")
        line = line.prefix(1).uppercased() + line.dropFirst()
        return line
    }

    // MARK: Lanes

    private struct Lanes {
        let s: CGFloat
        let single: Bool
        let dew: Bool, rain: Bool, models: Bool, windLine: Bool, windArrows: Bool, storms: Bool
        /// Height of the row of hour numbers under the rain bars; 0 for none.
        let rainHours: CGFloat

        var header: CGFloat { (single ? 16 : 18) * s }
        var icon: CGFloat { 24 * s }
        var temp: CGFloat { (single ? 106 : 120) * s }
        var dewH: CGFloat { dew ? 13 * s : 0 }
        var rainH: CGFloat { rain ? 40 * s : 0 }
        var modelsH: CGFloat { models ? 10 * s : 0 }
        var windH: CGFloat { windLine ? 44 * s : (windArrows ? 15 * s : 0) }
        var stormH: CGFloat { storms ? 18 * s : 0 }
        var axis: CGFloat { 13 * s }
        var gap: CGFloat { 6 * s }

        private func after(_ top: CGFloat, _ h: CGFloat) -> CGFloat { top + h + (h > 0 ? gap : 0) }

        var iconTop: CGFloat { header + 2 * s }
        var tempTop: CGFloat { iconTop + icon }
        var dewTop: CGFloat { tempTop + temp + gap }
        var rainTop: CGFloat { after(dewTop, dewH) }
        var rainHoursTop: CGFloat { rainTop + rainH + (rainHours > 0 ? 2 * s : 0) }
        var modelsTop: CGFloat { rain ? rainHoursTop + rainHours + 1 * s : rainTop }
        var windTop: CGFloat { after(modelsTop, modelsH) }
        var stormTop: CGFloat { after(windTop, windH) }
        var axisTop: CGFloat { after(stormTop, stormH) + 2 * s }
        var height: CGFloat { axisTop + axis }
    }

    private var lanes: Lanes {
        Lanes(s: scale, single: isSingleDay, dew: showsDew, rain: showsRain, models: showsModels,
              windLine: showsWindLine, windArrows: showsWindArrows, storms: showsStorms,
              rainHours: isTenFoot && showsRain ? tx(8) : 0)
    }

    /// The column the lane names sit in on a ten-foot screen; 0 elsewhere,
    /// where they share the plot's left edge as they always have.
    private var gutter: CGFloat { isTenFoot ? tx(40) : 0 }

    /// A length at this figure's scale.
    private func pt(_ points: CGFloat) -> CGFloat { points * scale }
    /// A type size, or a gap that makes room for type, at the text's scale.
    private func tx(_ points: CGFloat) -> CGFloat { points * textScale }

    /// Narrowest an hour may be drawn before the figure scrolls sideways. A
    /// single day is read hour by hour, so it gets far more room per hour.
    private var hourMinimum: CGFloat { isSingleDay ? 40 : pt(11) }

    var body: some View {
        VStack(alignment: .leading, spacing: tx(6)) {
            if let quietLanes {
                Text(quietLanes)
                    .font(.system(size: tx(11), weight: .medium))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let minWidth = CGFloat(hours.count) * hourMinimum
                if geo.size.width >= minWidth {
                    figure(width: geo.size.width)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        figure(width: minWidth).frame(width: minWidth)
                    }
                    // Opens at NOW, not at midnight. On a phone a day is three
                    // screens wide, and opening on the left edge meant that at
                    // seven in the evening the first thing shown was 12–6 AM.
                    .defaultScrollAnchor(nowAnchor(viewport: geo.size.width, content: minWidth),
                                         for: .initialOffset)
                    // A NEW FRAME IS A NEW SCROLL: keyed to the first hour, a
                    // changed frame gets its own initial offset, while a refresh
                    // of the same frame keeps wherever you had scrolled to.
                    .id(hours.first?.epoch)
                }
            }
            .frame(height: lanes.height)
        }
    }

    /// The scroll anchor that puts now about a third of the way in.
    private func nowAnchor(viewport: CGFloat, content: CGFloat) -> UnitPoint? {
        guard let nowIndex, content > viewport else { return nil }
        let nowX = (CGFloat(nowIndex) + 0.5) * content / CGFloat(max(hours.count, 1))
        let u = (nowX - viewport * 0.3) / (content - viewport)
        return UnitPoint(x: min(max(u, 0), 1), y: 0.5)
    }

    private func figure(width: CGFloat) -> some View {
        let colW = (width - gutter) / CGFloat(max(hours.count, 1))
        return readable(ZStack(alignment: .topLeading) {
            Canvas { ctx, size in draw(ctx, size, colW) }
            // SF Symbols keep their multicolor rendering only as real views, so
            // the sky lane sits above the canvas rather than inside it.
            ForEach(iconMarks, id: \.self) { mark in
                Image(systemName: WeatherSymbol.name(hours[mark.at].icon))
                    .font(.system(size: tx(14))).symbolRenderingMode(.multicolor)
                    .position(x: gutter + x(mark.position, colW), y: lanes.iconTop + lanes.icon / 2)
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

    private struct IconMark: Hashable { var at: Int; var position: Double }

    /// A single day: one icon per run of unchanging sky. Three days: one per
    /// six hours, on the hour of the day's parts — seventy icons would be noise.
    ///
    /// A MEASURED hour has no icon, and that isn't a hole to paper over. The
    /// station does not report "partly cloudy", and deriving a sky from solar
    /// radiation would be a guess wearing a record's clothes.
    private var iconMarks: [IconMark] {
        guard isSingleDay else {
            return hours.indices.filter { localHours[$0] % 6 == 3 && !hours[$0].icon.isEmpty }
                .map { IconMark(at: $0, position: Double($0)) }
        }
        var runs: [(first: Int, last: Int)] = []
        var open: String?
        for i in hours.indices {
            let icon = hours[i].icon
            guard !icon.isEmpty else { open = nil; continue }
            if open == icon, !runs.isEmpty { runs[runs.count - 1].last = i } else { runs.append((i, i)) }
            open = icon
        }
        return runs.map { IconMark(at: $0.first, position: Double($0.first + $0.last) / 2) }
    }

    private func x(_ index: Double, _ colW: CGFloat) -> CGFloat { (CGFloat(index) + 0.5) * colW }

    private func yTemp(_ t: Double) -> CGFloat {
        let f = (t - tempSpan.lowerBound) / (tempSpan.upperBound - tempSpan.lowerBound)
        return lanes.tempTop + lanes.temp - CGFloat(f) * lanes.temp
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ colW: CGFloat) {
        drawLaneLabels(ctx)
        // Everything else is drawn in the plot's own coordinates, right of the
        // gutter when there is one.
        var ctx = ctx
        ctx.translateBy(x: gutter, y: 0)
        drawNight(ctx, colW)
        if isSingleDay { drawBands(ctx, colW) } else { drawDays(ctx, colW) }
        drawTemperature(ctx, colW)
        if showsDew { drawDew(ctx, colW) }
        if showsRain { drawRain(ctx, colW); drawRainHours(ctx, colW) }
        if showsModels { drawModels(ctx, colW) }
        if showsWindLine { drawWindLine(ctx, colW) }
        if showsWindArrows { drawWindArrows(ctx, colW) }
        if showsStorms { drawStorms(ctx, colW) }
        drawAxis(ctx, colW)
        drawNow(ctx, colW)
        drawHover(ctx, colW, size: size)
    }

    private func drawNight(_ ctx: GraphicsContext, _ colW: CGFloat) {
        let top = lanes.tempTop, bottom = lanes.axisTop - lanes.gap
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
    private func drawDays(_ ctx: GraphicsContext, _ colW: CGFloat) {
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

    /// The day's parts as regions, not cards: a name, a hairline where one ends,
    /// and the stretch's muggiest hour as the colour of its rule.
    private func drawBands(_ ctx: GraphicsContext, _ colW: CGFloat) {
        for band in bands {
            let x0 = CGFloat(band.first) * colW
            let x1 = CGFloat(band.last + 1) * colW
            let color = band.dew.map { dewBandColor($0) } ?? Color.secondary
            let rule = CGRect(x: x0 + 1, y: lanes.header - pt(3), width: x1 - x0 - 2, height: pt(2.5))
            ctx.fill(Path(roundedRect: rule, cornerRadius: pt(1.25)), with: .color(color.opacity(0.55)))
            ctx.draw(Text(band.title).font(.system(size: tx(9), weight: .semibold)).foregroundStyle(.secondary),
                     at: CGPoint(x: x0 + 3, y: 0), anchor: .topLeading)
            if band.first > 0 {
                var sep = Path()
                sep.move(to: CGPoint(x: x0, y: lanes.tempTop))
                sep.addLine(to: CGPoint(x: x0, y: lanes.tempTop + lanes.temp))
                ctx.stroke(sep, with: .color(.primary.opacity(0.08)), lineWidth: 1)
            }
        }
    }

    private func drawLaneLabels(_ ctx: GraphicsContext) {
        func label(_ s: String, _ y: CGFloat) {
            ctx.draw(Text(s).font(.system(size: tx(8), weight: .bold)).foregroundStyle(.tertiary),
                     at: CGPoint(x: pt(3), y: y), anchor: .topLeading)
        }
        if showsRain { label("RAIN", lanes.rainTop) }
        if showsModels { label("MODELS", lanes.modelsTop) }
        if showsWindLine { label("WIND", lanes.windTop) }
        if showsStorms { label("STORMS", lanes.stormTop + pt(4)) }
    }

    /// Where the storm lane's own label ends. A bar under it centres its label
    /// in what is left, or drops it.
    private func stormLabelEnd(_ ctx: GraphicsContext) -> CGFloat {
        // In its own column the label is already clear of every bar.
        guard gutter == 0 else { return 0 }
        return pt(3) + ctx.resolve(Text("STORMS").font(.system(size: tx(8), weight: .bold)))
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
        // WHAT HAPPENED AND WHAT IS EXPECTED ARE NOT THE SAME CLAIM. Behind the
        // seam the station measured this; ahead of it a model guessed. One curve
        // stroked one way would quietly assert we'd measured tonight — so the
        // fact is solid and the guess is dashed, joined at the shared point.
        let seam = hours.lastIndex { $0.isObserved }
        if let seam, seam < hours.count - 1 {
            ctx.stroke(SmoothCurve.path(Array(pts[0...seam])), with: .color(.orange.opacity(0.95)),
                       style: StrokeStyle(lineWidth: pt(2.2), lineCap: .round, lineJoin: .round))
            ctx.stroke(SmoothCurve.path(Array(pts[seam...])), with: .color(.orange.opacity(0.7)),
                       style: StrokeStyle(lineWidth: pt(1.8), lineCap: .round, lineJoin: .round, dash: [pt(4), pt(3)]))
        } else {
            ctx.stroke(line, with: .color(.orange.opacity(0.9)),
                       style: StrokeStyle(lineWidth: pt(2), lineCap: .round, lineJoin: .round))
        }

        // A single day is labelled wherever it turns; three days at each day's
        // high and low.
        var marks: [(index: Int, isHigh: Bool)] = []
        if isSingleDay {
            marks = turningPoints.map { ($0, true) }
        } else {
            for span in spans {
                if let h = span.high { marks.append((h, true)) }
                if let l = span.low { marks.append((l, false)) }
            }
        }
        for mark in marks {
            guard let t = hours[mark.index].temperature, let p = pts[mark.index] else { continue }
            let r = pt(3)
            let isLow = !isSingleDay && !mark.isHigh
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(isLow ? .blue.opacity(0.8) : .orange))
            let above = isLow ? !(bottom - p.y > tx(16)) : p.y - lanes.tempTop > tx(16)
            ctx.draw(Text("\(Int(t.rounded()))°").font(scale == 1 ? .caption.weight(.semibold)
                                                          : .system(size: tx(11), weight: .semibold))
                        .foregroundStyle(isLow ? Color.secondary : Color.primary),
                     at: CGPoint(x: p.x, y: above ? p.y - tx(11) : p.y + tx(12)), anchor: .center)
        }
    }

    /// Humidity as a wash, not a second axis: the comfort bands the gauge
    /// teaches, blended hour to hour so the moment it eases off is a colour
    /// change. Labelled where it starts, at each new day, and where it ends up,
    /// whenever that's a different number.
    private func drawDew(_ ctx: GraphicsContext, _ colW: CGFloat) {
        let dews = hours.map(\.dewPoint)
        let stops = hours.indices.compactMap { i -> Gradient.Stop? in
            guard let d = dews[i] else { return nil }
            return Gradient.Stop(color: dewBandColor(d).opacity(0.75),
                                 location: Double(i) / Double(max(hours.count - 1, 1)))
        }
        guard !stops.isEmpty else { return }
        let top = lanes.dewTop, h = lanes.dewH
        let rect = CGRect(x: 0, y: top, width: CGFloat(hours.count) * colW, height: h)
        ctx.fill(Path(roundedRect: rect, cornerRadius: pt(4)),
                 with: .linearGradient(Gradient(stops: stops),
                                       startPoint: CGPoint(x: x(0, colW), y: 0),
                                       endPoint: CGPoint(x: x(Double(hours.count - 1), colW), y: 0)))

        let known = dews.enumerated().compactMap { pair in pair.element.map { (pair.offset, $0) } }
        guard let first = known.first else { return }
        func label(_ text: String, at index: Int, trailing: Bool = false) {
            ctx.draw(Text(text).font(.system(size: tx(9), weight: .bold)).foregroundStyle(.white),
                     at: CGPoint(x: x(Double(index), colW) + (trailing ? pt(4) : -pt(4)), y: top + h / 2),
                     anchor: trailing ? .trailing : .leading)
        }
        label("DEW \(Int(first.1.rounded()))°", at: first.0)
        var said = (index: first.0, value: first.1)
        for span in spans.dropFirst() {
            guard let d = dews[span.first], abs(d - said.value) >= 3 else { continue }
            label("\(Int(d.rounded()))°", at: span.first + 1)
            said = (span.first, d)
        }
        if let end = known.last, abs(end.1 - said.value) >= 3, end.0 - said.index >= 6 {
            label("\(Int(end.1.rounded()))°", at: end.0, trailing: true)
        }
    }

    private func drawRain(_ ctx: GraphicsContext, _ colW: CGFloat) {
        let top = lanes.rainTop + tx(10), usable = lanes.rainH - tx(10)
        // A baseline so a dry stretch reads as "no rain" rather than as nothing drawn.
        var base = Path()
        base.move(to: CGPoint(x: 0, y: top + usable))
        base.addLine(to: CGPoint(x: CGFloat(hours.count) * colW, y: top + usable))
        ctx.stroke(base, with: .color(.blue.opacity(0.15)), lineWidth: pt(1))

        for i in hours.indices {
            let h = hours[i]
            let amount = h.precip ?? 0
            // A measured hour's bar is full because it rained, not because it was likely to.
            let prob = h.isObserved ? (amount > 0 ? 100 : 0) : (h.precipProbability ?? 0)
            guard prob >= 10 || amount > 0 else { continue }
            let barH = max(2, CGFloat(prob / 100) * usable)
            let rect = CGRect(x: x(Double(i), colW) - colW * 0.3, y: top + usable - barH,
                              width: colW * 0.6, height: barH)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.blue.opacity(0.18)))
            let wet = min(1, amount / Self.wetHour)
            if wet > 0 {
                let fh = max(1.5, CGFloat(wet) * barH)
                ctx.fill(Path(roundedRect: CGRect(x: rect.minX, y: rect.maxY - fh,
                                                  width: rect.width, height: fh), cornerRadius: 1.5),
                         with: .color(.blue.opacity(0.85)))
            }
        }
        // Each day's chance and water, over its likeliest hour still to come —
        // or, with nothing ahead, over its wettest measured one.
        for span in spans {
            let range = span.first...span.last
            let total = hours[range].compactMap(\.precip).reduce(0, +)
            let ahead = range.filter { !hours[$0].isObserved }
            let likeliest = ahead.max { (hours[$0].precipProbability ?? 0) < (hours[$1].precipProbability ?? 0) }
            var chance: Double?
            var anchor: Int?
            if let likeliest, let p = hours[likeliest].precipProbability, p >= Self.rainChance {
                chance = p; anchor = likeliest
            } else if total > 0 {
                anchor = range.max { (hours[$0].precip ?? 0) < (hours[$1].precip ?? 0) }
            }
            guard let anchor else { continue }
            var parts: [String] = []
            if let chance { parts.append("\(Int(chance.rounded()))%") }
            if total >= 0.01 { parts.append(WeatherAlmanac.inches(total)) } else if total > 0 { parts.append("trace") }
            guard !parts.isEmpty else { continue }
            ctx.draw(Text(parts.joined(separator: " · ")).font(.system(size: tx(9), weight: .semibold)).foregroundStyle(.blue),
                     at: CGPoint(x: x(Double(anchor), colW), y: lanes.rainTop + tx(4)), anchor: .center)
        }
    }

    /// The hour, under each bar that has one, as a bare number — the bars'
    /// own row, so "the rain starts at 3" is read off rather than counted to.
    private func drawRainHours(_ ctx: GraphicsContext, _ colW: CGFloat) {
        guard lanes.rainHours > 0 else { return }
        for i in hours.indices {
            guard (hours[i].precipProbability ?? 0) >= 10 || (hours[i].precip ?? 0) > 0 else { continue }
            let h = localHours[i] % 12 == 0 ? 12 : localHours[i] % 12
            ctx.draw(Text("\(h)").font(.system(size: tx(7), weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary),
                     at: CGPoint(x: x(Double(i), colW), y: lanes.rainHoursTop), anchor: .top)
        }
    }

    /// How many of the models have rain in that hour, as a strip that darkens
    /// with agreement — only where the models reach (about eighteen hours).
    private func drawModels(_ ctx: GraphicsContext, _ colW: CGFloat) {
        let rowH = lanes.modelsH - pt(2)
        for (i, a) in agreement where a.of > 0 {
            let rect = CGRect(x: CGFloat(i) * colW, y: lanes.modelsTop + pt(1), width: colW, height: rowH)
            let share = Double(a.wet) / Double(a.of)
            ctx.fill(Path(rect), with: .color(share > 0 ? .blue.opacity(0.1 + 0.8 * share)
                                                         : .primary.opacity(0.05)))
        }
    }

    private func drawWindLine(_ ctx: GraphicsContext, _ colW: CGFloat) {
        let top = lanes.windTop + tx(8), h = lanes.windH - tx(8)
        func y(_ mph: Double) -> CGFloat { top + h - CGFloat(min(mph, windMax) / windMax) * h }

        // The gusty line, so "windy" is a place on the chart rather than a judgement.
        var ref = Path()
        ref.move(to: CGPoint(x: 0, y: y(Self.gusty)))
        ref.addLine(to: CGPoint(x: CGFloat(hours.count) * colW, y: y(Self.gusty)))
        ctx.stroke(ref, with: .color(.primary.opacity(0.18)),
                   style: StrokeStyle(lineWidth: pt(1), dash: [pt(3), pt(3)]))
        let gustyLabel = ctx.resolve(Text("\(Int(Self.gusty)) mph").font(.system(size: tx(8))).foregroundStyle(.tertiary))
        let gustyAt = CGPoint(x: CGFloat(hours.count) * colW - pt(2), y: y(Self.gusty) - pt(1))
        if isTenFoot {
            // The gust line runs right through it otherwise.
            let size = gustyLabel.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
            let back = CGRect(x: gustyAt.x - size.width - pt(3), y: gustyAt.y - size.height,
                              width: size.width + pt(5), height: size.height)
            ctx.fill(Path(roundedRect: back, cornerRadius: pt(3)), with: .color(.black.opacity(0.75)))
        }
        ctx.draw(gustyLabel, at: gustyAt, anchor: .bottomTrailing)

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

    /// A quiet wind as sparse arrows pointing where it's GOING, with its speed.
    private func drawWindArrows(_ ctx: GraphicsContext, _ colW: CGFloat) {
        let mid = lanes.windTop + lanes.windH / 2
        let every = isSingleDay ? 3 : 6
        for i in hours.indices where localHours[i] % every == 0 {
            guard let speed = hours[i].windAvg, speed >= 1 else { continue }
            let cx = x(Double(i), colW)
            if let from = hours[i].windDirection ?? hours[i].windDirectionCardinal.flatMap(Self.degrees) {
                var layer = ctx
                layer.translateBy(x: cx - pt(9), y: mid)
                layer.rotate(by: .degrees(from + 180))
                var arrow = Path()
                arrow.move(to: CGPoint(x: 0, y: pt(4.5)))
                arrow.addLine(to: CGPoint(x: 0, y: -pt(4.5)))
                arrow.move(to: CGPoint(x: -pt(2.5), y: -pt(2)))
                arrow.addLine(to: CGPoint(x: 0, y: -pt(4.5)))
                arrow.addLine(to: CGPoint(x: pt(2.5), y: -pt(2)))
                layer.stroke(arrow, with: .color(.secondary),
                             style: StrokeStyle(lineWidth: pt(1.2), lineCap: .round, lineJoin: .round))
            }
            ctx.draw(Text("\(Int(speed.rounded()))").font(.system(size: tx(9))).foregroundStyle(.secondary),
                     at: CGPoint(x: cx + 1, y: mid), anchor: .leading)
        }
    }

    /// "SSW" → 202.5. The TV doesn't compile the Mac's `Compass`.
    private static func degrees(_ cardinal: String) -> Double? {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return points.firstIndex(of: cardinal.uppercased()).map { Double($0) * 22.5 }
    }

    /// One bar per day in the storm category's own colour. A day with no
    /// outlook loaded is grey and says so, rather than looking quiet.
    private func drawStorms(_ ctx: GraphicsContext, _ colW: CGFloat) {
        guard let risks else { return }
        for span in spans {
            let rect = CGRect(x: CGFloat(span.first) * colW + pt(2), y: lanes.stormTop,
                              width: CGFloat(span.last - span.first + 1) * colW - pt(4), height: lanes.stormH)
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
        let every = isSingleDay ? 3 : 6
        for i in hours.indices where localHours[i] % every == 0 && (isSingleDay || localHours[i] != 0) {
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

        // WITH ITS DAY: the figure runs past midnight, and "2AM" under the
        // cursor shouldn't leave anyone working out which one.
        let date = Date(timeIntervalSince1970: TimeInterval(h.epoch))
        var parts = ["\(When.day(date, calendar: calendar)) \(h.clock)"]
        if let t = h.temperature { parts.append("\(Int(t.rounded()))°") }
        if let d = h.dewPoint { parts.append("dew \(Int(d.rounded()))°") }
        // A measured hour has no chance left in it, only an amount.
        if !h.isObserved, let p = h.precipProbability, p >= 10 { parts.append("\(Int(p.rounded()))% rain") }
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

    // MARK: Shape helpers

    /// Where the temperature actually changes direction — the only places a number
    /// earns a label on a single day. A plateau is labelled once, at its middle.
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
}

// MARK: - Curves

/// The smoothed line every forecast chart draws its temperature and wind with.
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
