//
//  MapControls.swift
//
//  THE MAP'S CONTROLS, ONE JOB PER PLACE.
//
//  They used to be one floating panel: a radio list of views, the chosen
//  view's settings opened inline under it (so everything below jumped when you
//  switched), the context layers, Recentre, and a column of grey notes down the
//  right that mixed data ages, settings and statuses. It worked and it read as
//  a form. Now:
//
//   · TOP LEFT, what you're looking at — `MapViewPicker`, one menu grouped by
//     kind: what's happening now, what's forecast, and Texas's own.
//   · TOP RIGHT, the map's own tools — `MapTools`: Layers and Recentre. They
//     belong to the map, not to a view, so they don't change when it does.
//   · ALONG THE BOTTOM, everything about the view — `MapViewBar`: home's line
//     on top, the colour key behind an ⓘ, and one row of controls with the
//     view's settings on the left and its WHEN on the right. Every view has a
//     when: a loop to scrub, a forecast day to pick, or a snapshot's date.
//
//  The bar keeps that shape on every view, so switching changes what is in
//  it, never where things are.
//
//  On a phone the old corner button and sheet stay; this is the layout for a
//  window with room for a map AND its controls — the Mac and an iPad.
//

import SwiftUI
import CoreLocation
import WeatherKit

// MARK: - Shared card

extension View {
    /// The material card every map control sits on. `on` false draws nothing,
    /// for a piece that sits inside a card already.
    @ViewBuilder func mapCard(_ on: Bool = true, maxWidth: CGFloat) -> some View {
        if on {
            self
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        } else {
            self
        }
    }
}

// MARK: - Top left: the view

/// Which picture the map shows: a button naming it, which OPENS INTO the list
/// of views rather than raising a menu beside it. A system menu read as a
/// second, separate control; this is the same card, grown.
///
/// Grouped by what KIND of picture each is — the old flat list never said
/// that radar is now and Storms is a forecast — and every row says what the
/// view answers and what it would show right now, so a view can be judged
/// before it's chosen.
struct MapViewPicker: View {
    @Binding var surface: MapSurface
    @Binding var expanded: Bool
    let captions: [MapSurface: String]

    @State private var hovered: MapSurface?

    private static let groups: [(name: String, views: [MapSurface])] = [
        ("Now", [.radar, .cloud]),
        ("Forecast", [.storms, .excessiveRain, .rainTotals]),
        ("Texas", [.fire]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider().padding(.horizontal, 10)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.groups, id: \.name) { group in
                        Text(group.name.uppercased())
                            .font(.system(size: 10, weight: .semibold)).tracking(0.7)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 3)
                        ForEach(group.views) { row($0) }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: expanded ? 320 : nil, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .fixedSize(horizontal: !expanded, vertical: true)
        #if os(macOS)
        // Escape closes it, as it would a menu.
        .onExitCommand { close() }
        #endif
    }

