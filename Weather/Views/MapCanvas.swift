//
//  MapCanvas.swift  (Weather)
//
//  ONE map, drawn from a list of LAYERS. Reusable on purpose: the sidebar's Map
//  surface mounts it full-bleed, and a `place` block can mount the same thing in
//  its expanded view later without a second implementation.
//
//  TWO DISTINCTIONS RUN THROUGH THIS FILE, and they are orthogonal — a layer has
//  an answer to both, and neither answer implies the other.
//
//  WHAT A LAYER IS MADE OF — `MapLayerContent`. Pins are keyed by ID, owned by
//  you, and persist; a field is keyed by TIME, fetched, and expires. Forcing
//  radar to become a block to get it on screen would have been the mistake, and
//  the two disagreeing about what an `id` even means is the cheapest possible
//  proof of that. (This used to be spelled out as a `MapLayerFamily` that nothing
//  but the panel read. It is the shape of the content enum now, where it is
//  enforced rather than merely asserted.)
//
//  HOW MUCH SCREEN IT CLAIMS — `MapLayerRole`, and this is the one that decides
//  what can coexist. A raster field is full-bleed and mostly opaque, so two of
//  them do not layer, they FIGHT: whichever draws second wins and the other was
//  never worth fetching. Sparse marks composite over anything. So subjects are
//  exclusive and context is additive, and the panel is built to make that
//  impossible to get wrong rather than merely discouraged.
//

import SwiftUI
import MapKit
import WeatherKit

// MARK: - Layer model

/// What a layer is FOR, which is what decides whether it can coexist with another.
enum MapLayerRole: String, Hashable {
    /// A full-bleed raster field — the map's SUBJECT. Mutually exclusive by
    /// nature, not by policy: radar under a burn-ban wash is not a layered
    /// picture, it is a fetched loop nobody can see.
    case subject
    /// Sparse marks that composite over anything — where you are, what is urgent.
    /// Additive, because an outline and a pin cost the map nothing.
    case context

    var heading: String {
        switch self {
        case .subject: return "View"
        case .context: return "Always"
        }
    }
}

/// What a layer actually puts on the map.
enum MapLayerContent {
    case pins([MapPin])
    /// A raster field — radar, satellite, fire. See `FieldRenderer` for why this
    /// becomes exactly two overlays — the frame leaving and the frame arriving —
    /// rather than one per frame or one that blends both itself.
    case field(FieldLayer)
    case outlines([MapOutline])
    /// One radar's reach and beam-height rings. See `RadarCoverage`.
    case coverage(RadarCoverage)
    /// Filled forecast areas — an SPC or WPC outlook. See `MapShapes` for why
    /// they are painted as one group rather than polygon by polygon.
    case regions(RegionSet)
    /// Lines with nothing inside them — county boundaries.
    case boundaries(BoundarySet)
}

/// A raster field and where its loop currently is.
///
/// THE SOURCE IS THE IDENTITY. Two layers with the same `source.id` draw the same
/// pixels, so the canvas rebuilds an overlay only when that id changes — a
/// playhead moving is not a reason to touch the map at all, which is the whole
/// point of the rewrite.
struct FieldLayer {
    let source: FieldTileSource
    /// Every stamp in the loop, oldest first, for prefetching. A single-entry
    /// list is a still.
    var stamps: [String]
    var playhead: FieldRenderer.Playhead
}

struct MapPin: Identifiable, Equatable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let title: String
    let subtitle: String?
    /// Present when this pin stands for something openable. Nothing in this app
    /// sets it yet — it was a `BlockID` in Almanac, and widening it to an opaque
    /// string is what let the canvas come across without the block model having to
    /// follow it. The canvas never interprets it; it only hands it back.
    let openID: String?
    let tint: Color
    /// An AREA rather than a point (`PlaceLocation.radiusMeters`). A locality is
    /// genuinely a region, and drawing it as a pin would claim a precision the
    /// place never had. Same refusal as a hazard's `resolution`.
    let radiusMeters: Double?

    static func == (a: MapPin, b: MapPin) -> Bool { a.id == b.id }
}

