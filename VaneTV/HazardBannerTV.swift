//
//  HazardBannerTV.swift  (tvOS)
//
//  The warning, in a colour you cannot miss.
//
//  It sits over the tabs, not in one, because the one thing that must never
//  depend on a tab is being told something is coming for you.
//
//  Colour comes from `Hazard.tint` — the NWS's own severity ramp, shared with
//  the Mac app through WeatherKit — so a tornado warning is never the shade a
//  flood watch gets, on either screen.
//

import SwiftUI
import WeatherKit

struct HazardBannerTV: View {
    let hazard: Hazard
    let others: Int

    var body: some View {
        // A CAPSULE BESIDE THE TAB BAR, NOT A STRIP ABOVE IT. The strip was the
        // full width of the screen and pushed everything below it down: two
        // lines, then one, and still a sixth of the height spent before Now had
        // drawn anything. In the tab bar's own row it costs no height at all,
        // and the colour — the NWS's ramp — is what makes it impossible to miss,
        // not its size.
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
            Text(hazard.event.uppercased())
                .font(.system(size: 28, weight: .heavy)).tracking(0.5)
                .lineLimit(1)
            if let until = hazard.expires {
                Text("until \(until.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 22, weight: .medium)).opacity(0.85)
                    .lineLimit(1)
            }
            if others > 0 {
                Text("+\(others)")
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(.black.opacity(0.25), in: Capsule())
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(hazard.tint, in: Capsule())
        .foregroundStyle(.white)
        .fixedSize()
    }
}
