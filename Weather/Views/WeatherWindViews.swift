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
//  has to be checkable in the frame everyone else states the weather in. So the
//  facing gets a SENTENCE instead: the body words go where the prose is, and the
//  picture stays in the issued frame. [[egocentric-weather-and-facing]] draws the
//  line at exactly this seam.
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

    var body: some View {
        Canvas { context, canvasSize in
            let side = min(canvasSize.width, canvasSize.height)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            // Leaves room for the compass letters outside the outermost ring.
            let radius = side / 2 - 18

            drawGrid(&context, center: center, radius: radius)
            drawPetals(&context, center: center, radius: radius)
            drawLabels(&context, center: center, radius: radius)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(accessibilityText)
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
                context.fill(path, with: .color(windBandColor(band, of: rose.bands.count)))
            }
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

// MARK: - The year

/// Monthly mean speed as bars, with each month's prevailing direction beneath.
///
/// A bar chart rather than twelve small roses: the question "when is it strongest"
/// is a comparison of one number across twelve categories, which is the plainest
/// thing a bar chart does. The direction rides underneath as an arrow because it's
/// a second variable on the same axis, not a second chart.
struct WindSeasonChart: View {
    let climate: WindClimate

    private var months: [(month: Int, rose: WindRose)] {
        (1...12).compactMap { m in climate.byMonth[m].map { (m, $0) } }
    }

    private var peak: Double {
        max(1, months.map(\.rose.meanSpeed).max() ?? 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(months, id: \.month) { entry in
                VStack(spacing: 5) {
                    Text(String(format: "%.1f", entry.rose.meanSpeed))
                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(entry))
                        .frame(height: max(3, CGFloat(entry.rose.meanSpeed / peak) * 92))
                    if let arc = entry.rose.dominantArc() {
                        Image(systemName: "arrow.up")
                            // The arrow points the way the AIR MOVES — opposite the
                            // bearing the wind comes from. Drawing it pointing at the
                            // source is the same off-by-180 the rose's petals avoid,
                            // and on an arrow it reads as an outright error.
                            .rotationEffect(.degrees(arc.centerDegrees + 180))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(arc.compass)
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    Text(WindClimate.monthName(entry.month).prefix(1))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 165, alignment: .bottom)
    }

    /// The windiest and calmest months carry the colour; the rest stay quiet. The
    /// chart's job is the comparison, and colouring all twelve would make the two
    /// that answer the question no easier to find than the ten that don't.
    private func barColor(_ entry: (month: Int, rose: WindRose)) -> Color {
        if entry.month == climate.windiestMonth?.month { return windBandColor(4, of: 6) }
        if entry.month == climate.calmestMonth?.month { return windBandColor(0, of: 6) }
        return Color.secondary.opacity(0.35)
    }
}

// MARK: - The surface

struct WindSurface: View {
    let climate: WindClimate
    /// True degrees the person is looking toward, when they've said.
    let facing: Double?

    private var rose: WindRose { climate.overall }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            summaryCard
            roseCard
            seasonCard
            sectorCard
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
                    if let sentence = facingSentence {
                        Text(sentence)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The record stated in body words, which only exists once you've said which
    /// way you're looking. Without a facing there is nothing to say and this
    /// renders nothing — a guessed facing would be worse than none.
    private var facingSentence: String? {
        guard let facing, let arc = rose.dominantArc() else { return nil }
        let feel = Compass.windFeel(from: arc.centerDegrees, facing: facing)
        return "Facing \(Compass.cardinal(facing)), that's wind \(feel) most of the year."
    }

    private var roseCard: some View {
        card(label: "Where it comes from") {
            HStack(alignment: .top, spacing: 22) {
                WindRoseChart(rose: rose)
                VStack(alignment: .leading, spacing: 16) {
                    WindBandLegend(bands: rose.bands)
                    Divider().frame(width: 120)
                    stat("Calm", String(format: "%.0f%%", rose.calmFraction * 100),
                         "under 1 mph — direction means nothing here")
                    stat("Average", String(format: "%.1f mph", rose.meanSpeed), "while it's moving")
                    stat("Steadiness", String(format: "%.2f", rose.constancy), constancyNote)
                    if let peak = rose.peakGust {
                        stat("Hardest gust", String(format: "%.0f mph", peak.speed),
                             peak.date.formatted(.dateTime.month(.abbreviated).day().year()))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var constancyNote: String {
        switch rose.constancy {
        case ..<0.3: return "variable — it cancels itself out"
        case ..<0.5: return "favours a quarter, but wanders"
        default:     return "holds its direction"
        }
    }

    private var seasonCard: some View {
        card(label: "Around the year") {
            VStack(alignment: .leading, spacing: 12) {
                WindSeasonChart(climate: climate)
                Text("Average speed by month, in mph. The arrow under each bar points the way the air moves.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// The numbers behind the picture. A rose is read by shape and this is how you
    /// check one — including the fact a petal can't show, which is that the rare
    /// quarters are often the violent ones.
    private var sectorCard: some View {
        card(label: "By direction") {
            VStack(spacing: 0) {
                HStack {
                    Text("FROM").frame(width: 44, alignment: .leading)
                    Text("TIME").frame(width: 60, alignment: .trailing)
                    Text("AVERAGE").frame(width: 80, alignment: .trailing)
                    Text("PEAK GUST").frame(width: 90, alignment: .trailing)
                    Spacer()
                }
                .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
                .padding(.bottom, 6)

                ForEach(rose.sectors.filter { $0.minutes > 0 }, id: \.index) { sector in
                    HStack {
                        Text(sector.compass)
                            .font(.callout.weight(isDominant(sector) ? .semibold : .regular))
                            .frame(width: 44, alignment: .leading)
                        Text(String(format: "%.1f%%", sector.fraction * 100))
                            .frame(width: 60, alignment: .trailing)
                        Text(String(format: "%.1f", sector.meanSpeed))
                            .frame(width: 80, alignment: .trailing)
                        Text(sector.peakGust.map { String(format: "%.0f", $0) } ?? "—")
                            .frame(width: 90, alignment: .trailing)
                        // The bar is the same fraction the rose draws radially —
                        // the table and the picture must never disagree.
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(isDominant(sector) ? windBandColor(3, of: 6) : Color.secondary.opacity(0.25))
                                .frame(width: geo.size.width * CGFloat(sector.fraction / maxFraction),
                                       height: 8)
                                .frame(height: geo.size.height, alignment: .center)
                        }
                        .frame(height: 18)
                    }
                    .font(.callout.monospacedDigit())
                    .padding(.vertical, 2)
                }
            }
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