struct MapOutline: Identifiable, Equatable {
    let id: String
    let rings: [[CLLocationCoordinate2D]]
    let tint: Color

    static func == (a: MapOutline, b: MapOutline) -> Bool { a.id == b.id }
}

struct MapLayer: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let role: MapLayerRole
    var isOn: Bool
    let content: MapLayerContent
    /// What the layer can say about itself in one glance — "8 places", "10:20 PM".
    /// Nil when it has nothing true to add; see [[controls-earn-their-space]].
    var caption: String?

    var pins: [MapPin] { if case .pins(let p) = content { return p }; return [] }
    var outlines: [MapOutline] { if case .outlines(let o) = content { return o }; return [] }
    var coverage: RadarCoverage? { if case .coverage(let c) = content { return c }; return nil }
    var regions: RegionSet? { if case .regions(let r) = content { return r }; return nil }
    var boundaries: BoundarySet? { if case .boundaries(let b) = content { return b }; return nil }
    var field: FieldLayer? {
        if case .field(let field) = content { return field }
        return nil
    }
}

/// A request to move the camera. A TOKEN rather than a binding, because the map's
/// region is the user's after they first touch it — recentring on every SwiftUI
/// update would fight the pan they are in the middle of.
struct MapFocus: Equatable {
    var center: CLLocationCoordinate2D
    var radiusMeters: Double
    /// Bumped by the caller to re-issue the same focus.
    var token: Int

    static func == (a: MapFocus, b: MapFocus) -> Bool { a.token == b.token }
}

// MARK: - The canvas

/// MapKit is the same framework on both platforms; only the representable's
/// spelling differs. See `PlatformBridge` for the rule about where a fork lives.
#if os(macOS)
typealias MapViewRepresentable = NSViewRepresentable
#else
typealias MapViewRepresentable = UIViewRepresentable
#endif

struct MapCanvas: MapViewRepresentable {
    let layers: [MapLayer]
    var focus: MapFocus?
    var onSelect: (String) -> Void = { _ in }

    /// Called once per display refresh with the seconds since the last one, and
    /// answers with where each field layer's loop now is, by layer id.
    ///
    /// WHY THE DISPLAY LINK DOES NOT GO THROUGH SWIFTUI. A dissolve moves its
    /// blend on every refresh. Routing that through `@Published` would run a full
    /// SwiftUI update pass — rebuilding every layer, diffing every pin — sixty
    /// times a second in order to change one `CGFloat` that only the renderer
    /// reads. This hands the number straight to the renderer and leaves SwiftUI
    /// to the things that change at human speed.
    var onDisplayTick: ((Double) -> [String: FieldRenderer.Playhead])?

    /// The tiles a field layer's viewport needs, whenever that set changes.
    /// This is what drives prefetching, and it is correct across a pan by
    /// construction — the renderer computes coverage from the viewport it was
    /// just asked to draw, rather than inferring it from what MapKit asked for.
    var onVisibleTiles: ((String, [FieldTileGrid.Tile]) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

#if os(macOS)
    func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateNSView(_ map: MKMapView, context: Context) { updateMap(map, context: context) }
    static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
    }
#else
    func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateUIView(_ map: MKMapView, context: Context) { updateMap(map, context: context) }
    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
    }
