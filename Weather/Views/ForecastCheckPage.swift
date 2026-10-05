//
//  ForecastCheckPage.swift
//
//  FORECAST CHECK — each forecast against what the station measured, measure
//  by measure, and how much worse it gets the further out it was made.
//
//  Its own page because it is its own question. It used to be a card at the
//  bottom of History, a table of "said 94°, hit 97°" rows, which made the
//  reader do the comparing; the charts put the two on one axis and colour the
//  gap, so a forecast running cold all week is a row of orange, not a column of
//  minus signs.
//
//  It began as the HIGH alone — the one number every source has — and grew a
//  card for every measure the log can grade: the low (held to the forecast you
//  went to bed with), the chance of rain (graded the only way a percentage can
//  be, by how often it rained at each chance), and from October 2026 the day's
//  peak gust and muggiest air, which the daily forecast never carried and the
//  log only started keeping then.
//

import SwiftUI
import Charts
import WeatherKit

struct ForecastCheckPage: View {
    @ObservedObject var model: ForecastCheckModel
    let timezone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.checks.isEmpty && model.watchingSince == nil {
                StationCard(label: "Forecast check") {
                    Text("No forecasts kept yet. Every forecast the app fetches from now on is written down, and graded once its day is over and measured.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                StationCard(label: "Highs") { pairCard(.high) }
                StationCard(label: "Lows") { pairCard(.low) }
                StationCard(label: "Rain") { RainCalibrationView(calibration: model.rain, timezone: timezone) }
                StationCard(label: "Peak gust") { pairCard(.gust) }
                StationCard(label: "Peak dew point") { pairCard(.dewPoint) }
                StationCard(label: "How far out to trust it") { byLead }
                StationCard(label: "Day by day · highs") {
                    ForecastCheckCard(model: model, timezone: timezone, showsSentence: false)
                }
            }
        }
    }

    @ViewBuilder private func pairCard(_ measure: DailyMeasure) -> some View {
        ForecastPairView(measure: measure,
                         checks: model.checksByMeasure[measure] ?? [],
                         verdict: model.verdicts[measure],
                         loggedSince: measure.isTemperature ? model.watchingSince : model.gustLoggedSince,
                         timezone: timezone)
    }

    // MARK: By lead

    /// Highs and lows side by side at each lead — the low's line is the one
    /// that says whether the night-before forecast is worth going to bed on.
    @ViewBuilder private var byLead: some View {
        let high = model.leadSkillByMeasure[.high] ?? []
        let low = model.leadSkillByMeasure[.low] ?? []
        VStack(alignment: .leading, spacing: 10) {
            ForEach([(DailyMeasure.high, high), (.low, low)], id: \.0) { measure, skill in
                if let sentence = ForecastAccuracy.leadSentence(skill, measure: measure) {
                    Text(sentence)
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if high.count >= 2 || low.count >= 2 {
                Chart {
                    ForEach(high) { skill in
                        BarMark(x: .value("Made", leadLabel(skill.leadDays)),
                                y: .value("Typical miss", skill.typicalMiss))
                            .foregroundStyle(by: .value("Measure", "High"))
                            .position(by: .value("Measure", "High"))
                            .cornerRadius(3)
                    }
                    ForEach(low) { skill in
                        BarMark(x: .value("Made", leadLabel(skill.leadDays)),
                                y: .value("Typical miss", skill.typicalMiss))
                            .foregroundStyle(by: .value("Measure", "Low"))
                            .position(by: .value("Measure", "Low"))
                            .cornerRadius(3)
                    }
                }
                .chartForegroundStyleScale(["High": Color.orange.opacity(0.8), "Low": Color.teal.opacity(0.8)])
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                        AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))°") } }
                    }
                }
                .frame(height: 170)
                Text("Each bar: how far the forecast was from the measured value on a typical day, "
                     + "by how far ahead it was made. A lead shows once \(ForecastAccuracy.minimumDays) days can speak for it.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Needs \(ForecastAccuracy.minimumDays) measured days that were each forecast at two or more leads. "
                     + "The log keeps every forecast for ten days out, so this fills in as the days it covered finish.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func leadLabel(_ lead: Int) -> String {
        switch lead {
        case 0: return "Morning of"
        case 1: return "Day before"
        default: return "\(lead) days out"
        }
    }
}

// MARK: - One measure, forecast against measured

/// The forecast as rings, the measured value as a line, and the gap between
/// them coloured: orange when the forecast came in under (cold, or low), blue
/// when over, grey inside the measure's tolerance.
struct ForecastPairView: View {
    let measure: DailyMeasure
    let checks: [ForecastCheck]
    let verdict: ForecastVerdict?
    /// When the log started keeping this measure — for the waiting state.
    let loggedSince: String?
    let timezone: TimeZone

