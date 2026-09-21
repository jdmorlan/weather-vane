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
//  The loop itself is the same trick the Mac learned: EVERY FRAME IS INSTALLED
//  AT ONCE and animation is an alpha change. Adding and removing an overlay per
//  frame throws away rendered tiles and re-requests them, which reads as a
//  stutter — and on a TV, at ten feet, a stutter is the only thing anyone sees.
//

import SwiftUI
import MapKit
import WeatherKit

struct TVRadarMap: UIViewRepresentable {
    let center: CLLocationCoordinate2D
    let radiusMeters: Double
    let frames: [RadarFrame]
    let index: Int
    let hazards: [Hazard]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .mutedStandard
        map.pointOfInterestFilter = .excludingAll
        // The camera is fixed. Nothing on a remote should move it, and a map
        // that drifts under a storm you are watching is worse than no map.
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        // No rotate or pitch toggles: tvOS doesn't offer them, because there is
        // no gesture that could reach them in the first place.
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
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator

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

        // --- The loop ---
        if c.installedFrames != frames.map(\.id) {
            for overlay in map.overlays where overlay is RadarTileOverlay { map.removeOverlay(overlay) }
            c.renderers.removeAll()
            for frame in frames { map.addOverlay(RadarTileOverlay(frame: frame), level: .aboveRoads) }
            c.installedFrames = frames.map(\.id)
            c.shownFrame = nil
        }

        let current = frames.indices.contains(index) ? frames[index].id : nil
        if c.shownFrame != current {
            c.shownFrame = current
            for (id, renderer) in c.renderers {
                let wanted: CGFloat = (id == current) ? 1 : 0
                if renderer.alpha != wanted {
                    renderer.alpha = wanted
                    renderer.setNeedsDisplay()
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var appliedCenter: CLLocationCoordinate2D?
        var appliedRadius: Double?
        var installedOutlines: [String] = []
        var installedFrames: [String] = []
        var shownFrame: String?
        var renderers: [String: MKTileOverlayRenderer] = [:]

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? RadarTileOverlay {
                if let existing = renderers[tiles.frame.id] { return existing }
                let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
                renderers[tiles.frame.id] = renderer
                // Opacity is baked per pixel in `RadarTileShading`; the layer
                // draws at full strength and lets the shading carry hierarchy.
                renderer.alpha = (tiles.frame.id == shownFrame) ? 1 : 0
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
    }
}

final class TVHazardPolygon: MKPolygon {
    var tint: UIColor = .orange
}
