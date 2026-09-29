//
//  MapShapes.swift  (Weather)
//
//  Vector shapes on the map that are neither a warning polygon nor a raster
//  field: forecast AREAS (the SPC and WPC outlooks) and administrative LINES
//  (county boundaries). Each is one overlay with its own renderer, not one
//  MapKit polygon per shape, and each for a different reason.
//
//  AREAS ARE PAINTED AS A GROUP. An outlook is nested categories — Slight inside
//  Marginal inside Thunderstorms — and WPC's overlap and carry holes besides;
//  rain-total bands are holes all the way down.
//  Drawn as translucent polygons one by one, every overlap would darken, and the
//  inside of a Slight would read as a colour neither office uses. So the fills
//  are painted OPAQUE, lowest category first, into a transparency layer, and the
//  layer as a whole is composited at one opacity. What you see is exactly the
//  office's map, laid over ours.
//
//  LINES ARE CULLED PER TILE. Three thousand counties as three thousand
//  `MKPolygon`s is three thousand renderers, each asked to draw on every tile.
//  One renderer that keeps each county's bounding box can skip everything
//  outside the tile it was handed, and thin the points it does draw to what a
//  screen point can show.
//

import SwiftUI
import MapKit
import WeatherKit

// MARK: - Forecast areas

/// A set of filled areas, lowest first — which is draw order.
struct RegionSet {
    struct Region {
        let rings: [[MKMapPoint]]
        /// Per RING, for culling. A rain band is one feature spanning half the
        /// country with thousands of rings; skipping only whole regions would
        /// rebuild all of them for every tile they touch.
        let ringBounds: [MKMapRect]
        let bounds: MKMapRect
        let fill: CGColor
        let stroke: CGColor
    }

    /// Changes when the picture does — product, day and issue time — and is
    /// the only thing the canvas compares.
    let id: String
    let regions: [Region]
    let boundingMapRect: MKMapRect
    /// How much of the map shows through the fills.
    let fillOpacity: CGFloat
    /// The edge, in screen points.
    let strokeWidth: CGFloat

    init(id: String, fillOpacity: CGFloat, strokeWidth: CGFloat,
         regions: [(rings: [[CLLocationCoordinate2D]], fill: CGColor, stroke: CGColor)]) {
        self.id = id
        self.fillOpacity = fillOpacity
        self.strokeWidth = strokeWidth
        self.regions = regions.map { region in
            let rings = region.rings.map { $0.map(MKMapPoint.init) }
            let ringBounds = rings.map(Self.bounds(of:))
            return Region(rings: rings, ringBounds: ringBounds,
                          bounds: ringBounds.reduce(MKMapRect.null) { $0.union($1) },
                          fill: region.fill, stroke: region.stroke)
        }
        boundingMapRect = self.regions.reduce(MKMapRect.null) { $0.union($1.bounds) }
    }

    static func bounds(of points: [MKMapPoint]) -> MKMapRect {
        guard let first = points.first else { return .null }
        var (minX, maxX, minY, maxY) = (first.x, first.x, first.y, first.y)
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

final class RegionOverlay: NSObject, MKOverlay {
    let set: RegionSet
    let boundingMapRect: MKMapRect
    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }

    init(_ set: RegionSet) {
        self.set = set
        boundingMapRect = set.boundingMapRect
    }
}

final class RegionRenderer: MKOverlayRenderer {
    private let set: RegionSet

