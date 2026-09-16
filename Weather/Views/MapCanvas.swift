//
//  MapCanvas.swift  (macOS)
//
//  ONE map, drawn from a list of LAYERS. Reusable on purpose: the sidebar's Map
//  surface mounts it full-bleed, and a `place` block can mount the same thing in
//  its expanded view later without a second implementation.
//
//  THE DISTINCTION THAT SHAPES THE FILE — a layer belongs to one of two families,
//  and they are not the same kind of thing wearing different colours:
//
//  · BLOCKS  — a projection of blocks that carry coordinates. Keyed by ID, owned
//              by you, persists. This is the gallery's membership under a spatial
//              renderer, which is why the map is a LENS and not a new kind.
//  · FIELD   — data ABOUT space: radar, warning polygons, later fire danger.
//              Keyed by TIME, fetched, expires. Never a block — though "save this
//              moment" promoting one into a block is the obvious later verb.
//
//  Forcing radar to become a block to get it on screen would have been the
//  mistake, and the two families disagreeing about what an `id` even means is the
//  cheapest possible proof of that.
//

import SwiftUI
import MapKit
import WeatherKit

// MARK: - Layer model

enum MapLayerFamily: String, Hashable {
    case blocks, field

    /// The layer list groups by family, so the difference is visible rather than
    /// merely true.
    var heading: String {
        switch self {
        case .blocks: return "Yours"
        case .field:  return "Conditions"
        }
    }
}

/// What a layer actually puts on the map.
enum MapLayerContent {
    case pins([MapPin])
    case tiles(RadarFrame?)
    case outlines([MapOutline])
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
    let family: MapLayerFamily
    var isOn: Bool
    let content: MapLayerContent
    /// What the layer can say about itself in one glance — "8 places", "10:20 PM".
    /// Nil when it has nothing true to add; see [[controls-earn-their-space]].
    var caption: String?

    var pins: [MapPin] { if case .pins(let p) = content { return p }; return [] }
    var outlines: [MapOutline] { if case .outlines(let o) = content { return o }; return [] }
    var frame: RadarFrame? { if case .tiles(let f) = content { return f }; return nil }
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

struct MapCanvas: NSViewRepresentable {
    let layers: [MapLayer]
    var focus: MapFocus?
    var onSelect: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .mutedStandard
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        map.showsZoomControls = true
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
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
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

        // --- Radar tiles ------------------------------------------------------
        // ONE frame here, unlike the Weather card's pre-installed loop: the card
        // animates, this shows what's there. Installing thirteen overlays for a
        // map you're panning around would pay for a loop nobody asked to watch.
        let frame = visible.compactMap(\.frame).first
        if c.installedFrame != frame?.id {
            for overlay in map.overlays where overlay is RadarTileOverlay { map.removeOverlay(overlay) }
            if let frame {
                map.addOverlay(RadarTileOverlay(frame: frame), level: .aboveRoads)
            }
            c.installedFrame = frame?.id
        }
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
        var installedFrame: String?

        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? RadarTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
                renderer.alpha = 0.75
                return renderer
            }
            if let polygon = overlay as? HazardPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                let tint = NSColor(polygon.tintColor)
                renderer.strokeColor = tint
                renderer.lineWidth = 2.5
                // Outline-heavy, because the returns INSIDE the polygon are the
                // reason there is a polygon.
                renderer.fillColor = tint.withAlphaComponent(0.08)
                return renderer
            }
            if let circle = overlay as? AreaCircle {
                let renderer = MKCircleRenderer(circle: circle)
                let tint = NSColor(circle.tint)
                renderer.strokeColor = tint.withAlphaComponent(0.7)
                renderer.lineWidth = 1.5
                renderer.fillColor = tint.withAlphaComponent(0.10)
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
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

private final class MapPinView: MKMarkerAnnotationView {
    static let reuseID = "map-pin"

    override var annotation: MKAnnotation? {
        didSet {
            guard let pin = (annotation as? PinAnnotation)?.pin else { return }
            markerTintColor = NSColor(pin.tint)
            glyphImage = NSImage(systemSymbolName: "mappin", accessibilityDescription: nil)
            displayPriority = .required
            canShowCallout = true
            // An AREA's marker is de-emphasised: the circle is the honest shape,
            // and a bold pin at its centre would read as a specific address.
            alphaValue = pin.radiusMeters == nil ? 1.0 : 0.65
        }
    }
}
