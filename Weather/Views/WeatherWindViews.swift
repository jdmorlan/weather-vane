//
//  WeatherWindViews.swift  (macOS)
//
//  THE WIND, AS ITS OWN SURFACE.
//
//  Every other card here answers a question about a moment or a stretch. The wind
//  is the one measure whose interesting questions are all about the WHOLE RECORD —
//  which way does it usually come from, does that turn with the season, when does
//  it actually blow — and none of them fit in a line on the Now tab. That's what
//  earns it a tab rather than a card.
//
//  THE ROSE IS DRAWN NORTH-UP, on purpose, even though this app owns a wind dial
//  that rotates to your facing. The dial shows ONE reading and its whole job is to
//  put the wind where it is in the room. A rose is a climatology — the thing you
//  compare against a neighbour's, a forecast, a memory of the last house — and it
//  has to be checkable in the frame everyone else states the weather in.
//  [[egocentric-weather-and-facing]] draws the line at exactly this seam.
//
//  Conventional forms throughout: a stacked polar rose and a bar chart of monthly
//  means. Both are the shapes a person has already learned to read from any
//  weather site, and neither needed inventing.
//

import SwiftUI
import WeatherKit

/// Sequential ramp for the speed bands — ordered data, so the colour has to be
/// ordered too: one hue family darkening and warming with speed, never a
/// categorical palette that would imply the bands are unrelated kinds.
func windBandColor(_ index: Int, of count: Int) -> Color {
    let ramp: [Color] = [
        Color(red: 0.78, green: 0.87, blue: 0.94),
        Color(red: 0.55, green: 0.75, blue: 0.88),
        Color(red: 0.33, green: 0.60, blue: 0.80),
        Color(red: 0.96, green: 0.78, blue: 0.35),
        Color(red: 0.90, green: 0.53, blue: 0.24),
        Color(red: 0.76, green: 0.24, blue: 0.22),
    ]
    guard count > 1 else { return ramp[0] }
    let position = Double(index) / Double(count - 1) * Double(ramp.count - 1)
    return ramp[min(ramp.count - 1, max(0, Int(position.rounded())))]
}

// MARK: - The rose

/// A stacked wind rose: sixteen petals, each split by speed band, on rings of
/// percent-of-time.
///
/// Petals point at the direction the wind comes FROM, which is the meteorological
/// convention and the one thing about a rose that is genuinely easy to get
/// backwards. A petal reaching the 15% ring to the south means the wind blew from
/// the south 15% of the time — it does not mean the air went south.
struct WindRoseChart: View {
    let rose: WindRose
    var size: CGFloat = 300
    /// The sector the pointer is over. Owned by the parent because the readout
    /// beside the chart is driven by it — the rose and the panel are one
    /// instrument, not a picture with a caption.
    @Binding var hovered: Int?
    /// A sector clicked to hold, so you can read the numbers without keeping the
    /// mouse still. Clicking the same petal again releases it.
    @Binding var pinned: Int?

    /// What the readout should describe: what you're pointing at, else what you
    /// pinned.
    private var active: Int? { hovered ?? pinned }

    /// Ring spacing chosen from the data rather than fixed, so a station with a
    /// tight rose doesn't draw every petal inside the first ring.
    private var ringStep: Double {
        let peak = rose.sectors.map(\.fraction).max() ?? 0.1
        switch peak {
        case ..<0.06: return 0.02
        case ..<0.12: return 0.03
        case ..<0.25: return 0.05
        default:      return 0.10
        }
    }

    private var rings: Int {
        let peak = rose.sectors.map(\.fraction).max() ?? 0.1
        return max(2, Int(ceil(peak / ringStep)))
    }

    private var outer: Double { Double(rings) * ringStep }

    /// Centre and radius, computed once from `size` so the DRAWING and the
    /// HIT-TESTING cannot drift apart. Deriving them twice is how an interactive
    /// chart ends up highlighting the petal next to the one you're pointing at.
    private var center: CGPoint { CGPoint(x: size / 2, y: size / 2) }
    /// Leaves room for the compass letters outside the outermost ring.
    private var radius: CGFloat { size / 2 - 18 }

