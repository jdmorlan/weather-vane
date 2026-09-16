//
//  SettingsView.swift  (Weather)
//
//  The four things the app cannot work out for itself. In Almanac these were
//  rows on a much longer settings page; here they are the entire configuration
//  surface, which is a fair summary of what this app actually needs to know.
//

import SwiftUI
import CoreLocation

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Station") {
                TextField("Tempest token", text: $settings.tempestToken)
                    .textContentType(.password)
                TextField("Station ID", value: $settings.tempestStationID, format: .number.grouping(.never))
                Text("tempestwx.com → Settings → Data Authorizations")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Home") {
                TextField("Latitude", value: $settings.homeLat, format: .number.precision(.fractionLength(0...6)))
                TextField("Longitude", value: $settings.homeLon, format: .number.precision(.fractionLength(0...6)))
            }

            Section("Facing") {
                // -1 is "unset", and unset has to stay REACHABLE: a facing you
                // can't clear would make every egocentric phrasing a claim you
                // never agreed to.
                Toggle("The house faces a direction", isOn: Binding(
                    get: { settings.homeFacing >= 0 },
                    set: { settings.homeFacing = $0 ? max(0, settings.homeFacing) : -1 }))
                if settings.homeFacing >= 0 {
                    Slider(value: $settings.homeFacing, in: 0...359, step: 1) {
                        Text("Degrees true")
                    }
                    Text("\(Int(settings.homeFacing))° — \(Self.compass(settings.homeFacing))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 8)
    }

    private static func compass(_ degrees: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((degrees / 22.5).rounded()) % points.count
        return points[index]
    }
}