    private var header: some View {
        Button { withAnimation(.spring(duration: 0.28, bounce: 0.12)) { expanded.toggle() } } label: {
            HStack(spacing: 9) {
                Image(systemName: surface.symbol)
                    .font(.system(size: 15))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(surface.label).font(.headline)
                    Text(surface.question).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View: \(surface.label)")
        .accessibilityHint(expanded ? "Close the list of views" : "Choose what the map shows")
    }

    private func row(_ view: MapSurface) -> some View {
        let chosen = view == surface
        return Button {
            surface = view
            close()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: view.symbol)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .foregroundStyle(chosen ? Color.accentColor : .primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(view.label).font(.callout.weight(chosen ? .semibold : .regular))
                    Text(view.question).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let caption = captions[view] {
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(
                chosen ? Color.accentColor.opacity(0.16)
                : hovered == view ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? view : (hovered == view ? nil : hovered) }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func close() {
        withAnimation(.spring(duration: 0.24, bounce: 0.1)) { expanded = false }
    }
}

// MARK: - Top right: the map's tools

/// Layers and Recentre — the map's, not any one view's. Layers is a menu of
/// checkmarks rather than a list on screen: they're set once and left.
struct MapTools: View {
    let layers: [MapLayer]
    @Binding var context: Set<String>
    /// Warnings out, for the badge — so "none" never needs writing anywhere.
    let warningCount: Int
    let recenter: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let recenter {
                Button(action: recenter) {
                    Image(systemName: "scope")
                        .font(.system(size: 14))
                        .frame(width: 18, height: 18)
                        .toolCard()
                }
                .buttonStyle(.plain)
                .keyboardShortcut("0", modifiers: .command)
                .help("Recentre on home (⌘0)")
                .accessibilityLabel("Recentre on home")
            }
            Menu {
                ForEach(layers) { layer in
                    Toggle(isOn: binding(for: layer.id)) {
                        Label {
                            Text(layer.name)
                            if let caption = layer.caption { Text(caption) }
                        } icon: {
                            Image(systemName: layer.symbol)
                        }
                    }
                }
            } label: {
                Label("Layers", systemImage: "square.3.layers.3d")
                    .font(.callout.weight(.medium))
                    .toolCard()
                    .overlay(alignment: .topTrailing) {
                        if warningCount > 0 && context.contains("warnings") {
                            Text("\(warningCount)")
                                .font(.system(size: 10, weight: .bold)).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.red, in: Capsule())
                                .offset(x: 5, y: -5)
                                .accessibilityLabel("\(warningCount) warnings out")
                        }
                    }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { context.contains(id) },
                set: { on in if on { context.insert(id) } else { context.remove(id) } })
    }
}

private extension View {
    func toolCard() -> some View {
        padding(.horizontal, 11).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Along the bottom: the view's bar

/// Home's line and the key on top, then one row: the view's settings on the
/// left, its time on the right. Any part a view hasn't got is left out —
/// Fire has no time to scrub, the forecasts have no settings — but the parts
/// it has are always in the same place.
struct MapViewBar<Top: View, Settings: View, When: View>: View {
    /// Whether the top part has a key to open. Drawn as an ⓘ at the bar's top
    /// right; the parts read `keyOpen` and show their key when it's on.
    let hasKey: Bool
    @Binding var keyOpen: Bool
    let hasTop: Bool
    let hasSettings: Bool
    @ViewBuilder var top: Top
    @ViewBuilder var settings: Settings
    @ViewBuilder var when: When

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if hasTop {
                HStack(alignment: .top, spacing: 10) {
                    top.frame(maxWidth: .infinity, alignment: .leading)
                    if hasKey { infoButton }
                }
                Divider()
            }
            // ONE HEIGHT, WHATEVER IS IN IT. A scrub strip, a sweep's two
            // lines and a "loading" line are all different heights, and the
            // bar jumped every time a setting swapped one for another.
            HStack(alignment: .center, spacing: 12) {
                if hasSettings {
                    HStack(spacing: 8) { settings }
                        .fixedSize()
                    Divider().frame(height: 22)
                }
                when.frame(maxWidth: .infinity)
            }
            .frame(height: Self.controlsHeight)
        }
        .mapCard(maxWidth: 760)
        .padding(.horizontal, 16)
    }

    static var controlsHeight: CGFloat { 40 }

    private var infoButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { keyOpen.toggle() }
        } label: {
            Image(systemName: keyOpen ? "info.circle.fill" : "info.circle")
                .font(.system(size: 15))
                .foregroundStyle(keyOpen ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(keyOpen ? "Hide the colours" : "What the colours mean")
        .accessibilityLabel(keyOpen ? "Hide the key" : "Show the key")
    }
}

/// A forecast's days as the bar's WHEN: the window the chosen day covers, in
/// local time, and the days to choose from.
struct ForecastDayPicker: View {
    let product: OutlookProduct
    @Binding var period: Int
    /// "today 7 AM – tomorrow 7 AM", when the outlook has loaded.
    let window: String?

    /// The last window shown, held while the next day loads — see
    /// `OutlookLegend.barLine`.
    @State private var lastWindow: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(window ?? lastWindow ?? product.periodName(period))
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1)
                .opacity(window == nil && lastWindow != nil ? 0.5 : 1)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.18), value: window)
                .onChange(of: window, initial: true) { _, new in if let new { lastWindow = new } }
            Spacer(minLength: 8)
            BarChoices(options: product.periods.map { p in
                BarOption(value: p, icon: nil, text: name(p), title: title(p), detail: detail(p))
            }, selection: $period)
        }
    }

    /// Today and Tomorrow where the day is a day; rain totals RUN, so theirs
    /// say "through".
    private func name(_ p: Int) -> String {
        switch product {
        case .rainTotals: return p == 1 ? "Day 1" : "1–\(p)"
        default:
            switch p {
            case 1: return "Today"
            case 2: return "Tomorrow"
            default: return "Day \(p)"
            }
        }
    }

    private func title(_ p: Int) -> String {
        product == .rainTotals ? product.periodName(p) : "\(product.issuer) day \(p)"
    }

    private func detail(_ p: Int) -> String {
        switch product {
        case .rainTotals:
            return p == 1 ? "The rain forecast for the first 24 hours, from 7 AM."
                          : "All the rain forecast from 7 AM today through day \(p), added up."
        default:
            return "The \(p == 1 ? "first" : p == 2 ? "second" : "third") 24 hours of the outlook, 7 AM to 7 AM. Further out is less certain, so the areas are broader."
        }
    }
}

// MARK: - Choices in the bar