#endif

    private func makeMap(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .mutedStandard
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        #if os(macOS)
        map.showsZoomControls = true
        #endif
        // The whole reason this is a surface and not the Weather card: here you
        // are looking AROUND, so the camera is yours.
        map.isScrollEnabled = true
        map.isZoomEnabled = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.register(MapPinView.self, forAnnotationViewWithReuseIdentifier: MapPinView.reuseID)
        if let focus {
            map.setRegion(region(focus), animated: false)
            context.coordinator.appliedFocus = focus.token
        }
        context.coordinator.startDisplayLink(on: map)
        return map
    }

    private func updateMap(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.onSelect = onSelect

        if let focus, c.appliedFocus != focus.token {
            c.appliedFocus = focus.token
            map.setRegion(region(focus), animated: true)
        }

        let visible = layers.filter(\.isOn)

        // --- Pins -------------------------------------------------------------
        let pins = visible.flatMap(\.pins)
        if c.installedPins != pins.map(\.id) {
            map.removeAnnotations(map.annotations.compactMap { $0 as? PinAnnotation })
            map.addAnnotations(pins.map(PinAnnotation.init))
            c.installedPins = pins.map(\.id)
        }

        // --- Areas ------------------------------------------------------------
        let areas = pins.filter { $0.radiusMeters != nil }
        if c.installedAreas != areas.map(\.id) {
            for overlay in map.overlays where overlay is AreaCircle { map.removeOverlay(overlay) }
            for pin in areas {
                let circle = AreaCircle(center: pin.coordinate, radius: pin.radiusMeters ?? 0)
                circle.tint = pin.tint
                map.addOverlay(circle, level: .aboveRoads)
            }
            c.installedAreas = areas.map(\.id)
        }

        // --- Outlines (warning polygons) --------------------------------------
        let outlines = visible.flatMap(\.outlines)
        if c.installedOutlines != outlines.map(\.id) {
            for overlay in map.overlays where overlay is HazardPolygon { map.removeOverlay(overlay) }
            for outline in outlines {
                for ring in outline.rings where ring.count > 2 {
                    let polygon = HazardPolygon(coordinates: ring, count: ring.count)
                    polygon.tintColor = outline.tint
                    map.addOverlay(polygon, level: .aboveLabels)
                }
            }
            c.installedOutlines = outlines.map(\.id)
        }

        // --- Radar coverage rings ---------------------------------------------
        let coverage = visible.compactMap(\.coverage).first
        if c.installedCoverage != coverage {
            for overlay in map.overlays where overlay is CoverageRing { map.removeOverlay(overlay) }
            map.removeAnnotations(map.annotations.compactMap { $0 as? CoverageLabel })
            if let coverage {
                let center = CLLocationCoordinate2D(latitude: coverage.latitude, longitude: coverage.longitude)
                for ring in coverage.rings {
                    let circle = CoverageRing(center: center, radius: ring.radius)
                    circle.kind = ring.kind
                    map.addOverlay(circle, level: .aboveLabels)
                    map.addAnnotation(CoverageLabel(text: ring.label, coordinate:
                        CoverageLabel.north(of: center, by: ring.radius)))
                }
                map.addAnnotation(CoverageLabel(text: coverage.site, coordinate: center, isSite: true))
            }
            c.installedCoverage = coverage
        }

        // --- Forecast areas (outlooks) ----------------------------------------
        //
        // Above roads and under labels, so the town names you place yourself by
        // stay legible through the fill.
        let regions = visible.compactMap(\.regions)
        if c.installedRegions != regions.map(\.id) {
            for overlay in map.overlays where overlay is RegionOverlay { map.removeOverlay(overlay) }
            for set in regions { map.addOverlay(RegionOverlay(set), level: .aboveRoads) }
            c.installedRegions = regions.map(\.id)
        }

        // --- Boundary lines (counties) ----------------------------------------
        //
        // The BOTTOM of the above-labels level: over every field and every
        // outlook fill, because a line under a raster is a line you cannot see,
        // but under the warnings and radar rings, which are the things drawn on
        // purpose for right now.
        let boundaries = visible.compactMap(\.boundaries)
        if c.installedBoundaries != boundaries.map(\.id) {
            for overlay in map.overlays where overlay is BoundaryOverlay { map.removeOverlay(overlay) }
            for set in boundaries { map.insertOverlay(BoundaryOverlay(set), at: 0, level: .aboveLabels) }
            c.installedBoundaries = boundaries.map(\.id)
        }

        // --- Fields (radar, satellite, fire) ----------------------------------
        //
        // TWO OVERLAYS PER LAYER, AND NEITHER IS EVER REBUILT TO ANIMATE.
        //
        // One holds the frame dissolving out, the other the frame dissolving in.
        // Advancing the loop re-points each renderer at a stamp; crossfading them
        // is `MKOverlayRenderer.alpha`, which MapKit applies at composite time. No
        // overlay is added, removed or diffed to show the next scan, and no pixel
        // is blended twice. `FieldRenderer`'s header has the full account of why
        // this is the third shape this has taken and what was wrong with the other
        // two.
        let fields = visible.compactMap { layer in layer.field.map { (layer.id, $0) } }
        let wanted = fields.map { "\($0.0)|\($0.1.source.id)" }
        if c.installedFields != wanted {
            for overlay in map.overlays where overlay is FieldOverlay { map.removeOverlay(overlay) }
            c.fieldRenderers.removeAll()
            c.reportedTiles.removeAll()
            // Added in layer order so the list's top-to-bottom is the map's
            // back-to-front — radar under warnings, satellite under radar. Within
            // a layer, slot 1 goes on top of slot 0: it is the frame arriving, and
            // fading it IN over the one leaving is the direction that never shows
            // a gap between them.
            for (layerID, field) in fields {
                for slot in 0...1 {
                    map.addOverlay(FieldOverlay(source: field.source, layerID: layerID, slot: slot),
                                   level: .aboveRoads)
                }
            }
            c.installedFields = wanted
        }

        // The playhead is pushed every pass as well as from the display link, so
        // a layer that was just switched on draws immediately rather than waiting
        // for the next refresh.
        for (layerID, field) in fields {
            c.apply(field.playhead, to: layerID)
        }

        c.onVisibleTiles = onVisibleTiles
        c.onDisplayTick = onDisplayTick
    }

    private func region(_ focus: MapFocus) -> MKCoordinateRegion {
        MKCoordinateRegion(center: focus.center,
                           latitudinalMeters: focus.radiusMeters * 2,
                           longitudinalMeters: focus.radiusMeters * 2)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var onSelect: (String) -> Void
        var appliedFocus: Int?
        var installedPins: [String] = []
        var installedAreas: [String] = []
        var installedOutlines: [String] = []
        var installedCoverage: RadarCoverage?
        var installedRegions: [String] = []
        var installedBoundaries: [String] = []
        /// `layerID|sourceID` per installed field, in draw order. The source id is
        /// in the key because changing a ramp changes the pixels, and the overlay
        /// has to be rebuilt for that even though the layer is "the same" layer.
        var installedFields: [String] = []
        /// Held by layer id and then by SLOT: MapKit makes a renderer once per
        /// overlay and asks for it again on every redraw, so keeping them is what
        /// lets the display link move a crossfade without touching the map. Slot 0
        /// is the frame dissolving out, slot 1 the one dissolving in.
        var fieldRenderers: [String: [Int: FieldRenderer]] = [:]
        /// The tiles reported per layer SO FAR FOR THIS VIEWPORT, unioned.
        ///
        /// A UNION AND NOT THE LAST SET, because MapKit calls `draw` once per map
        /// rect rather than once per viewport — so any single call describes a
        /// slice of the screen. Replacing on each call still prefetched
        /// everything (every rect does get drawn eventually), but it meant the
        /// status line counted its progress against one slice's worth of tiles:
        /// a denominator that changed every paint, and a bar that could read
        /// "complete" with most of the map still missing.
        var reportedTiles: [String: Set<FieldTileGrid.Tile>] = [:]

        var onDisplayTick: ((Double) -> [String: FieldRenderer.Playhead])?
        var onVisibleTiles: ((String, [FieldTileGrid.Tile]) -> Void)?

        private var displayLink: CADisplayLink?
        private var lastTick: CFTimeInterval?

        /// For the sweep trail, which the display tick adds and removes itself.
        private weak var mapView: MKMapView?
        /// The wedge each field layer is revealing, so the next tick knows which
        /// sector changed and the end of a reveal can be noticed.
        private var activeReveal: [String: FieldRenderer.Reveal] = [:]
        private var trail: SweepTrailOverlay?
        private var trailRenderer: SweepTrailRenderer?

        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        // MARK: The clock

        /// A DISPLAY LINK RATHER THAN A TIMER, and the difference is the whole
        /// point. A dissolve is only smooth if it is sampled on the refreshes it
        /// will actually be shown on; a `Timer` at a nominal 60 Hz drifts against
        /// the display and lands two steps on one frame and none on the next,
        /// which reads as precisely the judder this replaces.
        func startDisplayLink(on view: MKMapView) {
            mapView = view
            guard displayLink == nil else { return }
            // AppKit hands out a link bound to the view's own display, which is
            // what keeps a dissolve smooth when the window is dragged to a second
            // monitor. UIKit has no such problem to solve and no such API.
            #if os(macOS)
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            #else
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            #endif
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            let now = link.timestamp
            defer { lastTick = now }
            guard let last = lastTick, let onDisplayTick else { return }
            let delta = now - last
            // A NEGATIVE OR ENORMOUS DELTA IS NOT TIME PASSING. Waking from sleep
            // and switching displays both hand the link a timestamp from a
            // different clock; `FieldLoopClock` caps the advance too, but there is
            // no reason to feed it nonsense to cap.
            guard delta > 0, delta < 1 else { return }

            for (layerID, playhead) in onDisplayTick(delta) {
                apply(playhead, to: layerID)
            }
        }

        /// Point the layer's two renderers at the frames the clock names, and set
        /// the weights it wants.
        ///
        /// THE ONLY EXPENSIVE THING HERE IS `setNeedsDisplay`, AND IT HAPPENS ONCE
        /// PER FRAME, NOT ONCE PER REFRESH. A stamp changes about twice a second;
        /// the alpha between them moves sixty times a second and costs two float
        /// assignments, because MapKit applies a renderer's alpha when it
        /// composites rather than by asking it to draw again.
        func apply(_ head: FieldRenderer.Playhead, to layerID: String) {
            guard let slots = fieldRenderers[layerID],
                  let first = slots[0], let second = slots[1] else { return }
            // THE FRAME ON SCREEN STAYS WHERE IT IS DRAWN. When the loop moves
            // on, the scan that was dissolving in becomes the one dissolving
            // out — and it is already rasterised in its slot. Fixed roles made
            // the out slot redraw that same scan at full strength at every
            // advance, piece by piece, which showed as squares of bare map.
            // Swapped, the only redraw is the new frame, at 1%.
            let (out, incoming) = !head.stampA.isEmpty && second.shownStamp == head.stampA
                ? (second, first) : (first, second)
            let coarser = [out.set(levelsUp: head.levelsUp), incoming.set(levelsUp: head.levelsUp)]
            if coarser[0] { out.setNeedsDisplay() }
            if coarser[1] { incoming.setNeedsDisplay() }

            updateTrail(head)
            if let site = head.sweep {
                applySweep(site, head: head, out: out, incoming: incoming, layerID: layerID)
                return
            }
            if activeReveal[layerID] != nil {
                endReveal(out: out, incoming: incoming, layerID: layerID)
            }

            // A still — a layer with no loop, or a paused one — names the same
            // scan twice. Drawing it into both slots would composite a picture
            // over itself, which at any alpha but 1 reads as a faint double
            // exposure.
            let isStill = head.stampB.isEmpty || head.stampB == head.stampA

            if out.set(stamp: head.stampA) { out.setNeedsDisplay() }
            if incoming.set(stamp: isStill ? "" : head.stampB) { incoming.setNeedsDisplay() }

            // THE INCOMING FRAME IS NEVER QUITE AT ZERO WHILE IT HAS A STAMP, and
            // that 1% is load-bearing. MapKit does not rasterise an overlay it is
            // not drawing — the original one-overlay-per-frame design's real bug —
            // so a slot held at a true 0 would have to rasterise the whole viewport
            // at the instant its dissolve began, which is a hitch exactly where a
            // hitch is most visible. Kept barely on, it is already drawn when the
            // fade starts. At 1% over a map it is not a picture anyone can see.
            let held = 0.01
            // Out fades only as fast as in covers for it — see `FieldDissolve`.
            let fade = FieldDissolve.alphas(blend: head.blend, opacity: head.opacity,
                                            fieldAlpha: out.source.dissolveOpacity)
            let alphaOut = isStill ? head.opacity : fade.out
            let alphaIn = isStill ? 0 : max(fade.in, held)
            if abs(Double(out.alpha) - alphaOut) > 0.002 { out.alpha = CGFloat(alphaOut) }
            if abs(Double(incoming.alpha) - alphaIn) > 0.002 { incoming.alpha = CGFloat(alphaIn) }
        }

        /// The viewport's tiles, reported up so the loop can be prefetched.
        /// Only when the union actually GREW, because a paint happens far more
        /// often than a pan and re-asking for the same eighty tiles is pure noise.
        func report(tiles: [FieldTileGrid.Tile], for layerID: String) {
            var known = reportedTiles[layerID] ?? []
            let before = known.count
            known.formUnion(tiles)
            guard known.count > before else { return }
            reportedTiles[layerID] = known
            onVisibleTiles?(layerID, Array(known))
        }

        /// A finished pan or zoom means the old union describes somewhere else.
        /// Cleared at the END of the gesture rather than continuously: during a
        /// drag the union growing to cover everywhere you passed over is harmless
        /// — those tiles are cheap and often where you are heading — but a
        /// denominator that reset sixty times a second would make the status line
        /// unreadable.
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            reportedTiles.removeAll()
        }

        // MARK: Sweep mode

        /// SWEEP MODE'S TWO SLOTS. Between reveals, the scan on screen alone. While
        /// one is coming in, both fully on and each clipped to its side of the line:
        /// the new scan inside the swept wedge, the old one outside it.
        private func applySweep(_ site: SweepSite, head: FieldRenderer.Playhead,
                                out: FieldRenderer, incoming: FieldRenderer, layerID: String) {
            let alpha = CGFloat(head.opacity)
            if out.alpha != alpha { out.alpha = alpha }

            guard let reveal = head.reveal else {
                if activeReveal[layerID] != nil { endReveal(out: out, incoming: incoming, layerID: layerID) }
                if out.set(stamp: head.stampA) { out.setNeedsDisplay() }
                if incoming.set(stamp: "") { incoming.setNeedsDisplay() }
                if incoming.alpha != 0 { incoming.alpha = 0 }
                return
            }

            let previous = activeReveal[layerID]
            let wedge = SweepGeometry.wedge(site, from: reveal.from, span: reveal.turned)
            out.set(clip: .outside(wedge))
            incoming.set(clip: .inside(wedge))
            let outMoved = out.set(stamp: head.stampA)
            let inMoved = incoming.set(stamp: head.stampB)
            if previous == nil || outMoved || inMoved || previous?.from != reveal.from {
                out.setNeedsDisplay(); incoming.setNeedsDisplay()
            } else if let previous {
                let dirty = SweepGeometry.sectorRect(site, from: reveal.from + previous.turned,
                                                     span: reveal.turned - previous.turned + 1)
                out.setNeedsDisplay(dirty); incoming.setNeedsDisplay(dirty)
            }
            if incoming.alpha != alpha { incoming.alpha = alpha }
            activeReveal[layerID] = reveal
        }

        private func endReveal(out: FieldRenderer, incoming: FieldRenderer, layerID: String) {
            activeReveal[layerID] = nil
            out.set(clip: nil); incoming.set(clip: nil)
            out.setNeedsDisplay(); incoming.setNeedsDisplay()
        }

        /// The line and its glow: on while a layer is in sweep mode, off otherwise.
        private func updateTrail(_ head: FieldRenderer.Playhead) {
            guard let site = head.sweep else {
                if let trail { mapView?.removeOverlay(trail) }
                trail = nil; trailRenderer = nil
                return
            }
            if let trail, trail.site == site {
                // MapKit may not have asked for the renderer yet on the first
                // tick or two; the next update catches up.
                trailRenderer?.update(azimuth: head.beamAzimuth)
            } else if let mapView {
                if let trail { mapView.removeOverlay(trail) }
                let new = SweepTrailOverlay(site)
                trail = new
                trailRenderer = nil
                mapView.addOverlay(new, level: .aboveLabels)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let trail = overlay as? SweepTrailOverlay {
                let renderer = SweepTrailRenderer(trail: trail)
                if trail === self.trail { trailRenderer = renderer }
                return renderer
            }
            if let field = overlay as? FieldOverlay {
                if let existing = fieldRenderers[field.layerID]?[field.slot] { return existing }
                let renderer = FieldRenderer(overlay: field)
                // Buys a zoom level on a retina display, which is the difference
                // between a crisp field and a soft one.
                #if os(macOS)
                renderer.tileScale = Double(mapView.window?.backingScaleFactor ?? 2)
                #else
                let scale = mapView.traitCollection.displayScale
                renderer.tileScale = Double(scale > 0 ? scale : 2)
                #endif
                renderer.onVisibleTiles = { [weak self] tiles, _ in
                    // `draw` runs on MapKit's own threads; the bookkeeping this
                    // feeds is main-only.
                    DispatchQueue.main.async { self?.report(tiles: tiles, for: field.layerID) }
                }
                fieldRenderers[field.layerID, default: [:]][field.slot] = renderer
                // NO FLAT LAYER ALPHA. This used to be 0.75 — one number applied
                // to every pixel, which is exactly what made radar a smear: the
                // service hands back hard alpha-255 pixels, so drizzle and a hail
                // core were equally solid and the only knob turned both down
                // together. Opacity is now baked per pixel from ramp position by
                // each source's `process`, and any remaining per-LAYER opacity is
                // the user's slider, carried on the playhead.
                return renderer
            }
            if let region = overlay as? RegionOverlay {
                return RegionRenderer(region: region)
            }
            if let boundary = overlay as? BoundaryOverlay {
                // The label colour, so the lines read on the light map and the
                // dark one. Quiet: they locate the weather, they are not it.
                let ink = PlatformColor(Color.primary).withAlphaComponent(0.38).cgColor
                return BoundaryRenderer(boundary: boundary, ink: ink)
            }
            if let polygon = overlay as? HazardPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                let tint = PlatformColor(polygon.tintColor)
                renderer.strokeColor = tint
                renderer.lineWidth = 2.5
                // Outline-heavy, because the returns INSIDE the polygon are the
                // reason there is a polygon.
                renderer.fillColor = tint.withAlphaComponent(0.08)
                return renderer
            }
            if let ring = overlay as? CoverageRing {
                // Quiet on purpose: these are the scope's graticule, not
                // weather, and they must never be mistaken for a boundary
                // someone issued. The edge is solid because it is a hard fact
                // about the data; the height rings are dashed because they are
                // a reading aid.
                let renderer = MKCircleRenderer(circle: ring)
                let ink = PlatformColor(Color.primary)
                switch ring.kind {
                case .reach:
                    renderer.strokeColor = ink.withAlphaComponent(0.55)
                    renderer.lineWidth = 1.5
                case .beamHeight:
                    renderer.strokeColor = ink.withAlphaComponent(0.35)
                    renderer.lineWidth = 1
                    renderer.lineDashPattern = [5, 5]
                }
                return renderer
            }
            if let circle = overlay as? AreaCircle {
                let renderer = MKCircleRenderer(circle: circle)
                let tint = PlatformColor(circle.tint)
                renderer.strokeColor = tint.withAlphaComponent(0.7)
                renderer.lineWidth = 1.5
                renderer.fillColor = tint.withAlphaComponent(0.10)
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let label = annotation as? CoverageLabel {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: CoverageLabelView.reuseID)
                    ?? CoverageLabelView(annotation: label, reuseIdentifier: CoverageLabelView.reuseID)
                view.annotation = label
                return view
            }
            guard annotation is PinAnnotation else { return nil }
            return mapView.dequeueReusableAnnotationView(withIdentifier: MapPinView.reuseID,
                                                         for: annotation)
        }

        /// Clicking a pin hands its id UP, rather than growing a second reader on
        /// the map. Whatever owns the pins already decided what looking at one
        /// means; a map that answered differently would be a fork.
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let pin = (view.annotation as? PinAnnotation)?.pin,
                  let openID = pin.openID else { return }
            onSelect(openID)
            mapView.deselectAnnotation(view.annotation, animated: false)
        }
    }
}

