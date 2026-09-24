//
//  SweepTrail.swift  (macOS, iPadOS)
//
//  Sweep mode on the map: the turning line with its fading trail, and the wedge
//  arithmetic the field renderer clips to while a scan is being swept in. What
//  the mode is for is in WeatherKit's `SweepClock`.
//
//  DRAWN IN MAP POINTS, INVALIDATED BY SECTOR. The line moves every display
//  refresh; repainting the whole viewport that often is exactly the cost
//  `FieldRenderer`'s header records as the source of past judder. So each tick
//  asks MapKit to redraw only the thin sector the line crossed since the last
//  one — a few degrees of a circle, not the screen.
//

import Foundation
import MapKit
import SwiftUI
import WeatherKit

/// A radar site on the map, and how far its lowest beam reaches.
struct SweepSite: Equatable {
    var latitude: Double
    var longitude: Double
    /// Ground distance, metres.
    var reach: Double
}

enum SweepGeometry {
    /// Arc spacing. At 460 km a 2° chord sits ~70 m inside the true arc —
    /// narrower than one gate, so nobody can see the difference.
    static let arcStep = 2.0

    static func center(_ s: SweepSite) -> MKMapPoint {
        MKMapPoint(CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude))
    }

    static func point(_ s: SweepSite, azimuth: Double) -> MKMapPoint {
        let p = RadarGeometry.destination(fromLatitude: s.latitude, longitude: s.longitude,
                                          bearing: azimuth, distance: s.reach)
        return MKMapPoint(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
    }

    /// Arc points clockwise from `from` through `span` degrees, inclusive.
    static func arc(_ s: SweepSite, from: Double, span: Double) -> [MKMapPoint] {
        guard span > 0 else { return [point(s, azimuth: from)] }
        let steps = max(1, Int((span / arcStep).rounded(.up)))
        return (0...steps).map { (i: Int) -> MKMapPoint in
            let offset: Double = span * Double(i) / Double(steps)
            return point(s, azimuth: from + offset)
        }
    }

    /// The area a line starting at `from` has passed after turning `span`.
    static func wedge(_ s: SweepSite, from: Double, span: Double) -> [MKMapPoint] {
        guard span > 0 else { return [] }
        return [center(s)] + arc(s, from: from, span: min(360, span))
    }

    /// The bounding box of a sector — what has to be redrawn when the line
    /// moves across it. Padded so antialiased edges are included.
    static func sectorRect(_ s: SweepSite, from: Double, span: Double) -> MKMapRect {
        let points = [center(s)] + arc(s, from: from, span: min(360, max(0, span)))
        let xs = points.map { $0.x }, ys = points.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
        else { return .null }
        let pad = (maxX - minX + maxY - minY) * 0.02 + 2_000
        return MKMapRect(x: minX - pad, y: minY - pad,
                         width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
    }
}

/// The trail's overlay: a circle's bounding box around the site, so MapKit asks
/// for it anywhere the line can reach.
final class SweepTrailOverlay: NSObject, MKOverlay {
    let site: SweepSite
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(_ site: SweepSite) {
        self.site = site
        coordinate = CLLocationCoordinate2D(latitude: site.latitude, longitude: site.longitude)
        boundingMapRect = SweepGeometry.sectorRect(site, from: 0, span: 360)
    }
}

/// The line and the glow behind it, like the phosphor on an old scope — which
/// is also what makes a reveal readable: the eye follows the bright edge and
/// sees the new returns appear in its wake.
final class SweepTrailRenderer: MKOverlayRenderer {
    /// How far behind the line the glow fades out, degrees.
    static let trailLength = 40.0
    private static let slices = 20

    private let site: SweepSite
    private let lock = NSLock()
    private var azimuth: Double?

    init(trail: SweepTrailOverlay) {
        site = trail.site
        super.init(overlay: trail)
    }

    /// Move the line, redrawing only the sector it and its trail crossed.
    func update(azimuth new: Double) {
        lock.lock()
        let old = azimuth
        azimuth = new
        lock.unlock()
        let tail = Self.trailLength + SweepGeometry.arcStep
        guard let old else { setNeedsDisplay(); return }
        var moved = (new - old).truncatingRemainder(dividingBy: 360)
        if moved < 0 { moved += 360 }
        setNeedsDisplay(SweepGeometry.sectorRect(site, from: old - tail, span: moved + tail + 1))
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        lock.lock(); let azimuth = self.azimuth; lock.unlock()
        guard let azimuth else { return }
        let center = point(for: SweepGeometry.center(site))
        let glow = CGColor(red: 0.45, green: 1.0, blue: 0.6, alpha: 1)

        // The glow: slices fading out behind the line.
        let slice = Self.trailLength / Double(Self.slices)
        for i in 0..<Self.slices {
            let fade = 1 - Double(i) / Double(Self.slices)
            let from = azimuth - Double(i + 1) * slice
            let path = CGMutablePath()
            path.move(to: center)
            path.addLines(between: SweepGeometry.arc(site, from: from, span: slice).map { point(for: $0) })
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(glow.copy(alpha: 0.2 * fade * fade) ?? glow)
            context.fillPath()
        }

        // The line itself, a constant two screen points whatever the zoom.
        let tip = point(for: SweepGeometry.point(site, azimuth: azimuth))
        context.setStrokeColor(glow.copy(alpha: 0.95) ?? glow)
        context.setLineWidth(2 / zoomScale)
        context.setLineCap(.round)
        context.move(to: center)
        context.addLine(to: tip)
        context.strokePath()
    }
}