/// One option of a `BarChoices`: an icon or a short word on the chip, and a
/// title and a sentence for the hint that explains it.
struct BarOption<Value: Hashable>: Identifiable {
    let value: Value
    let icon: String?
    let text: String?
    let title: String
    let detail: String
    var id: Value { value }
}

/// THE BAR'S OWN CONTROL. A system segmented control is a form control, and
/// at the bottom of a map it read like one; these are chips in the bar's own
/// material — an icon where an icon can carry it, a word where it can't. An
/// icon explains itself above the chip while the pointer rests on it; a word
/// doesn't need to.
///
/// EVERY CHIP KEEPS ITS SIZE. Only the colour says which is chosen, so
/// choosing never moves anything.
struct BarChoices<Value: Hashable>: View {
    let options: [BarOption<Value>]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let chosen = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: 5) {
                        if let icon = option.icon {
                            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                                .frame(width: 18, height: 18)
                        }
                        // One weight for chosen and not: bold is wider, and a
                        // chip that grows when chosen shoved the whole group.
                        if let text = option.text {
                            Text(text).font(.callout.weight(.medium))
                        }
                    }
                    .padding(.horizontal, option.text == nil ? 7 : 10).padding(.vertical, 4)
                    .foregroundStyle(chosen ? Color.accentColor : .secondary)
                    .background(Capsule().fill(chosen ? Color.accentColor.opacity(0.18) : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                // Only an icon needs explaining; a chip that says "Today"
                // has already said it.
                .barHint(option.text == nil ? option.title : nil, option.detail)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Hints

extension View {
    /// A title and a sentence above the control while the pointer rests on
    /// it — sooner and fuller than a tooltip. Nil title: no hint.
    ///
    /// DRAWN IN THE WINDOW, NOT A POPOVER. A popover is its own window, and
    /// macOS spends the first click outside one on closing it — so with the
    /// hint open, clicking the very chip it described did nothing, and it took
    /// a second click. This never takes a click: the pointer passes through it.
    func barHint(_ title: String?, _ detail: String) -> some View {
        modifier(BarHint(title: title, detail: detail))
    }
}

private struct BarHint: ViewModifier {
    let title: String?
    let detail: String

    @State private var showing = false
    @State private var pending: Task<Void, Never>?
    /// The hint's own height, measured, so it can sit exactly above the
    /// control. An alignment guide was meant to do this and didn't take: the
    /// hint drew down over the chips instead.
    @State private var hintHeight: CGFloat = 0

    func body(content: Content) -> some View {
        if let title {
            content
                .onHover { inside in
                    pending?.cancel()
                    if inside {
                        // A beat first, so sweeping across the bar doesn't
                        // flash a hint at every chip passed over.
                        pending = Task {
                            try? await Task.sleep(for: .milliseconds(450))
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeOut(duration: 0.12)) { showing = true }
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.1)) { showing = false }
                    }
                }
                // A click is a choice made; the hint has done its job. It
                // doesn't consume the click — the button still gets it.
                .simultaneousGesture(TapGesture().onEnded { pending?.cancel(); showing = false })
                .overlay(alignment: .top) {
                    if showing {
                        hint(title)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { hintHeight = $0 }
                            .offset(y: -(hintHeight + 10))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .zIndex(showing ? 1 : 0)
        } else {
            content
        }
    }

    private func hint(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(width: 250, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .fixedSize()
    }
}

// MARK: - Which radar, in the bar

/// The radar site, as the bar's chip: an antenna and the four letters, which
/// open UPWARD into the list of sites — the same card-grows treatment as the
/// view picker, and up because the bar sits at the bottom of the window,
/// where a list opening down ran off it.
struct RadarSiteChip: View {
    @Binding var choice: String
    @Binding var open: Bool
    let home: CLLocationCoordinate2D?

    @State private var listHeight: CGFloat = 0

    private var site: RadarSite? {
        RadarSites.site(choice) ?? home.flatMap {
            RadarSites.nearest(latitude: $0.latitude, longitude: $0.longitude).first
        }
    }

    var body: some View {
        Button { withAnimation(.spring(duration: 0.24, bounce: 0.1)) { open.toggle() } } label: {
            HStack(spacing: 5) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .medium))
                Text(site?.id ?? "----").font(.callout.weight(.medium)).monospaced()
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 0 : 180))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(open ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
            .foregroundStyle(open ? Color.accentColor : .primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // No hint while the list is open: the list says it all.
        .barHint(open ? nil : hintTitle, hintDetail)
        .overlay(alignment: .topLeading) {
            if open {
                RadarSiteList(choice: $choice, home: home) {
                    withAnimation(.spring(duration: 0.22, bounce: 0.1)) { open = false }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                .offset(x: -6, y: -(listHeight + 10))
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .zIndex(open ? 2 : 0)
        .accessibilityLabel("Radar: \(site.map { "\($0.id), \($0.name)" } ?? "none chosen")")
    }

    private var hintTitle: String {
        site.map { "\($0.id) · \($0.name)" } ?? "Choose a radar"
    }

    private var hintDetail: String {
        guard let site else { return "Set your home to use the nearest radar." }
        let how = choice == "auto" ? "The nearest radar to home" : "Chosen by you"
        let miles = home.map { Int(site.distance(toLatitude: $0.latitude, longitude: $0.longitude) / 1609.34) }
        return miles.map { "\(how), \($0) miles away. Click to pick another." } ?? "\(how). Click to pick another."
    }
}

/// The sites to choose from: a search on top, and under it the few nearest
/// home — or, once something is typed, what matches, in the same space.
///
/// THE NEAREST FEW, NOT ALL 159, up front. Past about the fifth-closest the
/// radar is too far away to see anything low over you — at 250 km the 0.5°
/// beam is 5 km up, above most rain — so the full list is for the day you're
/// watching somebody else's weather, and it's a search rather than a scroll.
///
/// ONE SIZE WHILE IT'S OPEN. Results take the nearby list's place at its
/// height, so typing never moves the card.
///
/// NEAREST IS A TAG, NOT A SECOND ROW. "Nearest to home" and "KDYX" were two
/// rows naming one radar; now the nearest carries a tag, and choosing it
/// means "follow the nearest" — the automatic choice that moves if home does.
private struct RadarSiteList: View {
    @Binding var choice: String
    let home: CLLocationCoordinate2D?
    let close: () -> Void

    @State private var query = ""
    @State private var hovered: String?
    @FocusState private var searchFocused: Bool

    private static let rowHeight: CGFloat = 32
    private static let rows = 6

    private func miles(_ site: RadarSite) -> Int? {
        home.map { Int(site.distance(toLatitude: $0.latitude, longitude: $0.longitude) / 1609.34) }
    }

    private var nearby: [RadarSite] {
        guard let home else { return [] }
        return RadarSites.nearest(latitude: home.latitude, longitude: home.longitude, count: 5)
    }

    /// A site chosen from the search, not among the nearby — shown first, so
    /// the list always has the radar on screen in it.
    private var chosenElsewhere: RadarSite? {
        guard choice != "auto", let site = RadarSites.site(choice),
              !nearby.contains(site) else { return nil }
        return site
    }

    private var matches: [RadarSite] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let found = RadarSites.all.filter {
            $0.id.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q)
        }
        // Nearest first when home is known, so "Houston" finds the one you mean.
        guard let home else { return found }
        return found.sorted {
            $0.distance(toLatitude: home.latitude, longitude: home.longitude)
                < $1.distance(toLatitude: home.latitude, longitude: home.longitude)
        }
    }

    private func isChosen(_ site: RadarSite) -> Bool {
        choice == site.id || (choice == "auto" && site == nearby.first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty && !nearby.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        if let chosenElsewhere {
                            row(chosenElsewhere, tag: nil)
                        }
                        Text("NEAR HOME")
                            .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 4)
                        ForEach(Array(nearby.enumerated()), id: \.element.id) { index, site in
                            row(site, tag: index == 0 ? "nearest" : nil)
                        }
                    }
                } else if matches.isEmpty {
                    Text("No radar matches “\(query)”")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 8)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(matches) { site in
                                row(site, tag: site == nearby.first ? "nearest" : nil)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                }
            }
            .frame(height: Self.rowHeight * CGFloat(Self.rows + (chosenElsewhere == nil ? 0 : 1)),
                   alignment: .top)
        }
        .padding(8)
        .frame(width: 340, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .onAppear { searchFocused = true }
        #if os(macOS)
        .onExitCommand(perform: close)
        #endif
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search all \(RadarSites.all.count) radars", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
                .onSubmit {
                    // Return takes the top match — the nearest one that fits.
                    if let first = matches.first, !query.isEmpty { pick(first) }
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
    }

    private func pick(_ site: RadarSite) {
        choice = site == nearby.first ? "auto" : site.id
        close()
    }

    private func row(_ site: RadarSite, tag: String?) -> some View {
        let chosen = isChosen(site)
        return Button { pick(site) } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(chosen ? 1 : 0)
                    .frame(width: 12)
                Text(site.id)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .foregroundStyle(chosen ? Color.accentColor : .secondary)
                Text(site.name).font(.callout).lineLimit(1)
                if let tag {
                    Text(tag)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.09)))
                }
                Spacer(minLength: 8)
                if let m = miles(site) {
                    Text("\(m) mi").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 7).fill(
                chosen ? Color.accentColor.opacity(0.14)
                : hovered == site.id ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? site.id : (hovered == site.id ? nil : hovered) }
        .accessibilityLabel("\(site.id), \(site.name)\(tag.map { ", \($0)" } ?? "")")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
