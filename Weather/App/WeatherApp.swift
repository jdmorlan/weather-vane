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
    /// The forecaster video playing, if any. See `VideoPlayer`.
    @StateObject private var playback = VideoPlayback()
    /// What the person's own rain gauge caught — every device, synced.
    @StateObject private var rainLog = RainLogStore()

    var body: some Scene {
        WindowGroup {
            root
                .environmentObject(settings)
                .environmentObject(playback)
                .environmentObject(rainLog)
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

    /// The iPhone gets its own root, in the same binary. Chosen by idiom, not
    /// by size class: an iPad in Slide Over is narrow but is still the device
    /// with the archive and the sidebar app, and a phone is never anything else.
    /// See `PhoneRoot` for why this is not a second target.
    @ViewBuilder private var root: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            PhoneRoot()
        } else {
            RootView()
        }
        #else
        RootView()
        #endif
    }
}