    var body: some View {
        Canvas { context, _ in
            drawGrid(&context, center: center, radius: radius)
            drawPetals(&context, center: center, radius: radius)
            drawLabels(&context, center: center, radius: radius)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hovered = sector(at: point)
            case .ended: hovered = nil
            }
        }
        .onTapGesture { point in
            guard let hit = sector(at: point) else { pinned = nil; return }
            pinned = (pinned == hit) ? nil : hit
        }
        .animation(.easeOut(duration: 0.12), value: active)
        .accessibilityLabel(accessibilityText)
    }

    /// Which petal a point falls in, or nil outside the rose.
    ///
    /// Empty sectors return nil rather than their index: a petal that isn't
    /// drawn can't be pointed at, and highlighting a blank wedge would imply
    /// the archive has something to say about it.
    private func sector(at point: CGPoint) -> Int? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let r = (dx * dx + dy * dy).squareRoot()
        guard r <= radius else { return nil }
        // Same frame as `point(_:_:bearing:)`: 0 is up, turning clockwise.
        var bearing = atan2(Double(dx), Double(-dy)) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        let index = Int((bearing / 22.5).rounded()) % 16
        guard let hit = rose.sectors.first(where: { $0.index == index }), hit.minutes > 0 else {
            return nil
        }
        return index
    }

    private func point(_ center: CGPoint, _ radius: CGFloat, bearing: Double) -> CGPoint {
        // Bearing 0 is up and turns clockwise; screen angles start at +x and turn
        // clockwise too (y grows downward), so the frames differ by a quarter turn.
        let radians = (bearing - 90) * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(Foundation.cos(radians)),
                       y: center.y + radius * CGFloat(Foundation.sin(radians)))
    }

    private func drawGrid(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        for ring in 1...rings {
            let r = radius * CGFloat(Double(ring) / Double(rings))
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            context.stroke(Path(ellipseIn: rect),
                           with: .color(.primary.opacity(ring == rings ? 0.20 : 0.10)),
                           lineWidth: 1)
        }
        // Spokes on the eight points people say out loud, not all sixteen — at
        // sixteen the grid competes with the petals it exists to measure.
        for i in 0..<8 {
            var path = Path()
            path.move(to: center)
            path.addLine(to: point(center, radius, bearing: Double(i) * 45))
            context.stroke(path, with: .color(.primary.opacity(0.07)), lineWidth: 1)
        }
        // Ring value, written once on the vertical so it reads without a legend.
        for ring in stride(from: 1, through: rings, by: rings > 3 ? 2 : 1) {
            let r = radius * CGFloat(Double(ring) / Double(rings))
            let text = Text("\(Int((Double(ring) * ringStep * 100).rounded()))%")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            context.draw(context.resolve(text), at: CGPoint(x: center.x + 3, y: center.y - r - 6),
                         anchor: .leading)
        }
    }

    private func drawPetals(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        guard rose.movingMinutes > 0 else { return }
        let half = 10.0   // 20° of the 22.5° bin, leaving a hairline between petals

        for sector in rose.sectors where sector.minutes > 0 {
            var inner = 0.0
            for (band, minutes) in sector.bandMinutes.enumerated() where minutes > 0 {
                let slice = minutes / rose.movingMinutes
                let outerFraction = inner + slice
                let r0 = radius * CGFloat(inner / outer)
                let r1 = radius * CGFloat(min(1, outerFraction / outer))
                inner = outerFraction

                var path = Path()
                let start = Angle.degrees(sector.degrees - half - 90)
                let end = Angle.degrees(sector.degrees + half - 90)
                path.addArc(center: center, radius: r1, startAngle: start, endAngle: end, clockwise: false)
                if r0 > 0.5 {
                    path.addArc(center: center, radius: r0, startAngle: end, endAngle: start, clockwise: true)
                } else {
                    path.addLine(to: center)
                }
                path.closeSubpath()
                // Everything recedes when one petal is active, so the shape you
                // asked about separates from the fifteen you didn't.
                let dim = active != nil && active != sector.index
                context.fill(path, with: .color(windBandColor(band, of: rose.bands.count)
                    .opacity(dim ? 0.32 : 1)))
            }
        }

        // The active petal's outline, drawn last so it sits over every band.
        if let active, let sector = rose.sectors.first(where: { $0.index == active }),
           sector.minutes > 0 {
            let r = radius * CGFloat(min(1, (sector.fraction) / outer))
            var path = Path()
            let start = Angle.degrees(sector.degrees - half - 90)
            let end = Angle.degrees(sector.degrees + half - 90)
            path.addArc(center: center, radius: r, startAngle: start, endAngle: end, clockwise: false)
            path.addLine(to: center)
            path.closeSubpath()
            context.stroke(path, with: .color(.primary.opacity(0.55)), lineWidth: 1.5)
        }
    }

    private func drawLabels(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let cardinals = [(0.0, "N"), (90.0, "E"), (180.0, "S"), (270.0, "W")]
        for (bearing, name) in cardinals {
            // North in red for the same reason the dial does it: it's the anchor
            // that makes the picture checkable against anyone else's weather.
            let text = Text(name)
                .font(.system(size: 11, weight: bearing == 0 ? .bold : .medium))
                .foregroundStyle(bearing == 0 ? Color.red.opacity(0.8) : Color.secondary)
            context.draw(context.resolve(text), at: point(center, radius + 11, bearing: bearing))
        }
    }

    private var accessibilityText: String {
        guard let arc = rose.dominantArc() else { return "Wind rose, no data" }
        return "Wind rose. Most often from \(arc.from) through \(arc.to), "
            + "\(Int((arc.fraction * 100).rounded())) percent of the time."
    }
}

