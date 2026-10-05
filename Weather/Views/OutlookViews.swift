//
//  OutlookViews.swift  (Weather)
//
//  The map's three forecast views — Storms (SPC's convective outlook),
//  Excessive rain (WPC's Excessive Rainfall Outlook) and Rain totals (WPC's
//  forecast accumulations) — drawn from the offices' own polygons over the
//  county lines. All the reading of those polygons is in WeatherKit's
//  `Outlooks.swift`; this file fetches, keeps, and explains.
//
//  THE LEGEND IS THE LESSON. A coloured map with a key that says "Slight" is
//  the display this app is trying not to be. So the card under the map leads
//  with where HOME is, says what that category means in the office's words, and
//  carries the one sentence that makes the whole map readable: what the
//  categories are a probability OF, or for rain totals, what kind of number
//  the total is. See [[weather-app-teaches-not-displays]].
//

import SwiftUI
import MapKit
import WeatherKit

// MARK: - Model

@MainActor
final class OutlookModel: ObservableObject {
    struct Key: Hashable {
        var product: OutlookProduct
        /// See `OutlookProduct.periods`.
        var period: Int
    }

    /// What we know about one outlook — including whether we know anything.
    /// Same rule as `HazardWatch`: a failed fetch never reads as an empty map.
    enum State {
        case loading
        case loaded(Outlook, fetched: Date)
        /// Carries the last good copy, if there was one, so a blip does not
        /// blank a map that was fine a minute ago.
        case failed(reason: String, last: Outlook?)
    }

    @Published private(set) var states: [Key: State] = [:]
    /// Each outlook's areas, projected for the map ONCE per issuance. `layers`
    /// is rebuilt on every SwiftUI pass — several a second while the radar
    /// model ticks behind it — and reprojecting thousands of points each time
    /// would be work done for a picture that has not changed.
    private var regionCache: [Key: RegionSet] = [:]

    private let client = OutlookClient(contact: "vane.weather.app")
    private var fetched: [Key: Date] = [:]

    func state(_ key: Key) -> State { states[key] ?? .loading }

    func outlook(_ key: Key) -> Outlook? {
        switch state(key) {
        case .loaded(let outlook, _): return outlook
        case .failed(_, let last): return last
        case .loading: return nil
        }
    }

    /// The outlook as the map draws it, or nil when there is nothing to draw.
    func regions(_ key: Key) -> RegionSet? {
        guard let outlook = outlook(key) else { return nil }
        let id = "\(key.product.rawValue)|\(key.period)|\(outlook.issued?.timeIntervalSince1970 ?? 0)|\(outlook.areas.count)"
        if let cached = regionCache[key], cached.id == id { return cached }
        // RAIN TOTALS ARE READ BY COLOUR, the outlooks by their edge. A band's
        // colour IS the amount, so it is filled more strongly and its edge is
        // a hairline; an outlook's line is the forecaster's boundary and is
        // what you place yourself against.
        let isAmount = key.product == .rainTotals
        let set = RegionSet(id: id, fillOpacity: isAmount ? 0.55 : 0.42,
                            strokeWidth: isAmount ? 0.6 : 1.5,
                            regions: outlook.areas.map { area in
            (rings: area.shape.rings.map { ring in
                ring.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
             },
             fill: area.fill.cgColor, stroke: area.stroke.cgColor)
        })
        regionCache[key] = set
        return set
    }

    /// Fetch if we have nothing, or what we have is older than the product's
    /// refresh interval. `force` is the Try again button.
    func load(_ key: Key, force: Bool = false) async {
        if !force, let when = fetched[key],
           Date().timeIntervalSince(when) < key.product.refreshInterval { return }
        if states[key] == nil { states[key] = .loading }
        do {
            let outlook = try await client.outlook(key.product, period: key.period)
            let now = Date()
            fetched[key] = now
            states[key] = .loaded(outlook, fetched: now)
        } catch is CancellationError {
            return
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            states[key] = .failed(reason: reason, last: outlook(key))
        }
    }