// MARK: - Map objects

final class PinAnnotation: NSObject, MKAnnotation {
    let pin: MapPin
    var coordinate: CLLocationCoordinate2D { pin.coordinate }
    var title: String? { pin.title }
    var subtitle: String? { pin.subtitle }

    init(_ pin: MapPin) { self.pin = pin }
}

final class AreaCircle: MKCircle {
    var tint: Color = .accentColor
}

final class CoverageRing: MKCircle {
    var kind: RadarCoverage.Ring.Kind = .reach
}

/// A ring's caption, sat on the ring at due north, or the site's name at its
/// centre.
final class CoverageLabel: NSObject, MKAnnotation {
    let text: String
    let isSite: Bool
    let coordinate: CLLocationCoordinate2D

    init(text: String, coordinate: CLLocationCoordinate2D, isSite: Bool = false) {
        self.text = text; self.coordinate = coordinate; self.isSite = isSite
    }

    /// Due north is a meridian, so this is exact without any great-circle work.
    static func north(of center: CLLocationCoordinate2D, by meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: center.latitude + meters / 111_195, longitude: center.longitude)
    }
}

/// The label drawn as an image through SwiftUI, which is the one text path that
/// is the same on AppKit, UIKit and tvOS.
private final class CoverageLabelView: MKAnnotationView {
    static let reuseID = "coverage-label"