    @State private var hover: Date?

    private func date(_ key: String) -> Date {
        DayKey.date(from: key, timeZone: timezone) ?? .distantPast
    }

    private func gapColor(_ check: ForecastCheck) -> Color {
        if check.wasClose(tolerance: measure.tolerance) { return .secondary }
        return check.error < 0 ? .orange : .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let verdict {
                Text(verdict.sentence)
                    .font(.title3.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let caveat = verdict.caveat {
                    Text(caveat).font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(waitingLine)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !checks.isEmpty {
                chart
                readout.readoutLine()
                Text("Line: the \(measure.noun) the station measured. Rings: what the \(measure.claimName) said. "
                     + "Orange gap: the forecast came in \(measure.underWord). Blue: \(measure.overWord). "
                     + "Grey: within \(measure.formatDelta(measure.tolerance)).")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var waitingLine: String {
        guard let since = loggedSince else {
            return "Not logged yet. The daily forecast never carried a \(measure.noun); the app now keeps the hourly forecast's, starting with its next fetch."
        }
        let left = max(0, ForecastAccuracy.minimumDays - checks.count)
        return "Keeping score since \(WeatherAlmanac.dayLabel(since)): \(checks.count) of the \(ForecastAccuracy.minimumDays) graded days a verdict needs"
            + (left > 0 ? ", so far. Each one is drawn as it arrives." : ".")
    }

    private var chart: some View {
        Chart {
            ForEach(checks) { check in
                RuleMark(x: .value("Day", date(check.day), unit: .day),
                         yStart: .value("Forecast", check.forecast),
                         yEnd: .value("Actual", check.actual))
                    .foregroundStyle(gapColor(check).opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            ForEach(checks) { check in
                LineMark(x: .value("Day", date(check.day), unit: .day),
                         y: .value("Measured", check.actual),
                         series: .value("Series", "actual"))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Day", date(check.day), unit: .day),
                          y: .value("Measured", check.actual))
                    .foregroundStyle(Color.primary)
                    .symbolSize(30)
            }
            ForEach(checks) { check in
                PointMark(x: .value("Day", date(check.day), unit: .day),
                          y: .value("Forecast", check.forecast))
                    .symbol(Circle().strokeBorder(lineWidth: 2))
                    .foregroundStyle(gapColor(check))
                    .symbolSize(70)
            }
            if let hover {
                RuleMark(x: .value("Day", hover, unit: .day)).foregroundStyle(Color.primary.opacity(0.25))
            }
        }
        .chartYScale(domain: domain)
        .chartXScale(domain: window.from...window.through)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, window.days / 6))) { value in
                AxisTick().foregroundStyle(Color.primary.opacity(0.15))
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(WeatherAlmanac.dayLabel(DayKey.string(for: d, timeZone: timezone)))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel { if let v = value.as(Double.self) { Text(measure.format(v)) } }
            }
        }
        .chartXSelection(value: $hover)
        .frame(height: 200)
    }

    /// THE WHOLE STRETCH, NOT JUST THE DAYS GRADED SO FAR — as Compare draws a
    /// stretch with days still to come. Fitted to the checks alone, two graded
    /// days were two huge marks at either end of the card; on a fixed month
    /// they are two days at the start of one, and each new day lands in its
    /// own place instead of rescaling the rest.
    ///
    /// A month from the first day kept, until there is more than a month to
    /// show; then the whole record.
    private var window: (from: Date, through: Date, days: Int) {
        let first = [loggedSince, checks.map(\.day).min()].compactMap { $0 }.min()
        let last = checks.map(\.day).max()
        guard let first, let start = DayKey.date(from: first, timeZone: timezone) else {
            return (.now, .now, 1)
        }
        let minimumEnd = DayKey.step(first, by: Self.windowDays - 1) ?? first
        let endKey = max(minimumEnd, last ?? minimumEnd)
        // Through the END of the last day, so its mark sits inside the chart.
        let end = DayKey.step(endKey, by: 1).flatMap { DayKey.date(from: $0, timeZone: timezone) } ?? start
        let days = max(1, Int((end.timeIntervalSince(start) / 86_400).rounded()))
        return (start, end, days)
    }

    private static let windowDays = 30

    private var domain: ClosedRange<Double> {
        let values = checks.flatMap { [$0.forecast, $0.actual] }
        guard let low = values.min(), let high = values.max() else { return 0...100 }
        return ((low - 3) / 5).rounded(.down) * 5 ... ((high + 3) / 5).rounded(.up) * 5
    }

    @ViewBuilder private var readout: some View {
        if let hover, let check = checks.first(where: {
            $0.day == DayKey.string(for: hover, timeZone: timezone)
        }) {
            HStack(spacing: 10) {
                Text(WeatherAlmanac.dayLabel(check.day)).font(.caption.weight(.semibold))
                Text("said \(measure.format(check.forecast)), measured \(measure.format(check.actual))")
                    .font(.caption.monospacedDigit())
                Text((check.error >= 0 ? "+" : "−") + measure.formatDelta(check.error))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(gapColor(check))
                if check.leadDays > 0 && !measure.gradesNightBefore {
                    Text("from the day before").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
        } else {
            Text("Point at a day to read it.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Rain

/// Each day's morning chance of rain as a bar, blue where it rained and grey
/// where it stayed dry; and underneath, how often it rained at each chance.
struct RainCalibrationView: View {
    let calibration: RainCalibration?
    let timezone: TimeZone

    @State private var hover: Date?

    private func date(_ key: String) -> Date {
        DayKey.date(from: key, timeZone: timezone) ?? .distantPast
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let calibration, let sentence = calibration.sentence {
                Text(sentence)
                    .font(.title3.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(calibration?.checks.count ?? 0) of the \(ForecastAccuracy.minimumDays) graded days this needs, so far.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let calibration, !calibration.checks.isEmpty {
                Chart {
                    ForEach(calibration.checks) { check in
                        BarMark(x: .value("Day", date(check.day), unit: .day),
                                y: .value("Chance", check.chance), width: .ratio(0.7))
                            .foregroundStyle(check.rained ? Color.blue.opacity(0.8) : Color.secondary.opacity(0.35))
                            .cornerRadius(2)
                    }
                    if let hover {
                        RuleMark(x: .value("Day", hover, unit: .day)).foregroundStyle(Color.primary.opacity(0.25))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(1, calibration.checks.count / 6))) { value in
                        AxisTick().foregroundStyle(Color.primary.opacity(0.15))
                        AxisValueLabel {
                            if let d = value.as(Date.self) {
                                Text(WeatherAlmanac.dayLabel(DayKey.string(for: d, timeZone: timezone)))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                        AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
                    }
                }
                .chartXSelection(value: $hover)
                .frame(height: 150)
                readout(calibration).readoutLine()

                // The buckets, as a row of plain counts — the test a chance has.
                HStack(spacing: 22) {
                    ForEach(calibration.buckets.filter { $0.days > 0 }) { bucket in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SAID \(bucket.label)")
                                .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.tertiary)
                            Text("rained \(bucket.wetDays) of \(bucket.days)")
                                .font(.callout.weight(.medium).monospacedDigit())
                        }
                    }
                }
                Text("Bars: the morning forecast's chance of rain. Blue: it rained (0.01″ or more). Grey: it stayed dry. "
                     + "A chance is right over many days, not on one — at 30%, it should rain about three times in ten.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func readout(_ c: RainCalibration) -> some View {
        if let hover, let check = c.checks.first(where: { $0.day == DayKey.string(for: hover, timeZone: timezone) }) {
            HStack(spacing: 10) {
                Text(WeatherAlmanac.dayLabel(check.day)).font(.caption.weight(.semibold))
                Text("said \(Int(check.chance.rounded()))%").font(.caption.monospacedDigit())
                Text(check.rained ? String(format: "rained %.2f″", check.amount) : "stayed dry")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(check.rained ? Color.blue : .secondary)
            }
            .foregroundStyle(.secondary)
        } else {
            Text("Point at a day to read it.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
