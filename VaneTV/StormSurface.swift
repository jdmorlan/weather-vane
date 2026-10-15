//
//  StormSurface.swift  (tvOS)
//
//  The window: four tabs — Now, Forecast, Map, Videos — and the warning above
//  them.
//
//  WHAT THIS REPLACED, THREE TIMES. First a full-bleed radar with a conditions
//  strip, which made the thing you check every thirty seconds the smallest item
//  on a hundred-inch screen. Then a single dense dashboard, which overflowed
//  while being built. Then a grid of eight cards — radar, wind, pressure,
//  comfort, rain, hours, days, sun — each a summary you pressed to open. That
//  one solved the overflow by making adding free, and adding free is what
//  undid it: every tile was one measure, and a measure alone is a fact with its
//  meaning a press away. The deck had become a list of sensors, not answers.
//
//  THREE SECTIONS, BY THE QUESTION ASKED, and the forecasters beside them.
//  The three are the Mac app's TODAY group exactly — what is happening, what
//  is coming, what is around you — which is what the television was for all
//  along. Everything about the record stayed on the Mac because a remote is a
//  terrible instrument for asking questions.
//
//    NOW       one composed screen: the temperature, the interpreter's
//              headline, the readings, and the next twelve hours.
//    FORECAST  the days ahead, drawn.
//    MAP       the radar, full screen. It is the tab you open when the weather
//              turns, so it opens on the loop rather than on a forecast.
//
//  THE SYSTEM'S TAB BAR, NOT OUR OWN BUTTONS. A segmented `Picker` traps
//  focus on tvOS; a `TabView` is the one top-level control the focus engine
//  was built around, and swiping up from any page reaches it.
//
//    VIDEOS    two forecasters' newest videos and live storm coverage, which
//              open in the YouTube app. See `VideosTab`.
//
//  THE WARNING SITS OVER ALL OF THEM. Being told something is coming for you must
//  never depend on which tab you left the TV on.
//

import SwiftUI
import WeatherKit

enum TVTab: Hashable {
    case now, forecast, map, videos

    /// `vane://map` → `.map`. The same names as the Mac's links (see
    /// `Destination.slug`), so one list of links works on every platform and
    /// each app ignores the ones it has no screen for.
    init?(url: URL) {
        switch url.host()?.lowercased() {
        case "now":      self = .now
        case "forecast": self = .forecast
        case "map":      self = .map
        case "videos":   self = .videos
        default:         return nil
        }
    }
}

struct StormSurface: View {
    @EnvironmentObject private var settings: TVSettings
    @StateObject private var radar = RadarModel()
    /// The loop's one clock, on the display's own refreshes. See `TVLoopDriver`.
    @StateObject private var driver = TVLoopDriver()
    @StateObject private var hazards = TVHazardModel()
    @StateObject private var conditions = TVConditionsModel()
    @StateObject private var storms = StormOutlookModel()
    @StateObject private var rainTotals = TVRainTotalsModel()
    @StateObject private var lines = TVBoundaries()
    @StateObject private var forecasters = ForecasterModel()

    @State private var tab: TVTab = .now
    /// Owned here rather than inside the map tab so the range survives leaving
    /// and re-entering it — a zoom you have to set again every time you come
    /// back is a zoom you stop using.
    @State private var range: TVMapZoom = .nearby
    /// Radar or an outlook, and the outlook's day. The view goes back to
    /// radar each time you come to the Map tab; see `MapTab.swift`.
    @State private var layer: TVMapLayer = .radar
    @State private var outlookDay = 1

    /// WHICH RADAR, stored as the Mac stores it: "auto" for the site nearest
    /// home, or an ICAO. Per device, not synced.
    @AppStorage("radarSite") private var radarSiteChoice: String = "auto"
    /// The site the map was last centred on by picking it. Nil centres on
    /// home: at launch, and after "Nearest to home".
    @State private var focusSite: RadarSite?

