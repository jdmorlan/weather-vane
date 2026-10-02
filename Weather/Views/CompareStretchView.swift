//
//  CompareStretchView.swift
//
//  COMPARE'S WEEK, MONTH AND SEASON: this stretch so far against the same days
//  in every other year.
//
//  The sentence leads — "October so far: 1.40″ of rain, the wettest start of the
//  4 shown" — and each chart is there to prove a half of it. Rain is drawn
//  ADDING UP, one line per year, because "wettest start" is a question about a
//  running total, and a bar per day hides it. Highs are this year's line, raw,
//  against the USUAL as a smooth band — each date's normal high, give or take
//  its typical spread, from the whole record.
//
//  Two earlier shapes failed. One line per year was a tangle past three years.
//  Then the band was the warmest-to-coolest of the other years each day, with
//  their average through it: with three years that is noise drawn as a shape —
//  its edges jumped wherever any one year had a front — and the jagged average
//  read as a second subject. "Disorienting" was the verdict. The smooth band
//  says what usual IS, so the only jagged thing on the chart is the weather.
//
//  The years are told apart by colour, and the colour belongs to the YEAR: 2024
//  is the same orange whichever years are chosen, so hiding one never repaints
//  the rest. Each line is labelled at its end, so identity never rests on
//  colour alone, and the table under the charts holds every number they draw.
//

import SwiftUI
import Charts
import WeatherKit

/// The colour a year wears everywhere on Compare.
///
/// Slots in a fixed order, counted from the record's first year — validated for
/// colour-blind separation on both surfaces. A ninth year reuses slot one,
/// which is years away and acceptable then only because every line is labelled.
enum YearPalette {
    private static let light: [Color] = [
        Color(red: 0x2a / 255, green: 0x78 / 255, blue: 0xd6 / 255),
        Color(red: 0xeb / 255, green: 0x68 / 255, blue: 0x34 / 255),
        Color(red: 0x1b / 255, green: 0xaf / 255, blue: 0x7a / 255),
        Color(red: 0xed / 255, green: 0xa1 / 255, blue: 0x00 / 255),
        Color(red: 0xe8 / 255, green: 0x7b / 255, blue: 0xa4 / 255),
        Color(red: 0x00 / 255, green: 0x83 / 255, blue: 0x00 / 255),
        Color(red: 0x4a / 255, green: 0x3a / 255, blue: 0xa7 / 255),
        Color(red: 0xe3 / 255, green: 0x49 / 255, blue: 0x48 / 255),
    ]
    private static let dark: [Color] = [
        Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xe5 / 255),
        Color(red: 0xd9 / 255, green: 0x59 / 255, blue: 0x26 / 255),
        Color(red: 0x19 / 255, green: 0x9e / 255, blue: 0x70 / 255),
        Color(red: 0xc9 / 255, green: 0x85 / 255, blue: 0x00 / 255),
        Color(red: 0xd5 / 255, green: 0x51 / 255, blue: 0x81 / 255),
        Color(red: 0x00 / 255, green: 0x83 / 255, blue: 0x00 / 255),
        Color(red: 0x90 / 255, green: 0x85 / 255, blue: 0xe9 / 255),
        Color(red: 0xe6 / 255, green: 0x67 / 255, blue: 0x67 / 255),
    ]

    static func color(_ year: Int, firstYear: Int, scheme: ColorScheme) -> Color {
        let slots = scheme == .dark ? dark : light
        let slot = ((year - firstYear) % slots.count + slots.count) % slots.count
        return slots[slot]
    }
}