    /// Every day of a product, fetched together — so picking another day shows
    /// it at once instead of a "Loading…" in its place. They're small, and
    /// `load` skips any still fresh.
    func warm(_ product: OutlookProduct) async {
        await withTaskGroup(of: Void.self) { group in
            for period in product.periods {
                group.addTask { await self.load(Key(product: product, period: period)) }
            }
        }
    }

    /// Keep the chosen outlook current for as long as it is on screen.
    func keepCurrent(_ key: Key) async {
        while !Task.isCancelled {
            await load(key)
            try? await Task.sleep(for: .seconds(60))
        }
    }
}

/// The bundled county outlines, decoded once per launch and shared. See
/// `CountyBoundaries`.
@MainActor
final class CountyLines: ObservableObject {
    static let shared = CountyLines()

    @Published private(set) var counties: [County] = []
    @Published private(set) var lines: BoundarySet?
    private var started = false
    /// Which county a point is in, remembered — a scan of every county is too
    /// much to repeat on each SwiftUI pass for a home that never moves.
    private var located: [String: County?] = [:]

    func county(containing point: GeoPoint) -> County? {
        guard !counties.isEmpty else { return nil }
        let key = "\(point.latitude),\(point.longitude)"
        if let known = located[key] { return known }
        let found = CountyBoundaries.county(containing: point, in: counties)
        located[key] = found
        return found
    }

    func load() async {
        guard !started else { return }
        started = true
        // A quarter of a million points: decoded and projected off the main
        // thread, so opening the map never waits on them.
        let built = await Task.detached(priority: .utility) { () -> ([County], BoundarySet)? in
            guard let counties = try? CountyBoundaries.load() else { return nil }
            return (counties, BoundarySet(id: "counties", rings: counties.flatMap(\.rings)))
        }.value
        guard let built else { return }
        counties = built.0
        lines = built.1
    }
}

// MARK: - The legend

/// Under the map, in the place the radar's scrub strip takes: which forecast
/// this is, where home falls in it, and what the colours measure.
struct OutlookLegend: View {
    let product: OutlookProduct
    let period: Int
    let state: OutlookModel.State
    let home: GeoPoint?
    let homeCounty: County?
    let retry: () -> Void
    /// Inside `MapViewBar`: no card of its own, and the key — the header,
    /// swatches, explanation and issue time — only when the bar's ⓘ is on.
    /// Home's line, and anything gone wrong, always show.
    var inBar = false
    var showsKey = true

    @State private var explaining = false
    /// The bar's last answer, held up while the next day loads.
    @State private var lastBar: BarText?

    var body: some View {
        Group {
            if inBar && !showsKey {
                barLine
            } else {
                card
            }
        }
        .onChange(of: barText, initial: true) { _, new in
            if case .loading = state { return }
            lastBar = new
        }
        // Another product's words would be about a different map.
        .onChange(of: product) { _, _ in lastBar = nil }
    }

