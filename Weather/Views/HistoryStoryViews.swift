//
//  HistoryStoryViews.swift
//
//  HISTORY'S STRETCH: what one month, season or year DID.
//
//  A sentence first — the fronts, where the rain went, how it ran against
//  normal — then the stretch day by day, a card per measure, then every event
//  with the numbers that make it that kind of event. The cards are there to
//  show the sentence is true: each front is marked where it landed, in every
//  card, and the bars after it sit lower.
//
//  Every day and every event opens that day's hours. The story is found at
//  daily resolution; the hour a front arrived is the day view's to show.
//

import SwiftUI
import Charts
import WeatherKit

/// The stretch day by day, ONE CARD PER MEASURE — highs, lows, rain, the
/// muggiest air, the strongest gust — on one shared date axis, with one hover
/// that lights the same day in every card.
///
/// It was one chart of highs, and before that a measure picker was proposed.
/// Both hide the thing worth seeing: how the measures move TOGETHER. A front is
/// highs dropping, lows dropping harder, the dew point falling and the gust
/// rising on the same date; a storm-cooled day drops the high and leaves the
/// dew point alone. Stacked on one axis, that reads straight down a column.
///
/// The temperature-like cards draw DEPARTURES — orange above the date's normal,
/// blue below — because "ran 4° warm" is a departure, and a bar against zero
/// reads faster than a bar against a line that slopes through the season.
/// Rain is drawn as itself.
struct StoryCards: View {
    let story: StretchStory
    var onOpenDay: (String) -> Void = { _ in }

    @State private var hover: Date?

    private static let zone = TimeZone.current
    private func date(_ key: String) -> Date {
        DayKey.date(from: key, timeZone: Self.zone) ?? .distantPast
    }

    private var hoveredDay: StoryDay? {
        guard let hover else { return nil }
        let key = DayKey.string(for: hover, timeZone: Self.zone)
        return story.days.first { $0.day == key }
    }

    /// The WHOLE stretch, not just the days so far: on Oct 4 a month's cards
    /// are still a month wide, three bars and twenty-eight empty days. Three
    /// bars stretched across the card read as a scale, not a week in.
    private var domain: ClosedRange<Date> {
        let first = date(story.days.first?.day ?? "")
        let last = date(max(story.lastDay, story.days.last?.day ?? "")).addingTimeInterval(86_400)
        return first...max(last, first.addingTimeInterval(86_400))
    }

