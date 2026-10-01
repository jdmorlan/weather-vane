//
//  WeatherSeasonViews.swift  (macOS)
//
//  Views that read the archive as a CALENDAR rather than as weather, such as
//  how much winter chill this station records.
//
//  They are planning views, built around one refusal: they show a WINDOW,
//  never a single date. "First frost: October 24" invites you to
//  plant against a precision the record doesn't have. "Usually late October —
//  as early as the 9th, as late as November 12" is the same data told honestly,
//  and it's the version you can actually make a decision with.
//

import SwiftUI
import WeatherKit

// MARK: - The shape of a day

/// The day's own cycle, month by month — the other rhythm this place has.
///
/// WHY IT IS ON THIS PAGE. Rhythms had exactly one cycle in it, the year, which
/// made "when things usually happen here" a half-answer. A day turns too, and
/// where its peak lands moves by well over an hour between midsummer and
/// midwinter. Nothing in the app could say so until the sample archive was
/// filled: `DailyRecord` keeps a day as its min, max and means, and a high of
/// 96° is silent about WHEN.
///
/// IT WAITS RATHER THAN COMPUTES. Every other card here builds its own answer in
/// a detached task; this one reads what `WeatherSamplesModel` already folded, because
/// the fold is sixteen seconds over two million samples and is shared with the
/// wind climatology. A card that triggered it would be a card that hangs.
struct DayShapeCard: View {
    let climate: DiurnalClimate

    /// Temperature first because its lag is the largest and the most surprising.
    /// The other two are a click away rather than three stacked charts: they are
    /// the same picture of a different measure, and reading them side by side is
    /// not the question.
    @State private var measure: DiurnalMeasure = .temperature

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let lead = leadLine {
                Text(lead).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("", selection: $measure) {
                ForEach(DiurnalMeasure.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)

            DiurnalView(climate: climate, measure: measure)

            Text(footnote).font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The one sentence the matrix can't say about itself: how far the peak
    /// actually travels, in words, with the two months that bracket it named.
    ///
    /// Written from `peakSpread` rather than from July and January by name — a
    /// station's calendar is its own, and naming the months the RECORD puts at
    /// the ends is both more honest and more interesting when they aren't the
    /// ones you'd guess.
    private var leadLine: String? {
        guard let spread = climate.peakSpread(measure) else { return nil }
        let earliest = YearAxis.months[spread.earliest.month - 1].name
        let latest = YearAxis.months[spread.latest.month - 1].name
        let gap = (spread.latest.slot - spread.earliest.slot) * DiurnalClimate.slotMinutes
        guard gap > 0 else {
            return "\(measure.name) peaks around \(DiurnalView.clock(spread.latest.slot)) here, and barely moves through the year."
        }
        var text = "\(measure.name) peaks around \(DiurnalView.clock(spread.latest.slot)) in \(latest)"
            + " and \(DiurnalView.clock(spread.earliest.slot)) in \(earliest) — \(gapLabel(gap)) apart."
        // The other headline, and only where it's true: the coldest minute of
        // the day is not midnight. Stated only when the record agrees, because
        // a station in a valley with a cold-air pool may genuinely disagree.
        if measure == .temperature, let overall = climate.overall.extremes(.temperature),
           overall.trough >= DiurnalClimate.slot(ofMinute: 3 * 60),
           overall.trough <= DiurnalClimate.slot(ofMinute: 8 * 60) {
            text += " The coldest moment of a day here is around \(DiurnalView.clock(overall.trough)) — first light, not midnight."
        }
        return text
    }

    private func gapLabel(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) minutes" }
        if rest == 0 { return hours == 1 ? "an hour" : "\(hours) hours" }
        return "\(hours)h \(rest)m"
    }

    /// What the picture is made of. It matters here more than on the archive's
    /// other charts: these are means of MINUTES, not of days, and the difference
    /// is the whole reason the card can exist.
    private var footnote: String {
        let days = climate.days
        var text = "Every recorded minute of \(days) archived \(days == 1 ? "day" : "days"), averaged by quarter-hour."
        if let first = climate.firstDay, let last = climate.lastDay {
            text += " \(WeatherAlmanac.dayLabel(first)) to \(WeatherAlmanac.dayLabel(last))."
        }
        return text
    }
}

// MARK: - Winter chill

/// What the yard banks each winter, and what that lets you plant.
///
/// Chill is the number nursery catalogs quote and almost nobody knows for their
/// own ground — a variety at "800 chill hours" planted where 500 accumulate
/// blooms raggedly and sets a light crop, every year, for the life of the tree.
struct WinterChillCard: View {
    let climate: Climatology
    let today: String
    /// Skip the seasonal collapse entirely.
    ///
    /// The collapse is a Now-card rule: on a page about what is happening,
    /// August has no use for chill hours and the card should get out of the way.
    /// Rhythms is a page about what the place DOES, where a fact being out of
    /// season is not a reason to hide it — and hiding it there left the rarest
    /// number in the app behind a Details link on a screen with room to spare.
    var alwaysOpen = false