    /// THE BAR'S ONE BLOCK, THE SAME SIZE IN EVERY STATE: a headline, and two
    /// lines held for what it means. Loading, an expired forecast, an empty
    /// map and a failure each used to add or drop a line, and the bar jumped
    /// whenever a day was picked. Here they say themselves in those same
    /// three lines; the rest is behind the ⓘ.
    private var barLine: some View {
        // WHILE A DAY LOADS, THE LAST ONE STAYS UP, DIMMED. Swapping in a
        // "Loading…" line for the half second a day took made every pick
        // flash twice — out to the loading line, back to the answer.
        let loading: Bool = { if case .loading = state { return true } else { return false } }()
        let shown = loading ? (lastBar ?? barText) : barText
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "house.fill").font(.system(size: 11))
                .foregroundStyle(shown.colour)
            VStack(alignment: .leading, spacing: 1) {
                Text(shown.headline).font(.callout.weight(shown.weight)).lineLimit(1)
                Text(shown.meaning).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .contentTransition(.opacity)
            .opacity(loading && lastBar != nil ? 0.5 : 1)
            .animation(.easeOut(duration: 0.18), value: shown)
            Spacer(minLength: 0)
            if case .failed = state {
                Button("Try again", action: retry).buttonStyle(.borderless).font(.callout)
            }
        }
    }


    struct BarText: Equatable {
        var headline: String
        var meaning: String
        var colour: Color
        var weight: Font.Weight
        init(_ headline: String, _ meaning: String, _ colour: Color, _ weight: Font.Weight) {
            self.headline = headline; self.meaning = meaning; self.colour = colour; self.weight = weight
        }
    }

    private var barText: BarText {
        let place = homeCounty.map { "Home (\($0.name) County)" } ?? "Home"
        func read(_ outlook: Outlook) -> BarText {
            guard let home else { return BarText("Set your home to see where it falls", "", .secondary, .medium) }
            let category = outlook.category(at: home)
            let area = outlook.areas.last { $0.category == category }
            var meaning = category.map(\.meaning) ?? noRiskMeaning ?? ""
            if outlook.isExpired() { meaning = "This forecast's window has closed; a newer one hasn't loaded yet." }
            return BarText(homeHeadline(category), meaning, area.map { $0.stroke.color } ?? .secondary, .medium)
        }
        switch state {
        case .loading:
            return BarText("Loading \(product.issuer)'s \(product.label.lowercased()), \(product.periodName(period))…",
                           "", .secondary, .regular)
        case .loaded(let outlook, _):
            return read(outlook)
        case .failed(let reason, let last):
            if let last {
                var text = read(last)
                text.meaning = "Couldn't refresh: \(reason). Showing the last copy."
                return text
            }
            return BarText("Couldn't load \(product.issuer)'s \(product.label.lowercased()) · \(place)", reason, .orange, .medium)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsKey { header }
            switch state {
            case .loading:
                VStack(alignment: .leading, spacing: 1) {
                    Text("Loading \(product.issuer)'s \(product.label.lowercased()), \(product.periodName(period))…")
                        .font(.callout).foregroundStyle(.secondary)
                    // The home line's height, held, so the bar doesn't
                    // shrink and grow back each time a day is picked.
                    if inBar { Text("").font(.caption).lineLimit(2, reservesSpace: true) }
                }
                .padding(.leading, inBar ? 19 : 0)
            case .loaded(let outlook, _):
                content(outlook)
            case .failed(let reason, let last):
                failure(reason)
                if let last { content(last) }
            }
        }
        .mapCard(!inBar, maxWidth: 440)
        .padding(.horizontal, inBar ? 0 : 16)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(product.issuer) · \(product.label) · \(product.periodName(period))")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 8)
            if let window = window {
                Text(window).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// "today 8 AM – tomorrow 7 AM", in local time. The offices write their
    /// windows in UTC, which is correct and useless at the kitchen table.
    private var window: String? {
        let outlook: Outlook?
        switch state {
        case .loaded(let o, _): outlook = o
        case .failed(_, let last): outlook = last
        case .loading: outlook = nil
        }
        guard let from = outlook?.validFrom, let until = outlook?.validUntil else { return nil }
        return When.range(from, until)
    }

    @ViewBuilder private func content(_ outlook: Outlook) -> some View {
        if outlook.isExpired() {
            Label("This forecast's window has closed — a newer one hasn't loaded yet.",
                  systemImage: "clock.badge.exclamationmark")
                .font(.caption).foregroundStyle(.orange)
        }
        homeLine(outlook)
        if outlook.areas.isEmpty {
            Text(emptyMap).font(.caption).foregroundStyle(.secondary)
        } else if showsKey {
            if product == .rainTotals {
                RainTotalRamp(outlook: outlook, home: home.flatMap { outlook.category(at: $0) })
            } else {
                swatches(outlook)
            }
        }
        if showsKey {
            explanation
            // Issued when, and when the office is due to reissue.
            Text(outlook.stamp.line())
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// WHERE YOU ARE FIRST. The map shows the country; this says which colour
    /// you are standing in, which a person would otherwise have to find by eye.
    @ViewBuilder private func homeLine(_ outlook: Outlook) -> some View {
        if let home {
            let category = outlook.category(at: home)
            let area = outlook.areas.last { $0.category == category }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "house.fill").font(.system(size: 11))
                    .foregroundStyle(area.map { $0.stroke.color } ?? .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(homeHeadline(category)).font(.callout.weight(.medium))
                    // A rain band has no meaning beyond its amount, which the
                    // headline already says.
                    let meaning = category.map(\.meaning) ?? noRiskMeaning ?? ""
                    if inBar {
                        // Two lines held, so changing day never changes the
                        // bar's height.
                        Text(meaning).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2, reservesSpace: true)
                    } else if !meaning.isEmpty {
                        Text(meaning).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func homeHeadline(_ category: OutlookCategory?) -> String {
        let place = homeCounty.map { "Home (\($0.name) County)" } ?? "Home"
        guard let category else {
            return product == .rainTotals ? "\(place): no measurable rain" : "\(place): outside every area"
        }
        var line = "\(place): \(category.scale(of: product))"
        if let threshold = category.threshold { line += " — at least \(threshold)" }
        return line
    }

    private var noRiskMeaning: String? {
        switch product {
        // SPC's general-thunder line is drawn at a 10% chance of thunder.
        case .severeStorms:  return "Less than a 10% chance of thunder near you"
        case .excessiveRain: return "Rain exceeding flash flood guidance is not expected near you"
        // WPC's lowest band starts at a hundredth of an inch.
        case .rainTotals:    return "Less than a hundredth of an inch forecast"
        }
    }

    private var emptyMap: String {
        switch product {
        case .severeStorms:  return "No thunderstorms are forecast anywhere in the country."
        case .excessiveRain: return "No area is at risk of excessive rain."
        case .rainTotals:    return "No measurable rain is forecast anywhere in the country."
        }
    }

    private func swatches(_ outlook: Outlook) -> some View {
        // Colours from the areas actually drawn, so the key can never disagree
        // with the map it sits under.
        let colours = Dictionary(outlook.areas.map { ($0.category.code, $0) }, uniquingKeysWith: { a, _ in a })
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { swatchRow(outlook.present, colours) }
            VStack(alignment: .leading, spacing: 3) { swatchRow(outlook.present, colours) }
        }
    }

    @ViewBuilder
    private func swatchRow(_ categories: [OutlookCategory], _ colours: [String: OutlookArea]) -> some View {
        ForEach(categories) { category in
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill((colours[category.code]?.fill ?? category.fill).color.opacity(0.75))
                    .overlay(RoundedRectangle(cornerRadius: 2)
                        .strokeBorder((colours[category.code]?.stroke ?? category.stroke).color, lineWidth: 1))
                    .frame(width: 12, height: 9)
                Text(category.name).font(.caption)
            }
            .fixedSize()
        }
    }

    /// The one sentence that makes the categories mean something, one tap
    /// away — it is long, and on the fourth look it is known.
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { explaining.toggle() }
            } label: {
                Label(explaining ? explainTitle : explainTitle + "?",
                      systemImage: explaining ? "chevron.down" : "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            if explaining {
                Text(product.measures)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if product != .rainTotals {
                    Text("The category is a probability, not a strength: “Moderate” means "
                         + "the dangerous version is more LIKELY, not that it will be moderate.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var explainTitle: String {
        product == .rainTotals ? "What kind of number is this" : "What do the categories measure"
    }

    private func failure(_ reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Couldn't reach \(product.issuer)").font(.callout)
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Try again", action: retry).buttonStyle(.borderless).font(.callout)
        }
    }
}

/// Rain totals' key: the bands on today's map as one continuous ramp, each
/// labelled with its floor in inches, and home's band marked. Fifteen named
/// swatches would be a table; an amount reads better as a scale.
private struct RainTotalRamp: View {
    let outlook: Outlook
    let home: OutlookCategory?

    var body: some View {
        let bands = outlook.present
        HStack(alignment: .top, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(bands) { band in
                    VStack(spacing: 2) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 7))
                            .opacity(band == home ? 1 : 0)
                        Rectangle()
                            .fill(band.fill.color.opacity(0.8))
                            .frame(height: 9)
                            .overlay(Rectangle().strokeBorder(Color.primary.opacity(band == home ? 0.9 : 0),
                                                              lineWidth: 1.5))
                        Text(band.code)
                            .font(.system(size: 8)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Text("in").font(.caption2).foregroundStyle(.secondary).padding(.top, 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rain bands from \(bands.first?.name ?? "") to \(bands.last?.name ?? "")")
    }
}
