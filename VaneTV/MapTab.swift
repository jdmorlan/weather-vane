//
//  MapTab.swift  (tvOS)
//
//  The map, full screen: the radar, the storm and excessive rain outlooks, and
//  how much rain is expected over the coming week.
//
//  IT OPENS ON RADAR, every time you come to it. On the Mac the map opens on
//  the storm outlook, because there you are usually planning. A television gets
//  switched on because the weather has already turned, and the question then is
//  what is out there right now.
//
//  TWO MENUS IN THE BOTTOM-LEFT CORNER, not a page to choose from first and
//  not rows of buttons. A chooser page put a press in front of the common case
//  and a Back between every comparison. Rows of pills — four views, then four
//  ranges or five periods under them — covered the bottom of the map and read
//  as a strip of stickers. Each menu shows what is chosen and opens tvOS's own
//  list when pressed: the view, the zoom, and — for an outlook — the day, or
//  for the rain how far the running total reaches, the way the offices issue
//  each.
//
//  ONE ZOOM FOR EVERY VIEW, kept when you switch between them, so the question
//  "is the rain I can see inside the storm-risk area" is two pictures of the
//  same place. The radar's four ranges plus a Wide one, because an outlook
//  covers several states and 150 miles shows only a corner of it. That leaves the bottom-right for the legend. A `Menu`,
//  not a bare `Picker`: a segmented picker is a focus container on tvOS that
//  captures left and right and cannot be swiped out of; a menu is one button
//  that opens a list. Four views
//  because those are the questions asked from a sofa; cloud and fire stay on
//  the Mac.
//
//  THE MAP IS NOT INSIDE THE TAB. It is one view behind the whole tab view,
//  shown and running only while Map is selected (see `TVRadarMap`), and the
//  tab above it draws nothing but the controls. Measured on an Apple TV 4K:
//  with the map inside the tab, leaving it cost 340 MB, then 800 MB, in a
//  single second — the tab switch tore down or snapshotted a full-screen 4K
//  MapKit view — and tvOS killed the app at 1.3 GB. Kept alive behind the
//  tabs, a switch builds and destroys nothing, and the loop is ready when you
//  come back.
//
//  The camera never moves on its own: there is no pointer to pan with, and a
//  remote's swipe belongs to the focus engine.
//

import SwiftUI
import MapKit
import WeatherKit

/// What the map is showing.
enum TVMapLayer: Hashable, CaseIterable {
    case radar, storms, excessiveRain, rainTotals

    var label: String {
        switch self {
        case .radar:         return "Radar"
        case .storms:        return "Severe storms"
        case .excessiveRain: return "Excessive rain outlook"
        case .rainTotals:    return "Rain totals"
        }
    }

    var symbol: String {
        switch self {
        case .radar:         return "dot.radiowaves.left.and.right"
        case .storms:        return "cloud.bolt.fill"
        case .excessiveRain: return "cloud.heavyrain.fill"
        case .rainTotals:    return "drop.fill"
        }
    }

    /// What the second menu offers: days for the outlooks, running totals for
    /// the rain. Empty for the radar, which has ranges instead.
    var periods: [Int] {
        switch self {
        case .radar:                  return []
        case .storms, .excessiveRain: return OutlookProduct.severeStorms.periods
        case .rainTotals:             return OutlookProduct.rainTotals.periods
        }
    }

    /// Where the second menu starts. The rain totals open on the whole week,
    /// because the week is the question they answer.
    var defaultPeriod: Int { self == .rainTotals ? 7 : 1 }

}

/// How much of the map is on screen, for every view. See the header.
enum TVMapZoom: String, CaseIterable {
    case overhead, close, nearby, regional, wide

    /// Metres. The radar's own ranges (see `RadarRange`), then Wide: several
    /// states, where the outlooks' risk areas and the week's rain are drawn.
    var radius: Double {
        switch self {
        case .overhead: return RadarRange.overhead.radius
        case .close:    return RadarRange.close.radius
        case .nearby:   return RadarRange.nearby.radius
        case .regional: return RadarRange.regional.radius
        case .wide:     return 650_000
        }
    }

