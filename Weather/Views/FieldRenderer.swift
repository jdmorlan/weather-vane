//
//  FieldRenderer.swift  (macOS)
//
//  ONE FRAME, DRAWN AS CHEAPLY AS POSSIBLE. The dissolve happens somewhere else.
//
//  THE HISTORY MATTERS, BECAUSE THIS FILE HAS NOW BEEN WRONG IN TWO OPPOSITE
//  DIRECTIONS.
//
//  First it was one `MKTileOverlay` per frame, animated by flipping each
//  renderer's `alpha` between 0 and 1. That flickered for two reasons: alpha 0 to
//  1 in a single refresh is a CUT, and MapKit will not load tiles for a renderer
//  it is not drawing, so every frame began materialising at the instant it became
//  visible.
//
//  Then it was ONE renderer that composited both frames itself — `draw` blending
//  stamp A and stamp B at weights the clock handed it. That fixed both of those
//  and introduced a third, which is the one you could feel: `MKOverlayRenderer.draw`
//  is CPU compositing, and a crossfade asked it to repaint the WHOLE VIEWPORT ON
//  EVERY DISPLAY REFRESH, twice over — once per frame being blended. On a big
//  window that is twenty-odd megapixels of alpha blending per refresh. It does not
//  fit in 16 ms, so refreshes get dropped, and dropped refreshes during a dissolve
//  are exactly the judder the dissolve was meant to remove.
//
//  WHAT IS TRUE NOW, AND WHY THE FIRST DESIGN'S IDEA IS RIGHT AFTER ALL. Both of
//  the original objections were about LOADING, not about alpha:
//
//   · "a cut, not an animation" was because alpha went 0 to 1 in one step. The
//     clock now reports a continuous blend, so alpha moves over ~260 ms.
//   · "MapKit will not load tiles for a renderer it is not drawing" was fatal
//     when the renderer's content WAS the tile loading. It is not any more:
//     `FieldTileStore` owns decoded pixels and `MapSurfaceView` prefetches the
//     whole loop from the viewport, neither of which asks MapKit's permission.
//
//  So the field is TWO overlays again — the frame dissolving out and the frame
//  dissolving in — and the crossfade is `MKOverlayRenderer.alpha`, which MapKit
//  applies when it composites. Each renderer draws ONE stamp, and only when that
//  stamp changes: about twice a second instead of sixty times. The per-refresh
//  work during a dissolve is now two float assignments.
//
//  AND THE PARENT-TILE FALLBACK. A tile that has not arrived is drawn from its
//  parent, scaled and clipped. That is what map clients have always done, and it
//  is now load-bearing rather than cosmetic: `FieldTileGrid.parents` gives the
//  prefetch a coarse first pass, so within about a second EVERY frame has a soft
//  complete picture and the loop can start moving while the sharp tiles arrive.
//

import Foundation
import MapKit
import WeatherKit

// MARK: - The overlay

/// One frame of one field on the map. Nothing but identity and a source —
/// everything about WHAT is drawn lives on the renderer, because that is what the
/// clock talks to.
final class FieldOverlay: NSObject, MKOverlay {
    let source: FieldTileSource
    /// The `MapLayer` this belongs to, so the canvas can match overlays to layers
    /// without holding a second table.
    let layerID: String
    /// Which half of the crossfade. Slot 0 holds the frame dissolving out, slot 1
    /// the frame dissolving in; they swap roles as the loop advances rather than
    /// being rebuilt, because rebuilding an overlay throws away everything MapKit
    /// has already rasterised.
    let slot: Int

    /// The field covers the world. It is not a shape on the map; it is the map's
    /// other half.
    var boundingMapRect: MKMapRect { .world }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 0, longitude: 0) }

    init(source: FieldTileSource, layerID: String, slot: Int) {
        self.source = source
        self.layerID = layerID
        self.slot = slot
    }
}

// MARK: - The renderer

final class FieldRenderer: MKOverlayRenderer {

    /// Where a field's loop is. Still one value rather than three properties, so
    /// the canvas can hand a consistent snapshot to both slots — a stamp from one
    /// tick and a blend from the next is a visible glitch.
    struct Playhead: Equatable {
        /// The frame dissolving OUT. Empty means nothing to draw.
        var stampA: String = ""
        /// The frame dissolving IN. Empty, or equal to `stampA`, means a still.
        var stampB: String = ""
        /// 0 shows `stampA` alone, 1 shows `stampB` alone.
        var blend: Double = 0
        /// The layer's own opacity, from the layer list.
        var opacity: Double = 1
        /// WHERE TO DRAW EACH SCAN, in map points. This is the entire cost of
        /// having a forecast: an extrapolated frame is a scan already in the store
        /// drawn somewhere it is not yet. Zero for every observation, so a loop
        /// without a nowcast behaves exactly as it did.
        var offsetA: CGPoint = .zero
        var offsetB: CGPoint = .zero
    }