    /// Every calendar day the cards span, held or not.
    private var calendarDays: [String] {
        guard var key = story.days.first?.day else { return [] }
        var keys: [String] = []
        while key <= story.lastDay || key <= (story.days.last?.day ?? key) {
            keys.append(key)
            guard let next = DayKey.step(key, by: 1) else { break }
            key = next
        }
        return keys
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StationCard(label: "Highs · day by day") { departureCard(.high, labelFronts: true) }
            StationCard(label: "Lows · day by day") { departureCard(.low) }
            StationCard(label: "Rain · day by day") { rainCard }
            StationCard(label: "Dew point · day by day") { departureCard(.dewPoint) }
            StationCard(label: "Gust · day by day") { departureCard(.gust) }
        }
    }

    // MARK: A measure against normal

    private func departureCard(_ m: DailyMeasure, labelFronts: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let line = summary(m) {
                Text(line).font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Chart {
                ForEach(story.days) { day in
                    if let off = day.departure(m) {
                        BarMark(x: .value("Day", date(day.day), unit: .day),
                                yStart: .value("Normal", 0), yEnd: .value("Departure", off),
                                width: .ratio(0.75))
                            .foregroundStyle((off >= 0 ? Color.orange : Color.blue)
                                .opacity(day.isReliable ? 0.8 : 0.3))
                            .cornerRadius(2)
                    }
                }
                RuleMark(y: .value("Normal", 0)).foregroundStyle(Color.primary.opacity(0.4))
                frontRules(labelled: labelFronts)
                hoverRule
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: departureDomain(m))
            .chartXAxis { dayAxis }
            .chartYAxis {
                AxisMarks(position: .leading, values: departureTicks(m)) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(v == 0 ? "normal" : (v > 0 ? "+" : "−") + m.formatDelta(v))
                        }
                    }
                }
            }
            .chartXSelection(value: $hover)
            .frame(height: 130)
            // Room for the "front" labels above the plot, so they don't sit
            // on the summary line.
            .padding(.top, labelFronts ? 12 : 0)
            readout(hint: labelFronts) { day in
                guard let v = day.value(m) else { return "no record" }
                var text = m.format(v)
                if let off = day.departure(m) {
                    let d = Int(off.rounded())
                    text += d == 0 ? " · normal" : " · \(m.formatDelta(Double(d))) \(d > 0 ? m.moreWord : m.lessWord) than usual"
                }
                return text
            }
            .readoutLine()
        }
    }

    /// "Highs ran 4° above normal — above on 28 of 30 days."
    private func summary(_ m: DailyMeasure) -> String? {
        let offs = story.days.filter(\.isReliable).compactMap { $0.departure(m) }
        guard !offs.isEmpty else { return nil }
        let mean = offs.reduce(0, +) / Double(offs.count)
        let above = offs.filter { $0 > 0 }.count
        let d = Int(mean.rounded())
        let lead = d == 0 ? "\(m.plural) ran about normal"
            : "\(m.plural) ran \(m.formatDelta(Double(d))) \(d > 0 ? m.moreWord : m.lessWord) than usual"
        var text = "\(lead) — above normal on \(above) of \(offs.count) days."
        if m == .gust, let top = story.days.filter({ $0.gust != nil }).max(by: { $0.gust! < $1.gust! }), let g = top.gust {
            text += " Strongest: \(m.format(g)) on \(WeatherAlmanac.dayLabel(top.day))."
        }
        return text
    }

    /// Symmetric about normal, so above and below read at the same scale.
    private func departureDomain(_ m: DailyMeasure) -> ClosedRange<Double> {
        let reach = story.days.compactMap { $0.departure(m) }.map(abs).max() ?? 5
        let edge = max(5, ((reach + 2) / 5).rounded(.up) * 5)
        return -edge...edge
    }

    /// Five labels at most — the edges, halfway, and normal — so a short card
    /// isn't a column of numbers.
    private func departureTicks(_ m: DailyMeasure) -> [Double] {
        let edge = departureDomain(m).upperBound
        return [-edge, -edge / 2, 0, edge / 2, edge]
    }

    // MARK: Rain

    private var rainCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rainSummary).font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Chart {
                ForEach(story.days) { day in
                    if let p = day.precip, p >= 0.01 {
                        BarMark(x: .value("Day", date(day.day), unit: .day), y: .value("Rain", p), width: .ratio(0.75))
                            // Teal where the number is the person's own gauge.
                            .foregroundStyle(day.rainFromGauge ? Color.teal.opacity(0.9)
                                             : Color.blue.opacity(day.isReliable ? 0.8 : 0.35))
                            .cornerRadius(2)
                    }
                }
                frontRules(labelled: false)
                hoverRule
            }
            .chartXScale(domain: domain)
            .chartXAxis { dayAxis }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel { if let v = value.as(Double.self) { Text(String(format: "%.1f″", v)) } }
                }
            }
            .chartXSelection(value: $hover)
            .frame(height: 110)
            readout(hint: false) { day in
                guard let p = day.precip else { return "no record" }
                let amount = p >= 0.01 ? String(format: "%.2f″", p) : "no rain"
                return day.rainFromGauge ? amount + " (your gauge)" : amount
            }
            .readoutLine()
        }
    }

    private var rainSummary: String {
        let wet = story.days.filter { ($0.precip ?? 0) >= 0.01 }
        guard let most = wet.max(by: { ($0.precip ?? 0) < ($1.precip ?? 0) }) else { return "No rain fell." }
        var text = String(format: "%.2f″ on %d %@; the most, %.2f″, on %@.", story.rain, wet.count,
                          wet.count == 1 ? "day" : "days", most.precip ?? 0, WeatherAlmanac.dayLabel(most.day))
        let gauged = story.days.filter(\.rainFromGauge)
        if !gauged.isEmpty {
            text += String(format: " %.2f″ of it is from your own gauge (teal).", gauged.reduce(0) { $0 + ($1.precip ?? 0) })
        }
        return text
    }

    // MARK: Shared marks

    /// Neutral, not blue: blue is "below normal" on these charts.
    @ChartContentBuilder private func frontRules(labelled: Bool) -> some ChartContent {
        ForEach(story.fronts) { front in
            RuleMark(x: .value("Day", date(front.day), unit: .day))
                .foregroundStyle(Color.primary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [3, 2]))
                .annotation(position: .top, spacing: 2) {
                    if labelled && calendarDays.count <= 62 {
                        Text("front").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
        }
    }

    @ChartContentBuilder private var hoverRule: some ChartContent {
        if let day = hoveredDay {
            RuleMark(x: .value("Day", date(day.day), unit: .day)).foregroundStyle(Color.primary.opacity(0.3))
        }
    }

    private var dayAxis: some AxisContent {
        AxisMarks(values: axisDays) { value in
            AxisTick().foregroundStyle(Color.primary.opacity(0.15))
            AxisValueLabel {
                if let d = value.as(Date.self) {
                    Text(WeatherAlmanac.dayLabel(DayKey.string(for: d, timeZone: Self.zone)))
                }
            }
        }
    }

    /// About six labels; month starts when the stretch is long enough to have them.
    private var axisDays: [Date] {
        let days = calendarDays
        if days.count > 62 {
            return days.filter { $0.hasSuffix("-01") }.map(date)
        }
        let step = max(1, days.count / 6)
        // Stop short of the last couple of days, whose label would run off the edge.
        return stride(from: 0, to: max(1, days.count - 2), by: step).map { date(days[$0]) }
    }

    /// The hovered day, read in this card's measure — and the way into its hours.
    @ViewBuilder private func readout(hint: Bool, _ value: @escaping (StoryDay) -> String) -> some View {
        if let day = hoveredDay {
            HStack(spacing: 10) {
                Text(WeatherAlmanac.dayLabel(day.day)).font(.caption.weight(.semibold))
                Text(value(day)).font(.caption.monospacedDigit())
                ForEach(story.events.filter { $0.day == day.day && $0.kind != .hottest && $0.kind != .coldest }) { event in
                    Label(event.title, systemImage: event.symbol).font(.caption)
                }
                Spacer(minLength: 0)
                Button("Open \(WeatherAlmanac.dayLabel(day.day)) →") { onOpenDay(day.day) }
                    .buttonStyle(.link).font(.caption)
            }
            .foregroundStyle(.secondary)
        } else if hint {
            // Said once, on the first card — five copies of it is clutter.
            Text("Point at a day — every card follows — and open it for its hours.")
                .font(.caption2).foregroundStyle(.tertiary)
        } else {
            // A real, invisible line — NOT nothing. An absent view takes its
            // reserved height with it, which is how cards two to five kept
            // growing under the pointer after the first one stopped.
            Text(" ").font(.caption2).hidden()
        }
    }
}

