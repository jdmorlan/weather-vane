//
//  UpperAirSurface.swift  (Weather)
//
//  Pattern, standing on its own.
//
//  It was in two places and belonged in neither. As a case in `WeatherView.Tab`
//  it sat among four surfaces built out of the station's own readings, which it
//  has nothing to do with — a different source (the GFS), a different clock
//  (four runs a day), a different subject (the wave upstairs, not this acre). And
//  it was ALSO the body of the not-configured screen, pasted under a blurb,
//  which is how a real surface ends up reading as a consolation prize.
//
//  Being its own destination fixes both. `patternVisible` — the property that
//  had to ask "is the Pattern tab selected OR is there no station at all" before
//  it could decide whether to fetch — becomes a view that is either on screen or
//  isn't, which is what the tab was clumsily trying to express in the first place.
//

import SwiftUI
import WeatherKit

struct UpperAirSurface: View {
    @ObservedObject var model: UpperAirModel
    @EnvironmentObject private var settings: AppSettings
    /// Opens setup, for the one thing this surface genuinely needs.
    var onSetUp: () -> Void

    /// Playback lives HERE rather than in the page, because the playbar is now
    /// pinned to this surface while the page scrolls underneath it. The page
    /// still needs it — the spacebar toggles play from anywhere — so it is shared
    /// rather than moved.
    @State private var playing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if settings.hasHome {
                    UpperAirPatternView(model: model, home: settings.homePoint,
                                        playing: $playing) {
                        Task { await model.load(home: settings.homePoint, force: true) }
                    }
                } else {
                    // The one thing it needs, and the reason: the flow is
                    // hemispheric, but "the height HERE" — which is what makes
                    // the reading personal rather than a weather-nerd chart — is
                    // sampled at the home point.
                    needsHome
                }
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // ON THE SCROLLVIEW, which is the whole point: an inset here floats over
        // the content and reserves room at the bottom, so the last card is still
        // fully readable rather than sitting under the bar. Only once there is a
        // run — a transport for nothing is furniture.
        .safeAreaInset(edge: .bottom) {
            if let frame = model.frame, (model.run?.frames.count ?? 0) > 1 {
                PatternPlaybar(model: model, playing: $playing, frame: frame)
            }
        }
        // Re-run when home moves: a run fetched for another point holds the
        // wrong "height here". `load` decides for itself whether a newer GFS run
        // can exist yet, so returning to this destination costs a file read
        // rather than a fetch.
        .task(id: "\(settings.homeLat)|\(settings.homeLon)") {
            await model.load(home: settings.homePoint)
        }
    }

    private var needsHome: some View {
        ContentUnavailableView {
            Label("Set your location first", systemImage: "globe.americas")
        } description: {
            Text("The 500 mb pattern is hemispheric, but the app reads it against one point — yours — to say whether you're under a ridge or a trough. It needs no Tempest station.")
        } actions: {
            Button("Set location", action: onSetUp)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 380)
    }
}
