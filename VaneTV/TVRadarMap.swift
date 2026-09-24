//
//  TVRadarMap.swift  (tvOS)
//
//  The radar, full bleed, with warning outlines over it.
//
//  A MUCH SMALLER THING than the Mac's `MapCanvas`, on purpose. That one is a
//  layer engine — pins, areas, outlines, tiles, a focus token, a selection
//  callback — because the Mac surface is a place you browse. Here the camera
//  never moves: there is no pointer to pan with, and a remote's swipe belongs to
//  the focus engine. The map is a backdrop for one loop.
//
//  THE SAME RENDERER AS THE MAC, NOT A SECOND ONE. This used to hand MapKit one
//  `MKTileOverlay` per frame and flip their alphas between 0 and 1: every frame
//  change was a hard cut, every tile went through a PNG encode just so MapKit
//  could decode it again, and a frame MapKit had not yet been asked to draw
//  arrived blank. It now draws through `FieldRenderer` — the Mac's two slots
//  with a real dissolve between them, pixels straight from `FieldTileStore`, and
//  a missing tile drawn from its parent while it renders. `FieldRenderer.swift`
//  is compiled into this target from the Mac's sources; see project.yml.
//
//  WHO MOVES THE LOOP. Not this view — it appears twice at once (the deck's card
//  face and the full-screen page), and two drivers would run the loop at double
//  speed. `TVLoopDriver` owns the one display link that ticks the clock; each
//  map only reads the playhead on its own refreshes and applies it.
//

import SwiftUI
import MapKit
import QuartzCore
import WeatherKit

// MARK: - The one clock

/// Ticks the radar loop on real display refreshes, so a dissolve lands on the
/// frames it is shown on. One per app, started by `StormSurface`.
@MainActor
final class TVLoopDriver: ObservableObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private weak var radar: RadarModel?

    func start(_ radar: RadarModel) {
        self.radar = radar
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() { link?.invalidate(); link = nil; last = nil }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        guard let last, let radar else { return }
        let delta = now - last
        guard delta > 0, delta < 1 else { return }
        // Hold on the newest scan until every scan is in, as the Mac does: a
        // loop that walks onto frames still downloading reads as broken.
        guard !radar.frames.isEmpty, radar.scansReady == radar.frames.count else { return }
        radar.tick(delta: delta)
    }
}

// MARK: - The map

struct TVRadarMap: UIViewRepresentable {
    let center: CLLocationCoordinate2D
    let radiusMeters: Double
    let radar: RadarModel
    let hazards: [Hazard]
    /// The radar's reach and beam-height rings. Passed only on the full-screen
    /// detail — on a card face the labels would be unreadable at ten feet.
    var coverage: RadarCoverage? = nil

