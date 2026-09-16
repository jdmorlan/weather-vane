//
//  WeatherQueryViews.swift  (macOS)
//
//  The Explore tab: build a question, get the days.
//
//  The point of the surface is that the ANSWER is a shape, not a list. "229 days
//  it rained" is a trivia fact; the same 229 days laid on a calendar say May is
//  the wet month and December is nearly nil, and that's a thing you can plan
//  around. So the results lead with the year grid and the month profile, and the
//  list of days sits underneath for when you want to go look at one.
//
//  The other job here is carrying the archive's honesty into the interface. A
//  count that's a floor has to LOOK like a floor, and a date nothing could
//  answer has to look different from a date where the answer was no — otherwise
//  the station's downtime quietly reads as good weather.
//

import SwiftUI
import WeatherKit

struct WeatherExploreView: View {
    /// Scroll target for a notice hand-off.
    static let builderAnchor = "explore-builder"

    let climate: Climatology
    /// Station-local today — what "notable NOW" is relative to.
    let today: String
    @Binding var query: DayQuery
    /// Bring the builder into view — the page is taller than the window, and a
    /// hand-off that only changes something off-screen reads as a dead click.
    var onOpenQuery: () -> Void = {}

    @State private var result: QueryResult?
    /// The other verb's answer. A query with an `aggregate` reports a NUMBER per group instead of listing
    /// days, so it renders through its own card — `result-views-must-not-assume-the-answer's-shape`
    /// arriving as a second real client.
    @State private var report: AggregateResult?
    @State private var notices: [Notice] = []
    @State private var daySort: DaySort = .recent
    /// Notices past the first, revealed on request — see `notable`.
    @State private var noticesExpanded = false
    /// The old lists, on request — see `resultCard`.
    @State private var showDayList = false
    /// The lens you PICKED, if you have. Nil means "whatever suits the question" (`defaultLens`), which is
    /// why this isn't seeded: a default that follows the query can't be stored as a choice.
    @State private var lens: ResultLens?
    /// The every-day view's reliability filter — see `reliabilityMenu`.
    @State private var atLeastYears = 0
    @State private var hovered: String?

    /// Chronological, or by how far from normal. The second is what finds the
    /// day worth looking at when the readings barely differ.
    enum DaySort: String, CaseIterable, Identifiable {
        case recent = "Most recent"
        case unusual = "Furthest from normal"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // ONE ROW. The notices are a sentence and the picker is a button — neither needs a row of its
            // own, and stacked they cost two.
            HStack(alignment: .center, spacing: 12) {
                notable
                presets
            }
            QueryBuilder(query: $query, availableYears: climate.years.reversed())
                .id(WeatherExploreView.builderAnchor)
            if let report {
                AggregateReportCard(result: report)
            } else if let result {
                headline(result)
                if result.matchCount > 0 {
                    // Before any of the counting instruments: what those days
                    // were actually LIKE. Every card below answers "how often" —
                    // this one answers the question you'd ask a person.
                    // THREE CARDS. Two of them answer questions of their own — WHEN this happens, and what
                    // the days were LIKE — and the third is the same set of days grouped whichever way you
                    // want to see it.
                    seasonCard(result)
                    profileCard(result)
                    resultCard(result)
                    if showDayList {
                        if !result.streaks.isEmpty { streaksCard(result) }
                        daysCard(result)
                    }
                    if !result.unconfirmed.isEmpty { unconfirmedCard(result) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(30)
            }
        }
        .task(id: queryKey) { await rebuild() }
        .task {
            // Independent of the query — computed once, not on every edit.
            let climate = climate, asOf = today
            notices = await Task.detached(priority: .userInitiated) {
                climate.notable(asOf: asOf)
            }.value
        }
    }

    // MARK: What the archive noticed on its own