    init(region: RegionOverlay) {
        set = region.set
        super.init(overlay: region)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let lineWidth = set.strokeWidth / zoomScale
        let reach = mapRect.insetBy(dx: -lineWidth, dy: -lineWidth)
        // A vertex within half a screen point of the last adds nothing visible.
        let tolerance = 0.5 / zoomScale
        // Built once per tile and used for both passes.
        let visible: [(region: RegionSet.Region, path: CGPath)] = set.regions.compactMap { region in
            guard region.bounds.intersects(reach) else { return nil }
            let path = self.path(region, within: reach, tolerance: tolerance)
            return path.isEmpty ? nil : (region, path)
        }
        guard !visible.isEmpty else { return }

        // THE FILLS, AS ONE GROUP. See the header. Clipped first so the
        // transparency layer is the size of this tile, not of the continent.
        context.saveGState()
        context.clip(to: rect(for: mapRect))
        context.setAlpha(set.fillOpacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for (region, path) in visible {
            context.addPath(path)
            context.setFillColor(region.fill)
            // Even-odd, so a WPC hole is a hole without knowing which ring it
            // is. A hole outside this tile was culled with its bounds, which is
            // safe: a ring can only change pixels inside its own bounding box.
            context.fillPath(using: .evenOdd)
        }
        context.endTransparencyLayer()
        context.restoreGState()

        // THE EDGES, CRISP AND ON TOP. The boundary is the forecaster's line,
        // and it is the thing you place yourself against.
        context.setLineWidth(lineWidth)
        context.setLineJoin(.round)
        for (region, path) in visible {
            context.addPath(path)
            context.setStrokeColor(region.stroke)
            context.strokePath()
        }
    }

    private func path(_ region: RegionSet.Region, within reach: MKMapRect, tolerance: Double) -> CGPath {
        let path = CGMutablePath()
        for (ring, bounds) in zip(region.rings, region.ringBounds)
        where ring.count > 2 && bounds.intersects(reach) {
            // Smaller than a point on screen: a speck, not a shape.
            guard bounds.width > tolerance || bounds.height > tolerance else { continue }
            var last = ring[0]
            path.move(to: point(for: last))
            for p in ring.dropFirst() where abs(p.x - last.x) > tolerance || abs(p.y - last.y) > tolerance {
                path.addLine(to: point(for: p))
                last = p
            }
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Boundary lines

/// Outlines to stroke, each with its bounding box for culling. A class so the
/// quarter-million converted points are built once and shared, not copied into
/// every SwiftUI pass that mentions the layer.
final class BoundarySet: @unchecked Sendable {
    let id: String
    let rings: [[MKMapPoint]]
    let bounds: [MKMapRect]
    let boundingMapRect: MKMapRect

    init(id: String, rings: [[GeoPoint]]) {
        self.id = id
        let converted = rings.map { ring in
            ring.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        }
        self.rings = converted
        bounds = converted.map(RegionSet.bounds(of:))
        boundingMapRect = bounds.reduce(MKMapRect.null) { $0.union($1) }
    }
}

final class BoundaryOverlay: NSObject, MKOverlay {
    let set: BoundarySet
    let boundingMapRect: MKMapRect
    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }

    init(_ set: BoundarySet) {
        self.set = set
        boundingMapRect = set.boundingMapRect
    }
}

final class BoundaryRenderer: MKOverlayRenderer {
    private let set: BoundarySet
    private let ink: CGColor

    init(boundary: BoundaryOverlay, ink: CGColor) {
        set = boundary.set
        self.ink = ink
        super.init(overlay: boundary)
    }

    /// Kilometres per screen point at which the lines are fully drawn, and at
    /// which they have faded out. Past the second the whole country is on
    /// screen and three thousand counties are a grey mesh that says nothing.
    private static let fullBelow = 1.5, goneAbove = 7.0

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(mapRect.origin.coordinate.latitude)
        let kmPerScreenPoint = 1 / zoomScale / pointsPerMeter / 1000
        let fade = 1 - min(1, max(0, (kmPerScreenPoint - Self.fullBelow) / (Self.goneAbove - Self.fullBelow)))
        guard fade > 0.02 else { return }

        let lineWidth = 0.8 / zoomScale
        // A vertex closer than half a screen point to the last one drawn adds
        // nothing a person can see, and at state scale it is most of them.
        let tolerance = 0.5 / zoomScale
        let reach = mapRect.insetBy(dx: -lineWidth, dy: -lineWidth)

        let path = CGMutablePath()
        for index in set.rings.indices where set.bounds[index].intersects(reach) {
            let ring = set.rings[index]
            guard let first = ring.first else { continue }
            path.move(to: point(for: first))
            var last = first
            for p in ring.dropFirst() where abs(p.x - last.x) > tolerance || abs(p.y - last.y) > tolerance {
                path.addLine(to: point(for: p))
                last = p
            }
            path.addLine(to: point(for: first))
        }
        guard !path.isEmpty else { return }
        context.addPath(path)
        context.setStrokeColor(ink.copy(alpha: ink.alpha * fade) ?? ink)
        context.setLineWidth(lineWidth)
        context.setLineJoin(.round)
        context.strokePath()
    }
}

// MARK: - Colour

extension OutlookColor {
    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}
