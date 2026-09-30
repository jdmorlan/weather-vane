//
//  StormSurface.swift  (tvOS)
//
//  The window: three tabs — Now, Forecast, Map — and the warning above them.
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
//  THREE SECTIONS, BY THE QUESTION ASKED. They are the Mac app's TODAY group
//  exactly — what is happening, what is coming, what is around you — which is
//  what the television was for all along. Everything about the record stayed on
//  the Mac because a remote is a terrible instrument for asking questions.
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
//  THE WARNING SITS OVER ALL THREE. Being told something is coming for you must
//  never depend on which tab you left the TV on.
//

import SwiftUI
import WeatherKit

enum TVTab: Hashable { case now, forecast, map }

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

    @State private var tab: TVTab = .now
    /// Owned here rather than inside the map tab so the range survives leaving
    /// and re-entering it — a zoom you have to set again every time you come
    /// back is a zoom you stop using.
    @State private var range: TVMapZoom = .nearby
    /// Radar or an outlook, and the outlook's day. The view goes back to
    /// radar each time you come to the Map tab; see `MapTab.swift`.
    @State private var layer: TVMapLayer = .radar
    @State private var outlookDay = 1

    private var nearestSite: RadarSite? {
        settings.homePoint.flatMap {
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
                       home: settings.homePoint,
                       range: $range, layer: $layer, day: $outlookDay)
            }
        }
        // Behind the tabs, always mounted. See `MapTab.swift` for the
        // measurement that put it here.
        .background {
            MapBackdrop(radar: radar, hazards: hazards, storms: storms, totals: rainTotals, lines: lines,
                        home: settings.homeCoordinate, range: range,
                        layer: layer, day: outlookDay,
                        isActive: tab == .map)
        }
        // In the tab bar's row, at the left, where it takes no height.
        .overlay(alignment: .topLeading) {
            if let worst = hazards.worst {
                HazardBannerTV(hazard: worst, others: hazards.active.count - 1)
                    .padding(.leading, 80)
            }
        }
        .background(Color.black)
        // The radar nearest home, drawn from its own Level II scans. No picker
        // on the TV: from a sofa the nearest site is the right answer.
        .onAppear { radar.site = nearestSite }
        .onChange(of: settings.homeLat) { _, _ in radar.site = nearestSite }
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
        .task(id: settings.homeLat) { await lines.load(home: settings.homePoint) }
        #if DEBUG
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