    /// What one slot is drawing: a scan and where to put it.
    private struct Frame: Equatable {
        var stamp: String = ""
        var offset: CGPoint = .zero
    }

    let source: FieldTileSource
    private let store: FieldTileStore

    private let lock = NSLock()
    /// The one frame this renderer draws. An empty stamp means draw nothing.
    private var frame = Frame()

    /// Backing scale of the screen the map is on. Set by the canvas; it buys one
    /// zoom level, which is the difference between a crisp field and a soft one
    /// on a retina display.
    var tileScale: Double = 2

    /// Handed the tiles the viewport actually needs, on an arbitrary thread.
    /// THIS IS WHAT REPLACED `RadarWarmer`. The old warmer learned its tile set by
    /// watching the visible frame ask MapKit for tiles, which meant every pan cost
    /// a blank pass before it knew what to fetch. A renderer that computes its own
    /// coverage already knows, and knows again the instant the viewport moves.
    var onVisibleTiles: (([FieldTileGrid.Tile], Int) -> Void)?

    /// Token for the store subscription, released on deinit so a renderer whose
    /// map is gone stops being told about tiles nobody is looking at.
    private var arrivalToken: Int?

    init(overlay: FieldOverlay, store: FieldTileStore = .shared) {
        self.source = overlay.source
        self.store = store
        super.init(overlay: overlay)

        // SUBSCRIBE, RATHER THAN ASK TO BE CALLED BACK. `paint` used to hand
        // `fetch` a completion that repainted the tile — but a tile the PREFETCH
        // had already started was skipped as in-flight and that completion was
        // dropped, so the tile landed in the cache with nothing left to redraw
        // it. A loop hid the bug by repainting constantly; a still layer like
        // satellite or a burn ban simply stayed half-drawn. Being told about
        // every arrival is correct however many callers raced for the tile.
        let id = source.id
        arrivalToken = store.observe { [weak self] key in
            guard key.source == id else { return }
            DispatchQueue.main.async { self?.invalidate(key) }
        }
    }

    deinit {
        if let arrivalToken { store.stopObserving(arrivalToken) }
    }

    // MARK: Driving it

    /// Point this renderer at a scan, drawn at an offset. Returns true when it
    /// actually moved, so the caller can decide whether a repaint is owed — which
    /// for a loop is about twice a second, not sixty times.
    @discardableResult
    func set(stamp: String, offset: CGPoint = .zero) -> Bool {
        let new = Frame(stamp: stamp, offset: offset)
        lock.lock()
        let changed = frame != new
        if changed { frame = new }
        lock.unlock()
        return changed
    }

    private var currentFrame: Frame {
        lock.lock(); defer { lock.unlock() }
        return frame
    }

    // MARK: Drawing

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let frame = currentFrame
        guard !frame.stamp.isEmpty else { return }

        let z = FieldTileGrid.zoom(forZoomScale: Double(zoomScale),
                                   tileSize: source.tileSize,
                                   scale: tileScale,
                                   clampedTo: source.zoomRange)

        // THE TILES ARE ASKED FOR WHERE THE WEATHER CAME FROM, and drawn where it
        // is going. An extrapolated frame shifts the picture by `offset`, so the
        // square of map this rect will end up showing is the rect shifted BACK by
        // the same amount. Getting that sign wrong does not fail — it draws
        // yesterday's storms on the wrong county, which is the one failure this
        // whole file exists to avoid.
        let sourceX = mapRect.origin.x - Double(frame.offset.x)
        let sourceY = mapRect.origin.y - Double(frame.offset.y)
        let placements = FieldTileGrid.placements(inRectX: sourceX, y: sourceY,
                                                  width: mapRect.size.width,
                                                  height: mapRect.size.height,
                                                  z: z)
        guard !placements.isEmpty else { return }

        // Tell whoever is prefetching what this viewport needs. Cheap, and it is
        // the only place in the app that knows.
        //
        // ONLY FROM AN UNSHIFTED FRAME, though. A forecast frame's placements are
        // upwind ground, not the viewport, and folding those into the reported set
        // would quietly redefine "what is on screen" — every one of them would
        // then be prefetched for all ten scans and counted in the loading bar's
        // denominator, for a picture only the newest scan will ever be drawn from.
        // The margin the forecast does need is asked for explicitly; see
        // `MapSurfaceView.upwindTiles`.
        if frame.offset == .zero {
            var seen = Set<FieldTileGrid.Tile>()
            let distinct = placements.compactMap { seen.insert($0.tile).inserted ? $0.tile : nil }
            onVisibleTiles?(distinct, z)
        }