    override var annotation: MKAnnotation? {
        didSet {
            guard let label = annotation as? CoverageLabel else { return }
            let content = HStack(spacing: 4) {
                if label.isSite {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
                Text(label.text)
            }
            .font(.system(size: label.isSite ? 11 : 10, weight: label.isSite ? .semibold : .regular))
            // A fixed dark capsule rather than a material: `ImageRenderer`
            // cannot draw materials, and white on near-black reads on both the
            // light and dark map without knowing which one is showing.
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.black.opacity(0.62), in: Capsule())
            let renderer = ImageRenderer(content: content)
            #if os(macOS)
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
            image = renderer.nsImage
            #else
            renderer.scale = UITraitCollection.current.displayScale
            image = renderer.uiImage
            #endif
            displayPriority = label.isSite ? .required : .defaultHigh
            canShowCallout = false
            collisionMode = .rectangle
        }
    }
}

private final class MapPinView: MKMarkerAnnotationView {
    static let reuseID = "map-pin"

    override var annotation: MKAnnotation? {
        didSet {
            guard let pin = (annotation as? PinAnnotation)?.pin else { return }
            markerTintColor = PlatformColor(pin.tint)
            glyphImage = PlatformImage.symbol("mappin")
            displayPriority = .required
            canShowCallout = true
            // An AREA's marker is de-emphasised: the circle is the honest shape,
            // and a bold pin at its centre would read as a specific address.
            #if os(macOS)
            alphaValue = pin.radiusMeters == nil ? 1.0 : 0.65
            #else
            alpha = pin.radiusMeters == nil ? 1.0 : 0.65
            #endif
        }
    }
}
