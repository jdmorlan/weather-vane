//
//  CompareDayHoursView.swift
//
//  COMPARE'S DAY, HOUR BY HOUR. Today — measured up to now, forecast after —
//  against every past year's version of the same date, read from the minutes
//  on disk.
//
//  The same grammar as the month: the subject as one bold line, the other
//  years as the band they spanned at each hour, with their average through it.
//  At 8am that sets this morning against every other October 2 morning; by
//  tomorrow the archive has today, and the line is just one of the years.
//

import SwiftUI
import Charts
import WeatherKit

struct CompareDayHoursView: View {
    /// The date, `MM-dd`.
    let monthDay: String
    /// Today's key — the subject is today only while `monthDay` is today's.
    let today: String
    /// Today by clock hour, measured then forecast. Index = clock hour.
    let todayHours: [HourSlice]
    /// The years the chips have left showing.
    let years: [Int]
    let firstYear: Int
    var store: (any SampleArchiveStore)?
    /// Temperature for a high or a low (a low is read for the night's
    /// bottom), the dew point, or the gust.
    var measure: DailyMeasure = .high

    @Environment(\.colorScheme) private var scheme
    /// Year → hour → temperature, for the date loaded.
    @State private var loaded: [Int: [Int: Double]] = [:]
    @State private var loadedFor: String?
    @State private var hover: Int?
    /// Every past year's hours as its own line, or the band they spanned.
    @State private var chartView: ChartView?

    private var viewKey: String { "compare.day.\(measure.isTemperature ? "temperature" : measure.rawValue)" }
    private var currentView: ChartView { chartView ?? ChartViewSwitch.stored(viewKey) }

    private var label: String { WeatherAlmanac.dateLabel(monthDay) }
    private var todayYear: Int { DayKey.year(of: today) ?? 0 }
    private var isTodaysDate: Bool { monthDay == DayKey.monthDay(of: today) }

