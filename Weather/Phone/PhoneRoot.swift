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

    func refresh(settings: AppSettings) async {
        await weather.refresh(token: settings.tempestToken, stationID: settings.tempestStationID)
        await hazards.refresh(settings: settings)
        await loadToday(settings: settings)
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
                                 hazards: models.hazards,
                                 refresh: { await models.refresh(settings: settings) },
                                 openSetup: { showingSetup = true })
                        .toolbar { settingsButton }
                }
            }
            Tab(Destination.map.rawValue, systemImage: Destination.map.symbol) {
                MapSurfaceView()
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
