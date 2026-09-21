//
//  VaneTVApp.swift  (tvOS)
//
//  Vane on the Apple TV. NOT a port of the Mac app, and the difference is the
//  whole design.
//
//  WHAT THIS IS FOR — a screen you put up when the weather turns. Not exploring,
//  not the archive, not a question you came to ask: one glanceable picture of
//  what is happening and what is about to. Everything in the Mac app that is
//  about the RECORD stayed on the Mac, because a remote is a terrible instrument
//  for asking questions and a television is a terrible place to read a table.
//
//  WHY IT NEEDED NO ARCHITECTURE. tvOS gives no guarantee that anything written
//  to disk survives — the system may purge an app's storage, which is flatly
//  incompatible with "years of your own readings live on this machine". That
//  ruled out a port and made this obvious instead: storm mode is entirely LIVE.
//  Radar frames, NWS warnings and the station's current conditions are all
//  fetched now and kept for minutes. There is nothing to persist but a location.
//
//  WHAT IT NEEDS TO BE TOLD — a home point, and that is all. Radar centres on it
//  and warnings are matched against it; neither needs a Tempest token. A station
//  is optional and adds the conditions strip. That asymmetry is what makes setup
//  on a remote bearable: two numbers, not a pasted UUID.
//

import SwiftUI

@main
struct VaneTVApp: App {
    @StateObject private var settings = TVSettings()

    var body: some Scene {
        WindowGroup {
            Group {
                if settings.hasHome {
                    StormSurface()
                        .environmentObject(settings)
                } else {
                    TVSetupView()
                        .environmentObject(settings)
                }
            }
            // AROUND BOTH BRANCHES, not on either one, because which branch is
            // showing is exactly what this can change: a TV with nothing set up
            // renders `TVSetupView`, and a record arriving from the person's Mac
            // or iPad flips it to `StormSurface` without anyone touching the
            // remote. Attached to the setup view, it would stop listening the
            // moment it succeeded.
            .task { settings.startSync() }
        }
    }
}
