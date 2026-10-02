//
//  WeatherPeriodViews.swift  (macOS)
//
//  History's week, month, season and year: one instance of a stretch, told as
//  what it did (`StretchStory` — the sentence, the strip, the events) and then
//  backed by its numbers against a usual one.
//
//  A curve of the year against smoothed normals used to lead here. The fronts
//  were in it — a three-day dive — but finding them was the reader's job, and
//  in a Houston summer the biggest dive is usually a thunderstorm, not a front.
//  The story names which.
//

import SwiftUI
import WeatherKit

// MARK: - Choosing the stretch
//
// DELETED: `PeriodFamily` + `PeriodPicker`, a family segmented control over a
// wrap of chips. Every control in it was a jump-to — it could only take you
// somewhere you had already decided to go — which is why nothing built into
// this surface got found. `WeatherArchiveBrowser` replaces it with a grain and
// a stepper you can walk. Kept nothing behind: a second way in is what made the
// first one unreachable.

/// Chips that wrap to the next line. AnyLayout rather than a LazyVGrid because
/// the chips are different widths ("May" against "September") and a grid would
/// column them into a ragged, mostly-empty table.
struct WrappingRow: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - The tab

/// Everything the archive knows about the chosen stretch. Held in its own view
/// so the summary is computed once per period change, off the main actor.
struct PeriodHistoryView: View {
    let climate: Climatology
    let today: String
    /// The window to read. Chosen by the browser above rather than by a picker
    /// of its own — a period is a POSITION, and there should be exactly one
    /// control in the tab that moves you.
    let period: WeatherPeriod
    /// The instance being read. Every year at this position is Compare's
    /// job — `CompareStretchView` — which cuts them to the same days.
    let focusYear: Int
    /// Opens one day of the stretch in History's day grain.
    var onOpenDay: (String) -> Void = { _ in }

    @State private var summary: PeriodSummary?
    /// What the stretch DID — fronts, rain, spells — for the sentence, the
    /// strip and the event list. Built beside the summary, off the main actor.
    @State private var story: StretchStory?

    /// A rolling window counts back from the archive's last day, not from today
    /// — the archive stops at yesterday by design.
    private var latestDay: String { climate.latestDay ?? today }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let summary {
                if let instance = summary.years.first(where: { $0.year == focusYear }) {
                    instanceCards(summary, instance)
                } else {
                    StationCard(label: "\(period.name) \(String(focusYear))") {
                        Text("The archive holds none of \(period.name) \(String(focusYear)).")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            }
        }
        .task(id: "\(period.id)·\(focusYear)") { await rebuild() }
    }

    /// One instance — what THIS September did.
    ///
    /// The story leads: the sentence, the stretch day by day, and every event
    /// that made it. The numbers against a usual September come last, as
    /// backing. A curve of this year against smoothed normals used to sit where
    /// the strip is, and left the reader to find the fronts in it themselves.
    @ViewBuilder private func instanceCards(_ s: PeriodSummary, _ year: PeriodYear) -> some View {
        instanceTiles(s, year)
        instanceHeadline(s, year)
        if let story {
            StoryCards(story: story, onOpenDay: onOpenDay)
            StationCard(label: "What happened") {
                StoryEventList(story: story, onOpenDay: onOpenDay)
            }
        }
    }

    /// Off the main actor: a period summary walks several years of smoothed
    /// series per measure, and doing that inside a SwiftUI body stutters the
    /// very arrow tap that asked for it.
    private func rebuild() async {
        let climate = climate, period = period
        // `asOf` means TODAY to the summary: it counts days through the one
        // before, and calls a stretch running when it ends on or after it. So
        // a finished stretch is asked about from the day after its last —
        // handing it the last day itself made a finished September read as
        // "still running — 30 of 29 days so far". `asOf` also picks the focus
        // year: asking from inside an instance is what pins it.
        let end = period.bounds(inYear: focusYear)?.end ?? latestDay
        let asOf = min(DayKey.step(end, by: 1) ?? today, today)
        let clamped = min(end, latestDay)
        let year = focusYear, title = Self.title(period, year)
        let (built, told) = await Task.detached(priority: .userInitiated) {
            (climate.summary(for: period, asOf: asOf),
             climate.story(period, year: year, title: title, latestDay: clamped))
        }.value
        // A slower earlier request must not overwrite the one now selected.
        // Comparing against `self.period` can't catch that — `self` here is the
        // view as it was when this task began — but `.task(id:)` cancels the
        // superseded task on every step, and
        // the detached work doesn't inherit that, so ask once it's back.
        guard !Task.isCancelled else { return }
        summary = built
        story = told
    }

