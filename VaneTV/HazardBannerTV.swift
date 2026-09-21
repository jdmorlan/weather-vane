//
//  HazardBannerTV.swift  (tvOS)
//
//  The warning, at the size a warning deserves.
//
//  It sits above every mode because the one thing that must never be a mode is
//  being told something is coming for you. Whatever you were looking at, this
//  takes the top of the screen.
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
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
            VStack(alignment: .leading, spacing: 6) {
                Text(hazard.event.uppercased())
                    .font(.system(size: 48, weight: .heavy)).tracking(1)
                if let until = hazard.expires {
                    Text("until \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 26)).opacity(0.85)
                }
            }
            Spacer(minLength: 0)
            if others > 0 {
                Text("+\(others) more")
                    .font(.system(size: 26, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(.black.opacity(0.25), in: Capsule())
            }
        }
        .padding(.horizontal, 60).padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hazard.tint)
        .foregroundStyle(.white)
    }
}
