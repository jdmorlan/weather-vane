//
//  SeasonTimelineView.swift  (macOS)
//
//  Parallel timelines for the turning of the season, on ONE shared date axis.
//
//  The axis is the whole design. Three curves let go of summer at different
//  times, and the useful question is about the GAPS between them — three more
//  weeks of everything being brutal, then a month of just the afternoons. Stack
//  the tracks on a common clock and that reads directly off the picture; put it
//  in a paragraph and the reader has to do date arithmetic to recover it.
//
//  THE BAR IS THE DATA. It used to be a flat rectangle with a stepped opacity at
//  each crossing — the chart's largest element, encoding nothing you couldn't
//  read off the labels, which made the labels the only thing to read. Now each
//  row is a heat strip of that measure's own normal across the horizon, so how
//  fast the season is letting go is visible as colour before a single date is
//  read, and the crossings become what they always were: annotations on a
//  descent, not the descent itself.
//
//  Two things follow from that and are worth keeping. A day the record can't
//  answer draws as a GAP, never as a colour — the strip is a claim about the
//  weather and it must not make one where the archive is silent. And the month
//  gridlines run the full height of the chart, because the question is about
//  three rows compared vertically, and ticks in a header strip 100pt above the
//  bottom row can't serve it.
//
//  A CROSSING IS A PILL, NOT A PARAGRAPH. Each one used to print three stacked
//  lines under its notch — threshold, date, provenance — laid out from the notch
//  into whatever space happened to be free. Four rows of that is a dozen loose
//  phrases at a dozen different left edges, and they collided: a label from one
//  row printed across the next row's strip. The date was the worst offender,
//  because the chart is a CALENDAR and a date written next to a mark is the one
//  thing position already says.
//
//  So the crossing keeps only what position can't carry — the threshold — inside
//  a pill on its own date, and the axis grew enough ticks to be read as a
//  calendar. Whether the date came from the forecast or the archive is the pill's
//  FILL rather than a third line. Everything else moved into the hover, which is
//  where detail belongs when the picture is meant to be read at a glance.
//

import SwiftUI
import WeatherKit

struct SeasonTimelineView: View {
    let tracks: [SeasonTrack]
    /// How far out the axis runs, in days from today.
    let horizonDays: Int

    private let labelWidth: CGFloat = 88
    private let stripHeight: CGFloat = 16
    private let pillHeight: CGFloat = 17
    /// Strip, a small gap, one lane of pills. Every row the same, because uneven
    /// rows would break the gridlines the whole comparison is read along.
    private var rowHeight: CGFloat { stripHeight + 5 + pillHeight + 6 }

    /// How far the axis reaches BEHIND today, in days. Shared by every row —
    /// they're on one clock or the chart says nothing — and zero unless the
    /// model found something running late.
    private var lookbackDays: Int { tracks.first?.lookbackDays ?? 0 }

