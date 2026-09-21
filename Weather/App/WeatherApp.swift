//
//  WeatherApp.swift  (Weather)
//
//  The whole app. The extraction from Almanac was cheap because `WeatherView`
//  arrived self-contained — its own tabs, its own models, its own refresh — and
//  this file was only ever a window to put it in.
//
//  That self-containment is also what had to be undone. An app whose navigation
//  is a control INSIDE one view is an app that can only ever have one view; the
//  sidebar, the setup sheet and the surfaces that need no station all live above
//  `WeatherView` now. See `RootView`.
//

import SwiftUI

@main
struct WeatherApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
            #if os(macOS)
                // Wider than the old two-tab window: the sidebar takes ~190pt
                // and the cards were already laid out to 1180.
                .frame(minWidth: 1000, minHeight: 640)
            #endif
        }
        #if os(macOS)
        .windowToolbarStyle(.unified)
        #endif

        // iPadOS HAS NO SETTINGS SCENE, and the difference is not cosmetic. On
        // the Mac, preferences are a window the system opens for you from a menu
        // that exists whether or not the app thinks about it. On an iPad there is
        // no menu and no second window, so the same `SettingsView` has to be
        // reachable from inside the one screen there is — `RootView` presents it
        // as a sheet from the toolbar. Same view, two ways in.
        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(settings)
        }
        #endif
    }
}