    // MARK: Pieces

    // MARK: One instance

    @ViewBuilder private func instanceHeadline(_ s: PeriodSummary, _ year: PeriodYear) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The story's sentence when there is one — what it did — and the
            // averages' when there isn't.
            Text(story?.sentence(isRunning: year.isInProgress) ?? instanceSentence(s, year))
                .font(.title3.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            // A thin instance is the one case where the numbers below are all
            // floors and means over the hours that were watched. Say so once,
            // here, rather than hedging every cell.
            if year.isInProgress {
                Text("\(instanceTitle(s, year)) is still running — \(year.daysCovered) of \(year.daysExpected) days so far.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if !year.isTrustworthy {
                Text("The station watched \(Int(year.coverage * 100))% of \(instanceTitle(s, year)). Its rain total is a floor, and its means are over the hours it saw.")
                    .font(.caption).foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "September 2025 ran 2.1° warmer than usual."
    ///
    /// Led by the DEPARTURE, not the value: the number you can read off the card
    /// below is the high; the thing you opened one instance to find out is how
    /// it compared. "Than usual" rather than "than a September", because the
    /// period's name doesn't take an article for every grain — the whole year
    /// is called "the year", and "than a the year" is what that produced.
    private func instanceSentence(_ s: PeriodSummary, _ year: PeriodYear) -> String {
        let title = instanceTitle(s, year)
        guard let high = year.high, let typical = s.typicalHigh, s.isMeaningful else {
            return "\(title) — \(degrees(year.high)) days, \(degrees(year.low)) nights."
        }
        let delta = high - typical
        guard abs(delta) >= 0.5 else {
            return "\(title) ran about normal — \(degrees(year.high)) days, \(degrees(year.low)) nights."
        }
        return "\(title) ran \(String(format: "%.1f", abs(delta)))° "
             + (delta > 0 ? "warmer" : "cooler")
             + " than usual — \(degrees(year.high)) days, \(degrees(year.low)) nights."
    }

    /// One instance's name: "September 2025", "Sep 24 – Sep 30, 2025", "2025".
    private func instanceTitle(_ s: PeriodSummary, _ year: PeriodYear) -> String {
        Self.title(s.period, year.year)
    }

    static func title(_ period: WeatherPeriod, _ year: Int) -> String {
        if period == .wholeYear { return String(year) }
        if period.name.contains("–") { return "\(period.name), \(year)" }
        return "\(period.name) \(year)"
    }

    // MARK: The tiles

    /// What the stretch was like, before anything is said about it: four
    /// tiles across the top, in the Forecast page's shape — temperature, the
    /// extremes, rain, mugginess — each with how it compared to a usual one.
    ///
    /// They used to be a grid at the BOTTOM, under the story, with the hottest
    /// and coldest days folded into a footnote. The extremes are what someone
    /// wants first ("how hot did it get?"), so they get a tile of their own,
    /// and the whole row comes first, before the sentence explains it.
    private func instanceTiles(_ s: PeriodSummary, _ year: PeriodYear) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) { tiles(s, year) }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { temperatureTile(s, year); rangeTile(year) }
                GridRow { rainTile(s, year); dewTile(s, year) }
            }
        }
    }

    @ViewBuilder private func tiles(_ s: PeriodSummary, _ year: PeriodYear) -> some View {
        temperatureTile(s, year)
        rangeTile(year)
        rainTile(s, year)
        dewTile(s, year)
    }

    private func temperatureTile(_ s: PeriodSummary, _ year: PeriodYear) -> some View {
        tile("Temperature", symbol: "thermometer.medium") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(degrees(year.high)).font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(degrees(year.low)).font(.title3).foregroundStyle(.secondary)
            }
            Text("average high and low").font(.caption).foregroundStyle(.tertiary)
            departureLine(year.high, s.typicalHigh, noun: "days")
            departureLine(year.low, s.typicalLow, noun: "nights")
        }
    }

    private func rangeTile(_ year: PeriodYear) -> some View {
        tile("Hottest and coldest", symbol: "arrow.up.arrow.down") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(degrees(year.hottest?.value)).font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(degrees(year.coldest?.value)).font(.title3).foregroundStyle(.secondary)
            }
            if let hot = year.hottest {
                Label("high on \(WeatherAlmanac.dayLabel(hot.day))", systemImage: "sun.max.fill")
                    .font(.callout).foregroundStyle(.secondary)
                rank(.hottest, day: hot.day)
            }
            if let cold = year.coldest {
                Label("low on \(WeatherAlmanac.dayLabel(cold.day))", systemImage: "moon.stars.fill")
                    .font(.callout).foregroundStyle(.secondary)
                rank(.coldest, day: cold.day)
            }
        }
    }

    /// "The warmest Sep 12 of the 4 on record" — the one thing the event list
    /// said about the extremes that the tile didn't, so it moved here with them.
    /// Only when the story ranked the SAME day the tile shows — the two pick
    /// their extremes separately, and a rank under the wrong date is worse
    /// than none.
    @ViewBuilder private func rank(_ kind: StoryEvent.Kind, day: String) -> some View {
        if let detail = story?.events.first(where: { $0.kind == kind && $0.day == day })?.detail, !detail.isEmpty {
            Text(detail)
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 28)
        }
    }

    private func rainTile(_ s: PeriodSummary, _ year: PeriodYear) -> some View {
        tile("Rain", symbol: "drop.fill") {
            Text(String(format: "%.2f″", year.precip))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("\(year.rainDays) wet \(year.rainDays == 1 ? "day" : "days")")
                .font(.callout).foregroundStyle(.secondary)
            // Said in words: "wetter" and "drier" read faster than a signed
            // number of inches, and rain has no warm or cool to colour.
            if let typical = s.typicalPrecip, s.isMeaningful {
                let delta = year.precip - typical
                Text(abs(delta) < 0.05 ? "about a usual amount"
                     : String(format: "%.2f″ %@ than usual", abs(delta), delta > 0 ? "wetter" : "drier"))
                    .font(.callout).foregroundStyle(delta > 0.05 ? Color.blue : .secondary)
            }
        }
    }

    private func dewTile(_ s: PeriodSummary, _ year: PeriodYear) -> some View {
        tile("Dew point", symbol: "humidity.fill") {
            Text(degrees(year.dewPoint)).font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("average — the mugginess").font(.caption).foregroundStyle(.tertiary)
            departureLine(year.dewPoint, s.typicalDewPoint, noun: "air", warmWord: "muggier", coolWord: "drier")
        }
    }

    /// "4° warmer days than usual" — or nothing, when the record is too young
    /// to say what usual is.
    @ViewBuilder private func departureLine(_ value: Double?, _ typical: Double?, noun: String,
                                            warmWord: String = "warmer", coolWord: String = "cooler") -> some View {
        if let value, let typical, summary?.isMeaningful == true {
            let delta = Int((value - typical).rounded())
            Text(delta == 0 ? "usual \(noun)" : "\(abs(delta))° \(delta > 0 ? warmWord : coolWord) \(noun) than usual")
                .font(.callout)
                .foregroundStyle(delta > 0 ? Color.orange : delta < 0 ? Color.accentColor : .secondary)
        }
    }

    private func tile<Content: View>(_ title: String, symbol: String,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }

    private func degrees(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))°" } ?? "—"
    }

    private func card<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        StationCard(label: label, content: content)
    }
}
