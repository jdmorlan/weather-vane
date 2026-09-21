//
//  TVSetupView.swift  (tvOS)
//
//  The one screen that needs the remote, and the shortest one that can be.
//
//  A TOKEN IS THE WRONG THING TO ASK A TELEVISION FOR — a Tempest personal token
//  is a UUID, and entering thirty-six characters on a remote is a punishment.
//  So the TV asks for what it actually needs and nothing more: radar centres on
//  a point and NWS warnings are matched against one, and NEITHER needs a
//  station. Two numbers gets you the whole of storm mode.
//
//  The station is offered second and framed as optional, because all it adds is
//  the conditions strip. Someone who wants it can paste a token with the iOS
//  Remote app's keyboard; someone who doesn't is not blocked.
//

import SwiftUI
import WeatherKit

struct TVSetupView: View {
    @EnvironmentObject private var settings: TVSettings
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var token = ""
    @State private var stations: [TempestStation] = []
    @State private var checking = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Vane").font(.system(size: 64, weight: .bold))
                Text("Radar and warnings for one place. Enter where you are.")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
            }

            HStack(spacing: 28) {
                field("Latitude", text: $latitude, example: "31.55")
                field("Longitude", text: $longitude, example: "-97.15")
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("Tempest station — optional")
                    .font(.system(size: 26, weight: .semibold))
                Text("Adds current conditions. Radar and warnings work without it.")
                    .font(.system(size: 22)).foregroundStyle(.secondary)
                TextField("Personal-use token", text: $token)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, design: .monospaced))
                    .onSubmit { Task { await lookUp() } }
                if checking { ProgressView() }
                ForEach(stations) { station in
                    Button {
                        settings.apply(token: token.trimmingCharacters(in: .whitespaces),
                                       station: station)
                        note = "Connected to \(station.name)"
                    } label: {
                        Label(station.name, systemImage: "sensor.tag.radiowaves.forward")
                    }
                }
                if let note {
                    Text(note).font(.system(size: 22)).foregroundStyle(.green)
                }
            }

            Spacer()

            Button("Start") { commitHome() }
                .disabled(Double(latitude) == nil || Double(longitude) == nil)
                .font(.system(size: 30, weight: .semibold))
        }
        .padding(80)
    }

    private func field(_ label: String, text: Binding<String>, example: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(.secondary)
            TextField(example, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 34, design: .monospaced))
                .frame(width: 320)
        }
    }

    private func commitHome() {
        guard let lat = Double(latitude), let lon = Double(longitude) else { return }
        settings.homeLat = lat
        settings.homeLon = lon
    }

    /// Same one-paste discovery the Mac setup uses — the token names its own
    /// stations, so nobody has to find a numeric id on a television.
    private func lookUp() async {
        let candidate = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= 20 else { return }
        checking = true
        defer { checking = false }
        stations = (try? await TempestClient.stations(token: candidate)) ?? []
        if stations.isEmpty { note = "That token didn’t return any stations." }
    }
}
