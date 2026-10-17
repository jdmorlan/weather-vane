//
//  ExploreViews.swift
//
//  The Explore page: ask a question, and get the answer as a place in the year.
//
//  WHAT IT IS FOR. You arrive with a question — when is it hot, when does it
//  freeze, does September usually get rain — and the page answers that question,
//  in its own terms. The old page answered every question with a count ("65
//  days … typically around February 5") and left the asked-for answer to be read
//  off a calendar of squares. Counting still matters (how often is how you learn
//  a climate), so the count is here, under Year by year; it just isn't the lead.
//
//  ONE ANSWER CARD, SEVERAL VIEWS of it: how often it happens on each date, the
//  readings themselves on those dates (was it 49° or 30°?), and the count season
//  by season. Under it, the cards that say something else about the same days:
//  the records (each opens its day), what those days were like, and the days the
//  station couldn't vouch for.
//
//  A question is one of the presets or one built by hand; either way it's a
//  `DayQuery`, and the page reads it through `WhenInTheYear`.
//

import SwiftUI
import WeatherKit

struct WeatherExploreView: View {
    /// Scroll target for a hand-off from another page.
    static let builderAnchor = "explore-builder"

    let climate: Climatology
    /// Station-local today.
    let today: String
    @Binding var query: DayQuery
    /// Open one day in History.
    var openDay: (String) -> Void = { _ in }
    /// Open one month in History.
    var openMonth: (String) -> Void = { _ in }

    @State private var shape: WhenInTheYear?
    /// What the days were like, and the ones that couldn't be counted.
    @State private var result: QueryResult?
    /// The other verb: a question that reports a number instead of finding days.
    @State private var report: ReportPicture?
    /// Which query the state above belongs to, so a stale answer never sits under a new question.
    @State private var answered: DayQuery?
    @State private var editing = false