    /// Total days across the axis, so today is at `lookbackDays`.
    private var axisDays: Int { lookbackDays + horizonDays }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tracks) { track in
                trackRow(track)
            }
            dateAxis
        }
    }

    // MARK: Axis

    /// The calendar, along the bottom. Below the rows rather than above them
    /// because it's the thing you look up AFTER finding a mark — and a mark is
    /// only a date at all if the scale is close enough to hand to read off.
    private var dateAxis: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: labelWidth)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(axisTicks, id: \.offset) { tick in
                        Text(tick.label)
                            .font(.system(size: 9, weight: tick.major ? .semibold : .regular))
                            .foregroundStyle(tick.major ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                            .fixedSize()
                            // Centred on its own line, so the number sits under
                            // the date it names instead of beside it.
                            .frame(width: 44, alignment: .center)
                            .offset(x: x(tick.offset, in: geo.size.width) - 22)
                    }
                }
            }
            .frame(height: 14)
            .padding(.top, 3)
        }
    }

    /// One tick per month start and per mid-month, plus today.
    ///
    /// Month names alone were too coarse to read a date off: a mark two thirds
    /// of the way between "Oct" and "Nov" is somewhere around the 20th, and
    /// working that out is exactly the arithmetic the chart exists to spare you.
    /// Offsets are SIGNED — a boundary inside the lookback is negative.
    private var axisTicks: [(offset: Int, label: String, major: Bool)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var ticks: [(Int, String, Bool)] = []

        var cursor = calendar.date(byAdding: .day, value: -lookbackDays, to: today) ?? today
        cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: cursor)) ?? cursor
        for _ in 0..<20 {
            for day in [1, 15] {
                var parts = calendar.dateComponents([.year, .month], from: cursor)
                parts.day = day
                guard let mark = calendar.date(from: parts) else { continue }
                let offset = calendar.dateComponents([.day], from: today, to: mark).day ?? 0
                guard offset >= -lookbackDays, offset <= horizonDays else { continue }
                // Keep clear of "Today" rather than printing over it.
                guard abs(offset) > 5 else { continue }
                ticks.append((offset, day == 1
                              ? mark.formatted(.dateTime.month(.abbreviated))
                              : "15", day == 1))
            }
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        ticks.append((0, "Today", true))
        return ticks.sorted { $0.0 < $1.0 }
    }

    /// The subset that gets a line drawn down the chart. Mid-month ticks are a
    /// reading aid on the axis; a full-height line for each would turn the
    /// background into graph paper and compete with the strips.
    private var gridTicks: [(offset: Int, label: String, major: Bool)] {
        axisTicks.filter(\.major)
    }

    private func x(_ days: Int, in width: CGFloat) -> CGFloat {
        width * CGFloat(days + lookbackDays) / CGFloat(max(1, axisDays))
    }

    // MARK: One track

    private func trackRow(_ track: SeasonTrack) -> some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: track.symbol).font(.caption2).foregroundStyle(color(track))
                Text(track.name).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: labelWidth, alignment: .leading)
            // Line the label up with the middle of its strip, not with the text
            // that hangs below it.
            .padding(.top, 1)

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    // Behind everything, running the full row height so the lines
                    // read as continuous down the whole chart.
                    gridlines(width: width, height: rowHeight)

                    heatStrip(track, width: width)

                    // Lateness first, so the notches sit on top of the ends of
                    // the bar that measures it.
                    ForEach(clusters(track), id: \.days) { cluster in
                        latenessBar(cluster, track: track, width: width)
                    }

                    // Notch on the strip, pill in the lane below it — two
                    // passes, so a pill wide enough to hold "32° · 28°" can't
                    // drag its notch off the date it marks.
                    ForEach(clusters(track), id: \.days) { cluster in
                        Rectangle()
                            .fill(Color.primary.opacity(0.55))
                            .frame(width: 1.5, height: stripHeight)
                            .offset(x: x(cluster.days, in: width))
                    }
                    ForEach(clusters(track), id: \.days) { cluster in
                        pill(cluster, track: track, width: width)
                    }
                }
            }
            .frame(height: rowHeight)
        }
    }

    private func gridlines(width: CGFloat, height: CGFloat) -> some View {
        ForEach(gridTicks, id: \.offset) { tick in
            Rectangle()
                // Today carries more weight once there's a past to divide it
                // from: it stops being a starting line and becomes the seam
                // between what happened and what's expected.
                .fill(Color.primary.opacity(tick.offset == 0 ? (lookbackDays > 0 ? 0.3 : 0.14) : 0.07))
                .frame(width: 1, height: height)
                .offset(x: x(tick.offset, in: width))
        }
    }

    /// The delay itself, drawn to scale: a bar under the strip running from the
    /// date this should have happened to the date it's now going to.
    ///
    /// This is the encoding the row was missing. A crossing that's late has two
    /// positions on the axis and the answer is the distance between them, so the
    /// chart draws that distance and lets the axis underneath say how long it is.
    ///
    /// Drawn INSIDE the strip, along its bottom edge, rather than in a lane of
    /// its own: it's a statement about that stretch of weather, and a caption
    /// floating below the bar read as a fourth loose piece of text.
    @ViewBuilder
    private func latenessBar(_ cluster: MilestoneCluster, track: SeasonTrack, width: CGFloat) -> some View {
        if let normal = cluster.normalDaysFromNow, normal < cluster.days {
            let start = x(normal, in: width)
            let end = x(cluster.days, in: width)

            // The ghost: where the archive said the season would be by now.
            Rectangle()
                .fill(Color.primary.opacity(0.3))
                .frame(width: 1.5, height: stripHeight)
                .offset(x: start)

            Capsule()
                .fill(Color.white.opacity(0.85))
                .frame(width: max(2, end - start), height: 2.5)
                .offset(x: start, y: stripHeight - 4.5)
                .help(overdueCaption(cluster))
        }
    }

    /// The hover for the lateness bar. A floor, not a measurement, when the
    /// forecast has only ruled the crossing out rather than found it.
    private func overdueCaption(_ cluster: MilestoneCluster) -> String {
        let days = cluster.days - (cluster.normalDaysFromNow ?? 0)
        let usual = usualDate(cluster)
        return cluster.basis == .forecast
            ? "Usually \(usual) — running \(days) days late."
            : "Usually \(usual) — at least \(days) days late, and the forecast doesn't reach it."
    }

    /// The measure's normal across the horizon, one slot per day.
    ///
    /// Drawn as rects in a Canvas rather than as a gradient: a gradient can't
    /// leave a hole, and the days the archive can't answer have to stay visibly
    /// empty. Overdrawn half a pixel each side so the seams don't read as
    /// stripes on a retina scale.
    private func heatStrip(_ track: SeasonTrack, width: CGFloat) -> some View {
        let base = color(track)
        return Canvas { context, size in
            let slot = size.width / CGFloat(max(1, track.curve.count))
            for (index, value) in track.curve.enumerated() {
                guard let value else { continue }
                let rect = CGRect(x: CGFloat(index) * slot - 0.5, y: 0,
                                  width: slot + 1, height: size.height)
                // Floor of 0.10 rather than 0: past the last crossing the season
                // has eased, but the row still has to exist to be read against.
                let shade = 0.10 + 0.72 * track.intensity(value)
                context.fill(Path(rect), with: .color(base.opacity(shade)))
            }
        }
        .frame(width: width, height: stripHeight)
        .overlay(alignment: .leading) {
            // Where knowing stops. Left of this the strip is the forecast, right
            // of it the archive's normals, and the two are not the same claim.
            if track.forecastDays > 0, track.forecastDays < track.curve.count {
                Rectangle().fill(Color.white.opacity(0.5))
                    .frame(width: 1, height: stripHeight)
                    .offset(x: x(track.forecastDays, in: width))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // What the strip is made of, said once, on the strip itself.
        .help(stripHelp(track))
    }

    /// The strip names its own instruments, left to right.
    private func stripHelp(_ track: SeasonTrack) -> String {
        var parts: [String] = []
        if track.lookbackDays > 0 {
            parts.append("what \(track.name.lowercased()) actually did over the last \(track.lookbackDays) days")
        }
        if track.forecastDays > 0 {
            parts.append("the forecast for the next \(track.forecastDays)")
        }
        parts.append("then the usual reading for each day after")
        var text = "\(track.name.capitalized): " + parts.joined(separator: ", ") + "."
        if track.curve.contains(where: { $0 == nil }) {
            text += " Gaps are dates the archive can't answer."
        }
        return text
    }

    /// Crossings that land on (nearly) the same date, drawn as one marker.
    ///
    /// With only a few years of record two thresholds can share a median date
    /// exactly — 32° and 28° both landing on Nov 10 — and two labels at the same
    /// x would print on top of each other.
    private struct MilestoneCluster {
        var days: Int
        var milestones: [SeasonMilestone]
        var label: String { milestones.map(\.label).joined(separator: " · ") }
        /// Just the numbers. "below" is the row's whole job — every crossing on a
        /// cooling track is a below — and the axis underneath says when.
        var short: String { milestones.map { "\(Int($0.threshold))°" }.joined(separator: "·") }
        var monthDay: String { milestones[0].monthDay }
        /// Only when every crossing in the cluster agrees — a mixed cluster has
        /// no single thing to say, so it says nothing and reads as a normal.
        var basis: SeasonBasis {
            let first = milestones[0].basis
            return milestones.allSatisfy { $0.basis == first } ? first : .normal
        }
        var normalMonthDay: String? { milestones[0].normalMonthDay }
        /// The earliest usual date in the cluster, signed against today. Only
        /// present when every crossing here is late — a cluster with one overdue
        /// member and one on-time one has no single delay to draw.
        var normalDaysFromNow: Int? {
            guard milestones.allSatisfy(\.isOverdue) else { return nil }
            return milestones.compactMap(\.normalDaysFromNow).min()
        }
        var isOverdue: Bool { normalDaysFromNow != nil }
    }

    private func clusters(_ track: SeasonTrack) -> [MilestoneCluster] {
        var result: [MilestoneCluster] = []
        for milestone in track.milestones {
            // Within three days is closer than the labels can be drawn apart.
            if let last = result.last, milestone.daysFromNow - last.days <= 3 {
                result[result.count - 1].milestones.append(milestone)
            } else {
                result.append(MilestoneCluster(days: milestone.daysFromNow, milestones: [milestone]))
            }
        }
        return result
    }

    /// A crossing as a pill on its own date.
    ///
    /// It carries the threshold and nothing else. The date is its position, the
    /// measure is its row, and where the date CAME FROM is how it's drawn:
    ///
    /// - solid — the forecast can see this one happen, so it's a date;
    /// - outlined — the archive's long-run habit, so it's a tendency;
    /// - dashed — the forecast has ruled it out through its whole window, so the
    ///   pill sits at the earliest it could still be. A floor, not a date, and
    ///   it must not be drawn as one.
    ///
    /// Everything a sentence would have said is one hover away.
    private func pill(_ cluster: MilestoneCluster, track: SeasonTrack, width: CGFloat) -> some View {
        let tint = color(track)
        let solid = cluster.basis == .forecast
        let floor = cluster.basis == .notBefore
        let size = pillWidth(cluster.short)
        // Centred on the notch, then pushed back inside the plot at either end
        // rather than hanging off it.
        let left = min(max(x(cluster.days, in: width) - size / 2, 0), max(0, width - size))

        return Text(cluster.short)
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(solid ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
            .fixedSize()
            .frame(width: size, height: pillHeight)
            .background {
                Capsule().fill(solid ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.16)))
                Capsule().strokeBorder(tint.opacity(solid ? 0 : 0.6),
                                       style: StrokeStyle(lineWidth: 1,
                                                          dash: floor ? [2.5, 2.5] : []))
            }
            .help(cluster.milestones.map { helpText($0, track: track) }.joined(separator: "\n"))
            .offset(x: left, y: stripHeight + 5)
    }

    /// Sized from the text rather than measured, so the pill can be positioned
    /// before layout runs — a centred pill needs its own width to find its left
    /// edge, and a GeometryReader per pill to learn it is a lot of machinery for
    /// four characters of monospaced digits.
    private func pillWidth(_ label: String) -> CGFloat {
        14 + 6.6 * CGFloat(label.count)
    }

    /// The date the archive expected this crossing on, as a day label.
    private func usualDate(_ cluster: MilestoneCluster) -> String {
        if let normal = cluster.normalMonthDay {
            return WeatherAlmanac.dayLabel("2001-\(normal)")
        }
        return WeatherAlmanac.dayLabel("2001-\(cluster.monthDay)")
    }

    private func helpText(_ milestone: SeasonMilestone, track: SeasonTrack) -> String {
        // A late crossing is a different sentence from an early or an on-time
        // one: the interesting fact isn't the date, it's the gap.
        if milestone.isOverdue {
            // Unmoved, the milestone still sits on its own normal date.
            let usual = WeatherAlmanac.dateLabel(milestone.normalMonthDay ?? milestone.monthDay)
            switch milestone.basis {
            case .forecast:
                let late = milestone.lateByDays ?? 0
                return "\(track.name) \(milestone.label): usually \(usual), and this year it still hasn't happened. The forecast crosses it \(WeatherAlmanac.dateLabel(milestone.monthDay)) — \(late) days late."
            default:
                return "\(track.name) \(milestone.label): usually \(usual), and this year it still hasn't happened. The forecast doesn't reach it either, so it's at least \(track.forecastDays) more days."
            }
        }
        switch milestone.basis {
        case .forecast:
            var text = "\(track.name) \(milestone.label): the forecast crosses it \(WeatherAlmanac.dateLabel(milestone.monthDay))"
            if let normal = milestone.normalMonthDay {
                text += ", against a usual \(WeatherAlmanac.dateLabel(normal))"
            }
            return text + "."
        case .notBefore:
            var text = "\(track.name) \(milestone.label): the forecast stays on the far side of it for the next \(track.forecastDays) days, so this can't happen before \(WeatherAlmanac.dateLabel(milestone.monthDay))"
            if let normal = milestone.normalMonthDay {
                text += " — \(track.name.lowercased()) usually cross it \(WeatherAlmanac.dateLabel(normal))"
            }
            return text + ". When it actually happens is past what the forecast can say."
        case .normal:
            break
        }
        var text = "\(track.name) \(milestone.label): typically \(WeatherAlmanac.dateLabel(milestone.monthDay))"
        if let earliest = milestone.earliest, let latest = milestone.latest, earliest != latest {
            text += ", ranging \(WeatherAlmanac.dateLabel(earliest)) to \(WeatherAlmanac.dateLabel(latest))"
        }
        text += " across \(milestone.yearsObserved) \(milestone.yearsObserved == 1 ? "year" : "years") of record."
        return text
    }

    private func color(_ track: SeasonTrack) -> Color {
        switch track.measure {
        case .afternoons: return .orange
        case .nights: return .indigo
        case .humidity: return .teal
        case .freeze: return .blue
        }
    }
}