    /// The radar map centres on a picked site; the outlooks are about home,
    /// so they always centre there.
    private var mapCenter: CLLocationCoordinate2D? {
        guard layer == .radar, let site = focusSite else { return settings.homeCoordinate }
        return CLLocationCoordinate2D(latitude: site.latitude, longitude: site.longitude)
    }

    /// Anything that is not a known site means the one nearest home.
    private var resolvedSite: RadarSite? {
        if let chosen = RadarSites.site(radarSiteChoice) { return chosen }
        return settings.homePoint.flatMap {
            RadarSites.nearest(latitude: $0.latitude, longitude: $0.longitude).first
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Now", systemImage: "cloud.sun", value: .now) {
                NowTab(report: conditions.report, hasStation: settings.hasStation)
                    .background(Color.black)
            }
            Tab("Forecast", systemImage: "calendar", value: .forecast) {
                ForecastTab(report: conditions.report, hasStation: settings.hasStation,
                            storms: storms, home: settings.homePoint)
                    .background(Color.black)
            }
            Tab("Map", systemImage: "map", value: .map) {
                MapTab(radar: radar, storms: storms, totals: rainTotals, hasHome: settings.hasHome,
                       home: settings.homePoint, radarSite: $radarSiteChoice,
                       range: $range, layer: $layer, day: $outlookDay)
            }
            // A forecaster on the air with a storm, said in the tab's own name
            // so it can be seen from any tab. In the name because tvOS tab bars
            // take no badge.
            Tab(forecasters.stormStreams.isEmpty ? "Videos" : "Videos · LIVE",
                systemImage: "play.rectangle", value: .videos) {
                VideosTab(model: forecasters)
                    .background(Color.black)
            }
        }
        .onOpenURL { url in
            if let t = TVTab(url: url) { tab = t }
        }
        // Behind the tabs, always mounted. See `MapTab.swift` for the
        // measurement that put it here.
        .background {
            MapBackdrop(radar: radar, hazards: hazards, storms: storms, totals: rainTotals, lines: lines,
                        home: settings.homeCoordinate, center: mapCenter, range: range,
                        layer: layer, day: outlookDay,
                        isActive: tab == .map)
        }
        // In the tab bar's row — the warning at the left, the radar's age at
        // the right while the loop is up — where they take no height. Both are
        // centred on the tab bar itself; see `TVTabBarRow`.
        .overlay(alignment: .top) {
            HStack(spacing: 0) {
                if let worst = hazards.worst {
                    HazardBannerTV(hazard: worst, others: hazards.active.count - 1)
                }
                Spacer(minLength: 0)
                if tab == .map && layer == .radar && settings.hasHome {
                    RadarClockPill(radar: radar, range: range)
                }
            }
            .tabBarRow()
        }
        .background(Color.black)
        // The radar nearest home unless another was chosen on the Map tab.
        .onAppear { radar.site = resolvedSite }
        .onChange(of: settings.homeLat) { _, _ in radar.site = resolvedSite }
        .onChange(of: radarSiteChoice) { _, choice in
            radar.site = resolvedSite
            // Picking a radar is asking to see what it sees: centre on the
            // site, wide enough for the ground it covers well, as the Mac
            // does. "Nearest to home" is the way back to home.
            if choice == "auto" {
                focusSite = nil
            } else {
                focusSite = resolvedSite
                range = .regional
            }
        }
        .onAppear { driver.start(radar); driver.pause(tab != .map) }
        .onChange(of: tab) { _, tab in
            if tab == .map { layer = .radar }
            driver.pause(tab != .map)
        }
        .onChange(of: layer) { _, layer in
            driver.pause(tab != .map || layer != .radar)
            // Each view's own periods: an outlook's day, or the week of rain.
            if !layer.periods.contains(outlookDay) || layer == .rainTotals {
                outlookDay = layer.defaultPeriod
            }
        }
        .onDisappear { driver.stop() }
        // `driving: false` — the display link above moves the loop. Two drivers
        // would run it at twice the speed. On the surface rather than the map
        // tab so the loop is already downloaded when you switch to it.
        .task { await radar.run(driving: false) }
        .task { await hazards.poll(point: settings.homePoint) }
        // On the surface, not the tab, so the outlooks are in before you look.
        .task { await storms.keepCurrent() }
        // On the surface, not the tab, so the LIVE badge appears without
        // anyone opening Videos first.
        .task { await forecasters.poll() }
        .task(id: settings.homeLat) { await lines.load(home: settings.homePoint) }
        #if DEBUG
        // `-VaneStartTab map` opens on a tab, so a layout can be checked in
        // the simulator without a remote.
        .onAppear {
            switch UserDefaults.standard.string(forKey: "VaneStartTab") {
            case "forecast": tab = .forecast
            case "map":      tab = .map
            case "videos":   tab = .videos
            default:         break
            }
        }
        // A soak test for memory: `-VaneSoak YES` walks every range on the map,
        // then round the tabs, forever — what a remote does when someone is
        // looking around. Measured with Instruments; see `TVSoak`.
        .task {
            guard UserDefaults.standard.bool(forKey: "VaneSoak") else { return }
            await TVSoak.run(tab: $tab, range: $range, layer: $layer, day: $outlookDay)
        }
        #endif
        .task {
            guard settings.hasStation else { return }
            await conditions.poll(token: settings.tempestToken,
                                  stationID: settings.tempestStationID)
        }
    }
}