    var body: some View {
        StationCard(label: "Hour by hour · \(measure.isTemperature ? "temperature" : measure.label.lowercased())") {
            ChartViewSwitch(key: viewKey, selection: Binding(get: { currentView }, set: { chartView = $0 }))
        } content: {
            if loadedFor != loadKey {
                ProgressView("Reading every \(label)'s minutes…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let overlay, overlay.subject != nil, !overlay.others.isEmpty {
                content(overlay)
            } else {
                Text("The minute record doesn't hold \(label) in enough of the years shown to compare hours.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: loadKey) { await load() }
    }

    /// A high and a low read the same hours; the dew point and the gust don't.
    private var loadKey: String {
        "\(monthDay)|\(measure.isTemperature ? "temperature" : measure.rawValue)"
    }

    /// Every past year's version of the date, off disk and off the main actor.
    private func load() async {
        let key = loadKey
        guard let store else { loadedFor = key; return }
        let monthDay = monthDay, today = today, first = firstYear, last = todayYear, measure = measure
        let traces = await Task.detached(priority: .userInitiated) { () -> [Int: [Int: Double]] in
            var out: [Int: [Int: Double]] = [:]
            for year in first...max(first, last) {
                let day = String(format: "%04d-%@", year, monthDay)
                guard day < today, let samples = try? store.samples(onDay: day), !samples.isEmpty else { continue }
                let hourly = HourTrace.hourly(samples, day: day, timeZone: .current, measure: measure)
                if !hourly.isEmpty { out[year] = hourly }
            }
            return out
        }.value
        guard !Task.isCancelled else { return }
        loaded = traces
        loadedFor = key
    }

    private var todayTrace: HourTrace? {
        guard isTodaysDate, years.contains(todayYear) else { return nil }
        var temps: [Int: Double] = [:]
        var observed: Set<Int> = []
        for (hour, slice) in todayHours.enumerated() where hour < 24 {
            guard let temp = slice.value(measure) else { continue }
            temps[hour] = temp
            if slice.isObserved { observed.insert(hour) }
        }
        return temps.isEmpty ? nil : HourTrace(year: todayYear, temps: temps, observed: observed)
    }

    private var overlay: DayOverlay? {
        let past = years.sorted(by: >).compactMap { year in
            loaded[year].map { HourTrace(year: year, temps: $0) }
        }
        if let today = todayTrace {
            return DayOverlay(dateLabel: label, subject: today, isToday: true, others: past, measure: measure)
        }
        guard let newest = past.first else { return nil }
        return DayOverlay(dateLabel: label, subject: newest, isToday: false,
                          others: Array(past.dropFirst()), measure: measure)
    }

    private func color(_ year: Int) -> Color {
        YearPalette.color(year, firstYear: firstYear, scheme: scheme)
    }

    // MARK: The chart

    private func content(_ o: DayOverlay) -> some View {
        let subject = o.subject!
        let tint = color(subject.year)
        let measured = subject.temps.filter { subject.observed.contains($0.key) }
            .sorted { $0.key < $1.key }
        // The forecast joins the last measured hour so the dashed line meets
        // the solid one instead of starting in mid-air.
        var ahead = subject.temps.filter { !subject.observed.contains($0.key) }
            .sorted { $0.key < $1.key }
        if let last = measured.last, !ahead.isEmpty { ahead.insert(last, at: 0) }
        let band = o.band

        return VStack(alignment: .leading, spacing: 10) {
            if let sentence = sentence(o) {
                Text(sentence)
                    .font(.title3.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Chart {
                if currentView == .years {
                    // Every past year's hours as its own line, in its colour.
                    ForEach(o.others) { trace in
                        ForEach(trace.temps.sorted { $0.key < $1.key }, id: \.key) { point in
                            LineMark(x: .value("Hour", point.key), y: .value("Value", point.value),
                                     series: .value("Series", String(trace.year)))
                                .foregroundStyle(color(trace.year))
                                .lineStyle(StrokeStyle(lineWidth: 1.5))
                        }
                        if let last = trace.temps.max(by: { $0.key < $1.key }) {
                            PointMark(x: .value("Hour", last.key), y: .value("Value", last.value))
                                .symbolSize(0)
                                .annotation(position: .trailing, spacing: 4) {
                                    Text(String(trace.year)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                        }
                    }
                } else {
                ForEach(band, id: \.hour) { hour in
                    AreaMark(x: .value("Hour", hour.hour),
                             yStart: .value("Coolest", hour.low),
                             yEnd: .value("Warmest", hour.high),
                             series: .value("Band", "others"))
                        .foregroundStyle(Color.primary.opacity(0.09))
                    LineMark(x: .value("Hour", hour.hour),
                             y: .value("Average", hour.mean),
                             series: .value("Series", "average"))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                }
                ForEach(measured, id: \.key) { point in
                    LineMark(x: .value("Hour", point.key), y: .value("Temp", point.value),
                             series: .value("Series", "subject"))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                ForEach(ahead, id: \.key) { point in
                    LineMark(x: .value("Hour", point.key), y: .value("Temp", point.value),
                             series: .value("Series", "forecast"))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
                if o.isToday, subject.isPartlyForecast, let now = subject.lastObserved,
                   let value = subject.temps[now] {
                    PointMark(x: .value("Hour", now), y: .value("Temp", value))
                        .symbolSize(40)
                        .foregroundStyle(tint)
                        .annotation(position: .top, spacing: 4) {
                            Text("now").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        }
                }
                if let last = (ahead.last ?? measured.last) {
                    PointMark(x: .value("Hour", last.key), y: .value("Temp", last.value))
                        .symbolSize(0)
                        .annotation(position: .top, spacing: 4) {
                            Text(o.isToday ? "today" : String(subject.year))
                                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        }
                }
                if currentView == .usual, let last = band.last {
                    PointMark(x: .value("Hour", last.hour), y: .value("Average", last.mean))
                        .symbolSize(0)
                        .annotation(position: .trailing, spacing: 4) {
                            Text(o.others.count == 1 ? String(o.others[0].year) : "others' average")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                }
                if let hover {
                    RuleMark(x: .value("Hour", hover))
                        .foregroundStyle(Color.primary.opacity(0.3))
                }
            }
            .chartXScale(domain: 0...23)
            .chartYScale(domain: domain(o))
            .chartXAxis {
                AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21]) { value in
                    AxisTick().foregroundStyle(Color.primary.opacity(0.15))
                    AxisValueLabel {
                        if let hour = value.as(Int.self) { Text(Self.axisClock(hour)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(measure.format(v)) }
                    }
                }
            }
            .chartXSelection(value: $hover)
            .frame(height: 220)
            .padding(.trailing, 80)

            readout(o).readoutLine()
            Text(caption(o))
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// For temperature, the afternoon's peak AND the night's bottom — one
    /// chart holds both, so its sentence says both.
    private func sentence(_ o: DayOverlay) -> String? {
        guard measure.isTemperature else { return o.sentence() }
        var low = o
        low.measure = .low
        let parts = [o.sentence(), low.extremeClause()].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func caption(_ o: DayOverlay) -> String {
        let years = o.others.map { String($0.year) }.joined(separator: ", ")
        if currentView == .years {
            return "One line per past \(label) (\(years)), from the station's minutes; "
                + (o.isToday ? "today bold — solid measured, dashed forecast." : "\(o.subject.map { String($0.year) } ?? "") bold.")
        }
        var text = "Shaded: the highest to lowest \(measure.isTemperature ? "temperature" : measure.label.lowercased()) the other \(label)s (\(years)) reached at each hour, from the station's minutes."
        if o.isToday { text += " Solid: measured today. Dashed: the forecast." }
        return text
    }

    @ViewBuilder private func readout(_ o: DayOverlay) -> some View {
        if let hover {
            HStack(spacing: 12) {
                Text(DayOverlay.clock(hover)).font(.caption.weight(.semibold))
                ForEach([o.subject!] + o.others) { trace in
                    if let v = trace.temps[hover] {
                        HStack(spacing: 4) {
                            Circle().fill(color(trace.year)).frame(width: 7, height: 7)
                            let tag = o.isToday && trace.year == todayYear
                                ? (trace.observed.contains(hover) ? "today" : "forecast")
                                : String(trace.year)
                            Text("\(tag) \(measure.format(v))").font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            .foregroundStyle(.secondary)
        } else {
            Text("Point at an hour to read every year's value.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func domain(_ o: DayOverlay) -> ClosedRange<Double> {
        let values = (o.subject.map { Array($0.temps.values) } ?? [])
            + o.band.flatMap { [$0.low, $0.high] }
        guard let low = values.min(), let high = values.max() else { return 0...100 }
        return ((low - 3) / 5).rounded(.down) * 5 ... ((high + 3) / 5).rounded(.up) * 5
    }

    private static func axisClock(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        case 1..<12: return "\(hour)a"
        default: return "\(hour - 12)p"
        }
    }
}