    var label: String {
        switch self {
        case .overhead: return RadarRange.overhead.label
        case .close:    return RadarRange.close.label
        case .nearby:   return RadarRange.nearby.label
        case .regional: return RadarRange.regional.label
        case .wide:     return "Wide"
        }
    }

    /// How far the picture reaches, in the units the question is asked in.
    var miles: String {
        switch self {
        case .overhead: return "7 mi"
        case .close:    return "19 mi"
        case .nearby:   return "56 mi"
        case .regional: return "150 mi"
        case .wide:     return "400 mi"
        }
    }
}

/// The map itself, which lives BEHIND the tab view rather than inside the Map
/// tab. See the header.
struct MapBackdrop: View {
    @ObservedObject var radar: RadarModel
    @ObservedObject var hazards: TVHazardModel
    @ObservedObject var storms: StormOutlookModel
    @ObservedObject var totals: TVRainTotalsModel
    @ObservedObject var lines: TVBoundaries
    let home: CLLocationCoordinate2D?
    let range: TVMapZoom
    let layer: TVMapLayer
    let day: Int
    /// Whether the Map tab is showing. Off it, the map is hidden and paused.
    let isActive: Bool

    var body: some View {
        if let home {
            ZStack {
                TVRadarMap(center: home,
                           radiusMeters: range.radius,
                           radar: radar, hazards: hazards.drawable,
                           coverage: layer == .radar ? radar.coverage : nil,
                           isActive: isActive,
                           showsRadar: layer == .radar,
                           outlook: layer == .rainTotals ? totals.totals[day]
                                                         : storms.outlook(for: layer, day: day),
                           counties: lines.counties, stateOutline: lines.outline)
                    .focusable(false)
                Circle().stroke(.white, lineWidth: 5).frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.7), radius: 5)
                    .overlay { Circle().fill(.white).frame(width: 10, height: 10) }
            }
            .opacity(isActive ? 1 : 0)
            .ignoresSafeArea()
        }
    }
}

extension StormOutlookModel {
    /// The outlook a map layer draws for a day, or nil for the radar or when
    /// that day's has not loaded.
    func outlook(for layer: TVMapLayer, day: Int) -> Outlook? {
        switch layer {
        case .radar, .rainTotals: return nil
        case .storms:             return categorical.first { $0.period == day }
        case .excessiveRain:      return flood.first { $0.period == day }
        }
    }
}

/// WPC's rain totals, fetched only while the view is up. A seven-day total is
/// half a megabyte even simplified, and nothing else on the TV needs it.
@MainActor
final class TVRainTotalsModel: ObservableObject {
    @Published private(set) var totals: [Int: Outlook] = [:]
    @Published private(set) var failure: String?
    @Published private(set) var loading: Set<Int> = []
    private var fetched: [Int: Date] = [:]
    private let client = OutlookClient(contact: "vane.weather.app")