/// What a station-shaped tab says when there is no station, so the tab is
/// never simply empty.
struct NoStationNotice: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sensor.tag.radiowaves.forward")
                .font(.system(size: 64)).foregroundStyle(.secondary)
            Text("No station connected").font(.system(size: 40, weight: .medium))
            Text("The map and warnings work without one. Connect a Tempest from Vane on your Mac or iPad and it arrives here on its own.")
                .font(.system(size: 26)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1000)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A station tab whose first report has not arrived yet.
struct WaitingNotice: View {
    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
            Text("Reading the station…").font(.system(size: 28)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
/// Drives the surface the way a remote does, so memory can be measured on the
/// device without anyone holding one.
@MainActor
enum TVSoak {
    static func run(tab: Binding<TVTab>, range: Binding<TVMapZoom>,
                    layer: Binding<TVMapLayer>, day: Binding<Int>) async {
        var lap = 0
        while !Task.isCancelled {
            lap += 1
            tab.wrappedValue = .map
            for r in TVMapZoom.allCases {
                range.wrappedValue = r
                radarLog.info("soak lap \(lap): map \(r.rawValue, privacy: .public)")
                try? await Task.sleep(for: .seconds(6))
            }
            for (l, d) in [(TVMapLayer.storms, 1), (.storms, 2), (.excessiveRain, 1),
                           (.rainTotals, 7), (.rainTotals, 3), (.radar, 1)] {
                layer.wrappedValue = l
                day.wrappedValue = d
                radarLog.info("soak lap \(lap): layer \(l.label, privacy: .public) day \(d)")
                try? await Task.sleep(for: .seconds(4))
            }
            for t in [TVTab.now, .forecast, .map, .now] {
                tab.wrappedValue = t
                radarLog.info("soak lap \(lap): tab \(String(describing: t), privacy: .public)")
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
#endif

/// The tab bar's own row, for the things that sit beside it — the warning,
/// the radar's age. Centred on the bar, not hung from the top of the screen:
/// hung from the top, a two-line pill and a one-line one sat at different
/// heights, and neither lined up with the tabs.
enum TVTabBarRow {
    /// From the top of the screen to the tab bar's vertical centre, in points.
    /// Measured off the system tab bar; tvOS gives no API for it.
    static let center: CGFloat = 80
    /// The tab bar's side margins, so a pill's edge lines up with the screen's.
    static let inset: CGFloat = 80
}

extension View {
    func tabBarRow() -> some View {
        self
            .frame(height: 2 * TVTabBarRow.center, alignment: .center)
            .padding(.horizontal, TVTabBarRow.inset)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
    }
}