/// `(2023) (2024) (●2026)` — which years Compare lines up. Shared by every grain.
struct YearChips: View {
    let years: [Int]
    let firstYear: Int
    let current: Int?
    @Binding var hidden: Set<Int>

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Text("Years").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(years, id: \.self) { year in
                chip(year)
            }
        }
    }

    private func chip(_ year: Int) -> some View {
        let shown = !hidden.contains(year)
        // The last one showing stays: a comparison of nothing is not a state
        // the page should be able to reach.
        let isLast = shown && hidden.count == years.count - 1
        return Button {
            if shown { hidden.insert(year) } else { hidden.remove(year) }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(shown ? YearPalette.color(year, firstYear: firstYear, scheme: scheme)
                                : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(String(year))
                    .font(.callout.weight(year == current ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(shown ? .primary : .tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(shown ? Color.primary.opacity(0.07) : .clear, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(shown ? 0.12 : 0.08)))
        }
        .buttonStyle(.plain)
        .disabled(isLast)
        .help(shown ? "Hide \(String(year))" : "Show \(String(year))")
    }
}

struct CompareStretchView: View {
    let climate: Climatology
    let period: WeatherPeriod
    let today: String
    let forecast: [String: (high: Double?, low: Double?, precip: Double?)]
    let hidden: Set<Int>
    let firstYear: Int
    var onPickYear: (Int) -> Void = { _ in }

    @Environment(\.colorScheme) private var scheme
    @State private var comparison: StretchComparison?
    /// The usual per day of the stretch for every measure: normal ± typical
    /// spread. Built with the comparison, off the main actor.
    @State private var usual: [DailyMeasure: [(index: Int, low: Double, mid: Double, high: Double)]] = [:]
    /// ONE hover for every card: pointing at Oct 5 in the lows lights Oct 5
    /// in the rain and the gusts too.
    @State private var hover: Int?
    /// Each chart's view — every year's line, or this year against the usual —
    /// keyed by chart and remembered across visits (`ChartViewSwitch`).
    @State private var views: [String: ChartView] = [:]

    private func view(_ key: String) -> ChartView { views[key] ?? ChartViewSwitch.stored(key) }
    private func viewBinding(_ key: String) -> Binding<ChartView> {
        Binding(get: { view(key) }, set: { views[key] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let comparison {
                content(comparison)
            } else {
                StationCard(label: period.name) {
                    ProgressView("Lining up the years…")
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        }
        .task(id: "\(period.id)|\(today)") {
            let climate = climate, period = period, today = today, forecast = forecast
            let (built, band) = await Task.detached(priority: .userInitiated) {
                let built = climate.stretch(period, today: today, forecast: forecast)
                var band: [DailyMeasure: [(index: Int, low: Double, mid: Double, high: Double)]] = [:]
                if let start = built.subject?.start {
                    for measure in DailyMeasure.allCases {
                        var rows: [(index: Int, low: Double, mid: Double, high: Double)] = []
                        for index in 0..<built.length {
                            guard let key = DayKey.step(start, by: index),
                                  let usual = climate.normalBand(measure, monthDay: DayKey.monthDay(of: key)) else { continue }
                            rows.append((index, usual.mid - usual.spread, usual.mid, usual.mid + usual.spread))
                        }
                        band[measure] = rows
                    }
                }
                return (built, band)
            }.value
            guard !Task.isCancelled else { return }
            comparison = built
            usual = band
        }
    }

    private func shown(_ c: StretchComparison) -> [StretchYear] {
        c.years.filter { !hidden.contains($0.year) }
    }

    private func color(_ year: Int) -> Color {
        YearPalette.color(year, firstYear: firstYear, scheme: scheme)
    }

    @ViewBuilder private func content(_ c: StretchComparison) -> some View {
        if let sentence = c.sentence(years: Set(shown(c).map(\.year)), measure: .high) {
            Text(sentence)
                .font(.title3.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        StationCard(label: c.isRunning ? "Rain so far" : "Rain through \(c.period.name)") {
            ChartViewSwitch(key: "compare.rain", selection: viewBinding("compare.rain"))
        } content: {
            if view("compare.rain") == .years { rainChart(c) } else { rainUsualChart(c) }
        }
        // A card per measure rather than a picker: how they move TOGETHER —
        // nights warm while days run normal, a front dropping all four — is
        // the thing worth seeing, and a picker shows one at a time.
        //
        // Each card draws EVERY YEAR as its own line by default — real years
        // doing real things, which is what a comparison is — or this year
        // against the smooth usual band, a click away in its corner.
        ForEach(DailyMeasure.allCases) { measure in
            let key = "compare.\(measure.rawValue)"
            StationCard(label: measure.dailyTitle) {
                ChartViewSwitch(key: key, selection: viewBinding(key))
            } content: {
                if view(key) == .years { yearsChart(c, measure) } else { highsChart(c, measure) }
            }
        }
        StationCard(label: tableTitle(c)) {
            table(c)
        }
    }

    // MARK: Axis

    /// Day index → "Oct 5", read off the subject year so a leap year's Feb 29
    /// lands where it does in that year.
    private func dateLabel(_ index: Int, _ c: StretchComparison) -> String {
        guard let start = c.subject?.start, let key = DayKey.step(start, by: index) else { return "" }
        return WeatherAlmanac.dateLabel(DayKey.monthDay(of: key))
    }

    private func xDomain(_ c: StretchComparison) -> ClosedRange<Int> {
        0...max(1, c.length - 1)
    }

    // MARK: Rain

    /// Each year's rain adding up through the stretch. The running year stops
    /// at yesterday and carries on dashed through the forecast's amounts —
    /// stopping where the hourly forecast stops, because a day it doesn't
    /// reach is unknown, not dry.
    private func rainChart(_ c: StretchComparison) -> some View {
        let years = shown(c)
        let ahead = rainAhead(c)
        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(years) { year in
                    ForEach(year.cumulativeRain, id: \.index) { point in
                        LineMark(x: .value("Day", point.index),
                                 y: .value("Rain", point.total),
                                 series: .value("Year", String(year.year)))
                            .foregroundStyle(color(year.year))
                            .lineStyle(StrokeStyle(lineWidth: year.isCurrent ? 2.5 : 1.5))
                    }
                    // The running year's newest measured day gets a dot: on the
                    // second of the month it is the ONLY measured day, and a
                    // line of one point draws nothing.
                    if year.isCurrent, let last = year.cumulativeRain.last {
                        PointMark(x: .value("Day", last.index), y: .value("Rain", last.total))
                            .symbolSize(36)
                            .foregroundStyle(color(year.year))
                    }
                }
                ForEach(ahead, id: \.index) { point in
                    LineMark(x: .value("Day", point.index),
                             y: .value("Rain", point.total),
                             series: .value("Year", "forecast"))
                        .foregroundStyle(color(c.subject?.year ?? 0))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
                // End labels, spread so close finishes don't overprint.
                ForEach(spreadLabels(rainEnds(years, ahead: ahead), span: rainSpan(years, ahead: ahead)),
                        id: \.year) { label in
                    PointMark(x: .value("Day", label.index), y: .value("Rain", label.y))
                        .symbolSize(0)
                        .annotation(position: .trailing, spacing: 4) { endLabel(label.year) }
                }
                todayRule(c)
                if let hover {
                    hoverRule(hover)
                }
            }
            .chartXScale(domain: xDomain(c))
            .chartXAxis { dayAxis(c) }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(String(format: "%.1f″", v)) }
                    }
                }
            }
            .chartXSelection(value: $hover)
            .frame(height: 180)
            .padding(.trailing, 36)   // room for the end labels
            hoverReadout(hover, c) { year, index in
                year.cumulativeRain.first { $0.index == index }.map { String(format: "%.2f″", $0.total) }
            }
            .readoutLine()
            if !ahead.isEmpty {
                Text("Dashed: the forecast's rain, added on from today.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func rainEnds(_ years: [StretchYear], ahead: [(index: Int, total: Double)]) -> [(year: Int, index: Int, value: Double)] {
        years.compactMap { year in
            if year.isCurrent, let last = ahead.last { return (year.year, last.index, last.total) }
            return year.cumulativeRain.last.map { (year.year, $0.index, $0.total) }
        }
    }

    /// The rain axis's reach, for spacing labels: zero to the wettest end.
    private func rainSpan(_ years: [StretchYear], ahead: [(index: Int, total: Double)]) -> Double {
        max(0.5, (years.compactMap { $0.cumulativeRain.last?.total } + ahead.map(\.total)).max() ?? 0.5)
    }

    /// The running year's forecast continuation, starting from its last
    /// measured total so the dashed line joins the solid one.
    private func rainAhead(_ c: StretchComparison) -> [(index: Int, total: Double)] {
        guard c.isRunning, let subject = c.subject, !hidden.contains(subject.year),
              !c.forecast.isEmpty else { return [] }
        let base = subject.cumulativeRain.last ?? (index: (c.cut ?? 0) - 1, total: 0)
        var points = [(index: base.index, total: base.total)]
        var total = base.total
        for day in c.forecast {
            guard let precip = day.precip else { break }
            total += precip
            points.append((day.index, total))
        }
        return points.count > 1 ? points : []
    }

    // MARK: Highs

    /// Every shown year as its own line, coloured as everywhere on Compare; this
    /// year bold, with the forecast dashed on where it reaches (highs and lows).
    private func yearsChart(_ c: StretchComparison, _ measure: DailyMeasure) -> some View {
        let years = shown(c)
        let ahead = highsAhead(c, measure)
        return VStack(alignment: .leading, spacing: 8) {
            if let clause = c.clause(measure, years: Set(years.map(\.year))) {
                Text(clause).font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Chart {
                ForEach(years) { year in
                    ForEach(year.days.filter { $0.value(measure) != nil }, id: \.index) { day in
                        LineMark(x: .value("Day", day.index),
                                 y: .value("Value", day.value(measure) ?? 0),
                                 series: .value("Year", String(year.year)))
                            .foregroundStyle(color(year.year))
                            .lineStyle(StrokeStyle(lineWidth: year.isCurrent ? 2.5 : 1.5))
                    }
                    if year.isCurrent, let last = year.days.last(where: { $0.value(measure) != nil }),
                       let v = last.value(measure) {
                        PointMark(x: .value("Day", last.index), y: .value("Value", v))
                            .symbolSize(30)
                            .foregroundStyle(color(year.year))
                    }
                }
                ForEach(spreadLabels(yearEnds(years, measure, ahead: ahead, c: c),
                                     span: yearsDomain(years, measure, ahead: ahead).upperBound
                                         - yearsDomain(years, measure, ahead: ahead).lowerBound), id: \.year) { label in
                    PointMark(x: .value("Day", label.index), y: .value("Value", label.y))
                        .symbolSize(0)
                        .annotation(position: .trailing, spacing: 4) { endLabel(label.year) }
                }
                ForEach(ahead, id: \.index) { point in
                    LineMark(x: .value("Day", point.index), y: .value("Value", point.high),
                             series: .value("Year", "forecast"))
                        .foregroundStyle(color(c.subject?.year ?? 0))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
                todayRule(c)
                if let hover { hoverRule(hover) }
            }
            .chartXScale(domain: xDomain(c))
            .chartYScale(domain: yearsDomain(years, measure, ahead: ahead))
            .chartXAxis { dayAxis(c) }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel { if let v = value.as(Double.self) { Text(measure.format(v)) } }
                }
            }
            .chartXSelection(value: $hover)
            .frame(height: 170)
            .padding(.trailing, 36)
            hoverReadout(hover, c) { year, index in
                year.days.first { $0.index == index }?.value(measure).map { measure.format($0) }
            }
            .readoutLine()
            Text("One line per year shown; \(c.subject.map { String($0.year) } ?? "this year") bold"
                 + (ahead.isEmpty ? "." : ", dashed where it's the forecast.")
                 + " Hide years with the chips above.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// End labels, spread so none sit on another. Years that end within a
    /// couple of days of each other share the right edge, and two that also
    /// end within a few degrees overprinted ("2024" over "2026"); each is
    /// nudged to keep a minimum gap, in the chart's own units, keeping order.
    private func spreadLabels(_ ends: [(year: Int, index: Int, value: Double)],
                              span: Double) -> [(year: Int, index: Int, y: Double)] {
        let gap = span * 0.09
        let sorted = ends.sorted { $0.value < $1.value }
        var placed: [(year: Int, index: Int, y: Double)] = []
        for e in sorted {
            var y = e.value
            if let below = placed.last(where: { abs($0.index - e.index) <= 3 }), y - below.y < gap {
                y = below.y + gap
            }
            placed.append((e.year, e.index, y))
        }
        return placed
    }

    /// Where each year's line ends — the running year at the end of its
    /// forecast when there is one.
    private func yearEnds(_ years: [StretchYear], _ measure: DailyMeasure,
                          ahead: [(index: Int, high: Double)], c: StretchComparison) -> [(year: Int, index: Int, value: Double)] {
        years.compactMap { year in
            if year.isCurrent, let last = ahead.last { return (year.year, last.index, last.high) }
            guard let last = year.days.last(where: { $0.value(measure) != nil }), let v = last.value(measure) else { return nil }
            return (year.year, last.index, v)
        }
    }

    private func yearsDomain(_ years: [StretchYear], _ measure: DailyMeasure,
                             ahead: [(index: Int, high: Double)]) -> ClosedRange<Double> {
        let values = years.flatMap { $0.days.compactMap { $0.value(measure) } } + ahead.map(\.high)
        guard let low = values.min(), let high = values.max() else { return 0...100 }
        return ((low - 3) / 5).rounded(.down) * 5 ... ((high + 3) / 5).rounded(.up) * 5
    }

    /// Rain's usual view: this year's running total against the other years'
    /// — their average as a line, the driest to wettest of them as a band.
    /// Rain adds up, so even a band of a few years is smooth rather than the
    /// jagged envelope the daily charts had.
    private func rainUsualChart(_ c: StretchComparison) -> some View {
        let subject = c.subject.flatMap { hidden.contains($0.year) ? nil : $0 }
        let others = shown(c).filter { $0.year != c.subject?.year }
        let band: [(index: Int, low: Double, mid: Double, high: Double)] = (0..<c.length).compactMap { i in
            let totals = others.compactMap { y in y.cumulativeRain.first { $0.index == i }?.total }
            guard let lo = totals.min(), let hi = totals.max() else { return nil }
            return (i, lo, totals.reduce(0, +) / Double(totals.count), hi)
        }
        let ahead = rainAhead(c)
        let tint = color(subject?.year ?? 0)
        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(band, id: \.index) { b in
                    AreaMark(x: .value("Day", b.index), yStart: .value("Driest", b.low), yEnd: .value("Wettest", b.high),
                             series: .value("Band", "others"))
                        .foregroundStyle(Color.primary.opacity(0.1))
                    LineMark(x: .value("Day", b.index), y: .value("Average", b.mid), series: .value("Series", "average"))
                        .foregroundStyle(Color.secondary.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                if let subject {
                    ForEach(subject.cumulativeRain, id: \.index) { p in
                        LineMark(x: .value("Day", p.index), y: .value("Rain", p.total), series: .value("Series", "subject"))
                            .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    if let last = subject.cumulativeRain.last {
                        PointMark(x: .value("Day", last.index), y: .value("Rain", last.total))
                            .symbolSize(36).foregroundStyle(tint)
                            .annotation(position: .top, spacing: 4) { endLabel(subject.year) }
                    }
                }
                ForEach(ahead, id: \.index) { p in
                    LineMark(x: .value("Day", p.index), y: .value("Rain", p.total), series: .value("Series", "forecast"))
                        .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
                if let last = band.last {
                    PointMark(x: .value("Day", last.index), y: .value("Average", last.mid))
                        .symbolSize(0)
                        .annotation(position: .trailing, spacing: 4) {
                            Text("others' average").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                todayRule(c)
                if let hover { hoverRule(hover) }
            }
            .chartXScale(domain: xDomain(c))
            .chartXAxis { dayAxis(c) }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel { if let v = value.as(Double.self) { Text(String(format: "%.1f″", v)) } }
                }
            }
            .chartXSelection(value: $hover)
            .frame(height: 180)
            .padding(.trailing, 80)
            hoverReadout(hover, c) { year, index in
                year.cumulativeRain.first { $0.index == index }.map { String(format: "%.2f″", $0.total) }
            }
            .readoutLine()
            Text("Shaded: the driest to wettest running total of the other years shown, with their average through it.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func highsChart(_ c: StretchComparison, _ measure: DailyMeasure) -> some View {
        let band = usual[measure] ?? []
        let subject = c.subject.flatMap { hidden.contains($0.year) ? nil : $0 }
        let measured = subject?.days.filter { $0.value(measure) != nil } ?? []
        let ahead = highsAhead(c, measure)
        let tint = color(subject?.year ?? 0)
        return VStack(alignment: .leading, spacing: 8) {
            if let clause = c.clause(measure, years: Set(shown(c).map(\.year))) {
                Text(clause).font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Chart {
                ForEach(band, id: \.index) { day in
                    AreaMark(x: .value("Day", day.index),
                             yStart: .value("Usual low end", day.low),
                             yEnd: .value("Usual high end", day.high),
                             series: .value("Band", "usual"))
                        .foregroundStyle(Color.primary.opacity(0.1))
                }
                ForEach(measured, id: \.index) { day in
                    LineMark(x: .value("Day", day.index),
                             y: .value("Value", day.value(measure) ?? 0),
                             series: .value("Series", "subject"))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                if let last = measured.last, let high = last.value(measure) {
                    PointMark(x: .value("Day", last.index), y: .value("Value", high))
                        .symbolSize(36)
                        .foregroundStyle(tint)
                        .annotation(position: .top, spacing: 4) {
                            if let year = subject?.year { endLabel(year) }
                        }
                }
                ForEach(ahead, id: \.index) { point in
                    LineMark(x: .value("Day", point.index),
                             y: .value("Value", point.high),
                             series: .value("Series", "forecast"))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
                if let last = band.last {
                    PointMark(x: .value("Day", last.index), y: .value("Usual", last.mid))
                        .symbolSize(0)
                        .annotation(position: .trailing, spacing: 4) {
                            Text("usual").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                todayRule(c)
                if let hover {
                    hoverRule(hover)
                }
            }
            .chartXScale(domain: xDomain(c))
            .chartYScale(domain: highsDomain(c, measure, band: band, ahead: ahead))
            .chartXAxis { dayAxis(c) }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(measure.format(v)) }
                    }
                }
            }
            .chartXSelection(value: $hover)
            .frame(height: 150)
            .padding(.trailing, 44)
            hoverReadout(hover, c) { year, index in
                year.days.first { $0.index == index }?.value(measure).map { measure.format($0) }
            }
            .readoutLine()
            // NOT "a dive is usually a front": in a Houston summer the deepest
            // dive in the record (July 13, 2026) was thunderstorms — the dew
            // point never moved. History's events say which a dive was.
            Text("Shaded: the usual \(measure.noun) for each date, give or take its typical spread, across every year on record"
                 + (ahead.isEmpty ? "." : ". Dashed: the forecast.")
                 + bandNote(measure))
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What a line leaving the band means, per measure.
    private func bandNote(_ measure: DailyMeasure) -> String {
        switch measure {
        case .high, .low: return " A dive below the band is a front or a storm — open the year in History to see which."
        case .dewPoint: return " A drop below the band is drier air arriving — usually a front."
        case .gust: return " A spike above the band is a storm or a front's wind."
        }
    }

    /// Fitted to what's drawn, padded and snapped to 5°. Swift Charts' own
    /// automatic domain was reaching for zero and squashing every line flat.
    private func highsDomain(_ c: StretchComparison, _ measure: DailyMeasure,
                             band: [(index: Int, low: Double, mid: Double, high: Double)],
                             ahead: [(index: Int, high: Double)]) -> ClosedRange<Double> {
        var values = band.flatMap { [$0.low, $0.high] } + ahead.map(\.high)
        if let subject = c.subject, !hidden.contains(subject.year) {
            values += subject.days.compactMap { $0.value(measure) }
        }
        guard let low = values.min(), let high = values.max() else { return 0...100 }
        return ((low - 3) / 5).rounded(.down) * 5 ... ((high + 3) / 5).rounded(.up) * 5
    }

    private func highsAhead(_ c: StretchComparison, _ measure: DailyMeasure) -> [(index: Int, high: Double)] {
        guard c.isRunning, let subject = c.subject, !hidden.contains(subject.year) else { return [] }
        var points: [(index: Int, high: Double)] = []
        // The forecast reaches only the high and the low; a gust or dew point
        // line simply stops at yesterday.
        guard measure.isTemperature else { return [] }
        if let last = subject.days.last(where: { $0.value(measure) != nil }), let v = last.value(measure) {
            points.append((last.index, v))
        }
        points += c.forecast.compactMap { day in (measure == .high ? day.high : day.low).map { (day.index, $0) } }
        return points.count > 1 ? points : []
    }

    // MARK: Shared marks

    @ChartContentBuilder private func todayRule(_ c: StretchComparison) -> some ChartContent {
        if c.isRunning, let cut = c.cut, cut > 0, cut < c.length {
            RuleMark(x: .value("Today", cut))
                .foregroundStyle(Color.primary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("today").font(.caption2).foregroundStyle(.secondary)
                }
        }
    }

    private func hoverRule(_ index: Int) -> some ChartContent {
        RuleMark(x: .value("Day", index))
            .foregroundStyle(Color.primary.opacity(0.3))
            .lineStyle(StrokeStyle(lineWidth: 1))
    }

    private func dayAxis(_ c: StretchComparison) -> some AxisContent {
        let step = max(1, c.length / 6)
        return AxisMarks(values: Array(stride(from: 0, to: c.length, by: step))) { value in
            AxisTick().foregroundStyle(Color.primary.opacity(0.15))
            AxisValueLabel {
                if let index = value.as(Int.self) { Text(dateLabel(index, c)) }
            }
        }
    }

    private func endLabel(_ year: Int) -> some View {
        Text(String(year))
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// One line under the chart while the pointer is over it: the date, then
    /// each shown year's value there, each beside its colour.
    @ViewBuilder private func hoverReadout(_ index: Int?, _ c: StretchComparison,
                                           value: @escaping (StretchYear, Int) -> String?) -> some View {
        if let index {
            HStack(spacing: 12) {
                Text(dateLabel(index, c)).font(.caption.weight(.semibold))
                ForEach(shown(c)) { year in
                    if let v = value(year, index) {
                        HStack(spacing: 4) {
                            Circle().fill(color(year.year)).frame(width: 7, height: 7)
                            Text("\(String(year.year)) \(v)").font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            .foregroundStyle(.secondary)
        } else {
            Text("Point at a day to read every year's value.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: The table

    private func tableTitle(_ c: StretchComparison) -> String {
        guard c.isRunning, let cut = c.cut, cut > 0 else {
            return "Whole \(c.period.name), each year"
        }
        if cut == 1 { return "\(dateLabel(0, c)), each year" }
        return "\(dateLabel(0, c)) – \(dateLabel(cut - 1, c)), each year"
    }

    /// Every number the charts draw, for reading across — and the door from each
    /// year into History.
    private func table(_ c: StretchComparison) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("").frame(width: 64, alignment: .leading)
                    head("RAIN"); head("WET DAYS"); head("AVG HIGH"); head("AVG LOW"); head("HOTTEST")
                    head("PEAK DEW"); head("TOP GUST")
                    Text("").gridCellUnsizedAxes(.horizontal)
                }
                ForEach(shown(c)) { year in
                    let t = year.tally
                    GridRow {
                        HStack(spacing: 6) {
                            Circle().fill(color(year.year)).frame(width: 8, height: 8)
                            Button(String(year.year)) { onPickYear(year.year) }
                                .buttonStyle(.link)
                                .font(.callout.weight(year.isCurrent ? .bold : .medium))
                                .help("Open \(c.period.name) \(String(year.year)) in History")
                        }
                        .frame(width: 64, alignment: .leading)
                        cell(String(format: "%.2f″", t.rain))
                        cell("\(t.wetDays)")
                        cell(degrees(t.meanHigh))
                        cell(degrees(t.meanLow))
                        cell(degrees(t.hottest))
                        cell(degrees(t.meanDewPoint))
                        cell(t.strongestGust.map { "\(Int($0.rounded())) mph" } ?? "—")
                        if !t.isComparable {
                            Text("\(t.daysHeld) of \(t.days) days")
                                .font(.caption).foregroundStyle(.orange.opacity(0.9))
                                .help("The archive holds only part of this stretch, so its rain is a floor and it isn't ranked.")
                        } else {
                            Text("").gridCellUnsizedAxes(.horizontal)
                        }
                    }
                }
            }
            Text("Click a year to open it in History.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func head(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.tertiary)
            .frame(width: 70, alignment: .leading)
    }

    private func cell(_ text: String) -> some View {
        Text(text).font(.callout.monospacedDigit()).frame(width: 70, alignment: .leading)
    }

    private func degrees(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))°" } ?? "—"
    }
}