    @State private var showAllFruit = false
    @State private var expanded = false

    /// Chill is a planting-season question. From October through April it's live —
    /// a winter is accumulating, or you're deciding what to put in the ground. In
    /// August it's reference material, and it collapses to a line until asked for.
    private var isInSeason: Bool {
        if alwaysOpen { return true }
        let monthDay = DayKey.monthDay(of: today)
        return monthDay >= "10-01" || monthDay <= "04-30"
    }

    var body: some View {
        let summary = climate.chillSummary()
        VStack(alignment: .leading, spacing: 16) {
            if summary.isMeaningful, let typical = summary.typicalChillHours {
                if isInSeason || expanded {
                    headline(summary, typical: typical)
                    seasonBars(summary)
                    Divider()
                    fruitList(summary)
                    if !isInSeason {
                        Button("Collapse") { expanded = false }
                            .buttonStyle(.link).font(.caption)
                    }
                } else {
                    collapsed(summary, typical: typical)
                }
            } else {
                buildingUp(summary)
            }
        }
    }

    /// Out of season: the answer in one line, with the detail a click away.
    private func collapsed(_ summary: ChillSummary, typical: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("At least \(Int(typical.rounded())) chill hours in a typical winter")
                .font(.callout)
            Text("— enough for \(supportedSummary(typical))")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Details") { expanded = true }
                .buttonStyle(.link).font(.caption)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func supportedSummary(_ hours: Double) -> String {
        let comfortable = FruitChill.ranked(for: hours).filter { $0.1 == .comfortable }.map(\.0.name)
        guard !comfortable.isEmpty else { return "low-chill varieties only" }
        let named = comfortable.prefix(3).map { $0.lowercased() }.joined(separator: ", ")
        return comfortable.count > 3 ? "\(named) and \(comfortable.count - 3) more" : named
    }

    @ViewBuilder private func headline(_ summary: ChillSummary, typical: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("at least").font(.callout).foregroundStyle(.secondary)
                Text("\(Int(typical.rounded()))")
                    .font(.system(size: 34, weight: .light, design: .rounded))
                Text("chill hours in a typical winter")
                    .font(.callout).foregroundStyle(.secondary)
            }
            // The floor is a promise; the estimate is a guess. Saying which is
            // which is the difference between a number you can plant against and
            // a number that merely sounds precise.
            if let coverage = summary.typicalCoverage, coverage < 0.99, let estimate = summary.typicalEstimate {
                Text("Your station recorded \(Int((coverage * 100).rounded()))% of a typical winter’s hours, so the real total is higher — probably around \(Int(estimate.rounded())).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let low = summary.lowestChillHours, let high = summary.highestChillHours, low != high {
                Text("Observed \(Int(low.rounded()))–\(Int(high.rounded())) across \(summary.seasonsCounted) winters. Hours between 32° and 45°, October through February.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress = summary.inProgress {
                Text("This winter so far: \(Int(progress.chillHours.rounded())) hours")
                    .font(.caption.weight(.medium)).foregroundStyle(.tint)
            }
        }
    }

    /// One bar per winter, so a mild year is visible rather than averaged away.
    @ViewBuilder private func seasonBars(_ summary: ChillSummary) -> some View {
        let seasons = summary.seasons.filter { $0.isTrustworthy || $0.isInProgress }
        if let peak = seasons.map(\.chillHours).max(), peak > 0 {
            VStack(spacing: 5) {
                ForEach(seasons) { season in
                    HStack(spacing: 10) {
                        Text(season.label)
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        GeometryReader { geo in
                            Capsule()
                                .fill(season.isInProgress ? Color.secondary.opacity(0.4) : Color.blue.opacity(0.65))
                                .frame(width: max(2, geo.size.width * (season.chillHours / peak)))
                        }
                        .frame(height: 8)
                        Text("\(Int(season.chillHours.rounded()))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        // Without this, a winter the station half-missed looks
                        // identical to a genuinely mild one.
                        Text(season.isInProgress ? "so far"
                             : season.coverage < 0.95 ? "\(Int((season.coverage * 100).rounded()))% rec." : "")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .frame(width: 56, alignment: .leading)
                            .help(season.coverage < 0.95
                                  ? "The station recorded \(Int((season.coverage * 100).rounded()))% of this winter’s hours, so its real total is higher than the bar shows."
                                  : "")
                    }
                }
            }
        }
    }

    /// Fruit measured against the LOW winter, not the average — a tree is a
    /// ten-year commitment and the winter that disappoints is the one that counts.
    @ViewBuilder private func fruitList(_ summary: ChillSummary) -> some View {
        if let reliable = summary.planningChillHours {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("WHAT THAT SUPPORTS")
                        .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.tertiary)
                    Spacer()
                    Text("against a typical winter’s \(Int(reliable.rounded())) recorded hours")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                let ranked = FruitChill.ranked(for: reliable)
                let shown = showAllFruit ? ranked : ranked.filter { $0.1 != .insufficient }
                ForEach(shown, id: \.0.id) { fruit, fit in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: symbol(fit)).foregroundStyle(color(fit))
                            .font(.caption).frame(width: 16)
                        Text(fruit.name).font(.callout)
                            .frame(width: 150, alignment: .leading)
                        Text("\(Int(fruit.low))–\(Int(fruit.high)) hrs")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text(fit == .marginal ? "low-chill varieties only" : fruit.note)
                            .font(.caption).foregroundStyle(fit == .marginal ? .secondary : .tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }

                Button(showAllFruit ? "Hide what won't get enough chill"
                                    : "Show what won't get enough chill") {
                    showAllFruit.toggle()
                }
                .buttonStyle(.link).font(.caption)

                // The single most useful caveat on the card: these are cultivar
                // ranges, so a number that rules out "peach" rules out most
                // peaches, never the fruit.
                Text("These are ranges across a fruit’s common varieties, not fixed numbers — most fruits have low-chill selections bred well below their usual range. And the hours above are a floor, not a ceiling, so anything marginal here is likelier to work than not. Check the specific variety’s requirement before buying.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private func buildingUp(_ summary: ChillSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = summary.inProgress {
                Text("This winter so far: \(Int(progress.chillHours.rounded())) chill hours")
                    .font(.callout.weight(.medium))
            }
            Text(summary.seasonsCounted == 0
                 ? "Once a full winter is archived, this will show the chill hours this station records and which fruit trees that supports."
                 : "\(summary.seasonsCounted) complete \(summary.seasonsCounted == 1 ? "winter" : "winters") archived. Three gives a reliable average.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func symbol(_ fit: ChillFit) -> String {
        switch fit {
        case .comfortable: return "checkmark.circle.fill"
        case .marginal: return "circle.lefthalf.filled"
        case .insufficient: return "xmark.circle"
        }
    }

    private func color(_ fit: ChillFit) -> Color {
        switch fit {
        case .comfortable: return .green
        case .marginal: return .yellow
        case .insufficient: return .secondary
        }
    }
}
