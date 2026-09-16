//
//  MapSurfaceView.swift  (Weather)
//
//  The Map tab: one `MapCanvas` plus the list of layers feeding it.
//
//  WHY IT'S ITS OWN TAB — every other tab answers a question about a POINT (your
//  station, your home) over TIME. This one is the other axis: what is around, and
//  what is coming, right now. A radar loop and a warning polygon are the two
//  things in the whole app that have no meaning at a single coordinate.
//
//  AND WHY IT'S CALLED MAP — Map is the RENDERER, not the membership. In Almanac
//  the same canvas also drew your `place` blocks; that layer did not come across
//  (the block model stayed behind) but naming the tab after the renderer is what
//  leaves the door open for it to come back.
//

import SwiftUI
import MapKit
import WeatherKit

struct MapSurfaceView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var radar = RadarModel()
    @StateObject private var hazards = WeatherHazardModel()

    @State private var showRadar = true
    @State private var showWarnings = true
    @State private var focus: MapFocus?
    @State private var focusToken = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            canvas
            panel.padding(14)
        }
        .overlay(alignment: .bottom) { timeline }
        .navigationTitle("Map")
        .task { await radar.run() }
        .task { await hazards.poll(settings: settings) }
        .onAppear(perform: recenterHome)
    }

    private var canvas: some View {
        MapCanvas(layers: layers, focus: focus)
            .ignoresSafeArea()
    }

    private var panel: some View {
        // Spelled out rather than a ternary in the argument list: `hasHome ? f : nil`
        // gives the type checker a function-vs-nil unification it cannot do inside
        // a ViewBuilder, and the diagnostic it produces names none of that.
        let recenter: (() -> Void)? = settings.hasHome ? { recenterHome() } : nil
        return LayerPanel(layers: layers,
                          toggleRadar: $showRadar,
                          toggleWarnings: $showWarnings,
                          recenter: recenter)
    }

    // MARK: Layers

    private var layers: [MapLayer] {
        // Two layers, both FIELD. Almanac's third — your `place` blocks — stayed
        // behind with the block model. `MapLayerFamily.blocks` is kept rather than
        // deleted because the distinction it names (keyed by id and yours, versus
        // keyed by time and fetched) is what the canvas is built around, and it
        // costs nothing to leave the seam open.
        var built: [MapLayer] = []

        built.append(MapLayer(
            id: "radar", name: "Radar", symbol: "cloud.rain",
            family: .field, isOn: showRadar, content: .tiles(radar.current),
            caption: radar.current.map {
                $0.time.formatted(date: .omitted, time: .shortened)
            } ?? "—"))

        let outlines = warningOutlines()
        built.append(MapLayer(
            id: "warnings", name: "Warnings", symbol: "exclamationmark.triangle",
            family: .field, isOn: showWarnings, content: .outlines(outlines),
            // "none" is a real answer here and worth printing, unlike on the
            // Weather banner — you came to this surface to look, so an empty
            // layer is information rather than clutter.
            caption: outlines.isEmpty ? "none" : "\(outlines.count)"))

        return built
    }

    private func warningOutlines() -> [MapOutline] {
        hazards.watch.state().drawable.map { hazard in
            MapOutline(
                id: hazard.id,
                rings: (hazard.shape?.rings ?? []).map { ring in
                    ring.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                },
                tint: hazard.tint)
        }
    }

    // MARK: Camera

    private func recenterHome() {
        guard let home = settings.homeCoordinate else { return }
        focusToken += 1
        focus = MapFocus(center: home, radiusMeters: RadarRange.nearby.radius, token: focusToken)
    }

    // MARK: Timeline

    /// Only while radar is on, because it describes that layer and nothing else.
    @ViewBuilder private var timeline: some View {
        if showRadar, !radar.frames.isEmpty {
            HStack(spacing: 12) {
                Button { radar.isPlaying.toggle() } label: {
                    Image(systemName: radar.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)

                RadarTimeline(frames: radar.frames, index: radar.index) { radar.scrub(to: $0) }

                if let current = radar.current {
                    Text(current.time, format: .dateTime.hour().minute())
                        .font(.callout).monospacedDigit()
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 620)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
            .padding(.bottom, 16)
        }
    }
}

// MARK: - The layer list

/// Grouped BY FAMILY, because "yours" and "conditions" are the distinction the
/// whole canvas is built on — one is your blocks under a spatial renderer, the
/// other is fetched data about space. A flat list of toggles would hide the only
/// structural fact on the screen.
private struct LayerPanel: View {
    let layers: [MapLayer]
    @Binding var toggleRadar: Bool
    @Binding var toggleWarnings: Bool
    let recenter: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([MapLayerFamily.blocks, .field], id: \.self) { family in
                let group = layers.filter { $0.family == family }
                if !group.isEmpty {
                    Text(family.heading.uppercased())
                        .font(.system(size: 9, weight: .semibold)).tracking(0.7)
                        .foregroundStyle(.secondary)
                    ForEach(group) { layer in row(layer) }
                }
            }

            if let recenter {
                Divider().padding(.vertical, 2)
                Button(action: recenter) {
                    Label("Home", systemImage: "house").font(.callout)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(width: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func row(_ layer: MapLayer) -> some View {
        Toggle(isOn: binding(for: layer.id)) {
            HStack(spacing: 6) {
                Image(systemName: layer.symbol).frame(width: 16)
                Text(layer.name).font(.callout)
                Spacer(minLength: 4)
                if let caption = layer.caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func binding(for id: String) -> Binding<Bool> {
        switch id {
        case "radar":    return $toggleRadar
        default:         return $toggleWarnings
        }
    }
}
