//
//  RainfallCard.swift  (macOS)
//
//  Rain through the year, and the years against each other.
//
//  The month chart is the centre of it: for each month, this year's bar beside
//  the usual one, both rising from a common zero against a labelled scale. The
//  annual row underneath answers the other half — whether the year as a whole is
//  running wet or dry.
//
//  Both carry the same caveat, visibly: a total from a month with holes in it is
//  a FLOOR. Rain is the one measure a gap destroys outright — the hour the
//  station missed may be the hour it rained, and nothing nearby recovers it — so
//  a month the station didn't fully watch is marked rather than quietly drawn
//  short.
//

import SwiftUI
import WeatherKit

struct RainfallCard: View {
    let climate: Climatology
    let today: String

    @State private var summary: RainfallSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary, summary.isMeaningful {
                headline(summary)
                monthChart(summary)
                Divider()
                yearRow(summary)
            } else if let summary {
                Text(summary.years.isEmpty
                     ? "Once a full year is archived, this will show how rain falls across the year here."
                     : "\(summary.years.filter(\.isTrustworthy).count) complete year archived. Two makes a comparison.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: today) {
            let climate = self.climate
            let day = self.today
            summary = await Task.detached { climate.rainfallSummary(asOf: day) }.value
        }
    }

    // MARK: Headline

