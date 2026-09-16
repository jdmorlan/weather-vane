//
//  WeatherApp.swift  (Weather)
//
//  The whole app. `WeatherView` was already a self-contained surface inside
//  Almanac — its own tabs, its own models, its own refresh — which is the real
//  reason this extraction was cheap: there was nothing to invent here, only a
//  window to put it in.
//

import SwiftUI

@main
struct WeatherApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