        // NO PER-PIXEL ALPHA HERE. The crossfade is the renderer's `alpha`, which
        // MapKit applies when it composites this overlay over the map — so a frame
        // is rasterised once and then faded for free, rather than re-blended on
        // every refresh.
        for placement in placements {
            paint(placement, stamp: frame.stamp, offset: frame.offset, in: context)
        }
    }

    /// One tile of one frame. Falls back to a parent when the exact tile is not
    /// held yet, and asks for the exact one either way.
    private func paint(_ placement: FieldTileGrid.Placement, stamp: String,
                       offset: CGPoint, in context: CGContext) {
        let tile = placement.tile
        let key = FieldTileStore.Key(source: source.id, stamp: stamp,
                                     z: tile.z, x: tile.x, y: tile.y)

        if let image = store.image(for: key) {
            drawImage(image, in: tileRect(placement, offset: offset), context: context)
            return
        }

        // Not held. Ask for it — `fetch` is idempotent and de-duplicates in-flight
        // requests AND recently refused ones, so calling it from a paint is safe
        // however often a paint runs. The repaint comes from the subscription in
        // `init`, not from here.
        store.fetch(key, from: source)

        // MEANWHILE, DRAW THE PARENT. Three levels up is a 64x magnification,
        // which is past the point of being informative; beyond that an empty
        // square is the more honest answer than a coloured blur.
        for step in 1...3 {
            let parent = FieldTileGrid.Tile(z: tile.z - step,
                                            x: tile.x >> step, y: tile.y >> step)
            guard parent.z >= source.zoomRange.lowerBound else { return }
            let parentKey = FieldTileStore.Key(source: source.id, stamp: stamp,
                                               z: parent.z, x: parent.x, y: parent.y)
            guard let image = store.image(for: parentKey) else { continue }

            // The parent is drawn at ITS full size and clipped to this tile's
            // rectangle, which shows exactly the quarter (or sixteenth) that
            // belongs here. Cropping the image instead would mean the same
            // arithmetic done twice, once in pixels and once in map points, with
            // two chances to round it differently.
            let span = FieldTileGrid.tileSpan(z: parent.z)
            let parentOrigin = (x: floor(placement.mapX / span) * span + Double(offset.x),
                                y: floor(placement.mapY / span) * span + Double(offset.y))
            let parentRect = rect(for: MKMapRect(x: parentOrigin.x, y: parentOrigin.y,
                                                 width: span, height: span))
            context.saveGState()
            context.clip(to: tileRect(placement, offset: offset))
            drawImage(image, in: parentRect, context: context)
            context.restoreGState()
            return
        }
    }

    private func tileRect(_ placement: FieldTileGrid.Placement, offset: CGPoint) -> CGRect {
        let span = FieldTileGrid.tileSpan(z: placement.tile.z)
        return rect(for: MKMapRect(x: placement.mapX + Double(offset.x),
                                   y: placement.mapY + Double(offset.y),
                                   width: span, height: span))
    }

    /// FLIPPED, AND IT MATTERS. `CGContext.draw` places an image bottom-up, while
    /// the overlay context counts y downward from the north edge — drawn directly
    /// every tile arrives mirrored, which on a radar composite looks like
    /// plausible weather in the wrong place rather than like a bug.
    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        // NEAREST NEIGHBOUR, AND IT IS BOTH THE FAST ANSWER AND THE HONEST ONE.
        // This was `.high` to stop a faint seam grid: smoothed sampling bleeds a
        // tile's outermost pixels past its own rectangle, and the seams showed up
        // worst exactly where the field was faintest. `.none` does not resample at
        // all, so there is nothing to bleed — same fix, a fraction of the cost.
        //
        // It also stops pretending. The NEXRAD composite is roughly 1 km cells;
        // interpolating them into a smooth wash invents gradients the radar never
        // measured. Every serious radar client draws the bins as bins.
        context.interpolationQuality = .none
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// Repaint just the square a newly arrived tile covers, rather than the whole
    /// viewport. A prefetch finishing eighty tiles would otherwise be eighty full
    /// repaints of everything on screen.
    ///
    /// AND ONLY FOR THE FRAME THIS RENDERER IS SHOWING. A loop prefetch lands two
    /// hundred tiles across ten stamps, and nine tenths of them have nothing to do
    /// with what is on screen — repainting for those was two hundred invalidations
    /// per renderer during exactly the seconds the loop was trying to start
    /// moving.
    private func invalidate(_ key: FieldTileStore.Key) {
        let frame = currentFrame
        guard key.stamp == frame.stamp else { return }
        let span = FieldTileGrid.tileSpan(z: key.z)
        let origin = FieldTileGrid.origin(of: .init(z: key.z, x: key.x, y: key.y))
        setNeedsDisplay(MKMapRect(x: origin.x + Double(frame.offset.x),
                                  y: origin.y + Double(frame.offset.y),
                                  width: span, height: span))
    }
}