/// Every event in the stretch, in date order, each a door into its day.
struct StoryEventList: View {
    let story: StretchStory
    var onOpenDay: (String) -> Void = { _ in }

    /// What the list is for: things that HAPPENED. The hottest day and the
    /// coldest night are on the tiles at the top of the page, rank and all, so
    /// listing them here again was the same fact twice.
    private var listable: [StoryEvent] {
        story.events.filter { $0.kind != .hottest && $0.kind != .coldest }
    }

    /// A year holds over a hundred; past a couple of dozen the list is the
    /// big ones — fronts, rains of an inch or more, strong gusts — and says so.
    private var shown: [StoryEvent] {
        guard listable.count > 25 else { return listable }
        return listable.filter { event in
            switch event.kind {
            case .front: return true
            case .gust: return event.size >= 50
            case .rain: return event.size >= 1
            case .humidReturn, .warmSpell, .coolSpell, .hottest, .coldest: return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if listable.isEmpty {
                Text("Nothing stood out: no fronts, no rain worth a quarter inch, no runs of warm or cool days.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(shown) { event in
                Button { onOpenDay(event.day) } label: { row(event) }
                    .buttonStyle(.plain)
                    .help("Open \(WeatherAlmanac.dayLabel(event.day)) — its hours")
            }
            if shown.count < listable.count {
                Text("Showing the larger events — fronts, rains of an inch or more and gusts of 50 mph or more. "
                     + "Step to a month for all \(listable.count).")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ event: StoryEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: event.symbol)
                .foregroundStyle(event.kind == .front ? Color.blue : Color.accentColor)
                .frame(width: 20)
            Text(StretchStory.span(event.day, event.end))
                .font(.callout.weight(.semibold).monospacedDigit())
                .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.callout.weight(.medium))
                if !event.detail.isEmpty {
                    Text(event.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