    func load(period: Int) async {
        if let at = fetched[period],
           Date().timeIntervalSince(at) < OutlookProduct.rainTotals.refreshInterval { return }
        guard !loading.contains(period) else { return }
        loading.insert(period)
        defer { loading.remove(period) }
        do {
            totals[period] = try await client.outlook(.rainTotals, period: period)
            fetched[period] = Date()
            failure = nil
        } catch {
            // The last good copy stays on the map.
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// What the Map tab itself draws: only the controls, over a clear background,
/// so the backdrop shows through.
struct MapTab: View {
    @ObservedObject var radar: RadarModel
    @ObservedObject var storms: StormOutlookModel
    @ObservedObject var totals: TVRainTotalsModel
    let hasHome: Bool
    let home: GeoPoint?
    /// "auto" or an ICAO, as `StormSurface` stores it.
    @Binding var radarSite: String
    @Binding var range: TVMapZoom
    @Binding var layer: TVMapLayer
    @Binding var day: Int

    var body: some View {
        if hasHome {
            // The radar's age is up in the tab bar's row (`RadarClockPill`),
            // which leaves this corner to the menus.
            HStack(alignment: .bottom, spacing: 16) {
                viewMenu
                zoomMenu
                if layer == .radar { siteMenu } else { periodMenu }
                Spacer(minLength: 40)
                if layer != .radar { outlookCard }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(52)
            .task(id: layer == .rainTotals ? day : 0) {
                if layer == .rainTotals { await totals.load(period: day) }
            }
        } else {
            Text("Set a home location to see the map.")
                .font(.system(size: 28)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Menus

    private var viewMenu: some View {
        Menu {
            Picker("Map", selection: $layer) {
                ForEach(TVMapLayer.allCases, id: \.self) { l in
                    Label(l.label, systemImage: l.symbol).tag(l)
                }
            }
        } label: {
            MenuLabel(symbol: layer.symbol, text: layer.label)
        }
    }

    private var zoomMenu: some View {
        Menu {
            Picker("Zoom", selection: $range) {
                ForEach(TVMapZoom.allCases, id: \.self) { z in
                    Text("\(z.label) · \(z.miles)").tag(z)
                }
            }
        } label: {
            MenuLabel(symbol: "scope", text: range.label)
        }
    }

    /// Which radar. THE NEAREST FEW, as on the Mac: past about the fifth-closest
    /// site the beam is too high over home to see the rain under it. Every site
    /// is one level down, for watching somebody else's weather.
    private var siteMenu: some View {
        let nearby: [(site: RadarSite, miles: Int)] = home.map { h in
            RadarSites.nearest(latitude: h.latitude, longitude: h.longitude, count: 5).map {
                ($0, Int(($0.distance(toLatitude: h.latitude, longitude: h.longitude) / 1609.34).rounded()))
            }
        } ?? []
        let chosen = RadarSites.site(radarSite)
        let label = chosen.map { "\($0.id) · \($0.name)" }
            ?? nearby.first.map { "Nearest · \($0.site.id)" } ?? "Radar"
        return Menu {
            Picker("Radar", selection: $radarSite) {
                if let nearest = nearby.first {
                    Text("Nearest to home (\(nearest.site.id))").tag("auto")
                }
                ForEach(nearby, id: \.site.id) { entry in
                    Text("\(entry.site.id) · \(entry.site.name) · \(entry.miles) mi").tag(entry.site.id)
                }
            }
            Menu("All sites") {
                Picker("All sites", selection: $radarSite) {
                    ForEach(RadarSites.all) { site in
                        Text("\(site.id) · \(site.name)").tag(site.id)
                    }
                }
            }
        } label: {
            MenuLabel(symbol: "antenna.radiowaves.left.and.right", text: label)
        }
    }

    private var periodMenu: some View {
        Menu {
            Picker(layer == .rainTotals ? "Total" : "Day", selection: $day) {
                ForEach(layer.periods, id: \.self) { p in
                    Text(periodName(p)).tag(p)
                }
            }
        } label: {
            MenuLabel(symbol: "calendar", text: periodName(day))
        }
    }

    // MARK: Legend

    /// What the colours mean, and what they mean for home — the map alone
    /// shows where the risk is, not whether you are in it.
    @ViewBuilder private var outlookCard: some View {
        let outlook = layer == .rainTotals ? totals.totals[day] : storms.outlook(for: layer, day: day)
        VStack(alignment: .leading, spacing: 12) {
            if let outlook {
                if outlook.areas.isEmpty {
                    Text(layer == .rainTotals ? "No rain expected anywhere on the map."
                                              : "Nothing outlooked anywhere on the map.")
                        .foregroundStyle(.secondary)
                } else if layer == .rainTotals {
                    totalsHome(outlook)
                    TotalsRamp(categories: outlook.present)
                } else {
                    homeLine(outlook)
                    // The categories on this map, lowest to highest.
                    HStack(spacing: 8) {
                        ForEach(outlook.present.suffix(4)) { c in
                            Text(c.name)
                                .font(.system(size: 19, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(Capsule().fill(c.fill.color.opacity(0.75)))
                                .overlay(Capsule().stroke(c.stroke.color, lineWidth: 2))
                                .foregroundStyle(.black)
                        }
                    }
                }
                // Issued, and when the office is due to reissue — both with
                // their day, so 6 PM read at 1 AM says it was yesterday's.
                Text(outlook.stamp.line())
                    .font(.system(size: 18)).foregroundStyle(.tertiary)
            } else if layer == .rainTotals {
                if let failure = totals.failure, !totals.loading.contains(day) {
                    Text("Couldn't load the rain totals: \(failure)").foregroundStyle(.secondary)
                } else {
                    Text("Loading the rain totals…").foregroundStyle(.secondary)
                }
            } else if storms.fetched == nil && storms.failure == nil {
                Text("Loading the outlook…").foregroundStyle(.secondary)
            } else if let failure = storms.failure, storms.fetched == nil {
                Text("Couldn't load the outlook: \(failure)").foregroundStyle(.secondary)
            } else {
                Text("No outlook issued for this day yet.").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 22))
        .frame(width: layer == .rainTotals ? 680 : 560, alignment: .leading)
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    @ViewBuilder private func homeLine(_ outlook: Outlook) -> some View {
        if let home, let c = outlook.category(at: home) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(c.fill.color).frame(width: 16, height: 16)
                Text("At home: **\(c.name)** — \(c.meaning)")
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Home is outside every risk area.").foregroundStyle(.secondary)
        }
    }

    /// Days for an outlook; for rain totals, how far the running total reaches.
    private func periodName(_ period: Int) -> String {
        guard layer == .rainTotals else { return Self.dayName(period) }
        return period == 1 ? "Today" : "Next \(period) days"
    }

    /// The expected total at home, as the band it falls in.
    @ViewBuilder private func totalsHome(_ outlook: Outlook) -> some View {
        if let home, let c = outlook.category(at: home) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(c.fill.color).frame(width: 16, height: 16)
                Text("At home: **\(c.name)**")
            }
        } else {
            Text("At home: little or none").foregroundStyle(.secondary)
        }
    }

    /// "Today", "Tomorrow", then the weekday — the outlooks' day 1, 2 and 3.
    static func dayName(_ day: Int) -> String {
        switch day {
        case 1: return "Today"
        case 2: return "Tomorrow"
        default:
            let date = Calendar.current.date(byAdding: .day, value: day - 1, to: Date()) ?? Date()
            return date.formatted(.dateTime.weekday(.wide))
        }
    }
}

/// What a closed menu shows: what is chosen, and that pressing opens a list.
private struct MenuLabel: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
            Text(text)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 28, weight: .medium))
    }
}

/// The amount bands on the map, lowest to highest, as one strip with each
/// band's floor under it — WPC's own ramp.
private struct TotalsRamp: View {
    let categories: [OutlookCategory]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(categories) { c in
                VStack(spacing: 4) {
                    Rectangle().fill(c.fill.color).frame(height: 18)
                    Text(c.code).font(.system(size: 16).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(maxWidth: 60)
            }
            Text("in").font(.system(size: 16)).foregroundStyle(.secondary)
                .padding(.leading, 6).padding(.bottom, 22)
        }
    }
}

/// How old the radar picture is, in the tab bar's row while the loop is up.
struct RadarClockPill: View {
    @ObservedObject var radar: RadarModel
    let range: TVMapZoom

    var body: some View {
        if let current = radar.current {
            HStack(spacing: 10) {
                Circle().fill(radar.isStale ? Color.orange : Color.green)
                    .frame(width: 12, height: 12)
                // HOW OLD, not what o'clock. Nobody watching a storm converts
                // "2:05 PM" into "twenty minutes ago" — and twenty minutes is
                // the whole question, because it is how far the thing on screen
                // has already moved since the picture was taken. The clock time
                // stays as the smaller half, for anyone checking it against
                // another source.
                VStack(alignment: .leading, spacing: 0) {
                    // Scans still arriving is said, not left as a loop that
                    // mysteriously will not move.
                    Text(radar.scansReady < radar.frames.count
                         ? "Loading scans · \(radar.scansReady) of \(radar.frames.count)"
                         : RadarAge.describe(current.time))
                        .font(.system(size: 28, weight: .medium))
                    Text(When.moment(current.time))
                        .font(.system(size: 19).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(range.miles).font(.system(size: 22)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .fixedSize()
        }
    }
}
