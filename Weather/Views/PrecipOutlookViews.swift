//
//  PrecipOutlookViews.swift  (macOS)
//
//  ELEVEN MODELS, EIGHTEEN HOURS, AND THE DISAGREEMENT LEFT VISIBLE.
//
//  WHY A GRID AND NOT A LINE CHART. Eleven overlapping precipitation traces is the
//  classic spaghetti plot, and it answers the wrong question: it invites you to
//  read each model's shape, when what is actually being asked is "how many of
//  them say yes, and when". A row per model against a column per hour makes the
//  answer a COUNT you can take in without reading any value — a column that is
//  solid all the way down is agreement, and a single pale row is a holdout.
//
//  WHY NOT AN AVERAGE. Averaging them would have turned the afternoon of 20
//  September — two models with a real event, three with nothing — into a quiet
//  "a bit of rain", which is the one answer none of them gave. See
//  `PrecipOutlook.swift` for the numbers that settled it.
//
//  COLOUR CARRIES MAGNITUDE ONLY, AND IT IS ONE HUE. Identity lives in the row
//  labels, never in colour, so the card still reads with the colour removed. The
//  ramp is a single blue, monotonically darkening, which is the only honest
//  encoding for an amount — a rainbow across five steps would imply categories
//  that do not exist. Its light end is deliberately low-contrast against the
//  card, so every row also carries its TOTAL as a printed number and every cell
//  answers on hover: the picture is the glance, the numbers are the reading.
//

import SwiftUI
import WeatherKit

// MARK: - Model

@MainActor
final class PrecipOutlookModel: ObservableObject {
    @Published private(set) var outlook: PrecipOutlook?
    @Published private(set) var failure: String?
    @Published private(set) var isLoading = false

    /// There is no point to ask about yet.
    ///
    /// THE STATE THAT WAS MISSING, and its absence read as a bug in the card. A
    /// nil home made `load` return having touched nothing, so Rain showed "No
    /// forecast yet" — a sentence that describes the models, about a request that
    /// was never made. The reader has no way to tell that apart from five
    /// forecasts all declining to answer, and nothing on the screen says what to
    /// do about it.
    @Published private(set) var needsHome = false

    /// The models land on the hour, and NBM and HRRR rerun hourly. Twenty minutes
    /// is often enough to catch a new run soon after it publishes without asking
    /// five models' worth of question every time someone opens the tab.
    static let refreshEvery: Duration = .seconds(20 * 60)

    func load(home: GeoPoint?) async {
        guard let home else { needsHome = true; return }
        needsHome = false
        isLoading = true
        defer { isLoading = false }
        do {
            outlook = try await PrecipOutlookClient().outlook(home: home)
            failure = nil
        } catch {
            // The previous outlook is KEPT. An hour-old spread is still the
            // answer; blanking the card because one fetch failed would replace
            // information with an apology.
            failure = (error as? PrecipOutlookClient.Failure)?.errorDescription
                ?? error.localizedDescription
        }
    }

    func poll(home: GeoPoint?) async {
        while !Task.isCancelled {
            await load(home: home)
            try? await Task.sleep(for: Self.refreshEvery)
        }
    }
}

// MARK: - The card

struct PrecipOutlookCard: View {
    let outlook: PrecipOutlook?
    let failure: String?
    let isLoading: Bool
    /// Nothing has been asked, because there is nowhere to ask about.
    var needsHome: Bool = false
    /// Opens setup. Optional so the card stays usable from a preview.
    var onSetUpHome: (() -> Void)?