    func makeCoordinator() -> Coordinator { Coordinator(radar: radar) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .mutedStandard
        map.pointOfInterestFilter = .excludingAll
        // The camera is fixed. Nothing on a remote should move it, and a map
        // that drifts under a storm you are watching is worse than no map.
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        map.showsUserLocation = false
        // NOT FOCUSABLE, and this is the important one on tvOS. An MKMapView is
        // a focusable element, so with the map full-screen the focus engine can
        // hand it focus and then never give it back — the range buttons below
        // become unreachable and the page reads as frozen. The camera is fixed
        // and there is nothing here to interact with, so the whole view opts out.
        map.isUserInteractionEnabled = false
        map.setRegion(MKCoordinateRegion(center: center,
                                         latitudinalMeters: radiusMeters * 2,
                                         longitudinalMeters: radiusMeters * 2),
                      animated: false)
        context.coordinator.attach(to: map)
        return map
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.radar = radar

        if c.appliedCenter?.latitude != center.latitude
            || c.appliedCenter?.longitude != center.longitude
            || c.appliedRadius != radiusMeters {
            c.appliedCenter = center
            c.appliedRadius = radiusMeters
            map.setRegion(MKCoordinateRegion(center: center,
                                             latitudinalMeters: radiusMeters * 2,
                                             longitudinalMeters: radiusMeters * 2),
                          animated: true)
        }

        // --- Warning outlines ---
        let outlineIDs = hazards.map(\.id)
        if c.installedOutlines != outlineIDs {
            for overlay in map.overlays where overlay is TVHazardPolygon { map.removeOverlay(overlay) }
            for hazard in hazards {
                for ring in hazard.shape?.rings ?? [] where ring.count > 2 {
                    let coords = ring.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                    let polygon = TVHazardPolygon(coordinates: coords, count: coords.count)
                    polygon.tint = UIColor(hazard.tint)
                    map.addOverlay(polygon, level: .aboveLabels)
                }
            }
            c.installedOutlines = outlineIDs
        }

        // --- Coverage rings ---
        if c.installedCoverage != coverage {
            for overlay in map.overlays where overlay is TVCoverageRing { map.removeOverlay(overlay) }
            map.removeAnnotations(map.annotations.compactMap { $0 as? TVCoverageLabel })
            if let coverage {
                let center = CLLocationCoordinate2D(latitude: coverage.latitude, longitude: coverage.longitude)
                for ring in coverage.rings {
                    let circle = TVCoverageRing(center: center, radius: ring.radius)
                    circle.kind = ring.kind
                    map.addOverlay(circle, level: .aboveLabels)
                    // Due north sits on the ring along a meridian, no great-circle work.
                    let north = CLLocationCoordinate2D(latitude: center.latitude + ring.radius / 111_195,
                                                       longitude: center.longitude)
                    map.addAnnotation(TVCoverageLabel(text: ring.label, coordinate: north))
                }
            }
            c.installedCoverage = coverage
        }

        // --- The field ---
        c.installField(on: map)
        c.apply()
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var radar: RadarModel
        var appliedCenter: CLLocationCoordinate2D?
        var appliedRadius: Double?
        var installedOutlines: [String] = []
        var installedCoverage: RadarCoverage?

        /// The source the two slots were built for. A different site is a
        /// different source, and gets fresh overlays.
        private var installedSource: String?
        private var slots: [Int: FieldRenderer] = [:]
        private weak var map: MKMapView?
        private var link: CADisplayLink?
        /// The tiles this view last said it needed, so new scans can be
        /// prefetched without waiting for the map to redraw.
        private var visibleTiles: [FieldTileGrid.Tile] = []
        private var prefetchedStamps: [String] = []

        init(radar: RadarModel) { self.radar = radar }

        func attach(to map: MKMapView) {
            self.map = map
            let link = CADisplayLink(target: self, selector: #selector(refresh))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func detach() { link?.invalidate(); link = nil }

        /// Two overlays for the current site: the frame leaving and the frame
        /// arriving. Rebuilt only when the site changes.
        func installField(on map: MKMapView) {
            let source = radar.fieldSource
            guard source?.id != installedSource else { return }
            for overlay in map.overlays where overlay is FieldOverlay { map.removeOverlay(overlay) }
            slots = [:]
            installedSource = source?.id
            visibleTiles = []
            prefetchedStamps = []
            guard let source else { return }
            radarLog.info("tv: field installed for \(source.id, privacy: .public)")
            for slot in 0...1 {
                map.addOverlay(FieldOverlay(source: source, layerID: "radar", slot: slot), level: .aboveRoads)
            }
        }

        @objc private func refresh() {
            // THE SITE IS CHECKED HERE, NOT ONLY IN `updateUIView`. SwiftUI
            // calls that when this view's inputs change, and the radar model is
            // an object reference that never does — so a site chosen a moment
            // after launch never reached the map, and nothing was drawn. The
            // guard inside makes this free when nothing has changed.
            if let map { installField(on: map) }
            apply()
            // New scans arrive with nothing on screen having moved, so nothing
            // would ask for their tiles. Ask here when the list changes.
            if radar.stampsByUrgency != prefetchedStamps, !visibleTiles.isEmpty {
                prefetch(visibleTiles)
            }
        }

        /// The Mac's dissolve, read off the shared clock. See `MapCanvas.apply`
        /// for why the incoming slot is held at 1% rather than zero.
        func apply() {
            guard let out = slots[0], let incoming = slots[1] else { return }
            let head = radar.playhead
            let a = head.a?.stamp ?? "", b = head.b?.stamp ?? a
            let isStill = b.isEmpty || b == a
            if out.set(stamp: a) { out.setNeedsDisplay() }
            if incoming.set(stamp: isStill ? "" : b) { incoming.setNeedsDisplay() }
            let alphaOut = isStill ? 1 : 1 - head.blend
            let alphaIn = isStill ? 0 : max(head.blend, 0.01)
            if abs(Double(out.alpha) - alphaOut) > 0.002 { out.alpha = CGFloat(alphaOut) }
            if abs(Double(incoming.alpha) - alphaIn) > 0.002 { incoming.alpha = CGFloat(alphaIn) }
        }

        private func prefetch(_ tiles: [FieldTileGrid.Tile]) {
            guard let source = radar.fieldSource else { return }
            let stamps = radar.stampsByUrgency
            prefetchedStamps = stamps
            let store = FieldTileStore.shared
            // Coarse first, so every frame has a soft picture within a second.
            store.prefetch(stamps: stamps,
                           tiles: FieldTileGrid.parents(of: tiles, levelsUp: 2,
                                                        notBelow: source.zoomRange.lowerBound),
                           from: source)
            store.prefetch(stamps: stamps, tiles: tiles, from: source)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let field = overlay as? FieldOverlay {
                if let existing = slots[field.slot] { return existing }
                let renderer = FieldRenderer(overlay: field)
                let scale = mapView.traitCollection.displayScale
                renderer.tileScale = Double(scale > 0 ? scale : 1)
                renderer.onVisibleTiles = { [weak self] tiles, _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        let known = Set(self.visibleTiles)
                        let grown = known.union(tiles)
                        guard grown.count > known.count else { return }
                        self.visibleTiles = Array(grown)
                        self.prefetch(self.visibleTiles)
                    }
                }
                slots[field.slot] = renderer
                renderer.alpha = field.slot == 0 ? 1 : 0
                radarLog.info("tv: renderer slot \(field.slot) created, scale \(renderer.tileScale)")
                return renderer
            }
            if let ring = overlay as? TVCoverageRing {
                let renderer = MKCircleRenderer(circle: ring)
                // Heavier than the Mac's, for the same reason as the warning
                // outlines: it has to survive the far side of a room.
                switch ring.kind {
                case .reach:
                    renderer.strokeColor = UIColor.white.withAlphaComponent(0.6)
                    renderer.lineWidth = 3
                case .beamHeight:
                    renderer.strokeColor = UIColor.white.withAlphaComponent(0.4)
                    renderer.lineWidth = 2
                    renderer.lineDashPattern = [10, 10]
                }
                return renderer
            }
            if let polygon = overlay as? TVHazardPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.strokeColor = polygon.tint
                // Heavier than the Mac's 2.5pt. A warning boundary has to survive
                // being looked at from the far side of a room.
                renderer.lineWidth = 5
                renderer.fillColor = polygon.tint.withAlphaComponent(0.10)
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let label = annotation as? TVCoverageLabel else { return nil }
            let view = MKAnnotationView(annotation: label, reuseIdentifier: nil)
            let renderer = ImageRenderer(content:
                Text(label.text)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.black.opacity(0.62), in: Capsule()))
            renderer.scale = UITraitCollection.current.displayScale
            view.image = renderer.uiImage
            view.displayPriority = .defaultHigh
            return view
        }
    }
}

final class TVCoverageRing: MKCircle {
    var kind: RadarCoverage.Ring.Kind = .reach
}

final class TVCoverageLabel: NSObject, MKAnnotation {
    let text: String
    let coordinate: CLLocationCoordinate2D
    init(text: String, coordinate: CLLocationCoordinate2D) {
        self.text = text; self.coordinate = coordinate
    }
}

final class TVHazardPolygon: MKPolygon {
    var tint: UIColor = .orange
}
