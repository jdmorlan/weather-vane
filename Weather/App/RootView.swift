//
//  RootView.swift  (Weather)
//
//  Two tabs, and the split between them is not arbitrary. WEATHER is a scrolling
//  page of cards anchored to one point — your station — read down. MAP is a
//  full-bleed canvas you pan around. Putting Map into `WeatherView`'s segmented
//  picker would have meant a map inside a `ScrollView`, which is two gestures
//  fighting over the same trackpad.
//
//  Map also works with NO station configured (radar and NWS warnings need only a
//  home point), which is the other reason it sits beside Weather rather than
//  inside it: it must stay reachable when the other tab is still asking for a
//  token.
//

import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            WeatherView()
                .tabItem { Label("Weather", systemImage: "cloud.sun") }
            MapSurfaceView()
                .tabItem { Label("Map", systemImage: "map") }
        }
    }
}