    var body: some View {
        if let outlook {
            VStack(alignment: .leading, spacing: 16) {
                verdict(outlook)
                grid(outlook)
                footer(outlook)
            }
        } else if needsHome {
            // NAMED, AND WITH THE DOOR IN IT. This card is the one forecast in
            // the app that needs no station, so it is the first thing a
            // half-configured install can show — which makes it the wrong place
            // for a shrug.
            VStack(alignment: .leading, spacing: 10) {
                Text("No home location set")
                    .font(.callout.weight(.medium))
                Text("These eleven models answer about a point on the map, not about your station. Setup finds it from the station you connect, or you can place it yourself.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let onSetUpHome {
                    Button("Set your location", action: onSetUpHome)
                        .buttonStyle(.link)
                }
            }
        } else if isLoading {
            Text("Asking the models…").font(.callout).foregroundStyle(.secondary)
        } else {
            Text(failure ?? "No forecast yet").font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: The headline

    @ViewBuilder private func verdict(_ outlook: PrecipOutlook) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(outlook.headline)
                .font(.title3.weight(.medium))
            if let detail = outlook.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            // NAMING THE HOLDOUT IS THE POINT OF THE CARD. "4 of 5" tells you
            // there is a dissenter; which one it is tells you whether to care.
            if let holdout = outlook.holdout {
                Text(outlook.wetModels.count == 1
                     ? "Only \(holdout.label) has it"
                     : "\(holdout.label) is the holdout")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: The grid

    private func grid(_ outlook: PrecipOutlook) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            hourAxis(outlook)
            // GROUPED, BECAUSE THE COUNT ONLY MEANS SOMETHING WITH THE WHO. Eight
            // coarse globals outvoting the one convection-resolving model is a
            // completely different situation from the reverse, and a flat list of
            // eleven rows hides which of those just happened.
            ForEach(PrecipModel.Family.allCases, id: \.self) { family in
                let rows = outlook.rows.filter { $0.model.family == family }
                if !rows.isEmpty {
                    if family != PrecipModel.Family.allCases.first {
                        Spacer().frame(height: 4)
                    }
                    familyHeading(family, rows: rows)
                    ForEach(rows) { row in modelRow(row, outlook: outlook) }
                }
            }
        }
    }

    /// The group's name and its own tally. A family that splits internally is
    /// worth seeing as "4 of 8" rather than being folded into the headline.
    private func familyHeading(_ family: PrecipModel.Family,
                               rows: [PrecipOutlook.Row]) -> some View {
        let wet = rows.count(where: \.isWet)
        return HStack(spacing: 6) {
            Text(family.heading.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.tertiary)
            if rows.count > 1 {
                Text("\(wet) of \(rows.count)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.quaternary)
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    private func modelRow(_ row: PrecipOutlook.Row, outlook: PrecipOutlook) -> some View {
        HStack(spacing: 8) {
            let stamp = outlook.stamp(row.model)
            Text(row.model.label)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(row.isWet ? .primary : .secondary)
                .frame(width: 52, alignment: .leading)
                .help("\(row.model.note)\n\(stamp.line())")

            HStack(spacing: 2) {
                ForEach(Array(row.inches.enumerated()), id: \.offset) { hour, value in
                    cell(value, time: outlook.times[safe: hour], model: row.model)
                }
            }

            // THE OBLIGED RELIEF, and useful in its own right. The ramp's light
            // end sits under 3:1 against the card — unavoidable for a heatmap —
            // so no cell is ever the only carrier of its value. Every row prints
            // its storm total, and every cell answers exactly on hover.
            Text(row.isWet ? WeatherAlmanac.inches(row.total) : "—")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(row.isWet ? .primary : .tertiary)
                .frame(width: 46, alignment: .trailing)

            // WHICH RUN, ON EVERY ROW. The models do not keep time together —
            // two rerun hourly, the globals every six hours and land hours
            // apart — so "4 of 11" is a vote between forecasts that knew
            // different things. NEXT is an estimate: this run's arrival plus
            // the model's cadence.
            Text(runLabel(stamp))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: Self.runWidth, alignment: .leading)
                .help(stamp.line())
            Text(stamp.next.map { When.moment($0) } ?? "—")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.quaternary)
                .frame(width: Self.runWidth, alignment: .leading)
                .help(stamp.nextPhrase() ?? "No schedule to estimate from")
        }
    }

    private static let runWidth: CGFloat = 92

    private func runLabel(_ stamp: SourceStamp) -> String {
        switch stamp.made {
        case .run(let d): return When.moment(d)
        default:          return "not published"
        }
    }

    /// Labelled every six hours rather than every hour: eighteen ticks in this
    /// width is a grey smear, and the axis is here to locate a column, not to be
    /// read off.
    private func hourAxis(_ outlook: PrecipOutlook) -> some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 52)
            HStack(spacing: 2) {
                ForEach(Array(outlook.times.enumerated()), id: \.offset) { i, time in
                    // A `Color.clear` takes the cell's flexible width and the
                    // label sits over it at natural size, so a label wider than
                    // one column overhangs instead of being truncated — the ticks
                    // stay aligned to the columns they name.
                    ZStack(alignment: .leading) {
                        Color.clear
                        if let label = axisLabel(outlook.times, i) {
                            Text(label)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Spacer().frame(width: 46)
            Text("RUN")
                .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.tertiary)
                .frame(width: Self.runWidth, alignment: .leading)
            Text("NEXT, EST.")
                .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.tertiary)
                .frame(width: Self.runWidth, alignment: .leading)
        }
        .frame(height: 11)
    }

    /// Every six hours, plus the column where the day turns over — named, so
    /// "2am" past midnight can't be read as this morning's. A six-hourly tick
    /// within three columns of the day mark gives way to it.
    private func axisLabel(_ times: [Date], _ i: Int) -> String? {
        let calendar = Calendar.current
        func isMidnight(_ j: Int) -> Bool {
            times.indices.contains(j) && calendar.component(.hour, from: times[j]) == 0
        }
        if i > 0, isMidnight(i) { return When.day(times[i]) }
        guard i % 6 == 0 else { return nil }
        if (1...3).contains(where: { isMidnight(i + $0) || (i - $0 > 0 && isMidnight(i - $0)) }) { return nil }
        return WeatherAlmanac.clock(calendar.component(.hour, from: times[i]))
    }

    private func cell(_ inches: Double?, time: Date?, model: PrecipModel) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(fill(inches))
            .overlay {
                // NO DATA IS NOT NO RAIN. HRRR stops at eighteen hours and the
                // globals run for days; a short model's empty columns have to read
                // as SILENT rather than as a confident forecast of nothing.
                if inches == nil {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.primary.opacity(0.12),
                                      style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
                }
            }
            .frame(height: 14)
            .frame(maxWidth: .infinity)
            .help(tooltip(inches, time: time, model: model))
    }

    private func tooltip(_ inches: Double?, time: Date?, model: PrecipModel) -> String {
        let when = time.map { When.moment($0) } ?? "—"
        guard let inches else { return "\(model.label) · \(when) — doesn't run this far" }
        return inches >= PrecipOutlook.measurable
            ? "\(model.label) · \(when) — \(WeatherAlmanac.inches(inches))"
            : "\(model.label) · \(when) — dry"
    }

    /// ONE HUE, DARKENING. `sqrt` rather than linear because hourly rainfall is
    /// heavily skewed: on a linear scale a 0.02″ drizzle hour and a dry hour are
    /// the same colour, and the only thing visible is the one cell that had a
    /// downpour. The interesting question is usually whether ANYTHING falls.
    private func fill(_ inches: Double?) -> Color {
        guard let inches, inches >= PrecipOutlook.measurable else {
            return Color.primary.opacity(inches == nil ? 0 : 0.05)
        }
        let heavy = 0.25
        let t = min(1, (inches / heavy).squareRoot())
        return Color(red: 0.165, green: 0.47, blue: 0.859)
            .opacity(0.38 + 0.62 * t)
    }

    // MARK: Footer

    private func footer(_ outlook: PrecipOutlook) -> some View {
        HStack(spacing: 10) {
            // The magnitude key. Identity needs no legend — the rows are labelled
            // — but an amount ramp is meaningless without one.
            HStack(spacing: 2) {
                Text("dry").font(.system(size: 9)).foregroundStyle(.tertiary)
                ForEach([0.0, 0.02, 0.06, 0.14, 0.25], id: \.self) { step in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fill(step))
                        .frame(width: 12, height: 8)
                }
                Text("\(WeatherAlmanac.inches(0.25))/hr").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(PrecipOutlookClient.credit) · fetched \(When.moment(outlook.fetched))")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}
