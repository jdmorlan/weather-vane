//
//  WeatherSeasonViews.swift  (macOS)
//
//  The two views that read the archive as a CALENDAR rather than as weather:
//  when the year turns here, and how much winter chill the yard banks.
//
//  Both are planning views, and both are built around the same refusal: they
//  show a WINDOW, never a single date. "First frost: October 24" invites you to
//  plant against a precision the record doesn't have. "Usually late October —
//  as early as the 9th, as late as November 12" is the same data told honestly,
//  and it's the version you can actually make a decision with.
//

import SwiftUI
import WeatherKit

// MARK: - When the year turns

/// Frost dates, the end of summer heat, and the length of the growing season —
/// each as a typical date with the spread the record has actually seen.
struct SeasonTransitionsCard: View {
    let climate: Climatology
    let today: String
    /// The ten-day outlook, in archive terms. Where it reaches, it overrules the
    /// normals — a card that says "two more days" while the forecast holds every
    /// night at 74° is telling you about other Septembers, not this one.
    var forecast: [SeasonForecastDay] = []

    /// How far ahead the card looks. Everything beyond this is computed and then
    /// deliberately dropped — in early August the first freeze is a real date and
    /// still ten weeks out, and showing it crowds out the three things that are
    /// about to happen. It reappears on its own as it comes near.
    private let horizonDays = 75

    /// Computed once per day rather than per render. Building the tracks scans
    /// the whole archive a dozen times over (three thresholds on each of four
    /// measures, each smoothed across every year), which is fine once and far too
    /// much for a SwiftUI body that re-evaluates on every scroll.
    @State private var tracks: [SeasonTrack] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if tracks.isEmpty {
                // Blank rather than a message: this is also the state while the
                // tracks are still being built, and "nothing ahead" would be a lie
                // for the first frame.
                Color.clear.frame(height: 1)
            } else {
                if let lead = leadLine(tracks) {
                    Text(lead).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SeasonTimelineView(tracks: tracks, horizonDays: horizonDays)
                growingSeasonLine(climate.growingSeasons(), tracks: tracks)
            }
        }
        .task(id: rebuildKey) {
            let climate = self.climate
            let horizon = self.horizonDays
            let day = self.today
            let outlook = self.forecast
            tracks = await Task.detached {
                climate.seasonalTracks(asOf: day, horizonDays: horizon, forecast: outlook)
            }.value
        }
    }

    /// Rebuild on a new day OR a changed outlook, but not on every refresh that
    /// returns the same numbers — the build scans the whole archive a dozen times.
    private var rebuildKey: String {
        today + forecast.map { "\($0.day):\($0.tempMin ?? -999):\($0.tempMax ?? -999)" }
            .joined(separator: "|")
    }

    /// One sentence the picture can't say on its own: what the nearest stretch
    /// actually is. Everything else the timeline shows better than prose.
    private func leadLine(_ tracks: [SeasonTrack]) -> String? {
        guard let track = tracks.first, let first = track.milestones.first else { return nil }

        // A late crossing outranks the countdown, wherever in the chart it sits.
        // It's the one thing here that isn't the usual shape of the year, the
        // pills deliberately don't spell it out, and it also breaks the
        // arithmetic the countdown is built on — "-8 more days" is nonsense.
        let late = tracks.compactMap { candidate -> (SeasonTrack, SeasonMilestone)? in
            candidate.milestones.first(where: \.isOverdue).map { (candidate, $0) }
        }
        // Most overdue wins, and these are negative, so that's the smallest.
        .min { ($0.1.normalDaysFromNow ?? 0) < ($1.1.normalDaysFromNow ?? 0) }

        if let (lateTrack, milestone) = late {
            let usual = WeatherAlmanac.dateLabel(milestone.normalMonthDay ?? milestone.monthDay)
            let behind = -(milestone.normalDaysFromNow ?? 0)
            let opening = "\(lateTrack.name) usually drop \(milestone.label) by \(usual). \(behind) days on, they still haven't"
            guard let lateBy = milestone.lateByDays, milestone.basis == .forecast else {
                return opening + ", and the forecast doesn't reach it either."
            }
            return opening + " — the forecast puts it \(WeatherAlmanac.dateLabel(milestone.monthDay)), \(lateBy) days late."
        }
        // A floor can't be counted from: the forecast has ruled the crossing out
        // through its window without saying what happens after, and "10 more days"
        // would be the same false precision the normals were guilty of.
        let least = first.basis == .notBefore ? "at least " : ""
        let others = tracks.dropFirst().compactMap { $0.milestones.first?.daysFromNow }
        guard let last = others.max(), last > first.daysFromNow else {
            return "\(least)\(first.daysFromNow) more days before \(tracks[0].name.lowercased()) drop \(first.label)."
        }
        return "\(least)\(first.daysFromNow) more days of all of it, then \(last - first.daysFromNow) more before the last of it eases."
    }

    /// Only shown alongside a freeze track — out of season it's trivia.
    @ViewBuilder private func growingSeasonLine(_ seasons: [GrowingSeason], tracks: [SeasonTrack]) -> some View {
        let measured = seasons.compactMap(\.days).sorted()
        if tracks.contains(where: { $0.measure == .freeze }), measured.count >= 2,
           let shortest = measured.first, let longest = measured.last {
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill").foregroundStyle(.green).font(.caption)
                Text("Frost-free season runs \(measured[measured.count / 2]) days here (\(shortest)–\(longest) across \(measured.count) years).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
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

    @State private var showAllFruit = false
    @State private var expanded = false

    /// Chill is a planting-season question. From October through April it's live —
    /// a winter is accumulating, or you're deciding what to put in the ground. In
    /// August it's reference material, and it collapses to a line until asked for.
    private var isInSeason: Bool {
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
                 ? "Once a full winter is archived, this will show the chill hours your yard banks and which fruit trees that supports."
                 : "\(summary.seasonsCounted) complete \(summary.seasonsCounted == 1 ? "winter" : "winters") archived. Three makes a number worth planting against.")
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
