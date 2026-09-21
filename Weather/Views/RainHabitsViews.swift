//
//  RainHabitsViews.swift  (macOS)
//
//  The half of the rain question `RainfallCard` never answered.
//
//  That card is about AMOUNT — this year against the usual, month by month and
//  year by year. It is good at that and unchanged. But two Octobers holding the
//  same four inches draw identically on it, and they are not the same October:
//  one dripped it over fourteen grey days, the other dropped it in an afternoon.
//  These views are the other axis — how often, how hard, and how long it goes
//  without.
//
//  All three read `RainHabits`, which is where the arithmetic and its caveats
//  live. Nothing here decides what counts as a wet day or what a gap in the
//  archive means.
//

import SwiftUI
import WeatherKit

// MARK: - How often it rains

/// Wet days per month, with the typical fall ON those days riding underneath.
///
/// Two encodings rather than one chart with two axes: the bar is the count,
/// which is the question ("how many days does it rain in May"), and the number
/// under it is the depth, which is the follow-up. Putting depth on a second
/// y-axis would make the two look comparable when their units share nothing.
struct RainFrequencyChart: View {
    let months: [MonthWetness]

    private var peak: Double { max(1, months.map(\.wetDays).max() ?? 1) }
    private let plotHeight: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                axis
                ZStack(alignment: .bottomLeading) {
                    gridlines
                    HStack(alignment: .bottom, spacing: 7) {
                        ForEach(months) { month in column(month) }
                    }
                }
                .frame(height: plotHeight)
            }
            labels
            Text("Bar: days it rains in a typical month. Below: how much falls on one of those days.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func column(_ month: MonthWetness) -> some View {
        // A month too thin to speak draws nothing rather than a short bar, which
        // would read as a dry month instead of an unmeasured one.
        RoundedRectangle(cornerRadius: 2)
            .fill(month.isMeaningful
                  ? AnyShapeStyle(LinearGradient(colors: [Color.cyan.opacity(0.85),
                                                          Color.blue.opacity(0.75)],
                                                 startPoint: .top, endPoint: .bottom))
                  : AnyShapeStyle(Color.secondary.opacity(0.18)))
            .frame(maxWidth: .infinity)
            .frame(height: month.isMeaningful
                   ? max(2, plotHeight * CGFloat(month.wetDays / peak)) : 2)
            .frame(maxWidth: .infinity, alignment: .bottom)
            .help(help(month))
    }

    private func help(_ m: MonthWetness) -> String {
        guard m.isMeaningful else {
            return "\(m.name): only \(m.daysSampled) days on record — not enough to call it a habit."
        }
        return "\(m.name): rain on \(String(format: "%.0f", m.wetDays)) days in a typical month "
            + "(\(Int((m.wetShare * 100).rounded()))% of days). "
            + "A wet day brings \(WeatherAlmanac.inches(m.meanOnWetDays)); "
            + "the biggest on record was \(WeatherAlmanac.inches(m.wettestDay))."
    }

    private var ticks: [Double] {
        let step: Double = peak > 16 ? 5 : (peak > 8 ? 4 : 2)
        return Array(stride(from: 0, through: peak, by: step))
    }

    private var gridlines: some View {
        ZStack(alignment: .bottom) {
            ForEach(ticks, id: \.self) { v in
                Rectangle().fill(Color.primary.opacity(v == 0 ? 0.25 : 0.07))
                    .frame(height: v == 0 ? 1 : 0.5)
                    .offset(y: -plotHeight * CGFloat(v / peak))
            }
        }
        .frame(height: plotHeight, alignment: .bottom)
    }

    private var axis: some View {
        ZStack(alignment: .bottomTrailing) {
            ForEach(ticks, id: \.self) { v in
                Text("\(Int(v))").font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .offset(y: -plotHeight * CGFloat(v / peak) + 5)
            }
        }
        .frame(width: 18, height: plotHeight, alignment: .bottomTrailing)
    }

    private var labels: some View {
        HStack(spacing: 7) {
            Spacer().frame(width: 26)
            ForEach(months) { m in
                VStack(spacing: 1) {
                    Text(m.name).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(m.isMeaningful ? WeatherAlmanac.inches(m.meanOnWetDays) : "—")
                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Dry spells

struct DrySpellsCard: View {
    let habits: RainHabits

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline
            if !habits.longestDrySpells.isEmpty {
                Divider().opacity(0.5)
                VStack(spacing: 0) {
                    ForEach(habits.longestDrySpells) { spell in row(spell) }
                }
                Text("A stretch of days the station watched and saw no measurable rain. Days it didn’t watch end a stretch rather than extending it.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(habits.currentDryDays)")
                .font(.system(size: 30, weight: .light, design: .rounded).monospacedDigit())
            VStack(alignment: .leading, spacing: 2) {
                Text(habits.currentDryDays == 1 ? "day since it rained" : "days since it rained")
                    .font(.callout)
                if let last = habits.lastRain {
                    Text("Last was \(WeatherAlmanac.dayLabel(last.day, includeYear: true)) — \(WeatherAlmanac.inches(last.amount))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let longest = habits.longestDrySpells.first {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(longest.days) days")
                        .font(.callout.weight(.medium).monospacedDigit())
                    Text("longest on record").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func row(_ spell: DrySpell) -> some View {
        let longest = habits.longestDrySpells.first?.days ?? spell.days
        return HStack(spacing: 10) {
            Text("\(spell.days)")
                .font(.caption.monospacedDigit().weight(.medium))
                .frame(width: 30, alignment: .trailing)
            GeometryReader { geo in
                Capsule()
                    .fill(spell.isOpen ? AnyShapeStyle(Color.orange.opacity(0.7))
                                       : AnyShapeStyle(Color.secondary.opacity(0.40)))
                    .frame(width: max(2, geo.size.width * CGFloat(spell.days) / CGFloat(longest)))
            }
            .frame(height: 8)
            Text("\(WeatherAlmanac.dayLabel(spell.startDay, includeYear: false)) – \(WeatherAlmanac.dayLabel(spell.endDay, includeYear: true))")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 168, alignment: .leading)
            // "still going" is the one thing a length can't say for itself.
            Text(spell.isOpen ? "still going" : "")
                .font(.caption2).foregroundStyle(.orange)
                .frame(width: 62, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - The biggest days

/// What a single day here is capable of. The list rather than one extreme,
/// because the question behind it — is the record's biggest day a freak or a
/// thing that happens — is only answerable from the shape of the top few.
struct BiggestRainDaysCard: View {
    let days: [(day: String, amount: Double)]
    /// Hands a day to Explore's day view, the same way the crossing cards do.
    var onOpen: ((String) -> Void)?

    var body: some View {
        let peak = days.first?.amount ?? 1
        VStack(spacing: 0) {
            ForEach(days, id: \.day) { entry in
                HStack(spacing: 10) {
                    Text(WeatherAlmanac.inches(entry.amount))
                        .font(.callout.monospacedDigit().weight(.medium))
                        .frame(width: 62, alignment: .trailing)
                    GeometryReader { geo in
                        Capsule()
                            .fill(LinearGradient(colors: [Color.cyan.opacity(0.75),
                                                          Color.blue.opacity(0.85)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, geo.size.width * CGFloat(entry.amount / peak)))
                    }
                    .frame(height: 10)
                    Text(WeatherAlmanac.dayLabel(entry.day, includeYear: true))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { onOpen?(entry.day) }
                .help(onOpen == nil ? "" : "Open \(WeatherAlmanac.dayLabel(entry.day, includeYear: true))")
            }
        }
    }
}

// MARK: - The section

/// Owns the `RainHabits` build and lays the three cards out.
///
/// The build walks every reliable day in the archive — thousands of them, and
/// the dry-spell pass is a second walk — so it runs detached and once per day
/// rather than inside a `body` that re-evaluates on every scroll. Same reasoning
/// as `SeasonTransitionsCard`, and it matters more here because the record only
/// grows.
///
/// `card` is passed in rather than redefined: the chrome belongs to `WeatherView`
/// and a second copy of it here is how two surfaces start drifting apart.
struct RainHabitsSection<Card: View>: View {
    let climate: Climatology
    let today: String
    @ViewBuilder var card: (String, AnyView) -> Card

    @State private var habits: RainHabits?

    var body: some View {
        // A `Group` here was a bug, and one this codebase has already paid for
        // once (see `WeatherView.rainCard`): while `habits` is nil the Group
        // resolves to `EmptyView`, SwiftUI DROPS MODIFIERS on an EmptyView, and
        // the `.task` below never ran — so `habits` stayed nil forever and the
        // cards never appeared. A `VStack` is a real view whether or not it has
        // children, so the task survives the empty first frame.
        VStack(alignment: .leading, spacing: 18) {
            if let habits, habits.isMeaningful {
                card("How often it rains", AnyView(
                    RainFrequencyChart(months: habits.months)))
                card("Dry spells", AnyView(
                    DrySpellsCard(habits: habits)))
                if !habits.biggestDays.isEmpty {
                    card("Biggest days on record", AnyView(
                        BiggestRainDaysCard(days: habits.biggestDays)))
                }
            }
        }
        .task(id: today) {
            let c = climate, d = today
            habits = await Task.detached { c.rainHabits(asOf: d) }.value
        }
    }
}
