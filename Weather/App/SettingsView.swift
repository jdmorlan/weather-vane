//
//  SettingsView.swift  (Weather)
//
//  The four things the app cannot work out for itself — and, since setup exists,
//  a deliberately smaller job than it used to have.
//
//  It is no longer the front door. A user who has never configured anything meets
//  `SetupSheet`, which finds the station from a token instead of asking for an id
//  someone has to go and look up. What's left here is the ADJUSTMENT surface: the
//  place you come back to when the house's facing was wrong or home should be the
//  porch rather than the pole. The station row reflects that — it reports what's
//  connected and hands you back to setup, rather than offering a second, worse
//  way to type the same two fields.
//

import SwiftUI
import CoreLocation

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var showingSetup = false

    var body: some View {
        Form {
            Section("Station") {
                LabeledContent("Connected") {
                    HStack(spacing: 6) {
                        Image(systemName: settings.hasWeatherStation
                              ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(settings.hasWeatherStation
                                             ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                        Text(settings.hasWeatherStation ? settings.stationLabel : "No station")
                    }
                }
                Button(settings.hasWeatherStation ? "Change station…" : "Connect a station…") {
                    showingSetup = true
                }
                // The raw id, read-only. Kept visible because it's the number
                // every WeatherFlow support thread asks for, and removing it
                // from a settings window would make it unfindable — but not
                // editable, because a mistyped id is exactly the failure setup
                // was built to make impossible.
                if settings.tempestStationID != 0 {
                    LabeledContent("Station ID", value: String(settings.tempestStationID))
                        .foregroundStyle(.secondary)
                }

                // THE SAME DEEP LINK SETUP OFFERS, AND IT BELONGS HERE TOO.
                // Setup is a door you walk through once; the reasons to want this
                // page again all arrive later — a token revoked, one that expired,
                // a second station on the account, moving to a new device. Every
                // one of those sends you back to tempestwx.com, where the page
                // is buried under Settings → Data Authorizations — several levels
                // in, named nothing like "token", and not findable by guessing.
                // Keeping the link on the one screen that is ABOUT the connection
                // costs a row and saves that hunt every time.
                Link(destination: Platform.tokenPage) {
                    Label("Manage tokens at tempestwx.com", systemImage: "arrow.up.right.square")
                }
            }

            Section("Home") {
                // LABELLED EXPLICITLY, because a bare `TextField` title is only
                // a PLACEHOLDER on iOS — it shows while the field is empty and
                // vanishes the moment there's a value in it. These fields always
                // have a value, so on iPad the section rendered as two unlabelled
                // numbers and no way to tell latitude from longitude. macOS shows
                // the title either way; `LabeledContent` is what makes both true.
                LabeledContent("Latitude") {
                    TextField("Latitude", value: $settings.homeLat,
                              format: .number.precision(.fractionLength(0...6)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Longitude") {
                    TextField("Longitude", value: $settings.homeLon,
                              format: .number.precision(.fractionLength(0...6)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
                Text("The map centres here, and NWS warnings and outlooks are matched against it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Facing") {
                // Same control as setup, and deliberately so: this is where you
                // come back when the answer you gave in thirty seconds turns out
                // to want a nudge, and meeting a different control than the one
                // you answered the first time is its own small confusion.
                FacingPicker(degrees: $settings.homeFacing)
                Text("Which way the front of the house points. Lets the app phrase wind relative to you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 420)
        .padding(.vertical, 8)
        #endif
        .sheet(isPresented: $showingSetup) {
            // No `onFinish`: the Settings window can't reach the main window's
            // models, and it doesn't need to — `RootView` watches the token and
            // station id and starts the fetch when they change.
            SetupSheet {}
                .environmentObject(settings)
        }
    }
}
