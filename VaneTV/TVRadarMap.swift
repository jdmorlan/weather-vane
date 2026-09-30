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
//  WHO MOVES THE LOOP. Not this view. `TVLoopDriver` owns the one display link
//  that ticks the clock; the map only reads the playhead on its own refreshes
//  and applies it.
//
//  PAUSED, NOT HIDDEN, OFF THE MAP TAB. The map stays mounted behind the tabs
//  (see `MapTab.swift` for why), so on Now and Forecast it is transparent
//  rather than gone — and its two display links used to go on ticking at
//  60 Hz under it, applying a loop nobody could see. `isActive` pauses both.
//  Measured on an Apple TV 4K sitting on Now: 0% CPU. The scans still
//  download and decode, so the loop is ready when you come back.
//
//  THE OUTLOOKS DRAW ON THE SAME MAP, through the Mac's `RegionOverlay`: the
//  whole outlook as one overlay with one renderer. Not one `MKPolygon` per
//  shape — tried, and a seven-day rain total, thousands of rings, took the app
//  from 700 MB to 1.5 GB each time it came up. While an outlook is up the
//  radar comes off the map entirely — its two overlays removed, its clock
//  paused — rather than being drawn underneath where nobody could read either.
//
//  NOT `isHidden`. Tried: hiding the MKMapView made MapKit drop its 4K
//  drawing and build it again on the next switch, and the app went from 950
//  MB to 1.5 GB in a second and was killed — the very spike the backdrop
//  exists to avoid.
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

    /// Holds the playhead where it is while the map is out of sight.
    func pause(_ paused: Bool) {
        link?.isPaused = paused
        // The next tick after a pause measures from itself, not from when the
        // pause began, so the loop does not leap forward on return.
        last = nil
    }

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
    /// The radar's reach and beam-height rings.
    var coverage: RadarCoverage? = nil
    /// False while another tab is showing. See the header.
    var isActive = true
    /// False while an outlook is showing instead of the radar.
    var showsRadar = true
    /// The storm or flooding-rain outlook to draw, when one is chosen.
    var outlook: Outlook? = nil
    /// The home state's counties and its edge, over every view.
    var counties: BoundarySet? = nil
    var stateOutline: BoundarySet? = nil

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
        c.showsRadar = showsRadar
        c.setActive(isActive && showsRadar)

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

        // --- Counties and the state's edge ---
        let lineIDs = [counties?.id, stateOutline?.id].compactMap { $0 }
        if c.installedLines != lineIDs {
            for overlay in map.overlays where overlay is BoundaryOverlay { map.removeOverlay(overlay) }
            // Over the radar and the outlooks, as on the Mac: the lines are
            // how you read which counties a picture covers.
            for set in [counties, stateOutline].compactMap({ $0 }) {
                map.addOverlay(BoundaryOverlay(set), level: .aboveLabels)
            }
            c.installedLines = lineIDs
        }

        // --- Outlook areas ---
        let outlookID = outlook.map { "\($0.product)-\($0.period)-\($0.issued?.timeIntervalSince1970 ?? 0)" }
        if c.installedOutlook != outlookID {
            for overlay in map.overlays where overlay is RegionOverlay { map.removeOverlay(overlay) }
            if let outlook, !outlook.areas.isEmpty, let outlookID {
                // Rain totals are read by colour, the outlooks by their edge —
                // the Mac's weights, with heavier edges for across a room.
                let isAmount = outlook.product == .rainTotals
                let set = RegionSet(id: outlookID, fillOpacity: isAmount ? 0.6 : 0.55,
                                    strokeWidth: isAmount ? 1 : 3,
                                    regions: outlook.areas.map { area in
                    (rings: area.shape.rings.map { ring in
                        ring.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                     },
                     fill: area.fill.cgColor, stroke: area.stroke.cgColor)
                })
                // Below the labels, so the towns stay readable.
                map.addOverlay(RegionOverlay(set), level: .aboveRoads)
            }
            c.installedOutlook = outlookID
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
        var installedOutlook: String?
        var installedLines: [String] = []
        /// While false the radar's overlays are off the map. See the header.
        var showsRadar = true

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

        /// Off the Map tab the map still redraws when the layout around it
        /// changes, and each redraw reported tiles that were then prefetched
        /// for every scan — measured, a switch to Now asked for 690 MB.
        private var isActive = true

        func setActive(_ active: Bool) {
            isActive = active
            link?.isPaused = !active
        }

        /// ONE ZOOM AT A TIME. The camera only moves when the range changes,
        /// and then it animates through the zooms in between; each reported
        /// its tiles, and kept in one list they asked for three times what the
        /// cache holds. A report at a new zoom replaces the list; the same zoom
        /// adds to it, because a single redraw reports only part of the screen.
        private func saw(_ reported: [FieldTileGrid.Tile]) {
            guard let z = reported.map(\.z).max() else { return }
            let tiles = reported.filter { $0.z == z }
            if visibleTiles.first?.z != z {
                visibleTiles = tiles
            } else {
                let known = Set(visibleTiles)
                let grown = known.union(tiles)
                guard grown.count > known.count else { return }
                visibleTiles = Array(grown)
            }
            prefetch(visibleTiles)
        }

        /// A NEW RANGE IS A NEW PICTURE, so the list of tiles the loop
        /// prefetches starts again once the camera has arrived. Without this
        /// every range you had ever looked at stayed in the list, and so did
        /// every zoom the animation passed through on the way: measured on the
        /// TV, walking the ranges took one loop's request from 270 MB to 990 MB,
        /// far past the tile cache, and the tiles were redrawn forever.
        ///
        /// On ARRIVAL, not on the request. Cleared when the range was picked,
        /// the zooms in between piled straight back in.
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            visibleTiles = []
            prefetchedStamps = []
        }

        /// Two overlays for the current site: the frame leaving and the frame
        /// arriving. Rebuilt only when the site changes.
        func installField(on map: MKMapView) {
            let source = showsRadar ? radar.fieldSource : nil
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
                // AT MOST ONE TILE PIXEL PER POINT, never more. Two things
                // pushed it past that, both measured on the TV:
                //   · the zoom is rounded to the nearest level, so a range could
                //     land at 1.4 pixels per point — twice the tiles each way;
                //   · MapKit's zoom scale here counts the 4K screen's PIXELS, two
                //     per point, so a scale of 1 was really 2.
                // Close drew at z11 with 45 tiles a scan; the loop asked for
                // 675 MB of tiles, and the app is killed at about 1.3 GB.
                // 1/(2√2) undoes the pixels and turns the rounding into a floor:
                // 0.5 to 1 tile pixel per point at every range. Level II gates
                // are 250 m apart, coarser than a point at every range but
                // Regional, so the field loses nothing it had.
                renderer.tileScale = 1 / (2 * 2.0.squareRoot())
                renderer.onVisibleTiles = { [weak self] tiles, _ in
                    DispatchQueue.main.async {
                        guard let self, self.isActive else { return }
                        self.saw(tiles)
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
            if let lines = overlay as? BoundaryOverlay {
                // Heavier than the Mac's hairlines, for across a room. The
                // state's edge holds at every zoom; counties fade out when the
                // map is wide enough to make them a mesh.
                let isState = lines.set.id.hasPrefix("state-")
                return BoundaryRenderer(boundary: lines,
                                        ink: UIColor.white.withAlphaComponent(isState ? 0.85 : 0.4).cgColor,
                                        width: isState ? 3 : 1.4, fades: !isState)
            }
            if let region = overlay as? RegionOverlay {
                return RegionRenderer(region: region)
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
