//
//  RootView.swift  (Weather)
//
//  The window: a source list of six destinations, and the detail column they
//  drive. Also the one place that stays mounted for the whole session, which is
//  why the persistent work lives here rather than on any destination.
//
//  THE OLD SHAPE, AND WHY IT'S GONE — two tabs (Weather, Map) with Weather
//  carrying a five-way segmented picker inside its own `ScrollView`. That was
//  the right call while Weather was one surface inside Almanac and had exactly
//  one tab to spend. Standing alone it cost two things: the picker scrolled away
//  with the cards beneath it, so on History the way back was off-screen; and
//  Radar sat a level above four peers it has no authority over. The argument the
//  old file made for keeping Map out of the picker — that a map inside a
//  `ScrollView` is two gestures fighting over one trackpad — is preserved and
//  strengthened here: Radar is now its own column, not a card in a scroll.
//
//  WHAT MOVED UP — the eight models and every long-lived `.task`. A destination
//  that unmounts must not take the forecast, the hazard poll or the archive
//  catch-up down with it, and in a split view the detail column unmounts every
//  time you change destination. See `StationModels`.
//

import SwiftUI
import WeatherKit

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var models = StationModels()

    @State private var destination: Destination = .now
    @State private var showingSetup = false
    #if !os(macOS)
    /// iPadOS only. On the Mac this state does not exist because the settings
    /// window is the system's to open, not ours. See `WeatherApp`.
    @State private var showingSettings = false
    #endif

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $destination) { showingSetup = true }
        } detail: {
            detail
                .navigationTitle(destination.title)
                // Available on both since iOS 26. Worth stating because the
                // obvious iPad workaround — a leading toolbar item holding the
                // same string — is actively bad: squeezed against a centred
                // title it truncates to "Con...", and the sentence it drops is
                // where "updated 4:02 PM" lives.
                .modifier(FreshnessSubtitle(weather: models.weather) { subtitle(updated: $0) })
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar { toolbar }
        }
        // Presented from the root rather than from a destination: setup is about
        // the app, and a sheet owned by a view that navigation can unmount is a
        // sheet that vanishes mid-flow.
        .sheet(isPresented: $showingSetup) {
            SetupSheet { Task { await models.start(settings: settings) } }
                .environmentObject(settings)
        }
        #if !os(macOS)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(settings)
                    .navigationTitle("Settings")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSettings = false }
                        }
                    }
            }
        }
        #endif
        // FIRST RUN. `hasSeenSetup` and not `hasWeatherStation`, so that someone
        // who chose "Set up later" is not asked again on every launch — the
        // sidebar's "Finish setup" is how they come back when they're ready.
        .task {
            // BEFORE the first-run check, deliberately. A device that can be
            // handed its station by one the person already set up should not
            // open by asking them to set it up again.
            settings.startSync()
            if !settings.hasSeenSetup { showingSetup = true }
            await models.start(settings: settings)
        }
        // Polls for as long as the app is open, which is the point: a warning
        // issued while you're reading the ten-day has to arrive without you
        // asking, and it must not stop because you switched to Wind.
        .task { await models.hazards.poll(settings: settings) }
        // On the root for the same reason as the hazard poll: a new model run
        // landing while you are reading History should be there when you go back
        // to Rain, not start loading when you arrive.
        //
        // KEYED TO HOME, AND THE KEY IS THE BUG FIX. `poll` takes the point by
        // VALUE and loops on it forever, so an unkeyed `.task` captured whatever
        // home was at the instant the root appeared — which on a device being set
        // up for the first time is nil, because setup has not run yet. `load`
        // returns immediately on a nil home without setting `outlook` or
        // `failure`, so Rain sat on "No forecast yet" for the whole session and
        // only came right after a relaunch. The hazard poll never had this: it
        // takes the settings OBJECT and re-reads it every pass.
        //
        // A string rather than the `GeoPoint`: `.task(id:)` wants `Hashable` and
        // the point is only `Equatable`. Restarting also covers moving home,
        // which the old code could not do at all.
        .task(id: "\(settings.homeLat)|\(settings.homeLon)") {
            await models.precip.poll(home: settings.homePoint)
        }
        // A kept-alive window outlives midnight, and appearing is no longer a
        // proxy for "a new day". Without this the archive stops at the day the
        // app was launched, and yesterday can never be measured or graded.
        .task {
            for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) {
                models.catchUpArchives(settings: settings)
            }
        }
        // Re-graded when the archive gains a day — yesterday can only be scored
        // once the catch-up has measured it — and when a refresh files a new
        // claim, which is what makes the card appear on the very first morning
        // instead of after a relaunch.
        .task(id: models.checkKey) {
            await models.forecastCheck.load(store: models.archive.store,
                                            timeZone: models.weather.report?.timezone ?? .current,
                                            key: models.checkKey)
        }
        // The Day-shapes month, fetched the first time History is opened rather
        // than at launch. On the root so it survives leaving and returning to
        // the destination mid-flight.
        .task(id: destination) {
            guard destination == .history, settings.hasWeatherStation else { return }
            await models.loadDayShapes(settings: settings)
        }
        // Follows a station being connected mid-session: setup's completion
        // handler starts the fetch, and this catches the Settings-window route
        // to the same state.
        .task(id: "\(settings.tempestToken)|\(settings.tempestStationID)") {
            await models.start(settings: settings)
        }
    }

    @ViewBuilder private var detail: some View {
        switch destination {
        case .radar:
            MapSurfaceView()
        case .pattern:
            UpperAirSurface(model: models.upperAir) { showingSetup = true }
        case .station:
            if settings.hasWeatherStation {
                StationHealthView(model: models.health)
            } else {
                needsStation
            }
        case .now, .rhythms, .rain, .history, .wind, .explore:
            if settings.hasWeatherStation {
                WeatherView(models: models, destination: destination,
                            navigate: { destination = $0 },
                            openSetup: { showingSetup = true })
            } else {
                needsStation
            }
        }
    }

    /// What a station-shaped destination says when there is no station.
    ///
    /// This is the screen the old top-of-scroll blurb should always have been:
    /// it names the thing that's missing, it has a BUTTON, and it points at the
    /// two destinations that work right now instead of silently pasting one of
    /// them underneath.
    private var needsStation: some View {
        ContentUnavailableView {
            Label("Connect your Tempest station", systemImage: "sensor.tag.radiowaves.forward")
        } description: {
            Text("\(destination.title) reads your own station's measurements. Setup takes a token and about thirty seconds — it finds the station and its location for you.")
        } actions: {
            Button("Connect a station") { showingSetup = true }
                .buttonStyle(.borderedProminent)
            Button("See the radar instead") { destination = .radar }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The window subtitle: the destination's own one-liner before there's
    /// anything to report, and the freshness of the data once there is. A title
    /// bar is the right home for "how old is this" — it is true of the whole
    /// screen rather than of any card on it.
    private func subtitle(updated: Date?) -> String {
        if destination.needsStation, !settings.hasWeatherStation { return "No station connected" }
        if destination == .now, let updated {
            return "\(settings.stationLabel) · updated \(updated.formatted(date: .omitted, time: .shortened))"
        }
        return destination.caption
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        #if !os(macOS)
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
        #endif
        ToolbarItem {
            Button {
                Task {
                    await models.refresh(settings: settings,
                                         includingPattern: destination == .pattern)
                    // The health check is not part of a routine refresh — it's
                    // three more requests, and only one destination shows it.
                    // Asked for explicitly while looking at it, though, "refresh"
                    // has to mean the thing on screen.
                    if destination == .station { await models.health.refresh(settings: settings) }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(models.weather.isLoading || models.upperAir.isLoading
                      || !settings.hasWeatherStation)
            .help("Refresh")
        }
    }
}

/// The subtitle, redrawn when the forecast lands.
///
/// A MODIFIER BECAUSE THE ROOT CANNOT SEE THE CHANGE. `RootView` observes
/// `StationModels`, which publishes nothing of its own; the `WeatherModel`
/// inside it is where `lastUpdated` moves. So a subtitle computed in the root's
/// body only refreshed when something else redrew the root — switching
/// destination — and otherwise sat on the caption or on a stale time. This
/// observes the weather model itself, so the time moves when the data does.
private struct FreshnessSubtitle: ViewModifier {
    @ObservedObject var weather: WeatherModel
    let text: (Date?) -> String

    func body(content: Content) -> some View {
        content.navigationSubtitle(text(weather.lastUpdated))
    }
}
