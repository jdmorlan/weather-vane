//
//  SetupSheet.swift  (Weather)
//
//  First run, and the way back into it afterwards.
//
//  WHAT IT REPLACES — a headline, one paragraph pointing at a Settings section
//  that didn't exist by that name, and the upper-air pattern pasted underneath
//  it. No button. The pattern was there to prove the app wasn't broken, which is
//  a reasonable instinct and the wrong fix: it made a full-blown surface look
//  like consolation, and it put the app's only mention of setup at the top of a
//  scroll you had to already be on the right tab to see.
//
//  FOUR STEPS, AND WHY EACH EARNS ONE — Welcome says what the app is for, which
//  is the only moment anyone will read it. Station is the one that matters and
//  gets a whole step because it is the one that can FAIL. Home is a confirmation
//  rather than a question, since the station already told us where it is. Facing
//  is last because it is optional and because it is the strangest thing the app
//  asks for, and a strange question at step two reads as a demand where the same
//  question after everything works reads as an invitation.
//

import SwiftUI
import CoreLocation
import WeatherKit

struct SetupSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = SetupModel()
    @Environment(\.dismiss) private var dismiss
    /// Run after a successful setup so the app can start fetching against the
    /// station it just learned about, instead of waiting for the next launch.
    var onFinish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, station, home, facing

        var title: String {
            switch self {
            case .welcome: return "Weather"
            case .station: return "Connect your Tempest"
            case .home:    return "Where you are"
            case .facing:  return "Which way the house looks"
            }
        }
    }

    @State private var step: Step = .welcome

    /// The station arrived from iCloud while this sheet was still at the start.
    ///
    /// WHY THIS HAS TO LISTEN. A new device opens setup at once, but its first
    /// iCloud sync can take a minute to land — so someone who set Vane up on
    /// their Mac was being asked for a token they had already given, and could
    /// be halfway through pasting it again when the real one arrived. There is
    /// no "iCloud has finished checking" signal to wait for, so instead the
    /// sheet watches: if a station appears before they have committed their
    /// own, it stops asking and says so.
    @State private var arrivedFromSync = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// A phone. The sheet's 540×470 is a Mac window's size and an iPad form
    /// sheet's; on a phone it ran off both edges. There it takes the screen and
    /// scrolls, with the controls pinned underneath.
    private var isCompact: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            if isCompact {
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 22)
                        .padding(.top, 26)
                        .padding(.bottom, 16)
                }
            } else {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 34)
                    .padding(.top, 30)
            }
            Divider()
            controls
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: isCompact ? nil : 540, height: isCompact ? nil : 470)
        .onAppear {
            model.seed(from: settings)
            // Already here by the time the sheet appeared — a fast sync, or a
            // relaunch after one. Same answer as arriving a moment later.
            if settings.hasWeatherStation, !settings.hasSeenSetup { arrivedFromSync = true }
        }
        .onChange(of: settings.hasWeatherStation) { _, has in
            // Only before they've started on their own: on Welcome, or on
            // Station with nothing typed. A token they entered themselves
            // commits on the way to Home, so it never trips this.
            guard has, step == .welcome || (step == .station && model.token.isEmpty) else { return }
            withAnimation { arrivedFromSync = true }
        }
    }

    @ViewBuilder private var content: some View {
        if arrivedFromSync {
            synced
        } else {
            stepContent
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .welcome: welcome
        case .station: station
        case .home:    home
        case .facing:  facing
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "cloud.sun.fill")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            Text(Platform.keepsArchive ? "Your station, and everything it remembers"
                                       : "Your station, right now")
                .font(.title2.weight(.semibold))
            // "this Mac" was true when there was only a Mac. The sentence is
            // making a promise about where the record lives — on the machine in
            // front of you, not in someone's cloud — so the noun has to be the
            // machine in front of you.
            if Platform.keepsArchive {
                Text("This app reads your Tempest station directly — what it's doing right now, and the whole record behind it. It keeps its own archive on this \(Platform.deviceNoun), so questions like “how often has it rained this late in September” have an answer that isn't a guess.")
                    .foregroundStyle(.secondary)
            } else {
                // The phone is the live app: no archive, so no promise of one.
                // Where the record lives is worth saying, though — it is the
                // first thing someone who knows the iPad app will look for.
                Text("This app reads your Tempest station directly — what it's doing right now, how today has gone so far, and the ten days ahead. The years of readings behind it live in the iPad and Mac apps.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 11) {
                if Platform.keepsArchive {
                    bullet("bolt.fill", "Live conditions, today's shape, and a ten-day it grades itself on")
                    bullet("clock.arrow.circlepath", "Years of your own readings, searchable")
                } else {
                    bullet("bolt.fill", "Live conditions, today's shape, and the ten-day")
                }
                bullet("antenna.radiowaves.left.and.right", "Radar and NWS warnings — these work without a station")
            }
            .padding(.top, 2)
            // Said up front, so that someone expecting their station to follow
            // them knows to give it a moment rather than start typing.
            Label("Already set up Vane on another device with this iCloud account? Your station will arrive here by itself — it can take a minute.",
                  systemImage: "icloud")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 4)
            Spacer()
        }
    }

    // MARK: Arrived from iCloud

    private var synced: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.icloud.fill")
                .font(.system(size: 42))
                .foregroundStyle(.green)
            Text("You're already set up")
                .font(.title2.weight(.semibold))
            Text("Your station, \(settings.stationLabel), came over from your other device through iCloud\(settings.hasHome ? ", along with your home location" : ""). There's nothing to enter.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Facing is the one thing that deliberately does not travel — it is
            // about a person in their own doorway — so it is the one thing left
            // worth offering.
            Text("The one thing that doesn't carry over is which way the house faces. It's optional.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 19, alignment: .center)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: Station

    private var station: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Step.station.title).font(.title2.weight(.semibold))
            Text("Paste a personal-use token. The app finds your station from it — you don't need to look up an ID.")
                .font(.callout).foregroundStyle(.secondary)

            Link(destination: Platform.tokenPage) {
                Label("Get a token at tempestwx.com", systemImage: "arrow.up.right.square")
            }
            .font(.callout)

            // `TextField` rather than `SecureField`: the whole point of this
            // screen is that a paste can be checked, and a field that shows only
            // dots gives no way to see that a trailing space or a truncated copy
            // is why it failed. It is a read-only data token, not a password.
            TextField("Personal-use token", text: $model.token, prompt: Text("00000000-0000-0000-0000-000000000000"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onChange(of: model.token) { model.tokenChanged() }

            checkResult
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var checkResult: some View {
        switch model.check {
        case .idle:
            EmptyView()

        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for your stations…").foregroundStyle(.secondary)
            }
            .font(.callout)

        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                Spacer(minLength: 0)
                Button("Retry") { model.recheck() }.buttonStyle(.link)
            }
            .font(.callout)
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

        case .found(let stations) where stations.isEmpty:
            // A valid token on an account with no registered station. Not an
            // error, and saying "failed" about it would send someone hunting for
            // a better token they do not have.
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                Text("That token works, but there are no stations on the account yet. Register your Tempest in the WeatherFlow app first.")
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))

        case .found(let stations):
            VStack(alignment: .leading, spacing: 7) {
                Label(stations.count == 1 ? "Found your station"
                                          : "Found \(stations.count) stations — pick one",
                      systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(stations) { s in stationRow(s) }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }

    private func stationRow(_ s: TempestStation) -> some View {
        let picked = model.chosen?.id == s.id
        return Button { model.chosen = s } label: {
            HStack(spacing: 10) {
                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).font(.callout.weight(.medium))
                    // The timezone, not the coordinate: it is what a person
                    // recognises at a glance when two stations are 40 miles
                    // apart, and the lat/lon gets its own screen next anyway.
                    Text(s.timeZone ?? "Station \(s.id)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(picked ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Home

    /// Confirmation, not interrogation. The station registry already said where
    /// it is, so this screen's job is to let you say "actually, the house is
    /// over there" — which matters, because facing and the radar centre are read
    /// against home, not against the pole the sensor is on.
    private var home: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Step.home.title).font(.title2.weight(.semibold))
            Text(model.chosen?.hasLocation == true
                 ? "Taken from your station. Radar centres here and warnings are matched against it — adjust if the house sits somewhere else."
                 : "Radar centres here, and NWS warnings are matched against it.")
                .font(.callout).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text("Latitude").foregroundStyle(.secondary)
                    TextField("", value: $settings.homeLat,
                              format: .number.precision(.fractionLength(0...6)))
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                }
                GridRow {
                    Text("Longitude").foregroundStyle(.secondary)
                    TextField("", value: $settings.homeLon,
                              format: .number.precision(.fractionLength(0...6)))
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                }
            }
            .font(.callout)

            if !settings.hasHome {
                Label("Without this, Radar has nothing to centre on and warnings can't be matched.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Facing

    /// The one question the app asks that isn't about data, and the reason it asks: weather is
    /// issued north-up but READ by someone facing a direction. Storing the
    /// facing once is what lets "the wind is on the back of the house" be
    /// sayable at all. Optional, and unset by default — an unset facing is
    /// honest, and a guessed one puts words in your mouth on every wind card.
    private var facing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Step.facing.title).font(.title2.weight(.semibold))
            Text("Optional, and skippable — pick the direction the front of the house points. It lets the app say “the wind is on the back of the house” instead of “the wind is from 210°”.")
                .font(.callout).foregroundStyle(.secondary)

            FacingPicker(degrees: $settings.homeFacing)
                .padding(.top, 2)

            // The last screen is also where the app sets an expectation it would
            // otherwise fail: the first launch fetches years of history, the
            // Wind and History surfaces are empty until it lands, and someone
            // who wasn't told that reasonably concludes the app is broken.
            // Not on a phone, which downloads no history at all.
            if Platform.keepsArchive {
                Divider().padding(.vertical, 4)

                Label {
                    Text("When you finish, the app starts downloading your station's history in the background. History and Wind fill in as it arrives — the first pass takes a few minutes.")
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
                .font(.callout).foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        if arrivedFromSync {
            HStack {
                Button("Set which way it faces") {
                    arrivedFromSync = false
                    step = .facing
                }
                .buttonStyle(.link)
                Spacer()
                Button("Start") { finish(configured: true) }
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            stepControls
        }
    }

    private var stepControls: some View {
        HStack {
            if step == .welcome {
                // "Skip" only exists on the first screen, and it is worded as
                // what it does rather than as a refusal: three destinations work
                // with no station, so leaving here is a real way to use the app
                // rather than an abandonment we should be talking someone out of.
                Button("Set up later") { finish(configured: false) }
                    .buttonStyle(.link)
            } else {
                Button("Back") { retreat() }
            }

            Spacer()

            ForEach(Step.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }

            Spacer()

            Button(step == .facing ? "Start" : "Continue") { advance() }
                .keyboardShortcut(.defaultAction)
                .disabled(step == .station && !model.isSatisfied)
        }
    }

    private func advance() {
        switch step {
        case .welcome:
            step = .station
        case .station:
            // Committed HERE rather than at the end, because the Home screen
            // reads `settings.homeLat` — it shows the coordinate the station
            // gave us, which means the station has to be applied before that
            // screen is built.
            model.commit(to: settings)
            step = .home
        case .home:
            step = .facing
        case .facing:
            finish(configured: true)
        }
    }

    private func retreat() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func finish(configured: Bool) {
        settings.hasSeenSetup = true
        dismiss()
        if configured { onFinish() }
    }
}

/// The sixteen-point compass. Lifted out of `SettingsView` when setup needed the
/// same names — a second private copy would have been the third place in this
/// app that knows what 247° is called.
enum CompassPoint {
    static let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    static func name(_ degrees: Double) -> String {
        names[Int((degrees / 22.5).rounded()) % names.count]
    }
}