    private var question: ExploreQuestion { ExploreQuestion.describing(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            askRow.id(WeatherExploreView.builderAnchor)
            if editing {
                QueryBuilder(query: $query, availableYears: climate.years.reversed())
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.03)))
            }
            if answered != query {
                ProgressView().frame(maxWidth: .infinity).padding(30)
            } else if let report {
                ReportCard(picture: report, query: query) { grain, day in
                    grain == .month ? openMonth(day) : openDay(day)
                }
            } else if let shape, let result, !shape.matchedDays.isEmpty {
                WhenInTheYearCard(shape: shape, question: question, query: query,
                                  recordEnd: climate.latestDay ?? today, openDay: openDay)
                    .id(question.id + query.describe)
                recordsCard(shape)
                profileCard(shape, result)
                unconfirmedCard(shape, result)
                footer
            } else {
                card {
                    Text("Nothing in \(climate.dayCount.formatted()) days of record matches.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: query) { await rebuild() }
    }

    private func rebuild() async {
        // Debounced: dragging a threshold changes the query on every frame.
        do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
        let climate = climate, asked = query
        if asked.aggregate != nil {
            let built = await Task.detached(priority: .userInitiated) { climate.reportPicture(asked) }.value
            guard asked == query else { return }
            (report, shape, result, answered) = (built, nil, nil, asked)
            return
        }
        // Every year, every match: the year pin and a first/last rule are answered on the card, against this.
        var everything = asked
        everything.years = .all
        everything.sequence = nil
        let built = await Task.detached(priority: .userInitiated) {
            (climate.whenInTheYear(everything), climate.run(everything))
        }.value
        guard asked == query else { return }
        (report, shape, result, answered) = (nil, built.0, built.1, asked)
    }

    // MARK: The question

    private var askRow: some View {
        HStack(alignment: .center, spacing: 14) {
            questionMenu
            Text(query.describe)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(editing ? "Done" : "Edit question") {
                withAnimation(.easeOut(duration: 0.15)) { editing.toggle() }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var questionMenu: some View {
        Menu {
            ForEach(ExploreQuestion.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(ExploreQuestion.all.filter { $0.group == group }) { preset in
                        Button(preset.asks) { query = preset.query }
                    }
                }
            }
            Section("Report a number") {
                ForEach(DayQuery.reportQuestions, id: \.name) { preset in
                    Button(preset.name) { query = preset }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(query.aggregate != nil ? (query.name.isEmpty ? query.describe : query.name) : question.asks)
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Records

    /// A handful of single facts, each one a day you can open.
    private func recordsCard(_ shape: WhenInTheYear) -> some View {
        card(label: "Records") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10, alignment: .top)],
                      alignment: .leading, spacing: 10) {
                ForEach(shape.records) { record in recordTile(record) }
            }
        }
    }

    @ViewBuilder private func recordTile(_ record: WhenInTheYear.Record) -> some View {
        let content = { (opens: Bool) in
            VStack(alignment: .leading, spacing: 2) {
                Text(record.label.uppercased())
                    .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                if let day = record.day {
                    // A date record leads with the date; a value record leads with the value.
                    Text(record.value ?? WeatherAlmanac.dayLabel(day, includeYear: true))
                        .font(.system(size: 20, weight: .light, design: .rounded)).monospacedDigit()
                    Text(record.value != nil
                         ? WeatherAlmanac.dayLabel(day, includeYear: true) + (record.note.map { " · \($0)" } ?? "")
                         : reading(on: day))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(record.value ?? "").font(.system(size: 20, weight: .light, design: .rounded)).monospacedDigit()
                    Text(record.note ?? "").font(.caption).foregroundStyle(.secondary)
                }
                if opens { Text("Open the day").font(.caption2).foregroundStyle(Color.accentColor) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        if let day = record.day {
            Button { openDay(day) } label: { content(true) }
                .buttonStyle(.plain)
                .help("Open \(WeatherAlmanac.dayLabel(day, includeYear: true)) in History")
        } else {
            content(false)
        }
    }

    /// The reading that matters for this question, on one day.
    private func reading(on day: String) -> String {
        guard let record = climate.record(on: day) else { return "" }
        var seen = Set<Measure>()
        return query.conditions.compactMap { condition -> String? in
            let measure = condition.measure
            guard seen.insert(measure).inserted, let value = record[keyPath: measure.path] else { return nil }
            switch measure {
            case .high: return "\(measure.format(value)) high"
            case .low: return "\(measure.format(value)) low"
            case .rain: return "\(measure.format(value)) of rain"
            case .lightning: return "\(Int(value).formatted()) strikes"
            default: return "\(measure.name) \(measure.format(value))"
            }
        }.joined(separator: " · ")
    }

    // MARK: What those days were like

    /// The measures a person asks about first, in that order.
    private static let profiled: [Measure] = [.high, .low, .dewPoint, .humidity, .gust, .rain, .lightning]

    private func profileCard(_ shape: WhenInTheYear, _ result: QueryResult) -> some View {
        card(label: "What those days were like") {
            if result.profile.isEmpty {
                Text("None of the matching \(shape.noun) were recorded well enough to describe.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("The \(result.profile.matchedDays) \(shape.noun) that matched, against what those same dates usually do.")
                    .font(.caption).foregroundStyle(.tertiary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10, alignment: .top)],
                          alignment: .leading, spacing: 10) {
                    ForEach(Self.profiled.compactMap { m in result.profile.averages.first { $0.measure == m } }) { average in
                        profileTile(average, noun: shape.noun)
                    }
                }
            }
        }
    }

    private func profileTile(_ average: MeasureAverage, noun: String) -> some View {
        let name = average.measure == .gust ? "Peak gust" : average.measure.name
        return VStack(alignment: .leading, spacing: 2) {
            Text((average.wasAsked ? "asked · \(name)" : name).uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(average.wasAsked ? Color.accentColor : Color.secondary.opacity(0.7))
            if average.isShare {
                Text(shareInWords(average.matched).replacingOccurrences(of: " the", with: ""))
                    .font(.system(size: 21, weight: .light, design: .rounded))
                Text("\(noun) had \(average.measure == .rain ? "rain" : "lightning")")
                    .font(.caption).foregroundStyle(.secondary)
                if let usual = average.usual {
                    Text("usually \(shareInWords(usual, capital: false).replacingOccurrences(of: " the", with: ""))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                Text(average.matchedLabel)
                    .font(.system(size: 21, weight: .light, design: .rounded)).monospacedDigit()
                Text(average.departureLabel.map { "\($0) vs usual" } ?? "about normal")
                    .font(.caption).foregroundStyle(.secondary)
                if let usual = average.usualLabel {
                    Text("usually \(usual)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
    }

    // MARK: Not confirmed

    /// Days that read as matches but can't be counted as ones — named, never dropped.
    private func unconfirmedCard(_ shape: WhenInTheYear, _ result: QueryResult) -> some View {
        let one = String(shape.noun.dropLast())
        let list = result.unconfirmed
        return card(label: "Not confirmed") {
            if list.isEmpty {
                Text("None. Every \(one) that looked like a match was recorded well enough to count.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("\(list.count) \(list.count == 1 ? one : shape.noun) recorded a reading that matches, but the station missed too much of \(list.count == 1 ? "it" : "them") to be sure. They aren't in the counts above.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                        GridRow {
                            ForEach(["Day", "High / low", "Rain", "Dew point", "Gust", "Strikes"], id: \.self) {
                                Text($0.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                            }
                        }
                        Divider()
                        ForEach(list.prefix(8)) { match in
                            let r = match.record
                            GridRow {
                                HStack(spacing: 6) {
                                    Text(WeatherAlmanac.dayLabel(match.day, includeYear: true))
                                    Text("\(Int((r.coverage * 100).rounded()))% recorded")
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12)))
                                }
                                Text("\(r.tempMax.map { Measure.high.format($0) } ?? "—") / \(r.tempMin.map { Measure.low.format($0) } ?? "—")")
                                Text(r.precipTotal.map { Measure.rain.format($0) } ?? "—")
                                Text(r.dewPointMean.map { Measure.dewPoint.format($0) } ?? "—")
                                Text(r.windGustMax.map { Measure.gust.format($0) } ?? "—")
                                Text(r.strikeCount.map { $0.formatted() } ?? "—")
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption.monospacedDigit())
                }
                if list.count > 8 {
                    Text("and \(list.count - 8) more").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Footnotes

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let first = climate.earliestDay, let last = climate.latestDay {
                Text("Your station, \(WeatherAlmanac.dayLabel(first, includeYear: true)) to \(WeatherAlmanac.dayLabel(last, includeYear: true)).")
            }
            Text("How often counts the days within a week either side of each date, every year pooled; “most days” means more than half of them. First and last are medians across the seasons the record fully covers. A season’s chart covers only its season, from three weeks before the earliest first day to three weeks after the latest last.")
            Text("A day the station only partly recorded still counts when what it did record proves the match (a high of 93° proves 90° or more). A day that can’t settle the question isn’t counted either way, and one that looks like a match is listed under Not confirmed.")
        }
        .font(.caption).foregroundStyle(.tertiary)
        .frame(maxWidth: 620, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func card<Content: View>(label: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let label {
                Text(label.uppercased())
                    .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }
}