    /// The archive speaking first.
    ///
    /// Everything below this waits to be asked, which means the good findings
    /// only turn up if you happen to type the right question. These are the
    /// ones it found by itself — and each is a door: clicking loads the query
    /// behind it, so a claim is never something you just have to take.
    /// ONE LINE, opening to the rest.
    ///
    /// It was a card holding every notice — about 400px above everything else on the page. The argument
    /// against that isn't taste, it's what the panel does: **a panel earns permanent space by CHANGING,
    /// or by being where you're going.** These notices are stable for days at a time and nobody comes to
    /// the Explore page to read them; they're a "you might also want to look at this", which is a
    /// footnote's job.
    ///
    /// It still SPEAKS FIRST, which is the principle that matters and the one this could have broken: a
    /// bare "Notable ▾" button would make the archive wait to be asked. So the most interesting single
    /// notice is on the line, in full, and the rest are one click behind it.
    @ViewBuilder private var notable: some View {
        if let first = notices.first {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    noticeLine(first)
                    Spacer(minLength: 8)
                    if notices.count > 1 {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { noticesExpanded.toggle() }
                        } label: {
                            HStack(spacing: 3) {
                                Text(noticesExpanded ? "less" : "\(notices.count - 1) more")
                                Image(systemName: noticesExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8))
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if noticesExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(notices.dropFirst()) { notice in noticeLine(notice) }
                    }
                    .padding(.top, 7)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }

    /// One notice as a single line — the headline, and its detail trailing in a lighter weight rather
    /// than stacked beneath, which is what made each notice two rows tall.
    @ViewBuilder private func noticeLine(_ notice: Notice) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.symbol)
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
            Text(notice.headline).font(.callout).lineLimit(1)
            if let detail = notice.detail {
                Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            if notice.query != nil {
                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
        }
        if let handOff = notice.query {
            Button {
                query = handOff
                // The builder and the results are further down a tall page — setting the query without
                // moving looks exactly like nothing happening.
                onOpenQuery()
            } label: { content }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func noticeRow(_ notice: Notice, opens: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            // Aligned to the headline's cap height rather than sitting on the
            // text baseline, where a glyph-heavy symbol rides low.
            Image(systemName: notice.symbol)
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.headline).font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = notice.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The row is as wide as the card, so the chevron sat a long way
            // from the words it belonged to. Cap the text column and let the
            // chevron follow it.
            .frame(maxWidth: 620, alignment: .leading)
            if opens {
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(hovered == notice.id ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside && opens ? notice.id : (hovered == notice.id ? nil : hovered) }
        .help(opens ? "Open the days behind this" : "")
    }

    /// Identity for the recompute. Conditions and scope, not the name — renaming
    /// a query doesn't change its answer.
    /// The WHOLE query, not a hand-assembled summary of it.
    ///
    /// This was a string built from the conditions, the date scope and the year
    /// scope — and when the query grew a sequence filter and a preceding
    /// clause, the key didn't. Changing SHOW re-rendered the control and re-ran
    /// nothing, so every number below it stayed exactly as it was. A key that
    /// has to be kept in step by hand will always eventually fall out of step;
    /// `Hashable` on the model can't.
    private var queryKey: DayQuery { query }

    private func rebuild() async {
        // DEBOUNCE. `.task(id:)` restarts on every change to the query, and dragging a brush edge changes
        // it on every frame — so a drag was firing a full archive pass per pixel and the whole results
        // column re-rendered behind it, which is what made the handle feel like it was wading. Sleeping
        // first costs nothing: if the query changes again the task is cancelled here, before any work.
        do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
        let climate = climate, asked = query
        // Two verbs, one query: reduce it or select from it, never both. Running the day pipeline for a
        // question about totals would compute a set of instruments nobody asked for.
        if asked.aggregate != nil {
            let built = await Task.detached(priority: .userInitiated) {
                climate.aggregate(asked)
            }.value
            guard asked == query else { return }
            report = built
            result = nil
            return
        }
        let built = await Task.detached(priority: .userInitiated) {
            climate.run(asked)
        }.value
        // A slower earlier query must not overwrite the one now selected.
        guard asked == query else { return }
        result = built
        report = nil
    }

    // MARK: Presets

    /// ONE CONTROL THAT NAMES THE QUESTION AND OFFERS THE OTHERS.
    ///
    /// Eighteen chips in two labelled rows cost ~150pt to say "here are the questions you could ask" —
    /// worth having, nowhere near worth that. A menu serves the thing you actually do with them (reach
    /// for one you know) and teaches the list the first time you open it.
    ///
    /// It doubles as STATE: the button carries the current question's name, so the page says what you're
    /// looking at instead of leaving you to read it off the controls. That's the compact form of the
    /// query sentence, arriving in one line — and the reason the two headings could be deleted rather
    /// than shrunk: the menu's sections say the same thing at the moment you need it.
    private var presets: some View {
        Menu {
            Section("Ask your own") {
                ForEach(DayQuery.presets, id: \.name) { preset in
                    Button(preset.name) { adopt(preset) }
                }
            }
            Section("Report a number") {
                ForEach(DayQuery.reportPresets, id: \.name) { preset in
                    Button(preset.name) { adopt(preset) }
                }
            }
        } label: {
            // A BUTTON, NOT A MODE. It seeds the query and it's done; the label carrying the last thing
            // you picked made it look like state, and then quietly disagreed with itself the moment you
            // adjusted anything (every setter clears `name`). What you're looking at is said next to the
            // ANSWER instead, where state belongs.
            HStack(spacing: 6) {
                Image(systemName: "list.bullet").font(.system(size: 10))
                Text("Questions").font(.callout)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.09)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// A preset replaces the QUESTION and keeps where you were looking. Having set September 2025,
    /// flipping between questions shouldn't silently throw you back to all time.
    private func adopt(_ preset: DayQuery) {
        var seeded = preset
        seeded.scope = query.scope
        seeded.years = query.years
        query = seeded
    }

    // MARK: Results

    /// THE ANSWER BAR — the whole result in one row, and the mark that says the answer starts here.
    ///
    /// It was four stacked lines of increasingly quiet text with nothing separating it from the controls
    /// above or the cards below, so the page had no seam between "what I asked" and "what came back". One
    /// tinted row does both jobs: it reads as a summary, and the tint is the section break.
    ///
    /// The number stays large because it IS the answer; the question and its qualifiers sit beside it,
    /// smaller, in the order you'd say them.
    @ViewBuilder private func headline(_ r: QueryResult) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(r.isFloor && r.spread == nil ? "At least \(r.matchCount)" : "\(r.matchCount)")
                        .font(.system(size: 30, weight: .light, design: .rounded))
                    // A first/last query counts OCCURRENCES, not days — "2 days" reads as a quantity of
                    // weather rather than as two events.
                    Text(r.spread != nil
                         ? (r.matchCount == 1 ? "occurrence" : "occurrences")
                         : (r.matchCount == 1 ? "day" : "days"))
                        .font(.title3).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    // `describe` can't go stale — it's rendered from the query itself, so it stays true
                    // through every edit, which is why the picker button doesn't have to carry it.
                    Text((r.query.name.isEmpty ? r.query.describe : r.query.name).uppercased())
                        .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !qualifiers(r).isEmpty {
                        Text(qualifiers(r).joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            // "Do we normally get rain in September" is a question about YEARS, and it gets its own line
            // rather than joining the qualifiers, which are all about the count. It's also the only line
            // here that answers yes or no.
            if let sentence = yearRateSentence(r) {
                Text(sentence)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The hedge and the empty answer stay on their own lines: both are sentences, and both are the
            // kind of thing that must not be shortened into an asterisk.
            if r.isFloor {
                Text("\(r.daysUnanswerable) days can't answer this question — the station missed part of them, and a partial day can't rule out what it didn't see. The real count can only be higher.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if r.matchCount == 0 {
                Text("Nothing in \(climate.dayCount.formatted()) days of record matches.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Tinted rather than the cards' neutral grey: this is the answer, not another instrument.
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor.opacity(0.22)))
    }

    /// "Usually — 3 of the 4 comparable years."
    ///
    /// The count answers HOW MANY DAYS and the calendar answers WHICH DATES; neither answers whether a
    /// September, as a unit, normally does this. That's the question you actually ask about a month, and
    /// it was the one sentence the result couldn't say.
    ///
    /// Withheld under a sequence rule, where it's circular — "the first 100° day of each year" happens in
    /// every year that had one, by construction.
    private func yearRateSentence(_ r: QueryResult) -> String? {
        guard r.query.sequence == nil, let rate = r.yearRate, rate.isMeaningful else { return nil }
        let scope = r.query.scope.map { " in \($0.name)" } ?? ""
        // Naming the verdict first is the point — a bare fraction leaves the reader to decide what
        // counts as normal, which is the work they came here to have done.
        var out = rate.isUsual
            ? "Usually: \(rate.yearsWith) of the \(rate.yearsComparable) comparable years saw this\(scope)."
            : "Not usually: only \(rate.yearsWith) of the \(rate.yearsComparable) comparable years saw this\(scope)."
        // A year left out of the denominator is a fact about the station, and hiding it makes the
        // fraction look like more evidence than it is.
        if rate.yearsUncounted > 0 {
            out += " \(rate.yearsUncounted) more \(rate.yearsUncounted == 1 ? "year was" : "years were") too thinly watched to count either way."
        }
        return out
    }

    /// The things worth saying about the count, in the order you'd say them.
    private func qualifiers(_ r: QueryResult) -> [String] {
        var out: [String] = []
        if let rate = r.rate { out.append("\(Int((rate * 100).rounded()))% of the days that could answer") }
        if let typical = r.typicalMonthDay { out.append("typically around \(WeatherAlmanac.dateLabel(typical))") }
        return out
    }

    // MARK: The answer, one card, several lenses

    /// FOUR CARDS WERE ONE CARD ALL ALONG.
    ///
    /// Year by year, In a typical month, Through the year and Every matching day are the same set of days
    /// reduced four ways — grouped by year, by month-of-year, by date-of-year, or not at all. That's
    /// exactly what `Aggregate` describes, which means the predicate side had been doing aggregates in
    /// four hardcoded flavours, each with its own card, its own chart and its own caption. Counting is
    /// just `reduce: count`.
    ///
    /// So: one card, and a lens. The FORM follows the grouping (a punchcard for the raw set, bars for
    /// year and month, a heatmap for date-of-year) because that part was already right — the change is
    /// that you choose which question you're asking instead of scrolling past three you didn't.
    ///
    /// What is NOT a lens stays out: `profileCard` describes what the days were LIKE, and
    /// `AggregateReportCard` reduces a measure rather than a day count. Different questions, not
    /// different views of one.
    enum ResultLens: String, CaseIterable, Identifiable {
        case byDay, byMonth, byYear, spread
        var id: String { rawValue }

        var title: String {
            switch self {
            // The control picks a GROUPING, so it reads as one: "by day", not "every day", which sounds
            // like a claim about how often the thing happens.
            case .byDay: return "By day"
            case .byMonth:  return "By month"
            case .byYear:   return "By year"
            case .spread:   return "Occurrences"
            }
        }
    }

    /// A lens is offered only where it can say something true. A frequency curve over one date a year is
    /// flat at 4%; year bars under a first/last query are all 1. Those were already special-cased by
    /// hiding whole cards — now the same judgment decides what's in the picker.
    private func lenses(for r: QueryResult) -> [ResultLens] {
        r.spread != nil ? [.spread] : [.byDay, .byMonth, .byYear]
    }

    /// THE DEFAULT LENS FOLLOWS THE QUESTION. Ask about one year and the interesting axis is the months
    /// inside it; ask across all years with no date scope and it's where in the year this happens; pin a
    /// first/last and there is nothing to aggregate at all.
    private func defaultLens(for r: QueryResult) -> ResultLens {
        if r.spread != nil { return .spread }
        // Inside one year the interesting axis is its months; across years it's the dates themselves.
        return singleYear != nil ? .byMonth : .byDay
    }

    /// Your choice, while it still means anything for the question on screen.
    private func activeLens(for r: QueryResult) -> ResultLens {
        let available = lenses(for: r)
        if let lens, available.contains(lens) { return lens }
        return defaultLens(for: r)
    }

    private func resultCard(_ r: QueryResult) -> some View {
        let available = lenses(for: r)
        let active = activeLens(for: r)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if available.count > 1 {
                    HStack(spacing: 2) {
                        ForEach(available) { option in lensButton(option, active: active) }
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                } else {
                    // A first/last query has one lens, and "By day" is the wrong name for it — the
                    // answer is a date per year, which is what the card used to be titled.
                    Text(headerTitle(active, r).uppercased())
                        .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                }
                Spacer()
                if active == .byDay { reliabilityMenu(r) }
                // The SAME control the builder has, reachable from the answer. Not a second source of
                // truth — it writes `query.years`, so "just this year" here and there are one state.
                yearScopeMenu
                Button(showDayList ? "hide the lists" : "as lists") {
                    withAnimation(.easeOut(duration: 0.15)) { showDayList.toggle() }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            body(of: active, r)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }

    /// `MM-dd` → how many years opened (or closed) on it. `opens`/`closes` are computed for every query
    /// that isn't already a first/last, so this costs nothing to show.
    private func occurrenceCounts(_ spread: OccurrenceSpread?) -> [String: Int] {
        guard let spread else { return [:] }
        return spread.occurrences.reduce(into: [:]) { out, occurrence in
            out[occurrence.monthDay, default: 0] += 1
        }
    }

    /// `MM-dd` → what actually happened on that date, year by year.
    ///
    /// EVERY year, not only the matching ones. The shade answers "how often"; the years answer "and what
    /// about the rest" — a date that missed at 99° on a query for 100° is a different date from one that
    /// topped out at 84°, and the counts can't tell them apart. The archive already holds both.
    private func calendarNotes(_ r: QueryResult) -> [String: [CalendarDayNote]] {
        let opened = Set((r.opens?.occurrences ?? []).map(\.day))
        let closed = Set((r.closes?.occurrences ?? []).map(\.day))
        var out: [String: [CalendarDayNote]] = [:]

        for cell in r.calendar where !cell.years.isEmpty {
            out[cell.monthDay] = cell.years.map { year in
                CalendarDayNote(
                    year: year.year,
                    outcome: year.outcome,
                    // The temperature pair is printed on its own, so a high or low condition would say
                    // it twice.
                    readings: zip(r.query.conditions, year.values).compactMap { condition, value in
                        guard condition.measure != .high, condition.measure != .low else { return nil }
                        guard let value else { return nil }
                        return "\(condition.measure.name) \(condition.measure.format(value))"
                    },
                    temps: temperatures(high: year.high, low: year.low),
                    opened: opened.contains(year.day),
                    closed: closed.contains(year.day),
                    partial: !year.isReliable)
            }
        }
        return out
    }

    /// What the day was like, in the two numbers everyone reads first.
    private func temperatures(high: Double?, low: Double?) -> String? {
        switch (high, low) {
        case (let high?, let low?): return "\(Int(high.rounded()))° / \(Int(low.rounded()))°"
        case (let high?, nil): return "\(Int(high.rounded()))° high"
        case (nil, let low?): return "\(Int(low.rounded()))° low"
        default: return nil
        }
    }

    private func calendarLegend(_ r: QueryResult) -> String {
        var text = "Each square is one date, shaded by how often it matched across the years on record. Hollow squares are dates nothing could answer."
        if r.opens != nil || r.closes != nil {
            text += " Green pips mark the years this was the season's FIRST matching day, orange the LAST — one pip per year."
        }
        if atLeastYears > 0 {
            text += " Dates that matched in fewer than \(atLeastYears) years are faded, not hidden."
        }
        return text
    }

    private func headerTitle(_ lens: ResultLens, _ r: QueryResult) -> String {
        guard lens == .spread else { return lens.title }
        return query.sequence == .lastEachYear ? "Last occurrence" : "First occurrence"
    }

    @ViewBuilder private func body(of lens: ResultLens, _ r: QueryResult) -> some View {
        switch lens {
        // THE HEATMAP IS THE EVERY-DAY VIEW. A punchcard of actual days per year lived here for an hour
        // and earned its deletion: at ~3pt a day you can't read one, and "which dates does this happen on"
        // is the same question this answers with every year's evidence pooled instead of split five ways.
        case .byDay: calendarCard(r)
        case .byMonth:  monthsCard(r)
        case .byYear:   yearsCard(r)
        case .spread:   if let spread = r.spread { spreadCard(r, spread) }
        }
        if let runs = runSummary(r) {
            // A fact about the matched SET, so it holds under every lens rather than belonging to one.
            Text(runs).font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the runs came to, in a sentence. This is all that survives of the "Longest runs" card: six rows
    /// ranking runs whose blocks were visually identical (16 days is 4% of a year) were saying one thing.
    private func runSummary(_ r: QueryResult) -> String? {
        guard r.spread == nil, let longest = r.streaks.first, longest.length > 1 else { return nil }
        let notable = r.streaks.filter { $0.length >= 3 }.count
        var text = "Longest run \(longest.length) days from \(WeatherAlmanac.dateLabel(DayKey.monthDay(of: longest.firstDay))), \(longest.firstDay.prefix(4))"
        if notable > 1 { text += " · \(notable) runs of 3+ days" }
        if longest.endedAtGap { text += " · it ran into a gap in the record, so it may have been longer" }
        return text + "."
    }

    /// "Only dates that happen most years" — a display filter, not a query edit: it can't change a count,
    /// so it belongs to the view rather than to the question. Fading rather than hiding, because a date
    /// that matched twice out of four still matched.
    @ViewBuilder private func reliabilityMenu(_ r: QueryResult) -> some View {
        let most = r.calendar.map(\.yearsAnswered).max() ?? 0
        if most > 1 {
            Menu(atLeastYears == 0 ? "any year" : "\(atLeastYears)+ of \(most) years") {
                Button("any year") { atLeastYears = 0 }
                ForEach(2...max(2, most), id: \.self) { n in
                    Button("\(n)+ of \(most) years") { atLeastYears = n }
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .font(.caption)
        }
    }

    /// Years, from the answer end of the page.
    private var yearScopeMenu: some View {
        Menu(query.years.label) {
            Button("all years") { query.years = .all }
            Divider()
            ForEach(climate.years.reversed(), id: \.self) { year in
                Button(String(year)) { query.years = .year(year) }
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .font(.caption)
    }

    private func lensButton(_ option: ResultLens, active: ResultLens) -> some View {
        let selected = option == active
        return Button { lens = option } label: {
            Text(option.title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// WHAT THE DAYS WERE LIKE — the one card that isn't a count. Every other instrument answers "how
    /// often"; this answers the question you'd ask a person, so it leads the results.
    ///
    /// Each measure reads against what those dates USUALLY do, because the average alone says little: 101°
    /// in July is a hot day, in April it's a different kind of event. A measure the query NAMED is marked
    /// rather than hidden — days chosen for a high at or above 100 will of course average above normal, but
    /// how far past the threshold they ran is real, and dropping it would look like a bug.
    ///
    /// Rain and lightning read as a SHARE of days, never a daily mean: mean rainfall across a dry fortnight
    /// is a true number describing no day that happened. `MeasureAverage` already knows all of this — the
    /// card just lays its labels out.
    @ViewBuilder private func profileCard(_ r: QueryResult) -> some View {
        if !r.profile.isEmpty {
            card(label: "What it was like") {
                VStack(alignment: .leading, spacing: 10) {
                    WrappingRow(spacing: 8) {
                        ForEach(r.profile.averages) { average in profileBox(average) }
                    }
                    Text("Averaged over the \(r.profile.matchedDays) matching days solid enough to average, against what these dates usually do.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func profileBox(_ average: MeasureAverage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(average.name.uppercased())
                    .font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(.tertiary)
                if average.wasAsked {
                    // Marked, not removed: it's near-tautological and saying so costs one word.
                    Text("asked").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(average.matchedLabel)
                    .font(.system(size: 19, weight: .light, design: .rounded))
                if let departure = average.departureLabel {
                    Text(departure)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(average.departure ?? 0 > 0 ? Color.orange : Color.accentColor)
                }
            }
            if let usual = average.usualLabel {
                Text("usually \(usual)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 132, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func spreadCard(_ r: QueryResult, _ spread: OccurrenceSpread) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                Text(spreadSentence(spread))
                    .font(.title3.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                OccurrenceDates(spread: spread, typical: spread.typical)
                if !spread.isMeaningful {
                    Text("One occurrence isn't a pattern — this is the date it happened, not the date it usually happens.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func spreadSentence(_ spread: OccurrenceSpread) -> String {
        let noun = query.sequence == .lastEachYear ? "last" : "first"
        guard spread.isMeaningful, let typical = spread.typical else {
            guard let only = spread.occurrences.first else { return "No occurrences on record." }
            return "Once on record: \(WeatherAlmanac.dayLabel(only.day, includeYear: true))."
        }
        guard let earliest = spread.earliest, let latest = spread.latest else {
            return "Typically the \(noun) is around \(WeatherAlmanac.dateLabel(typical))."
        }
        // The window, not just the median. "Usually January 12" is a lie of
        // precision when the record runs January 2 to January 20.
        return "The \(noun) is typically around \(WeatherAlmanac.dateLabel(typical)) — "
             + "as early as \(WeatherAlmanac.dateLabel(earliest)), as late as \(WeatherAlmanac.dateLabel(latest))"
             + (spread.spreadDays.map { ", a \($0)-day window" } ?? "") + "."
    }

    /// The inverse question: not "when did this happen" but "when does this
    /// usually start". Only exists for an unscoped, all-years query — pinned to
    /// one year there's nothing to pool.
    @ViewBuilder private func seasonCard(_ r: QueryResult) -> some View {
        if let season = r.season, season.isMeaningful {
            card(label: "When it happens") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(sentence(season)).font(.title3.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    SeasonalCurve(season: season)
                    Text("Share of years with one of these days on each date, smoothed over a fortnight. The dashed line marks half the years — inside the darker band, this is more likely than not; the faint band is where it happens at all.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if r.season == nil, r.matchCount > 0,
                  query.scope != nil || query.years != .all {
            // Only when the SCOPE is what's suppressing it. Under a sequence
            // rule the curve is withheld for a different reason entirely, and
            // telling someone to widen settings they've already widened is
            // worse than saying nothing.
            Text("Set the dates to “any date” and the years to “all years” to see when these conditions usually arrive.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Two facts, in the order they're wanted: the window it happens in, and the
    /// narrower stretch where it's the norm.
    ///
    /// The season alone overclaimed. Freezing nights are more likely than not
    /// for a fortnight in late January — but they happen from November through
    /// March, and a headline naming only the fortnight read as a claim that the
    /// rest of winter was safe, directly contradicting the curve beneath it.
    private func sentence(_ season: SeasonalFrequency) -> String {
        var parts: [String] = []

        if season.hasUsefulActiveWindow, let from = season.activeBegins, let to = season.activeEnds {
            parts.append("Happens from \(WeatherAlmanac.dateLabel(from)) through \(WeatherAlmanac.dateLabel(to)).")
        }

        if let begins = season.begins, let ends = season.ends, let length = season.seasonLength {
            if length >= season.monthDays.count {
                parts.append("More often than not all year.")
            } else {
                parts.append("\(parts.isEmpty ? "More" : "More") often than not from \(WeatherAlmanac.dateLabel(begins)) to \(WeatherAlmanac.dateLabel(ends)) — \(length) days.")
            }
        } else if let peak = season.peak {
            // Never crossing is still an answer, and often the interesting one —
            // so lead with the fact and let the absence follow.
            parts.append("Likeliest around \(WeatherAlmanac.dateLabel(peak.monthDay)), when \(Int((peak.rate * 100).rounded()))% of years have one — but it never becomes the norm.")
        }

        return parts.isEmpty ? "No clear season." : parts.joined(separator: " ")
    }

    /// How many, year by year — the comparison that shows a trend, or shows
    /// that one year was simply extraordinary.
    private func yearsCard(_ r: QueryResult) -> some View {
        let peak = r.years.map(\.matched).max() ?? 1
        let selected = singleYear
        return Group {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(r.years.sorted { $0.year < $1.year }) { year in
                        let isSelected = year.year == selected
                        VStack(spacing: 5) {
                            Text("\(year.matched)")
                                .font(.system(size: 10, weight: isSelected ? .bold : .regular))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(year.isComparable ? 0.75 : 0.3))
                                .frame(height: max(2, CGFloat(year.matched) / CGFloat(max(1, peak)) * 90))
                                // The chosen year gets an outline rather than a
                                // different fill — the fill already means
                                // "comparable or not" and can't mean two things.
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.primary.opacity(isSelected ? 0.85 : 0), lineWidth: 1.5))
                            Text(String(year.year))
                                .font(.system(size: 10, weight: isSelected ? .bold : .regular))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                            // A year the station half-watched will always look
                            // calm; saying so is the difference between a trend
                            // and a story about the station's uptime.
                            Text(year.isComparable ? " " : "\(Int(year.coverage * 100))%")
                                .font(.system(size: 8)).foregroundStyle(.orange.opacity(0.9))
                        }
                        .frame(maxWidth: .infinity)
                        .help(year.isComparable
                              ? "\(year.year): \(year.matched) of \(year.answered) days."
                              : "\(year.year): \(year.matched) days, but only \(year.answered) of \(year.expected) could answer — a floor, not comparable to a full year.")
                    }
                }
                .frame(height: 140, alignment: .bottom)
                if let selected {
                    Text("Every year on record, so \(selected) has something to stand against. The dates you chose still apply.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if r.years.contains(where: { !$0.isComparable }) {
                    Text("Faded years couldn't answer enough days to compare — their counts can only be low.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func calendarCard(_ r: QueryResult) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                QueryCalendar(cells: r.calendar,
                              opens: occurrenceCounts(r.opens),
                              closes: occurrenceCounts(r.closes),
                              notes: calendarNotes(r),
                              atLeastYears: atLeastYears)
                Text(calendarLegend(r))
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Days in ONE month — but which "one month" depends on the year scope, and
    /// so does whether the number is a count or an average.
    ///
    /// Across all years it has to be an average: raw totals gave May 48, more
    /// days than May has, because it was counting four Mays. Pinned to a single
    /// year the average would be worse than useless — `rate × month length`
    /// EXTRAPOLATES, so a May watched for twenty days with eight rainy ones
    /// would report twelve. One year gets its actual count, and the months it
    /// only half-watched say so.
    private func monthsCard(_ r: QueryResult) -> some View {
        let single = singleYear
        let values = r.months.map { month in (month, value(month, single: single != nil)) }
        let peak = values.compactMap(\.1).max() ?? 1

        return Group {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(values, id: \.0.id) { month, value in
                        VStack(spacing: 5) {
                            Text(label(value)).font(.system(size: 9)).foregroundStyle(.secondary)
                            bar(value, peak: peak)
                            Text(month.name).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .help(help(month, year: single))
                    }
                }
                .frame(height: 130, alignment: .bottom)
                Text(single.map { "Days in each month of \($0). Outlined months are ones nothing on record could answer." }
                     ?? "Days in one month, averaged over the record — not the total across all years.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var singleYear: Int? {
        if case .year(let y) = query.years { return y }
        return nil
    }

    /// A count for one year, an average across many. Nil where nothing could
    /// answer — which is not a zero.
    private func value(_ month: QueryMonth, single: Bool) -> Double? {
        guard month.answered > 0 else { return nil }
        return single ? Double(month.matched) : month.typicalDays
    }

    private func label(_ value: Double?) -> String {
        guard let value else { return "?" }
        guard value > 0 else { return "" }
        // Under half a day a year still isn't never — "0" would be a lie, and
        // the bar is already at its floor height saying "rare".
        return value < 0.5 ? "<1" : "\(Int(value.rounded()))"
    }

    @ViewBuilder private func bar(_ value: Double?, peak: Double) -> some View {
        if let value {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(value > 0 ? 0.75 : 0.12))
                .frame(height: max(2, CGFloat(value / max(0.001, peak)) * 90))
        } else {
            // Nothing could answer this month — hollow, like the year grid, so
            // "unknown" never wears the shape of "never happened". In a single
            // year this is what a month that hasn't arrived yet looks like.
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                .frame(height: 90)
        }
    }

    private func help(_ month: QueryMonth, year: Int?) -> String {
        guard let year else {
            guard month.answered > 0 else { return "\(month.name): no day on record could answer this." }
            return "\(month.name): \(month.matched) of \(month.answered) days across the whole record "
                 + "(\(Int(((month.rate ?? 0) * 100).rounded()))%)."
        }
        guard month.answered > 0 else {
            return "\(month.name) \(year): no day could answer this — either the station missed it or it hasn't happened yet."
        }
        let watched = QueryMonth.length(of: month.month)
        let partial = month.answered < watched
        return "\(month.name) \(year): \(month.matched) of \(month.answered) days"
            + (partial ? " — only \(month.answered) of \(watched) were watched, so the count is a floor." : ".")
    }

    /// The longest runs, placed on the calendar rather than listed.
    ///
    /// A list of five date ranges makes you read all five before noticing that
    /// every long run starts in late spring. On a shared month axis that's the
    /// first thing you see, and the lengths become comparable as widths instead
    /// of as numbers you hold in your head.
    private func streaksCard(_ r: QueryResult) -> some View {
        card(label: "Longest runs") {
            VStack(alignment: .leading, spacing: 10) {
                StreakCalendar(streaks: Array(r.streaks.prefix(6)),
                               endsAt: climate.latestDay ?? today)
                if r.streaks.count > 6 {
                    Text("Showing the 6 longest of \(r.streaks.count) runs.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The matching days, with something to judge each one against.
    ///
    /// A bare list of date-and-reading is unreadable at length: forty rows of
    /// "71°, 72°, 71°" all look identical, and the one day that mattered is
    /// buried among them. Each row now carries how far it sat from normal FOR
    /// THAT DATE, which is what turns a reading into a fact — 71° is an
    /// ordinary August dew point and a remarkable April one.
    private func daysCard(_ r: QueryResult) -> some View {
        let ordered = sortedDays(r)
        let shown = Array(ordered.prefix(40))
        let widest = r.days.compactMap(\.departure).map(abs).max() ?? 1
        let hasBaseline = r.days.contains { $0.departure != nil }

        return card(label: "The days") {
            VStack(alignment: .leading, spacing: 8) {
                if hasBaseline {
                    Picker("", selection: $daySort) {
                        ForEach(DaySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 250)
                }

                ForEach(Array(shown.enumerated()), id: \.element.id) { index, match in
                    // A year heading whenever the year changes: under "most
                    // recent" it groups the list, and it answers for free
                    // whether the matches are spread or piled into one year.
                    if daySort == .recent,
                       index == 0 || yearOf(shown[index - 1]) != yearOf(match) {
                        Text(yearOf(match))
                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .padding(.top, index == 0 ? 2 : 8)
                    }
                    dayRow(match, widest: widest)
                }

                if r.days.count > shown.count {
                    // Never a silent truncation.
                    Text("Showing 40 of \(r.days.count) — \(daySort == .recent ? "most recent first" : "furthest from normal first").")
                        .font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                }
            }
        }
    }

    private func dayRow(_ match: MatchedDay, widest: Double) -> some View {
        HStack(spacing: 12) {
            Text(WeatherAlmanac.dayLabel(match.day, includeYear: daySort == .unusual))
                .font(.callout.monospacedDigit())
                .frame(width: daySort == .unusual ? 116 : 84, alignment: .leading)

            ForEach(Array(query.conditions.enumerated()), id: \.offset) { index, condition in
                if index < match.values.count {
                    Text(condition.measure.format(match.values[index]))
                        .font(.callout.monospacedDigit())
                        .frame(width: 66, alignment: .leading)
                }
            }

            if let departure = match.departure {
                departureBar(departure, widest: widest)
            }

            Spacer(minLength: 6)
            if !match.record.isReliable {
                Text("partly watched").font(.caption).foregroundStyle(.orange.opacity(0.9))
                    .help("The station missed part of this day. It still proves what it recorded.")
            }
        }
    }

    /// A signed bar from a centre line — right of centre is above normal for
    /// the date, left is below. Length is what makes an outlier findable by eye
    /// in a column of near-identical numbers.
    private func departureBar(_ departure: Double, widest: Double) -> some View {
        let magnitude = min(1, abs(departure) / max(0.001, widest))
        let above = departure >= 0
        return HStack(spacing: 8) {
            GeometryReader { geo in
                let half = geo.size.width / 2
                let length = max(1, CGFloat(magnitude) * half * 0.95)
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.15))
                        .frame(width: 1, height: 12).offset(x: half)
                    RoundedRectangle(cornerRadius: 2)
                        .fill((above ? Color.orange : Color.teal).opacity(0.7))
                        .frame(width: length, height: 8)
                        .offset(x: above ? half : half - length, y: 2)
                }
                .frame(height: 12)
            }
            .frame(width: 120, height: 12)

            Text(signedDeparture(departure))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
        }
        .help("Against what is normal for that date")
    }

    private func signedDeparture(_ value: Double) -> String {
        let measure = query.conditions.first?.measure
        guard abs(value) >= 0.05 else { return "normal" }
        let text = measure?.format(abs(value)) ?? String(format: "%.1f", abs(value))
        return (value > 0 ? "+" : "−") + text
    }

    private func sortedDays(_ r: QueryResult) -> [MatchedDay] {
        switch daySort {
        case .recent: return r.days
        case .unusual: return r.days.sorted { abs($0.departure ?? 0) > abs($1.departure ?? 0) }
        }
    }

    private func yearOf(_ match: MatchedDay) -> String { String(match.day.prefix(4)) }

    /// Days that read as matches but can't be counted as ones.
    ///
    /// Found the hard way: a January cold snap that sat between 17° and 19° all
    /// day reported as ZERO days below 30°, because the station was struggling
    /// in the very cold that made it interesting — 8 samples out of 48. The
    /// rule is right (a recorded high is a floor, so it can't prove a ceiling)
    /// and the count stays clean. But a result that contradicts what you lived
    /// through needs to say why, with the days named.
    private func unconfirmedCard(_ r: QueryResult) -> some View {
        card(label: "Not confirmed") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(r.unconfirmed.count) \(r.unconfirmed.count == 1 ? "day" : "days") recorded a reading that matches, but the station missed too much of \(r.unconfirmed.count == 1 ? "it" : "them") to be sure. They're not in the count above.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(r.unconfirmed.prefix(20)) { match in
                    HStack(spacing: 12) {
                        Text(WeatherAlmanac.dayLabel(match.day, includeYear: true))
                            .font(.callout.monospacedDigit())
                            .frame(width: 118, alignment: .leading)
                        ForEach(Array(query.conditions.enumerated()), id: \.offset) { index, condition in
                            if index < match.values.count {
                                Text(condition.measure.format(match.values[index]))
                                    .font(.callout.monospacedDigit())
                                    .frame(width: 66, alignment: .leading)
                            }
                        }
                        // The number that decides it — how much of the day the
                        // station actually saw.
                        Text("\(Int((match.record.coverage * 100).rounded()))% watched")
                            .font(.caption).foregroundStyle(.orange.opacity(0.9))
                        Spacer()
                    }
                }
                if r.unconfirmed.count > 20 {
                    Text("Showing 20 of \(r.unconfirmed.count).")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func card<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
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

// MARK: - Building the question

struct QueryBuilder: View {
    @Binding var query: DayQuery
    /// Newest first — the years the archive actually holds.
    let availableYears: [Int]

    /// Which condition's threshold scale is open, if any — see `valueControl`.
    @State private var thresholdEditing: Int?
    @State private var precedingEditing = false

    /// One card per condition.
    ///
    /// Laid out inline, two conditions ran together into a single strip of
    /// controls with no boundary between them — you had to parse the row to
    /// find where one clause ended. A card makes each clause a discrete object,
    /// and the conjunction becomes its HEADING (WHEN · AND · IN), so the
    /// builder still reads as a sentence without needing separators wedged
    /// between the pieces.
    /// TWO TIERS, and they are not the same kind of thing.
    ///
    /// The cards are CONDITIONS — predicates a day either satisfies or doesn't,
    /// including "the day before had rain", which is still a fact about this
    /// day. The row beneath is a FILTER over whatever those conditions found:
    /// first of the year, last, in a run. Sitting them side by side as peer
    /// cards claimed they were the same kind of clause, and they aren't — one
    /// decides which days qualify, the other picks from the days that did.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WrappingRow(spacing: 10) {
                ForEach(Array(query.conditions.enumerated()), id: \.offset) { index, condition in
                    conditionChip(index, condition)
                }
                if query.precededBy != nil { afterCard }
                addCard
            }
            scopeCard
            // TWO VERBS, ONE LINE — until they don't fit. They were two labelled rows with their own
            // headings, 120pt for what is really one sentence about how to answer: which days, and what
            // to report about them. Side by side in an HStack, though, the extra controls an aggregate
            // brings (measure, grouping, ranking) push past the pane and SwiftUI takes the width out of
            // the only compressible things present — the segmented labels, which then wrap one letter
            // per line. `WrappingRow` sizes every child at its IDEAL width and moves the overflow to
            // the next line instead, so a narrow pane costs a row, never legibility.
            WrappingRow(spacing: 22) {
                sequenceFilter
                reportRow
            }
        }
    }

    // MARK: The other verb — report a number instead of listing days

    private enum ReportChoice: String, Hashable, CaseIterable, Identifiable {
        case days, total, average, highest, lowest
        var id: Self { self }
        var label: String { rawValue.capitalized }

        var reduction: Aggregate.Reduction? {
            switch self {
            case .days:    return nil          // no aggregate at all: count the days, the original verb
            case .total:   return .sum
            case .average: return .mean
            case .highest: return .max
            case .lowest:  return .min
            }
        }
    }

    private var reportChoice: ReportChoice {
        guard let aggregate = query.aggregate else { return .days }
        switch aggregate.reduce {
        case .sum:   return .total
        case .mean:  return .average
        case .max:   return .highest
        case .min:   return .lowest
        case .count: return .days
        }
    }

    /// REPORT — "how much", where SHOW above is "which days".
    ///
    /// Two verbs over one query, so they sit as sibling rows rather than as separate screens: the History
    /// tab's cards are questions of exactly this shape, and the only reason they lived somewhere else was
    /// that the language couldn't say them.
    private var reportRow: some View {
        HStack(spacing: 8) {
            Text("REPORT")
                .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(offeredChoices) { option in reportButton(option) }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

                if let aggregate = query.aggregate {
                    Menu(aggregate.measure.name) {
                        ForEach(Measure.allCases) { measure in
                            Button(measure.name) { setMeasure(measure) }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()

                    Menu(groupLabel(aggregate.groupBy)) {
                        Button("all together") { setGrouping(.none) }
                        Button("per year") { setGrouping(.year) }
                        Button("per month") { setGrouping(.month) }
                        Button("per month of the year") { setGrouping(.monthOfYear) }
                    }
                    .menuStyle(.borderlessButton).fixedSize()

                    // Ranking is the difference between a trend and an answer to "the most", so it's a
                    // toggle rather than a hidden default.
                    Toggle("biggest first", isOn: Binding(
                        get: { query.aggregate?.rank != nil },
                        set: { on in setAggregate { $0.rank = on ? .highest : nil } }))
                        .toggleStyle(.checkbox).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Total is only a question you can ASK of a measure that accumulates.
    ///
    /// Rain and lightning strikes add up over a stretch; a temperature, a gust, a pressure does not.
    /// Summing daily highs gave "7,412°" — not a wrong answer but an answer to nothing, and it looked
    /// exactly as authoritative as a real one. The measure already knows which it is, so the button
    /// simply isn't there rather than being there and producing a number to be disbelieved.
    private var offeredChoices: [ReportChoice] {
        let current = query.aggregate
        let measure = current?.measure ?? defaultMeasure
        return ReportChoice.allCases.filter { option in
            guard let reduce = option.reduction else { return true }   // "Days" is always askable
            guard measure.reductions.contains(reduce) else { return false }
            // An average of an amount is per CYCLE, so under a grouping that holds one cycle it draws
            // the identical bars to Total. Two buttons, one answer, different words — offer one.
            let candidate = Aggregate(measure: measure, reduce: reduce,
                                      groupBy: current?.groupBy ?? .year)
            return !candidate.meanRestatesTotal
        }
    }

    /// Changing the grouping can strand the reduction the same way changing the measure can: a per-month
    /// rain average regrouped by year becomes the total under another name, so it moves to being the
    /// total outright rather than sitting on a button that's no longer offered.
    private func setGrouping(_ grouping: Aggregate.Grouping) {
        setAggregate {
            $0.groupBy = grouping
            if $0.meanRestatesTotal { $0.reduce = .sum }
        }
    }

    /// Changing the measure can invalidate the reduction — switching a rain TOTAL onto wind gust asks
    /// for something that isn't a number. The question moves to the measure's own natural reading
    /// (a gust's peak, a low's trough, a humidity's average) rather than being refused or left broken,
    /// and the change is visible: the highlighted button moves with it.
    private func setMeasure(_ measure: Measure) {
        setAggregate {
            $0.measure = measure
            if !measure.reductions.contains($0.reduce) { $0.reduce = measure.defaultReduction }
        }
    }

    private func groupLabel(_ grouping: Aggregate.Grouping) -> String {
        switch grouping {
        case .none:        return "all together"
        case .year:        return "per year"
        case .month:       return "per month"
        case .monthOfYear: return "per month of the year"
        }
    }

    private func setAggregate(_ change: (inout Aggregate) -> Void) {
        guard var aggregate = query.aggregate else { return }
        change(&aggregate)
        query.aggregate = aggregate
        query.name = ""
    }

    private func reportButton(_ option: ReportChoice) -> some View {
        let selected = reportChoice == option
        return Button {
            guard let reduce = option.reduction else {
                query.aggregate = nil
                query.name = ""
                return
            }
            // Keep whatever measure and grouping were already dialled in — switching from a total to an
            // average is a change of ONE thing, and resetting the rest would undo the setup.
            let existing = query.aggregate
            query.aggregate = Aggregate(measure: existing?.measure ?? defaultMeasure,
                                        reduce: reduce,
                                        groupBy: existing?.groupBy ?? .year,
                                        rank: existing?.rank,
                                        limit: existing?.limit)
            query.name = ""
        } label: {
            Text(option.label)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1).fixedSize()
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// What to report when nothing says otherwise: the measure the first condition already names, so
    /// "days over 100°" → "total high" isn't the first thing offered — rain is the usual subject of a sum.
    private var defaultMeasure: Measure { query.conditions.first?.measure ?? .rain }

    // MARK: The filter over what the conditions found

    private enum SequenceChoice: Hashable, CaseIterable, Identifiable {
        case all, first, last, runs
        var id: Self { self }
    }

    /// The label says what it's first OF.
    ///
    /// The rule already iterates instances of the SCOPE, not calendar years —
    /// scope a query to Winter and `bounds(inYear:)` hands back December
    /// through February. So "First each year" was never what the code did, and
    /// under a winter scope it was actively wrong: a winter's first freeze is
    /// not the year's first freeze.
    /// A named period reads straight into the sentence ("First each Winter").
    /// A brushed one is called something like "Sep 1 – Mar 1", which does not —
    /// so a hand-drawn stretch is simply a "window" here.
    private var scopeNoun: String {
        guard let scope = query.scope else { return "year" }
        return scope.kind == .custom ? "window" : scope.name
    }

    private func label(_ option: SequenceChoice) -> String {
        switch option {
        case .all: return "All days"
        case .first: return "First each \(scopeNoun)"
        case .last: return "Last each \(scopeNoun)"
        case .runs: return "In a run"
        }
    }

    private var choice: SequenceChoice {
        switch query.sequence {
        case nil: return .all
        case .firstEachYear: return .first
        case .lastEachYear: return .last
        case .inRunOfAtLeast: return .runs
        }
    }

    private var runLength: Int {
        if case .inRunOfAtLeast(let n) = query.sequence { return n }
        return 3
    }

    private var sequenceFilter: some View {
        // Buttons, not a segmented Picker.
        //
        // The Picker read its selection through a computed Binding and never
        // moved — clicking it changed neither the highlight nor anything below
        // it. Rather than keep guessing why, the selected state is now read
        // straight off the model and each choice is a Button whose action
        // plainly runs. Fewer moving parts than a control that has to be
        // trusted to round-trip a binding.
        HStack(spacing: 8) {
            Text("SHOW")
                .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    ForEach(SequenceChoice.allCases) { option in
                        choiceButton(option)
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

                if choice == .runs {
                    Stepper(value: Binding(get: { runLength },
                                           set: { query.sequence = .inRunOfAtLeast(max(2, $0)) }),
                            in: 2...30) {
                        Text("of \(runLength)+ days in a row")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .controlSize(.small).fixedSize()
                }
            }
        }
    }

    private func choiceButton(_ option: SequenceChoice) -> some View {
        let selected = choice == option
        return Button {
            switch option {
            case .all: query.sequence = nil
            case .first: query.sequence = .firstEachYear
            case .last: query.sequence = .lastEachYear
            // Keep the length you'd already dialled in.
            case .runs: query.sequence = .inRunOfAtLeast(runLength)
            }
            query.name = ""
        } label: {
            Text(label(option))
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1).fixedSize()
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// A condition on the day BEFORE. The per-day predicate model can't reach
    /// it — the fact lives in a different row — so it gets its own clause.
    /// A condition on the day BEFORE. The per-day predicate model can't reach it — the fact lives in a
    /// different row — so it stays its own clause, now as its own chip.
    @ViewBuilder private var afterCard: some View {
        if let condition = query.precededBy?.conditions.first {
            chip {
                connector("and the day before")
                Menu(condition.measure.name) {
                    ForEach(Measure.allCases) { measure in
                        Button(measure.name) {
                            setPreceding(Condition(measure, .atOrAbove(measure.defaultThreshold)))
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Menu(comparisonLabel(condition.test)) {
                    Button("at or above") { setPreceding(Condition(condition.measure, .atOrAbove(defaultValue(condition)))) }
                    Button("below") { setPreceding(Condition(condition.measure, .below(defaultValue(condition)))) }
                }
                .menuStyle(.borderlessButton).fixedSize()
                precedingValue(condition)
                removeButton("Remove this clause") { query.precededBy = nil }
            }
        }
    }

    @ViewBuilder private func precedingValue(_ condition: Condition) -> some View {
        if case .inBand(let name) = condition.test {
            Text(name).font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
        } else {
            let value = defaultValue(condition)
            Button { precedingEditing.toggle() } label: {
                Text(condition.measure.format(value))
                    .font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $precedingEditing, arrowEdge: .bottom) {
                ThresholdSlider(measure: condition.measure, value: value, width: 220) { chosen in
                    setPreceding(Condition(condition.measure,
                                           isAbove(condition.test) ? .atOrAbove(chosen) : .below(chosen)))
                }
                .padding(14)
            }
        }
    }

    private func setPreceding(_ condition: Condition) {
        query.precededBy = PrecedingClause(conditions: [condition],
                                           within: query.precededBy?.within ?? 1)
        query.name = ""
    }

    /// A condition as a CHIP, reading as the clause it is: `when High 100° or above`.
    ///
    /// These were 272×86 cards, and the reason was real — laid out inline, two conditions ran together
    /// with no boundary between them. But what actually made a condition tall was the THRESHOLD SLIDER it
    /// held; the rest is three menus. Move the slider into a popover on the value and the clause fits on
    /// one line, with a border doing the boundary job the card was chosen for. The earlier decision isn't
    /// reversed so much as its cause is removed.
    private func conditionChip(_ index: Int, _ condition: Condition) -> some View {
        chip {
            connector(index == 0 ? "when" : "and")
            Menu(condition.measure.name) {
                ForEach(Measure.allCases) { measure in
                    Button(measure.name) { retarget(index, to: measure) }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()

            Menu(comparisonLabel(condition.test)) {
                Button("at or above") { setTest(index, .atOrAbove(defaultValue(condition))) }
                Button("below") { setTest(index, .below(defaultValue(condition))) }
                if !condition.measure.bands.isEmpty {
                    Button("is") { setTest(index, .inBand(condition.measure.bands[2].name)) }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()

            valueControl(index, condition)

            if query.conditions.count > 1 {
                removeButton("Remove this condition") { query.conditions.remove(at: index) }
            }
        }
    }

    /// The word that joins the clause to the sentence — lowercase and quiet, so the chips read as prose
    /// rather than as a row of labelled boxes.
    private func connector(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    private func removeButton(_ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
        }
        .buttonStyle(.plain).foregroundStyle(.tertiary).help(help)
    }

    /// The chip shell every clause wears — one line, bordered, sized by its contents.
    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 3) { content() }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.09)))
    }

    @ViewBuilder private func valueControl(_ index: Int, _ condition: Condition) -> some View {
        switch condition.test {
        case .inBand(let name):
            Menu(name) {
                ForEach(condition.measure.bands) { band in
                    Button(band.name) { setTest(index, .inBand(band.name)) }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
        case .atOrAbove(let value), .below(let value):
            // The number is the chip's content; the SCALE is a popover. A slider needs ~180pt of width to
            // be landable, and paying that in permanent page height for a control you touch once per
            // question was the whole reason the clause was a card.
            Button {
                thresholdEditing = thresholdEditing == index ? nil : index
            } label: {
                Text(condition.measure.format(value))
                    .font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(get: { thresholdEditing == index },
                                          set: { if !$0 { thresholdEditing = nil } }),
                     arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(condition.measure.name) \(comparisonLabel(condition.test))")
                        .font(.caption).foregroundStyle(.secondary)
                    ThresholdSlider(measure: condition.measure, value: value, width: 220) { chosen in
                        setTest(index, isAbove(condition.test) ? .atOrAbove(chosen) : .below(chosen))
                    }
                }
                .padding(14)
            }
        case .between(let lower, let upper):
            // Read-only, as it always was: a range has two handles and the builder has never had a control
            // for setting one. It arrives from the query language — a model can say it — and shows as what
            // it is.
            Text("\(condition.measure.format(lower))–\(condition.measure.format(upper))")
                .font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
        }
    }

    private var addCard: some View {
        Menu {
            Button("Condition on the day") {
                query.conditions.append(Condition(.dewPoint, .below(65)))
            }
            Button("Condition on the day before") {
                setPreceding(Condition(.rain, .atOrAbove(0.1)))
            }
            .disabled(query.precededBy != nil)
        } label: {
            // AN EMPTY CONTROL SHOULDN'T BE THE LOUDEST THING ON THE PAGE. This was a 118×86 dashed card
            // holding nothing — a footprint that grew, in effect, as the query got emptier.
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text("condition").font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        // `.borderlessButton` + `.fixedSize` collapsed the label to bare text,
        // so the card lost its box and floated out of the row's alignment.
        // `.button` + `.plain` keeps the label exactly as drawn.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Narrow the question")
    }

    /// Scope isn't a condition, but it's one more clause of the same sentence —
    /// so it wears the same card with its own heading.
    /// Full width, and last — every condition above is asked WITHIN this
    /// stretch, so it's the ground the rest of the sentence stands on rather
    /// than another clause beside them. It also shares an axis with the "When
    /// it happens" curve in the results, which is why it's a strip and not a
    /// menu.
    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("IN")
                    .font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .foregroundStyle(.tertiary)
                // THE NAME IS THE CONTROL. It was a label, with a separate `presets ›` disclosure and an
                // `any date` link inside the brush to clear it — three affordances for "which stretch of
                // the year", and between them the words "any date" appeared four times on this card.
                scopeMenu
                if let length = scopeLength {
                    Text(length).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Text("of").font(.callout).foregroundStyle(.secondary)
                yearMenu
            }
            PeriodBrush(period: Binding(get: { query.scope },
                                        set: { query.scope = $0; query.name = "" }))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }

    /// Named stretches of the year, and the way back to none. Brushing still draws any window you like;
    /// this is for the ones that already have names, which is most of what anyone asks for.
    private var scopeMenu: some View {
        Menu {
            Button("Any date") { query.scope = nil; query.name = "" }
            Section("Seasons") {
                ForEach(WeatherPeriod.seasons) { period in
                    Button(period.name) { query.scope = period; query.name = "" }
                }
            }
            Section("Months") {
                ForEach(WeatherPeriod.months) { period in
                    Button(period.name) { query.scope = period; query.name = "" }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(query.scope?.name ?? "any date").font(.callout.weight(.medium))
                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// How long the window is — stated once, beside its name, instead of at the far end of its own row.
    private var scopeLength: String? {
        guard let scope = query.scope else { return nil }
        guard let start = YearAxis.day(of: scope.start), let end = YearAxis.day(of: scope.endExclusive)
        else { return nil }
        let length = start == end ? YearAxis.dayCount : YearAxis.wrap(end - start)
        let wraps = start + length > YearAxis.dayCount
        return "\(length) days\(wraps ? " · wraps the year end" : "")"
    }

    private func clause<Accessory: View, Content: View>(
        heading: String, width: CGFloat,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(heading)
                    .font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .foregroundStyle(.tertiary)
                Spacer()
                accessory()
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(width: width, height: 86, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }

    private var yearMenu: some View {
        Menu(query.years.label) {
            Button("all years") { query.years = .all }
            Divider()
            ForEach(availableYears, id: \.self) { year in
                Button(String(year)) { query.years = .year(year) }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: Edits

    /// Changing the measure has to rebuild the test too: "is Muggy" is
    /// meaningless once the measure is wind, and a 65 that meant degrees would
    /// silently become 65 mph.
    private func retarget(_ index: Int, to measure: Measure) {
        let wasAbove = isAbove(query.conditions[index].test)
        let value = measure.defaultThreshold
        query.conditions[index] = Condition(measure, wasAbove ? .atOrAbove(value) : .below(value))
    }

    private func setTest(_ index: Int, _ test: Test) {
        query.conditions[index] = Condition(query.conditions[index].measure, test)
        query.name = ""   // it's no longer the preset it started as
    }

    /// Keeps the number when only the direction changes, so flipping "below 90"
    /// to "at or above" doesn't also move the threshold.
    private func defaultValue(_ condition: Condition) -> Double {
        switch condition.test {
        case .atOrAbove(let v), .below(let v): return condition.measure.clamp(v)
        case .between(let lower, _): return condition.measure.clamp(lower)
        case .inBand(let name):
            let band = condition.measure.bands.first { $0.name == name }
            return band?.lower ?? band?.upper ?? condition.measure.defaultThreshold
        }
    }

    private func isAbove(_ test: Test) -> Bool {
        if case .atOrAbove = test { return true }
        return false
    }

    private func comparisonLabel(_ test: Test) -> String {
        switch test {
        case .atOrAbove: return "at or above"
        case .below: return "below"
        case .between: return "between"
        case .inBand: return "is"
        }
    }
}

// MARK: - Occurrences, one per year

/// The date it happened each year, as plain blocks.
///
/// This was a positioned timeline — a row per year with the date placed along a
/// shared axis and a band across the observed window. It was apparatus a first
/// occurrence doesn't need: these dates cluster, by definition, within a few
/// weeks of each other, so the placement encoded almost no variation while
/// costing a month axis, a spread band and a lot of horizontal travel to read
/// three dates. The sentence above already states the earliest, the latest and
/// the width of the window; what's left to show is which date, which year.
struct OccurrenceDates: View {
    let spread: OccurrenceSpread
    let typical: String?

    var body: some View {
        WrappingRow(spacing: 8) {
            ForEach(spread.occurrences) { occurrence in
                block(occurrence)
            }
        }
    }

    private func block(_ occurrence: Occurrence) -> some View {
        // The typical date is a computed central value, so in some records no
        // single year sits on it — then nothing is emphasised, which is honest.
        let isTypical = occurrence.monthDay == typical
        return VStack(spacing: 2) {
            Text(WeatherAlmanac.dateLabel(occurrence.monthDay))
                .font(.callout.weight(isTypical ? .bold : .medium))
                .foregroundStyle(isTypical ? Color.primary : Color.secondary)
            Text(String(occurrence.year))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 84)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(isTypical ? 0.22 : 0.10)))
    }
}

// MARK: - Runs on a calendar

/// Each run as a bar at its place in the year, longest first.
struct StreakCalendar: View {
    let streaks: [Streak]
    /// The archive's last day — what makes a run "still going".
    let endsAt: String

    private let labelWidth: CGFloat = 116

    /// Day-of-year, 0…365, for placing a date on the axis.
    private func position(_ key: String) -> Double {
        let monthDay = DayKey.monthDay(of: key)
        guard let index = StreakCalendar.yearDays.firstIndex(of: monthDay) else { return 0 }
        return Double(index) / Double(StreakCalendar.yearDays.count - 1)
    }

    private static let yearDays: [String] =
        WeatherPeriod(name: "", start: "01-01", endExclusive: "01-01").monthDays

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(streaks, id: \.firstDay) { streak in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(streak.length) days")
                            .font(.callout.weight(.semibold).monospacedDigit())
                        Text(WeatherAlmanac.dayLabel(streak.firstDay, includeYear: true))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: labelWidth, alignment: .leading)
                    bar(streak)
                }
            }
            monthAxis
        }
    }

    private func bar(_ streak: Streak) -> some View {
        // A run that reaches the end of the archive hasn't necessarily ended —
        // it's still going, which is the most interesting thing a run can be.
        let ongoing = streak.lastDay >= endsAt
        return GeometryReader { geo in
            let w = geo.size.width
            let start = position(streak.firstDay)
            let end = position(streak.lastDay)
            // A run crossing New Year wraps; draw it as two pieces rather than
            // as one bar running backwards across the whole year.
            let wraps = end < start
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.05))
                    .frame(height: 14)
                segment(from: start, to: wraps ? 1 : end, w, ongoing: ongoing)
                if wraps { segment(from: 0, to: end, w, ongoing: ongoing) }
            }
            .frame(height: 18)
        }
        .frame(height: 18)
        .help("\(WeatherAlmanac.dayLabel(streak.firstDay, includeYear: true)) – \(WeatherAlmanac.dayLabel(streak.lastDay, includeYear: true))"
              + (ongoing ? " — still going" : ""))
    }

    private func segment(from start: Double, to end: Double,
                         _ w: CGFloat, ongoing: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor.opacity(ongoing ? 0.95 : 0.6))
            .frame(width: max(2, CGFloat(end - start) * w), height: 14)
            .offset(x: CGFloat(start) * w)
            .overlay(alignment: .leading) {
                if ongoing {
                    Text("still going").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: CGFloat(start) * w + 5)
                }
            }
    }

    private var monthAxis: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: labelWidth)
            GeometryReader { geo in
                ForEach(1...12, id: \.self) { month in
                    Text(WeatherAlmanac.monthName(String(format: "%02d", month), long: false))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .fixedSize()
                        .offset(x: CGFloat(position(String(format: "2001-%02d-01", month))) * geo.size.width)
                }
            }
            .frame(height: 12)
        }
    }
}

// MARK: - Setting a threshold

/// A threshold on its own scale, with ticks.
///
/// Replaces a menu of six "sensible" values, which could only ever offer
/// somebody else's opinion about which numbers matter — and for rain, where the
/// difference between 1.00" and 1.40" is a real one, offered almost nothing.
struct ThresholdSlider: View {
    let measure: Measure
    let value: Double
    /// Sized by its container — inside a clause card there's more room than the
    /// old inline row ever gave it.
    var width: CGFloat = 176
    /// Called when the drag ENDS. Every intermediate position would re-run the
    /// whole query, so the number tracks the knob but the archive is only asked
    /// once you've landed.
    var onCommit: (Double) -> Void

    @State private var draft: Double = 0

    private var ticks: [Double] {
        let first = (measure.range.lowerBound / measure.tickStep).rounded(.up) * measure.tickStep
        return stride(from: first, through: measure.range.upperBound, by: measure.tickStep).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                // NO `step:` — macOS draws its own tick mark for every step,
                // and rain steps by 0.01 across three inches, so the control
                // came out wearing three hundred of them as a grey hatch. The
                // slider runs continuous and the value is snapped here instead,
                // which also leaves the labelled ticks below legible.
                Slider(value: Binding(get: { draft },
                                      set: { draft = snap($0) }),
                       in: measure.range) { editing in
                    if !editing { onCommit(draft) }
                }
                .controlSize(.small)
                .frame(width: width)

                Text(measure.format(draft))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 62, alignment: .leading)
            }
            tickMarks
        }
        .onAppear { draft = measure.clamp(value) }
        // Re-seed when the condition changes underneath — a preset, a new
        // measure, or a hand-off from another card.
        .onChange(of: value) { _, new in draft = measure.clamp(new) }
        .onChange(of: measure) { _, new in draft = new.clamp(draft) }
    }

    /// Round to the measure's own granularity — fine enough to land on the
    /// number you meant, never so fine that a round one is hard to hit.
    private func snap(_ value: Double) -> Double {
        let stepped = (value / measure.step).rounded() * measure.step
        return measure.clamp(stepped)
    }

    /// Inset to match the slider's track, which reserves half a knob at each
    /// end — ticks flush to the frame would sit off the scale they label.
    private var tickMarks: some View {
        GeometryReader { geo in
            let inset: CGFloat = 9
            let span = measure.range.upperBound - measure.range.lowerBound
            let usable = geo.size.width - inset * 2
            ForEach(ticks, id: \.self) { tick in
                let fraction = (tick - measure.range.lowerBound) / span
                Text(shortTick(tick))
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
                    .fixedSize()
                    // Centred on its own tick, but only as wide as its text —
                    // a fixed 30pt box per label had neighbours overlapping.
                    .frame(width: 24)
                    .offset(x: inset + CGFloat(fraction) * usable - 12)
            }
        }
        .frame(width: width, height: 11)
    }

    /// Ticks label the SCALE, not a reading — so they drop the unit's noise
    /// ("1.5" rather than "1.50\"") and let the value beside the slider carry
    /// the precise, formatted number.
    private func shortTick(_ tick: Double) -> String {
        switch measure {
        case .rain, .pressure, .uv:
            return tick == tick.rounded() ? "\(Int(tick))" : String(format: "%g", tick)
        default:
            return "\(Int(tick))"
        }
    }
}

// MARK: - The seasonal curve

/// How often the query is true through the year, with its season shaded.
///
/// The shaded band is drawn in TWO pieces when the season wraps the year end —
/// "the shop stays cool" runs September to June, and a single rectangle would
/// have to be drawn backwards across the whole chart to express that.
struct SeasonalCurve: View {
    let season: SeasonalFrequency
    /// The query's date window, drawn on top of a curve that ignores it.
    var scope: WeatherPeriod?
    /// When the pattern opens and closes each year.
    var opens: OccurrenceSpread?
    var closes: OccurrenceSpread?

    @State private var lit: String?
    /// The single year under the pointer, when it's near enough to name one.
    @State private var litYear: Int?

    /// The dates actually drawn.
    ///
    /// Unscoped that's the whole calendar. Under a date window it's the window
    /// plus a MARGIN either side — the axis follows the question, so 56 days
    /// get the width the year used to have and the curve inside them stops
    /// being a twitch near September. The margin is the part that still answers
    /// "or did I just pick the only days there are": if the curve is already
    /// falling away before the window opens and after it closes, the window
    /// caught the whole thing.
    private var days: [String] {
        let year = season.monthDays
        guard let scope, year.count > 60 else { return year }
        let window = scope.monthDays
        guard let opening = window.first, let start = year.firstIndex(of: opening) else { return year }

        let margin = min(max(10, window.count / 2), 60)
        let total = window.count + margin * 2
        guard total < year.count else { return year }
        return (0..<total).map { year[(start - margin + $0 + year.count * 2) % year.count] }
    }

    private func x(_ index: Int, _ width: CGFloat) -> CGFloat {
        guard days.count > 1 else { return 0 }
        return CGFloat(index) / CGFloat(days.count - 1) * width
    }

    private func y(_ rate: Double, _ height: CGFloat) -> CGFloat {
        height - CGFloat(rate) * height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 0) {
                axis
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    ZStack(alignment: .topLeading) {
                        seasonBands(w, h)
                        gridlines(w, h)
                        thresholdLine(w, h)
                        curve(w, h).stroke(Color.accentColor, lineWidth: 2)
                        peakMarker(w, h)
                        scopeOutline(w, h)
                        // Anchored to the plot rather than the marks lane so it
                        // has room to open upward — 16pt of lane can't hold it.
                        edgePopup(w, h)
                    }
                }
            }
            .frame(height: 140)
            edgeMarks
            monthAxis
        }
    }

    // MARK: When it opens and closes

    /// The first and last dates of each year, as brackets ON the time axis.
    ///
    /// Deliberately NOT a shaded region over the plot. This chart already spends
    /// fills on likelihood — faint means "happens at all", stronger means "more
    /// often than not" — and a third fill meaning "the opening date landed
    /// somewhere in here" would read as a third claim about the weather. These
    /// are positions in time, so they're drawn on the axis that measures time.
    private var edgeMarks: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 32)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(edges) { edge in
                        mark(edge, geo.size.width)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let group = nearest(to: point.x, geo.size.width)
                        lit = group
                        litYear = group
                            .flatMap { id in edges.first { $0.id == id } }
                            .flatMap { nearestYear($0, to: point.x, geo.size.width) }
                    case .ended:
                        lit = nil
                        litYear = nil
                    }
                }
            }
        }
        .frame(height: 16)
    }

    /// An opening or a closing, reduced to positions on the drawn axis.
    ///
    /// Occurrences outside the window are dropped rather than clamped — under a
    /// date window the axis is a fragment of the year, and pinning an October
    /// date to the right edge would invent a reading.
    private struct Mark: Identifiable {
        let id: Int          // the year
        let index: Int       // where it lands on the drawn axis
        let monthDay: String
    }

    /// Identity colours for the individual ticks.
    ///
    /// Deliberately NOT the accent — that's the curve — and deliberately not a
    /// warm-to-cool ramp, which in a weather chart would read as temperature.
    /// These are labels, not magnitudes. They only exist in the thin-record
    /// case: past five years the marks collapse into a bracket and there are no
    /// individual ticks left to name, so the palette never has to stretch.
    private static let identity: [Color] = [.orange, .mint, .purple, .pink, .yellow, .teal]

    private func colour(_ edge: Edge, _ mark: Mark) -> Color {
        guard !edge.showsBracket,
              let rank = edge.marks.firstIndex(where: { $0.id == mark.id })
        else { return .primary }
        return SeasonalCurve.identity[rank % SeasonalCurve.identity.count]
    }

    private struct Edge: Identifiable {
        let id: String
        let spread: OccurrenceSpread
        /// In calendar order along the axis, which is not year order.
        let marks: [Mark]
        let typical: Int?

        /// Under five years there is no typical to speak of, so the bracket is
        /// withheld and the years are shown as themselves. A median of three
        /// dates spanning four months is a number, not a fact.
        var showsBracket: Bool { marks.count >= 5 }
        var first: Int? { marks.first?.index }
        var last: Int? { marks.last?.index }
        var noun: String { id == "First" ? "First each year" : "Last each year" }
    }

    private var edges: [Edge] {
        [("First", opens), ("Last", closes)].compactMap { name, spread in
            guard let spread, spread.isMeaningful else { return nil }
            let index = Dictionary(days.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let marks = spread.occurrences
                .compactMap { occurrence -> Mark? in
                    guard let at = index[occurrence.monthDay] else { return nil }
                    return Mark(id: occurrence.year, index: at, monthDay: occurrence.monthDay)
                }
                .sorted { $0.index < $1.index }
            guard !marks.isEmpty else { return nil }
            return Edge(id: name, spread: spread, marks: marks,
                        typical: spread.typical.flatMap { index[$0] })
        }
    }

    @ViewBuilder private func mark(_ edge: Edge, _ w: CGFloat) -> some View {
        let on = lit == edge.id
        let tint = Color.primary.opacity(on ? 0.75 : 0.35)
        if edge.showsBracket, let first = edge.first, let last = edge.last {
            // A rule with end caps: the span reads as a span, and its WIDTH is
            // the finding — a tight bracket says the season keeps to a schedule.
            Path { p in
                let a = x(first, w), b = x(last, w)
                p.move(to: CGPoint(x: a, y: 8)); p.addLine(to: CGPoint(x: b, y: 8))
                p.move(to: CGPoint(x: a, y: 4)); p.addLine(to: CGPoint(x: a, y: 12))
                p.move(to: CGPoint(x: b, y: 4)); p.addLine(to: CGPoint(x: b, y: 12))
            }
            .stroke(tint, lineWidth: 1)
            if let typical = edge.typical {
                Path { p in
                    p.move(to: CGPoint(x: x(typical, w), y: 2))
                    p.addLine(to: CGPoint(x: x(typical, w), y: 14))
                }
                .stroke(Color.primary.opacity(on ? 0.9 : 0.5), lineWidth: 2)
            }
        } else {
            // Coloured only while the readout is open, so the palette is never
            // sitting on the chart unexplained — the legend and the marks
            // appear together or not at all.
            ForEach(edge.marks) { mark in
                Path { p in
                    p.move(to: CGPoint(x: x(mark.index, w), y: on ? 2 : 4))
                    p.addLine(to: CGPoint(x: x(mark.index, w), y: on ? 14 : 12))
                }
                .stroke(on ? colour(edge, mark) : tint, lineWidth: on ? 2.5 : 1.5)
            }
        }
    }

    /// Whichever mark the pointer is over, or nearest to — a bracket is a few
    /// pixels tall and demanding a direct hit would make it undiscoverable.
    private func nearest(to pointer: CGFloat, _ w: CGFloat) -> String? {
        let scored = edges.compactMap { edge -> (String, CGFloat)? in
            guard let first = edge.first, let last = edge.last else { return nil }
            let a = x(first, w), b = x(last, w)
            let distance = pointer < a ? a - pointer : (pointer > b ? pointer - b : 0)
            return (edge.id, distance)
        }
        guard let closest = scored.min(by: { $0.1 < $1.1 }), closest.1 < 40 else { return nil }
        return closest.0
    }

    /// The one year the pointer is actually on top of, if any. Naming a year
    /// requires a near-hit; naming the GROUP doesn't. Two tolerances, because
    /// they answer different questions — "what is this row" and "which of these".
    private func nearestYear(_ edge: Edge, to pointer: CGFloat, _ w: CGFloat) -> Int? {
        let closest = edge.marks.min { abs(x($0.index, w) - pointer) < abs(x($1.index, w) - pointer) }
        guard let closest, abs(x(closest.index, w) - pointer) < 8 else { return nil }
        return closest.id
    }

    // MARK: The readout

    /// The years themselves, at the marks.
    ///
    /// A caption under the chart was the obvious thing and it was wrong: it sat
    /// forty points below where the eye was, so it read as part of the footnote
    /// rather than as an answer to the pointer. This opens where you're looking.
    @ViewBuilder private func edgePopup(_ w: CGFloat, _ h: CGFloat) -> some View {
        if let lit, let edge = edges.first(where: { $0.id == lit }) {
            let centre = ((edge.first.map { x($0, w) } ?? 0) + (edge.last.map { x($0, w) } ?? w)) / 2
            popupBody(edge)
                // Opaque, not a material. It sits over a curve and a shaded
                // band, and anything showing through turned the dates into a
                // second layer of chart to read past.
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 3))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.18)))
                .fixedSize()
                .modifier(Anchored(centre: centre, width: w, bottom: h))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func popupBody(_ edge: Edge) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(edge.noun.uppercased())
                .font(.system(size: 9).weight(.semibold)).tracking(0.6)
                .foregroundStyle(.secondary)
            if edge.showsBracket, let typical = edge.spread.typical {
                Text("Typically \(WeatherAlmanac.dateLabel(typical))")
                    .font(.callout.weight(.medium))
            } else {
                // Too thin for a typical — say so where the claim would be.
                Text("Too few years to call one typical")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // IN AXIS ORDER, not year order — the same order the ticks read in,
            // left to right. The list is a legend for the marks, so the first
            // row has to be the leftmost tick: earliest first, latest last.
            // Sorting by year would scramble a legend against the thing it
            // labels, and it's the calendar spread you're reading, not a
            // chronology.
            //
            // Columns fill downward before moving right, so the sequence
            // survives the wrap.
            let rows = min(6, max(1, (edge.marks.count + 2) / 3))
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(stride(from: 0, to: edge.marks.count, by: rows)), id: \.self) { start in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(edge.marks[start..<min(start + rows, edge.marks.count)]) { mark in
                            yearRow(mark, colour(edge, mark), keyed: !edge.showsBracket)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
    }

    /// The swatch is what makes the list a LEGEND rather than a list — you read
    /// which tick is which without having to point at each one in turn.
    private func yearRow(_ mark: Mark, _ colour: Color, keyed: Bool) -> some View {
        let on = litYear == mark.id
        return HStack(spacing: 6) {
            if keyed {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(colour)
                    .frame(width: 3, height: 11)
            }
            Text(String(mark.id))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.secondary.opacity(0.75))
            Text(WeatherAlmanac.dateLabel(mark.monthDay))
                .font(.caption.weight(on ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(Color.primary)
        }
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(on ? Color.primary.opacity(0.10) : .clear))
    }

    /// Sits above the marks lane and never off the side of the chart.
    ///
    /// Measured with a `GeometryReader` in the background rather than a
    /// `PreferenceKey`: the preference never arrived, `size` stayed zero, and a
    /// zero-height popup computes an offset that puts its TOP where its bottom
    /// belonged — so it hung down across the marks it was describing.
    private struct Anchored: ViewModifier {
        let centre: CGFloat
        let width: CGFloat
        let bottom: CGFloat
        @State private var size: CGSize = .zero

        func body(content: Content) -> some View {
            content
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { size = geo.size }
                        .onChange(of: geo.size) { size = $0 }
                })
                // Until it has been measured it stays out of sight, rather than
                // flashing in the wrong place for a frame.
                .opacity(size == .zero ? 0 : 1)
                // NOT clamped to zero — a popup taller than the plot has to be
                // allowed to overflow above the chart.
                .offset(x: min(max(0, centre - size.width / 2), max(0, width - size.width)),
                        y: bottom - size.height - 10)
        }
    }

    private var axis: some View {
        GeometryReader { geo in
            ForEach([0.0, 0.5, 1.0], id: \.self) { rate in
                Text("\(Int(rate * 100))%")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .frame(width: 28, alignment: .trailing)
                    .offset(y: y(rate, geo.size.height) - 6)
            }
        }
        .frame(width: 32)
    }

    private func gridlines(_ w: CGFloat, _ h: CGFloat) -> some View {
        ForEach([0.0, 1.0], id: \.self) { rate in
            Path { p in
                p.move(to: CGPoint(x: 0, y: y(rate, h)))
                p.addLine(to: CGPoint(x: w, y: y(rate, h)))
            }
            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func thresholdLine(_ w: CGFloat, _ h: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: y(season.threshold, h)))
            p.addLine(to: CGPoint(x: w, y: y(season.threshold, h)))
        }
        .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }

    /// Two shaded windows, so the chart tells the same story as the sentence:
    /// the faint one is where this happens at all, the stronger one where it's
    /// the norm. Each is drawn in two pieces when it crosses New Year.
    @ViewBuilder private func seasonBands(_ w: CGFloat, _ h: CGFloat) -> some View {
        if season.hasUsefulActiveWindow {
            bands(from: season.activeBegins, to: season.activeEnds, opacity: 0.07, w, h)
        }
        bands(from: season.begins, to: season.ends, opacity: 0.16, w, h)
    }

    private struct Run: Identifiable { let id: Int; let start: Int; let end: Int }

    /// The stretches of VISIBLE dates a cyclic range covers.
    ///
    /// Working in runs rather than a start index and an end index is what lets
    /// the axis be a window: a band that opens before the left edge, or carries
    /// on past the right one, draws to the edge instead of failing to find its
    /// endpoint and vanishing. It handles the year-end wrap for free.
    private func runs(covering begins: String?, _ ends: String?) -> [Run] {
        guard let begins, let ends,
              let range = WeatherPeriod(name: "", from: begins, throughInclusive: ends)
        else { return [] }

        var found: [Run] = []
        var open: Int?
        for (index, monthDay) in days.enumerated() {
            if range.contains(monthDay: monthDay) {
                if open == nil { open = index }
            } else if let start = open {
                found.append(Run(id: start, start: start, end: index - 1))
                open = nil
            }
        }
        if let start = open { found.append(Run(id: start, start: start, end: days.count - 1)) }
        return found
    }

    private func bands(from begins: String?, to ends: String?,
                       opacity: Double, _ w: CGFloat, _ h: CGFloat) -> some View {
        ForEach(runs(covering: begins, ends)) { run in
            band(from: run.start, to: run.end, opacity: opacity, w, h)
        }
    }

    /// The date window, as an OUTLINE rather than another shaded band — the
    /// shading here already means something ("more often than not", "happens at
    /// all"), and a third fill would read as a third claim about the weather
    /// instead of a note about the question.
    @ViewBuilder private func scopeOutline(_ w: CGFloat, _ h: CGFloat) -> some View {
        if let scope {
            let window = scope.monthDays
            ForEach(runs(covering: window.first, window.last)) { run in
                outline(from: run.start, to: run.end, w, h)
            }
        }
    }

    private func outline(from start: Int, to end: Int, _ w: CGFloat, _ h: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.05))
            .frame(width: max(1, x(end, w) - x(start, w)), height: h)
            .overlay(alignment: .leading) { edge(h) }
            .overlay(alignment: .trailing) { edge(h) }
            .offset(x: x(start, w))
    }

    private func edge(_ h: CGFloat) -> some View {
        Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 1, height: h)
    }

    private func band(from start: Int, to end: Int, opacity: Double,
                      _ w: CGFloat, _ h: CGFloat) -> some View {
        Rectangle()
            .fill(Color.accentColor.opacity(opacity))
            .frame(width: max(1, x(end, w) - x(start, w)), height: h)
            .offset(x: x(start, w))
    }

    private func curve(_ w: CGFloat, _ h: CGFloat) -> Path {
        Path { p in
            var started = false
            for (index, monthDay) in days.enumerated() {
                // A date the curve couldn't reach BREAKS the line rather than
                // being bridged — the same rule the temperature curves follow.
                guard let rate = season.points[monthDay] else { started = false; continue }
                let point = CGPoint(x: x(index, w), y: y(rate, h))
                if started { p.addLine(to: point) } else { p.move(to: point); started = true }
            }
        }
    }

    @ViewBuilder private func peakMarker(_ w: CGFloat, _ h: CGFloat) -> some View {
        if let peak = season.peak, let index = days.firstIndex(of: peak.monthDay) {
            Circle().fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .offset(x: x(index, w) - 3, y: y(peak.rate, h) - 3)
        }
    }

    /// Months across a year; dates across a window. Two labels reading "Aug"
    /// and "Sep" is not an axis for eight weeks of data.
    private var monthAxis: some View {
        GeometryReader { geo in
            ForEach(ticks, id: \.self) { monthDay in
                if let index = days.firstIndex(of: monthDay) {
                    Text(tickLabel(monthDay))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .fixedSize()
                        .offset(x: 32 + x(index, geo.size.width - 32))
                }
            }
        }
        .frame(height: 12)
    }

    private var showsWholeMonths: Bool { days.count > 100 }

    private var ticks: [String] {
        guard !showsWholeMonths else { return days.filter { $0.hasSuffix("-01") } }
        // Six or so evenly spaced dates, and never one so near the right edge
        // that its label hangs off.
        let step = max(1, days.count / 6)
        return stride(from: 0, to: days.count - step / 2, by: step).map { days[$0] }
    }

    private func tickLabel(_ monthDay: String) -> String {
        let month = WeatherAlmanac.monthName(String(monthDay.prefix(2)), long: false)
        guard !showsWholeMonths else { return month }
        return "\(month) \(Int(monthDay.suffix(2)) ?? 1)"
    }
}

// MARK: - The year grid

/// Twelve rows of dates, shaded by how often each one matched.
///
/// A fixed 12×31 frame rather than a packed grid: the eye reads "early June" by
/// POSITION, and a layout that reflows when February is short would move every
/// date that follows it.
/// The year as a heatmap — ONE canvas, not 372 views.
///
/// It was a `VStack` of 12 `HStack`s of 31 cells, each doing a `String(format:)` dictionary lookup: about
/// 400 views and 400 format calls on every render. That's what made the Explore page expensive to rebuild,
/// and rebuilding is what a brush drag does — so the calendar nobody was looking at was paying for the
/// interaction at the top of the page. A grid of flat rectangles is exactly what a canvas is for.
///
/// The hover readout is the one thing a canvas can't do for free, so it's a single overlay driven by
/// pointer position rather than 372 `.help()` modifiers.
/// The year as a heatmap — ONE canvas, not 372 views.
///
/// It was a `VStack` of 12 `HStack`s of 31 cells, each doing a `String(format:)` dictionary lookup: about
/// 400 views and 400 format calls on every render. That's what made the Explore page expensive to rebuild,
/// and rebuilding is what a brush drag does — so the calendar nobody was looking at was paying for the
/// interaction at the top of the page. A grid of flat rectangles is exactly what a canvas is for.
///
/// WHAT ELSE THE GRID CAN CARRY. Each date already knows how often it matched; it can also know whether it
/// was the year's FIRST or LAST matching day (`QueryResult.opens` / `.closes`, computed whether or not
/// anyone asked for them). Marked as pips, seasonal edges show up on the same picture as frequency — one
/// pip per year, so a date that opened three different summers says so.
/// One year's version of a date, as the hover readout reads it.
struct CalendarDayNote: Identifiable, Equatable {
    var year: Int
    var outcome: CalendarYear.Outcome
    /// The queried measures on that day, in condition order.
    var readings: [String]
    /// High and low — what the day was LIKE, whatever the question was about.
    var temps: String?
    /// The season's first matching day that year…
    var opened: Bool
    /// …and its last.
    var closed: Bool
    /// The station missed part of the day. A day that matched can still be partial — a recorded high
    /// proves a floor no matter how many hours were missed.
    var partial: Bool
    var id: Int { year }

    var isMatch: Bool { outcome == .matched }

    /// What to say about a year the count doesn't include. A plain miss says nothing: its numbers are
    /// right there and they're the whole explanation.
    var label: String? {
        switch outcome {
        case .matched, .missed: return nil
        case .unanswerable: return "couldn't say"
        case .setAside: return "not counted"
        case .notSelected: return "not the one"
        }
    }
}

struct QueryCalendar: View {
    let cells: [QueryCalendarCell]
    /// `MM-dd` → how many years' patterns OPENED on that date.
    var opens: [String: Int] = [:]
    /// …and CLOSED.
    var closes: [String: Int] = [:]
    /// `MM-dd` → the years behind the square, oldest first.
    var notes: [String: [CalendarDayNote]] = [:]
    /// Dates matching in fewer than this many years fade back — the card's "3 of 4 years" filter.
    var atLeastYears: Int = 0

    private static let rowHeight: CGFloat = 20
    private static let gutter: CGFloat = 30
    private static let gap: CGFloat = 2
    private static let headerHeight: CGFloat = 14

    @State private var hovered: QueryCalendarCell?
    @State private var measured: CGFloat = 1

    /// Indexed once per result, not once per cell.
    private var byMonthDay: [String: QueryCalendarCell] {
        Dictionary(cells.map { ($0.monthDay, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        let index = byMonthDay
        Canvas { context, size in draw(context, size, index) }
            .frame(height: Self.rowHeight * 12 + Self.headerHeight)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = cell(at: point, index: index)
                case .ended: hovered = nil
                }
            }
            // Over the grid, at the square you're pointing at — not a line of prose forty points below,
            // which is where this readout used to live and where nobody was looking.
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in popup(geo.size) }
            }
    }

    /// The square's whole story, opened where the pointer is.
    @ViewBuilder private func popup(_ size: CGSize) -> some View {
        if let cell = hovered {
            let month = Int(cell.monthDay.prefix(2)) ?? 1
            let day = Int(cell.monthDay.suffix(2)) ?? 1
            let top = Self.headerHeight + CGFloat(month - 1) * Self.rowHeight
            popupBody(cell)
                // Opaque, not a material: it sits over the grid, and squares showing through would read as
                // a second layer of chart behind the numbers.
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 3))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.18)))
                .fixedSize()
                .modifier(Anchored(centre: Self.gutter + columnWidth(size.width) * (CGFloat(day) - 0.5),
                                   bounds: size, cellTop: top, cellBottom: top + Self.rowHeight))
                .allowsHitTesting(false)
        }
    }

    private func popupBody(_ cell: QueryCalendarCell) -> some View {
        let rows = notes[cell.monthDay] ?? []
        let shown = rows.prefix(12)
        return VStack(alignment: .leading, spacing: 6) {
            Text(WeatherAlmanac.dateLabel(cell.monthDay).uppercased())
                .font(.system(size: 9).weight(.semibold)).tracking(0.6)
                .foregroundStyle(.secondary)
            Text(frequency(cell))
                .font(.callout.weight(.medium))
            if !shown.isEmpty {
                Divider().opacity(0.6)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { noteRow($0) }
                }
                if rows.count > shown.count {
                    // Never a silent truncation.
                    Text("+ \(rows.count - shown.count) more years")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
    }

    /// The headline claim: how often this date did the thing, across the record.
    private func frequency(_ cell: QueryCalendarCell) -> String {
        guard let rate = cell.rate else { return "Nothing on record could answer" }
        let years = "\(cell.yearsAnswered) year\(cell.yearsAnswered == 1 ? "" : "s")"
        guard cell.yearsMatched > 0 else { return "No match in \(years) on record" }
        return "Matched \(cell.yearsMatched) of \(years) · \(Int((rate * 100).rounded()))%"
    }

    /// A year, what it did, and whether it was an edge of that season.
    ///
    /// A year that missed reads in the same columns as one that matched — that's the point of listing it.
    /// The swatch and the weight carry which is which, so the numbers stay comparable down the column
    /// instead of being split into two lists.
    private func noteRow(_ note: CalendarDayNote) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(note.isMatch ? Color.accentColor : Color.primary.opacity(0.15))
                .frame(width: 3, height: 11)
            Text(String(note.year))
                .font(.caption2.monospacedDigit()).foregroundStyle(Color.secondary.opacity(0.75))
            if let temps = note.temps {
                Text(temps)
                    .font(.caption.weight(note.isMatch ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(note.isMatch ? Color.primary : Color.secondary)
            }
            ForEach(note.readings, id: \.self) { reading in
                Text(reading)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(note.isMatch ? Color.primary : Color.secondary)
            }
            // The same two colours as the pips on the square, so the badge names the mark you can see.
            if note.opened { badge("first", .green) }
            if note.closed { badge("last", .orange) }
            if let label = note.label { badge(label, .secondary) }
            else if note.partial { badge("partly watched", .secondary) }
        }
    }

    private func badge(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(.system(size: 9).weight(.medium))
            .foregroundStyle(colour)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(colour.opacity(0.14)))
    }

    /// Beside the square, inside the grid, and never off an edge — below the row where there's room,
    /// above it in the last months of the year.
    private struct Anchored: ViewModifier {
        let centre: CGFloat
        let bounds: CGSize
        let cellTop: CGFloat
        let cellBottom: CGFloat
        @State private var size: CGSize = .zero

        func body(content: Content) -> some View {
            let below = cellBottom + 8
            return content
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { size = geo.size }
                        .onChange(of: geo.size) { size = $0 }
                })
                // Until it has been measured it stays out of sight, rather than flashing in the wrong
                // place for a frame.
                .opacity(size == .zero ? 0 : 1)
                .offset(x: min(max(0, centre - size.width / 2), max(0, bounds.width - size.width)),
                        y: below + size.height <= bounds.height ? below
                                                                : max(0, cellTop - 8 - size.height))
        }
    }

    private func columnWidth(_ width: CGFloat) -> CGFloat { max(1, (width - Self.gutter) / 31) }

    private func cell(at point: CGPoint, index: [String: QueryCalendarCell]) -> QueryCalendarCell? {
        guard point.x >= Self.gutter else { return nil }
        let row = Int((point.y - Self.headerHeight) / Self.rowHeight)
        let column = Int((point.x - Self.gutter) / columnWidth(measured))
        guard (0..<12).contains(row), (0..<31).contains(column) else { return nil }
        return index[String(format: "%02d-%02d", row + 1, column + 1)]
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize, _ index: [String: QueryCalendarCell]) {
        if measured != size.width { Task { @MainActor in measured = size.width } }
        let column = columnWidth(size.width)

        for day in stride(from: 1, through: 31, by: 1) where day % 5 == 0 || day == 1 {
            context.draw(context.resolve(Text("\(day)").font(.system(size: 7))
                .foregroundStyle(.tertiary)),
                         at: CGPoint(x: Self.gutter + column * (CGFloat(day) - 0.5), y: 7), anchor: .center)
        }

        for month in 1...12 {
            let y = Self.headerHeight + CGFloat(month - 1) * Self.rowHeight
            context.draw(context.resolve(Text(WeatherAlmanac.monthName(String(format: "%02d", month), long: false))
                .font(.system(size: 9)).foregroundStyle(.secondary)),
                         at: CGPoint(x: 0, y: y + Self.rowHeight / 2), anchor: .leading)

            for day in 1...31 {
                let key = String(format: "%02d-%02d", month, day)
                guard let cell = index[key] else { continue }
                let rect = CGRect(x: Self.gutter + column * CGFloat(day - 1) + Self.gap / 2,
                                  y: y + 1, width: column - Self.gap, height: Self.rowHeight - Self.gap)
                let path = Path(roundedRect: rect, cornerRadius: 3)
                // Three states, and the middle one is the one that matters: a date nothing could answer
                // must not look like a date where the answer was no.
                if let rate = cell.rate {
                    // Below the threshold a date isn't hidden, only quietened — the filter is for finding
                    // the reliable dates, not for pretending the others didn't match.
                    let dimmed = cell.yearsMatched < atLeastYears
                    context.fill(path, with: .color(.accentColor.opacity(dimmed ? 0.06 : 0.12 + 0.78 * rate)))
                } else {
                    context.stroke(path, with: .color(.primary.opacity(0.18)), lineWidth: 1)
                }
                pips(context, in: rect, count: opens[key] ?? 0, color: .green, atTop: true)
                pips(context, in: rect, count: closes[key] ?? 0, color: .orange, atTop: false)
            }
        }
    }

    /// One pip per year, along an edge: openings on top, closings underneath. A count rather than a blend,
    /// because "this was the first matching day in three different years" is a number worth reading.
    private func pips(_ context: GraphicsContext, in rect: CGRect, count: Int, color: Color, atTop: Bool) {
        guard count > 0 else { return }
        let size: CGFloat = 3
        let spacing: CGFloat = 1.5
        let shown = min(count, Int((rect.width - 4) / (size + spacing)))
        let total = CGFloat(shown) * size + CGFloat(max(0, shown - 1)) * spacing
        var x = rect.midX - total / 2
        let y = atTop ? rect.minY + 1.5 : rect.maxY - size - 1.5
        for _ in 0..<max(shown, 1) {
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: size, height: size)),
                         with: .color(color.opacity(0.9)))
            x += size + spacing
        }
    }
}

// MARK: - The other verb's answer

/// AN AGGREGATE, RENDERED. The counting instruments answer "how often"; this answers "how much", and it
/// is a different shape — one number per group, ranked or in order — so it gets its own card rather than
/// being forced through a day list.
///
/// This is what makes the History tab and Explore one feature instead of two. History's cards were
/// hand-built views over reductions the engine could already compute but the LANGUAGE couldn't ask for;
/// now the question is sayable, so the same answer can arrive from a preset, from the builder, or from a
/// conversation — and it can be edited afterwards, which a card never allowed.
///
/// Horizontal bars, deliberately: ordinary is the right answer for "compare these twelve numbers", and a
/// bespoke encoding would have to earn its place ([[conventional-charts-over-clever]]).
struct AggregateReportCard: View {
    let result: AggregateResult

    private var peak: Double { max(result.groups.map(\.value).max() ?? 1, 0.0001) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if result.isEmpty {
                Text("Nothing on record to add up.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 7) {
                    ForEach(result.groups) { group in row(group) }
                }
                footnote
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }

    /// The headline is the LEADER when something was ranked, because "the most" is the question that was
    /// asked; with no rank there is no single answer to lead with, so the label does the work.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.query.describe.uppercased())
                .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if result.aggregate.rank != nil, let leader = result.leader {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(result.format(leader.value))
                        .font(.system(size: 30, weight: .light, design: .rounded))
                    Text(leader.label).font(.title3).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ group: AggregateGroup) -> some View {
        HStack(spacing: 10) {
            Text(group.label)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(group.isTrustworthy ? Color.accentColor.opacity(0.75) : Color.orange.opacity(0.5))
                        .frame(width: max(3, geo.size.width * CGFloat(group.value / peak)))
                }
            }
            .frame(height: 14)
            Text(result.format(group.value))
                .font(.system(size: 11, design: .rounded)).monospacedDigit()
                .frame(width: 74, alignment: .leading)
        }
        // The bar is coloured by trust, and the hover says why — a thin group has to be visible without
        // an asterisk on every row, because on a young archive that would be most of them.
        .help(explain(group))
    }

    /// What the number was made from. A per-cycle mean leads with its DIVISOR, because "0.23 inches" is
    /// unreadable until you know whether it's per day, per month or per year — and the wrong reading is
    /// the plausible one.
    private func explain(_ group: AggregateGroup) -> String {
        var text = ""
        if result.aggregate.meansPerCycle {
            let noun = result.aggregate.cycleNoun
            text += "\(group.daysCounted) days over \(group.cycles) \(noun)\(group.cycles == 1 ? "" : "s")"
            text += ", so this is the \(result.aggregate.measure.name.lowercased()) one \(noun) sees. "
        } else {
            text += "\(group.daysCounted) days counted. "
        }
        if !group.isTrustworthy {
            text += "The station only saw \(group.daysObserved) of \(group.daysExpected) days here, so this is short by whatever fell on the rest."
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Says the quiet part: a total is only as complete as the days behind it, and an undercounted total
    /// looks exactly like a correct one.
    @ViewBuilder private var footnote: some View {
        let thin = result.groups.filter { !$0.isTrustworthy }
        VStack(alignment: .leading, spacing: 3) {
            if result.groupsConsidered > result.groups.count {
                Text("Showing \(result.groups.count) of \(result.groupsConsidered).")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if !thin.isEmpty {
                Text("Amber bars are stretches the station didn't fully see (\(thin.map(\.label).prefix(4).joined(separator: ", "))\(thin.count > 4 ? "…" : "")). Their numbers can only be short.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