    @ViewBuilder private func headline(_ summary: RainfallSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(WeatherAlmanac.inches(summary.yearToDate))
                    .font(.system(size: 30, weight: .light, design: .rounded))
                Text("so far this year").font(.callout).foregroundStyle(.secondary)
                if let departure = summary.departureToDate, abs(departure) >= 0.1 {
                    Text("\(WeatherAlmanac.inches(abs(departure))) \(departure > 0 ? "ahead of" : "behind") the usual pace")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((departure > 0 ? Color.blue : Color.orange).opacity(0.16), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            if let typicalToDate = summary.typicalToDate {
                Text("Prior years held \(WeatherAlmanac.inches(typicalToDate)) by this date, and \(summary.typicalYear.map { WeatherAlmanac.inches($0) } ?? "—") across a full year.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if summary.daysMissedThisYear > 0 {
                Text("\(summary.daysMissedThisYear) \(summary.daysMissedThisYear == 1 ? "day" : "days") of this year weren’t recorded, so the total is a floor.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: By month

    /// A plain grouped bar chart: two bars per month on a real baseline, with a
    /// labelled scale up the side.
    ///
    /// The previous version overlaid a narrow bar on a wide one inside a
    /// GeometryReader — which was both too clever and outright broken, since a
    /// ZStack there sizes to its content and floats rather than sitting on the
    /// bottom. Side-by-side bars from a common zero need no explaining, and every
    /// height can be checked against the axis instead of taken on trust.
    private func monthChart(_ summary: RainfallSummary) -> some View {
        let values = summary.months.flatMap { [$0.typical, $0.thisYear].compactMap { $0 } }
        let scale = Self.scale(peak: values.max() ?? 1)
        let plotHeight: CGFloat = 150

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                axisLabels(scale, height: plotHeight)
                ZStack(alignment: .bottomLeading) {
                    gridlines(scale, height: plotHeight)
                    HStack(alignment: .bottom, spacing: 7) {
                        ForEach(summary.months) { month in
                            monthColumn(month, scale: scale, height: plotHeight)
                        }
                    }
                }
                .frame(height: plotHeight)
            }
            // Labels ride in their own row with the same spacing, so they stay
            // under their bars without being inside the plot's coordinate space.
            HStack(spacing: 7) {
                Spacer().frame(width: 30)
                ForEach(summary.months) { month in
                    Text(month.name)
                        .font(.system(size: 10))
                        .foregroundStyle(month.isInProgress ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 14) {
                legendSwatch(Color.blue.opacity(0.8), "this year")
                legendSwatch(Color.secondary.opacity(0.45), "usual")
                if summary.months.contains(where: { $0.thisYear != nil && !$0.isTrustworthy }) {
                    legendSwatch(Color.orange.opacity(0.8), "partial month — floor only")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    /// Round inch marks with a step that yields four or five lines.
    private static func scale(peak: Double) -> (top: Double, step: Double) {
        let step: Double = peak > 8 ? 2 : peak > 4 ? 1 : peak > 2 ? 0.5 : 0.25
        let top = max(step, (peak / step).rounded(.up) * step)
        return (top, step)
    }

    private func axisLabels(_ scale: (top: Double, step: Double), height: CGFloat) -> some View {
        let marks = Array(stride(from: 0, through: scale.top, by: scale.step)).reversed()
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(marks.enumerated()), id: \.offset) { index, value in
                Text(value == 0 ? "0" : String(format: value < 1 ? "%.2f" : "%.0f", value))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .frame(height: height / CGFloat(max(1, marks.count - 1)),
                           alignment: index == marks.count - 1 ? .bottom : .top)
                    .offset(y: index == marks.count - 1 ? 0 : -5)
            }
        }
        .frame(width: 30, height: height, alignment: .topTrailing)
    }

    private func gridlines(_ scale: (top: Double, step: Double), height: CGFloat) -> some View {
        let marks = Array(stride(from: 0, through: scale.top, by: scale.step))
        return ZStack(alignment: .bottom) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, value in
                Rectangle()
                    .fill(Color.primary.opacity(value == 0 ? 0.25 : 0.07))
                    .frame(height: value == 0 ? 1 : 0.5)
                    .offset(y: -height * CGFloat(value / scale.top))
            }
        }
        .frame(height: height, alignment: .bottom)
    }

    /// Usual and this-year side by side, both rising from the same zero.
    private func monthColumn(_ month: MonthlyRainfall, scale: (top: Double, step: Double),
                             height: CGFloat) -> some View {
        func barHeight(_ value: Double?) -> CGFloat {
            guard let value, value > 0 else { return 0 }
            return max(2, height * CGFloat(value / scale.top))
        }
        return HStack(alignment: .bottom, spacing: 2) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.45))
                .frame(maxWidth: .infinity)
                .frame(height: barHeight(month.typical))
            RoundedRectangle(cornerRadius: 2)
                .fill(month.thisYear != nil && !month.isTrustworthy
                      ? Color.orange.opacity(0.8)
                      : Color.blue.opacity(month.isInProgress ? 0.5 : 0.8))
                .frame(maxWidth: .infinity)
                .frame(height: barHeight(month.thisYear))
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .help(help(month))
    }

    private func help(_ month: MonthlyRainfall) -> String {
        var text = WeatherAlmanac.monthName(String(format: "%02d", month.month))
        if let thisYear = month.thisYear {
            text += ": \(WeatherAlmanac.inches(thisYear)) this year"
            if month.isInProgress { text += " so far" }
        }
        if let typical = month.typical {
            text += month.thisYear == nil ? ": usually " : ", usually "
            text += "\(WeatherAlmanac.inches(typical)) (\(month.years) \(month.years == 1 ? "year" : "years"))"
        }
        if month.thisYear != nil && !month.isTrustworthy {
            text += ". The station recorded \(Int((month.coverage * 100).rounded()))% of this month, so its total is a floor."
        }
        return text
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: By year

    private func yearRow(_ summary: RainfallSummary) -> some View {
        let peak = max(0.5, summary.years.map(\.total).max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("YEAR BY YEAR")
                .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.tertiary)
            ForEach(summary.years) { year in
                HStack(spacing: 10) {
                    Text(String(year.year))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    GeometryReader { geo in
                        Capsule()
                            .fill(year.isTrustworthy ? Color.blue.opacity(0.6) : Color.secondary.opacity(0.35))
                            .frame(width: max(2, geo.size.width * CGFloat(year.total / peak)))
                    }
                    .frame(height: 8)
                    Text(WeatherAlmanac.inches(year.total))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .trailing)
                    Text(note(year))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(width: 92, alignment: .leading)
                }
            }
        }
    }

    /// Why a year's bar shouldn't be read as its rainfall, when that's the case.
    private func note(_ year: AnnualRainfall) -> String {
        if year.isInProgress { return "so far" }
        if year.coverage < 0.9 { return "\(Int((year.coverage * 100).rounded()))% recorded" }
        return ""
    }
}
