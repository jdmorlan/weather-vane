//
//  PhoneRoot.swift  (iPhone)
//
//  The iPhone's whole app: what it is like right now, and what is coming.
//
//  THE SAME BINARY AS THE IPAD, A DIFFERENT ROOT. A separate target would have
//  needed its own bundle id, and with it a second App Store listing, a second
//  iCloud identity and a second app group for widgets to share. So `VaneiOS` is
//  universal and `WeatherApp` chooses the root by idiom.
//
//  WHY IT IS NOT THE SIDEBAR APP ON A SMALL SCREEN. The Mac and iPad are where
//  you sit down and study the record; the phone is in your pocket when the
//  weather happens. It asks two questions — what is it doing, and is it about to
//  rain on me — and nine destinations built on years of archive answer neither
//  faster. So it holds `PhoneModels` and never `StationModels`, and that is the
//  whole mechanism by which a phone never backfills an archive: the code that
//  would do it is in the binary, and nothing here ever constructs it.
//
//  IT TURNS, AND WHAT TURNING MEANS DEPENDS ON THE TAB. Now on its side is
//  the next three days; the map on its side is a wider map, which in Houston
//  is the useful direction — lines come in from the west, and landscape shows
//  what is behind them.
//
//  Shaped like VaneTV's models for the same reason VaneTV is: fetched now, kept
//  for minutes. See [[iphone-app-is-live-only]] in the project memory.
//

import SwiftUI
import WeatherKit

/// The live models and nothing else. No archive, no samples backfill, no
/// forecast grading — each of those needs a record the phone does not keep.
@MainActor
final class PhoneModels: ObservableObject {
    let weather = WeatherModel()
    let today = DayObservationsModel()
    let hazards = WeatherHazardModel()
    /// SPC's and WPC's outlooks, for the storm lane in the forecast. Loaded
    /// with everything else so turning the phone finds them already read;
    /// `load` keeps its own ten-minute floor, so this costs nothing extra.
    let storms = StormOutlookModel()

    func refresh(settings: AppSettings) async {
        await weather.refresh(token: settings.tempestToken, stationID: settings.tempestStationID)
        await hazards.refresh(settings: settings)
        await loadToday(settings: settings)
        await storms.load()
    }

    /// Today's minutes, for the strip and the rain card. The key folds in a
    /// five-minute bucket exactly as `StationModels.loadToday` does, so a refresh
    /// re-reads the day at most that often.
    private func loadToday(settings: AppSettings) async {
        guard let r = weather.report else { return }
        let tz = r.timezone ?? .current
        let day = DayKey.string(for: Date(), timeZone: tz)
        let bucket = Int(Date().timeIntervalSince1970 / 300)
        await today.load(day: day, key: "\(day)|\(bucket)",
                         token: settings.tempestToken,
                         stationID: settings.tempestStationID,
                         timeZone: tz)
    }
}

struct PhoneRoot: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var models = PhoneModels()
    @Environment(\.scenePhase) private var scenePhase
    /// Compact height is an iPhone on its side — the only way this root is
    /// ever short. See `PhoneForecastView` for what Now does with it.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    @State private var showingSetup = false
    @State private var showingSettings = false

    /// Five minutes while the app is on screen, the same cadence as the hazard
    /// poll it now carries. The station reports every minute, but the forecast
    /// endpoint's current conditions do not move faster than this in any way
    /// you would see.
    private static let refreshInterval: Duration = .seconds(300)

    var body: some View {
        TabView {
            Tab(Destination.now.rawValue, systemImage: Destination.now.symbol) {
                NavigationStack {
                    PhoneNowView(weather: models.weather, today: models.today,
                                 hazards: models.hazards, storms: models.storms,
                                 refresh: { await models.refresh(settings: settings) },
                                 openSetup: { showingSetup = true })
                        .toolbar { settingsButton }
                }
                // OVER NOW, NOT INSTEAD OF IT, so turning the phone back finds
                // the scroll where it was left. The tab and status bars go, so
                // the figure has the whole short screen.
                .overlay {
                    if isLandscape {
                        PhoneForecastFigure(weather: models.weather, storms: models.storms)
                    }
                }
                .toolbar(isLandscape ? .hidden : .visible, for: .tabBar)
                .statusBarHidden(isLandscape)
            }
            Tab(Destination.map.rawValue, systemImage: Destination.map.symbol) {
                MapSurfaceView()
            }
            // Today's rain and your own gauge — the one thing the phone writes
            // rather than reads. See `PhoneRainView` for why it isn't the
            // iPad's archive-built Rain page.
            Tab(Destination.rain.rawValue, systemImage: Destination.rain.symbol) {
                NavigationStack {
                    PhoneRainView(weather: models.weather, today: models.today,
                                  refresh: { await models.refresh(settings: settings) })
                        .toolbar { settingsButton }
                }
            }
        }
        .sheet(isPresented: $showingSetup) {
            SetupSheet { Task { await models.refresh(settings: settings) } }
                .environmentObject(settings)
        }
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
        // First run, as on the iPad: sync BEFORE the check, so a phone that can
        // be handed its station by the Mac never opens by asking for a token.
        .task {
            settings.startSync()
            if !settings.hasSeenSetup { showingSetup = true }
        }
        // ONE LOOP FOR EVERYTHING LIVE, and it runs only while the app is in the
        // foreground. Keyed to the scene phase, so coming back to the app is
        // itself a refresh — the phone's version of "open it and look" — and
        // leaving cancels the loop instead of polling in a pocket. Keyed to the
        // station too, which is how setup finishing mid-session starts it.
        .task(id: "\(scenePhase)|\(settings.tempestToken)|\(settings.tempestStationID)|\(settings.homeLat)|\(settings.homeLon)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await models.refresh(settings: settings)
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    @ToolbarContentBuilder private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }
}