/// The band ladder, as a legend. Reads bottom-up in the same order the petals
/// stack, so the eye can walk one to the other.
struct WindBandLegend: View {
    let bands: [WindBand]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(bands.enumerated()).reversed(), id: \.offset) { index, band in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(windBandColor(index, of: bands.count))
                        .frame(width: 12, height: 10)
                    Text(label(band)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func label(_ band: WindBand) -> String {
        guard let upper = band.upper else { return "\(Int(band.lower))+ mph" }
        return "\(Int(band.lower))–\(Int(upper))"
    }
}

// MARK: - The surface

struct WindSurface: View {
    let climate: WindClimate

    /// The whole record, always. The summary sentences describe the station, not
    /// whatever month the pointer is resting on.
    private var allYear: WindRose { climate.overall }

    /// What the rose, the readout and the ladder are all showing: a month when
    /// one is selected, else the whole record. One property so the three can
    /// never disagree about which rose they're describing.
    private var rose: WindRose {
        activeMonth.flatMap { climate.byMonth[$0] } ?? climate.overall
    }

    @State private var hovered: Int?
    @State private var pinned: Int?
    @State private var hoveredMonth: Int?
    @State private var pinnedMonth: Int?
    private var activeMonth: Int? { hoveredMonth ?? pinnedMonth }
    private var active: WindSector? {
        (hovered ?? pinned).flatMap { index in rose.sectors.first { $0.index == index } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            summaryCard
            roseCard
        }
    }

    // MARK: Cards

    private var summaryCard: some View {
        card(label: "The wind here") {
            let lines = WeatherInterpreter.windSummary(climate)
            if lines.isEmpty {
                Text("Not enough archived days yet to say what the wind does here.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(index == 0 ? .title3 : .callout)
                            .foregroundStyle(index == 0 ? .primary : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The rose, and everything the old "By direction" table used to say.
    ///
    /// THAT TABLE IS GONE, and the rose ate it. Sixteen rows of from/time/
    /// average/peak-gust sat at the bottom of this surface restating what the
    /// picture above already drew, in a form nobody reads top to bottom — while
    /// the rose itself was 300pt of static canvas with a third of the card empty
    /// beside it. Pointing at a petal answers the same question in the place you
    /// were already looking, and the space the numbers need was there all along.
    ///
    /// A ladder of sixteen bars replaced the table for a while, on the argument
    /// that the one thing a hover can't do is show all sixteen at once. That
    /// argument was wrong: the rose IS all sixteen at once, and at 440pt it
    /// reads them better than a list of percentages. It went the same way the
    /// table did.
    private var roseCard: some View {
        card(label: activeMonth == nil ? "Where it comes from"
                                       : "Where it comes from · \(monthName(activeMonth!))") {
            // TWO COLUMNS, BOTH FULL HEIGHT. The month strip used to span the
            // whole card above the rose, which made a T: a wide bar over two
            // things of unequal height, with an orphaned patch of nothing under
            // the panel. Moving it into the right column gives that column a job
            // all the way down and leaves one clean division — the chart, and
            // everything you read about the chart.
            HStack(alignment: .top, spacing: 30) {
                VStack(spacing: 10) {
                    WindRoseChart(rose: rose, size: 460, hovered: $hovered, pinned: $pinned)
                    Text(hint).font(.caption2).foregroundStyle(.tertiary)
                }
                readout
                Spacer(minLength: 0)
            }
        }
    }

    private var hint: String {
        if let pinnedMonth { return "Holding \(monthName(pinnedMonth)) · click the month again to release" }
        if pinned != nil { return "Holding \(rose.sectors[pinned!].compass) · click again to release" }
        return "Point at a petal for its numbers · click to hold"
    }

    /// THE MONTH CHART, PROMOTED INTO A CONTROL.
    ///
    /// This was its own card — "Around the year", a bar per month with a little
    /// arrow under it. The bar said how hard and the arrow said roughly which
    /// way, which is an entire rose compressed to two numbers because there was
    /// nowhere to put the rose. There is now: `WindClimate.byMonth` has held a
    /// full `WindRose` per month all along, so pointing at a month can just draw
    /// it.
    ///
    /// Kept as BARS rather than becoming a plain segmented control, because the
    /// one thing the old card did that hovering can't is let you see at a glance
    /// which month is the windy one. That comparison stays; the filtering is new.
    private var monthStrip: some View {
        let speeds = (1...12).map { climate.byMonth[$0]?.meanSpeed ?? 0 }
        // All-year is INCLUDED in the scale because it is now drawn as a bar of
        // its own real value. It used to be a fixed 20pt block, which put it on
        // a different baseline from the twelve beside it and read as a glitch.
        // Its mean speed is directly comparable to a month's, so drawing it to
        // the same scale is both tidier and more honest — it doubles as the
        // reference line you'd otherwise want across the months.
        let peak = max(0.1, (speeds + [allYear.meanSpeed]).max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 5) {
                monthCell(nil, height: CGFloat(allYear.meanSpeed / peak),
                          label: "All", speed: allYear.meanSpeed)
                // A rule rather than a gap: it says "the thing on the left is a
                // different kind of thing" without leaving a hole in the row.
                Rectangle().fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 58)
                    .padding(.horizontal, 3)
                ForEach(1...12, id: \.self) { m in
                    monthCell(m, height: CGFloat(speeds[m - 1] / peak),
                              label: monthName(m), speed: speeds[m - 1])
                }
            }
            Text("Average speed by month, in mph. Point at one to draw that month’s rose.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func monthCell(_ month: Int?, height: CGFloat, label: String, speed: Double) -> some View {
        let isActive = activeMonth == month
        let missing = month != nil && climate.byMonth[month!] == nil
        return VStack(spacing: 4) {
            Text(speed > 0 ? String(format: "%.1f", speed) : "—")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(isActive ? .primary : .tertiary)
            RoundedRectangle(cornerRadius: 3)
                .fill(isActive ? AnyShapeStyle(.tint)
                      : AnyShapeStyle(Color.secondary.opacity(missing ? 0.10 : 0.30)))
                .frame(height: max(3, 54 * height))
            // ONE LINE, ALWAYS. "All year" wrapped to two and made that cell
            // taller than the twelve beside it; with the row bottom-aligned,
            // the extra line pushed its bar up off the shared baseline. The
            // label is the thing that has to give, not the alignment.
            Text(label)
                .font(.system(size: 9, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()
        }
        // Narrower than before: thirteen of these now share a column with the
        // panel rather than the whole card width.
        .frame(width: 38)
        .contentShape(Rectangle())
        .opacity(missing ? 0.45 : 1)
        .onHover { inside in
            guard !missing else { return }
            hoveredMonth = inside ? month : nil
            // A month change invalidates a pinned PETAL: the sector you were
            // holding may not even exist in the month now on screen.
            if inside { hovered = nil }
        }
        .onTapGesture {
            guard !missing else { return }
            pinnedMonth = (pinnedMonth == month) ? nil : month
            pinned = nil
        }
        .help(missing ? "No archived days in \(label) yet" : "")
    }

    private func monthName(_ month: Int) -> String {
        WeatherAlmanac.monthName(String(format: "%02d", month), long: false)
    }

    /// One panel, two states. With nothing selected it describes the whole
    /// record; with a petal active it describes that quarter. Same slot, so the
    /// card doesn't reflow under the pointer.
    /// THE PANEL IS A LAYOUT, NOT A LIST.
    ///
    /// It was one 300pt column with everything stacked down it, beside a card
    /// about 1,280pt wide — roughly 500pt of horizontal room sat unused while
    /// the content ran off the bottom. Spreading it out is not decoration: it
    /// also fixes the hover jump STRUCTURALLY rather than by reserving blank
    /// space: the figures sit in a ROW whose height is identical whether it
    /// holds four all-year numbers or three for one sector.
    ///
    /// AN "EVERY QUARTER" LADDER USED TO SIT HERE and has gone. It was carried
    /// over from the deleted table on the argument that it let you compare all
    /// sixteen sectors at once — but that is precisely what the rose is, and at
    /// 440pt it does it better. Sixteen bars restating the petals beside them
    /// was the same duplication the table had been guilty of, one layout later.
    @ViewBuilder private var readout: some View {
        VStack(alignment: .leading, spacing: 18) {
            monthStrip
            Divider()
            heading
            statsRow
            Divider()
            detailColumn
        }
    }

    /// One line, always present, so the top of the panel never moves.
    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let sector = active {
                Text("From \(sector.compass)").font(.title2.weight(.medium))
                if isDominant(sector) {
                    Text("prevailing").font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
            } else {
                Text(activeMonth == nil ? "The whole record" : monthName(activeMonth!))
                    .font(.title2.weight(.medium))
                Text("\(Platform.pointVerb) a quarter to narrow it")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Figures across rather than down, and a fixed row height — which is what
    /// stops the card shifting under the pointer.
    @ViewBuilder private var statsRow: some View {
        HStack(alignment: .top, spacing: 30) {
            if let sector = active {
                stat("Time", String(format: "%.1f%%", sector.fraction * 100),
                     "of moving hours")
                stat("Average", String(format: "%.1f mph", sector.meanSpeed),
                     "while it blew from here")
                stat("Peak gust", sector.peakGust.map { String(format: "%.0f mph", $0) } ?? "—",
                     "out of this quarter")
            } else {
                stat("Calm", String(format: "%.0f%%", rose.calmFraction * 100),
                     "under 1 mph")
                stat("Average", String(format: "%.1f mph", rose.meanSpeed), "while it's moving")
                stat("Steadiness", String(format: "%.2f", rose.constancy), constancyNote)
                if let peak = rose.peakGust {
                    stat("Hardest gust", String(format: "%.0f mph", peak.speed),
                         peak.date.formatted(.dateTime.month(.abbreviated).day().year()))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 54, alignment: .top)
    }

    /// Left half of the lower row: what the colours mean, and — with a petal
    /// active — how that quarter's own hours split across them.
    @ViewBuilder private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sector = active {
                Text("HOW HARD, FROM \(sector.compass)")
                    .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
                // The split the old table could never show: a rare sector that is
                // mostly hard wind is a different fact from a common one that is
                // mostly light, and the radial stack encodes it in a way nobody
                // can read off.
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(Array(sector.bandMinutes.enumerated()), id: \.offset) { band, minutes in
                            if minutes > 0 {
                                windBandColor(band, of: rose.bands.count)
                                    .frame(width: max(1, geo.size.width
                                                      * CGFloat(minutes / max(1, sector.minutes))))
                            }
                        }
                    }
                    .frame(height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .frame(height: 16)
                Text(bandBreakdown(sector))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().padding(.vertical, 4)
            }
            Text("SPEED BANDS")
                .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
            WindBandLegend(bands: rose.bands)
        }
        .frame(maxWidth: 420, alignment: .topLeading)
    }


    /// "Mostly 4–13 mph; 6% above 19." The two facts the bar is for.
    private func bandBreakdown(_ sector: WindSector) -> String {
        guard sector.minutes > 0 else { return "" }
        let shares = sector.bandMinutes.map { $0 / sector.minutes }
        guard let topIndex = shares.indices.max(by: { shares[$0] < shares[$1] }) else { return "" }
        let top = rose.bands[topIndex]
        let upper = top.upper.map { String(format: "%.0f", $0) } ?? "up"
        let hard = shares.indices.filter { rose.bands[$0].lower >= 19 }.map { shares[$0] }.reduce(0, +)
        var text = "Mostly \(String(format: "%.0f", top.lower))–\(upper) mph"
        if hard > 0.005 { text += "; \(String(format: "%.0f%%", hard * 100)) above 19" }
        return text + "."
    }


    private var constancyNote: String {
        switch rose.constancy {
        case ..<0.3: return "direction varies a lot"
        case ..<0.5: return "mostly from one quarter"
        default:     return "steady direction"
        }
    }


    private var maxFraction: Double {
        max(0.0001, rose.sectors.map(\.fraction).max() ?? 1)
    }

    private func isDominant(_ sector: WindSector) -> Bool {
        rose.dominantArc()?.sectors.contains(sector.index) ?? false
    }

    // MARK: Pieces

    private func stat(_ label: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
            Text(note).font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<Content: View>(label: String,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }
}
