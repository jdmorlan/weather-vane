//
//  MapSurfaceView.swift  (Weather)
//
//  The Map tab: one `MapCanvas`, one VIEW, and the context that is always welcome
//  over it.
//
//  WHY IT'S ITS OWN TAB — every other tab answers a question about a POINT (your
//  station, your home) over TIME. This one is the other axis: what is around, and
//  what is coming, right now. A radar loop, a warning polygon and a burn ban are
//  the things in the whole app that have no meaning at a single coordinate.
//
//  A VIEW, NOT A PILE OF TOGGLES. This started as one checkbox per layer, which
//  is what every radar app does and what makes them feel like a control panel
//  rather than a map. The problem is not clutter, it is that the toggles were
//  LYING about what was possible: radar and a burn ban are both full-bleed raster
//  fields, so switching both on does not layer them, it hides one. A picture
//  nobody can see is still being fetched, shaded and animated.
//
//  So the subject is a single choice. Cloud, radar, fire — you are looking at ONE
//  of those, and the options that belong to it (which ABI band, burn bans versus
//  active fires) live underneath it rather than beside it, because they are not
//  peers of the view, they are refinements of it.
//
//  WHAT STAYS ON REGARDLESS. Warnings and your home are not subjects and never
//  compete for the same pixels — an outline and a pin composite over anything. So
//  they are additive, and they are the only two things on this surface that are.
//  See `MapLayerRole`.
//

import SwiftUI
import MapKit
import WeatherKit

/// The map's SUBJECT — exactly one at a time. See the header for why this is a
/// choice rather than three checkboxes.
enum MapSurface: String, CaseIterable, Identifiable {
    case radar, cloud, fire

    var id: String { rawValue }

    var label: String {
        switch self {
        case .radar: return "Radar"
        case .cloud: return "Cloud"
        case .fire:  return "Fire"
        }
    }

    var symbol: String {
        switch self {
        case .radar: return "cloud.rain"
        case .cloud: return "cloud"
        case .fire:  return "flame"
        }
    }

    /// What this view is for, shown only while it is the one you are looking at.
    /// Three subtitles stacked in a narrow panel is noise; one under the thing you
    /// just chose is an answer.
    ///
    /// KEPT TO ONE LINE AT THE PANEL'S WIDTH. A subtitle that wraps makes its row
    /// taller than its siblings, and a radio list whose rows are different heights
    /// reads as though the tall one is a heading over the others rather than a
    /// peer of them — which is the exact relationship this control exists to get
    /// right.
    var question: String {
        switch self {
        case .radar: return "Rain, and where it's headed"
        case .cloud: return "The sky from above"
        case .fire:  return "Bans, and what's burning"
        }
    }
}

struct MapSurfaceView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var radar = RadarModel()
    @StateObject private var hazards = WeatherHazardModel()

    @State private var surface: MapSurface = .radar
    /// Additive, and only ever these two. See `MapLayerRole.context`.
    @State private var context: Set<String> = ["warnings", "home"]
    @State private var band: SatelliteFieldSource.Band = .infrared
    @State private var fireProduct: TexasFireFieldSource.Product = .burnBan
    @State private var focus: MapFocus?
    @State private var focusToken = 0

    /// Re-read on a timer rather than computed per frame: these are cache-busting
    /// buckets, and recomputing one inside `layers` would make every SwiftUI pass
    /// a potential new source id.
    @State private var satelliteStamp = SatelliteFieldSource.currentStamp()
    @State private var fireStamp = TexasFireFieldSource.currentStamp()

    /// The tiles the current view's renderer last said it needed. Held so the
    /// status line can count what is missing against what was actually asked for,
    /// rather than against a guess about the viewport.
    @State private var visibleTiles: [FieldTileGrid.Tile] = []
    @State private var progress = FieldTileStore.Progress()
    /// Whether every frame holds its coarse stand-in, which is what actually
    /// releases playback. Counted against a different tile set from `progress`, so
    /// it is its own value rather than a field on it.
    @State private var coarseReady = false
    /// Failed tiles belonging to the frame currently being drawn, which is a much
    /// narrower thing than `progress.failed`.
    @State private var onScreenFailed = 0
    /// When the picture last became incomplete. A load that finishes quickly
    /// should say nothing at all — a status line that flashes on every pan is
    /// worse than no status line.
    @State private var incompleteSince: Date?

    /// The source and stamps for whatever is on screen, so progress is counted
    /// against the view you are actually looking at.
    private var currentSource: FieldTileSource {
        switch surface {
        case .radar: return radarSource
        case .cloud: return satelliteSource
        case .fire:  return fireSource
        }
    }

    private var currentStamps: [String] {
        switch surface {
        case .radar: return radar.stampsByUrgency
        case .cloud: return [satelliteStamp]
        case .fire:  return [fireStamp]
        }
    }

    private var currentLayerID: String { surface.rawValue }

    /// The single frame being drawn right now, as opposed to every frame the loop
    /// will eventually walk. What the alarm in `fieldStatus` is counted against —
    /// see there for why the difference is the whole point.
    private var onScreenStamps: [String] {
        switch surface {
        case .radar: return radar.current.map { [$0.stamp] } ?? []
        case .cloud: return [satelliteStamp]
        case .fire:  return [fireStamp]
        }
    }

    private var radarSource: RadarFieldSource { RadarFieldSource(curve: .standard) }
    private var satelliteSource: SatelliteFieldSource { SatelliteFieldSource(band: band) }
    private var fireSource: TexasFireFieldSource { TexasFireFieldSource(product: fireProduct) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            canvas
            panel.padding(14)
        }
        .overlay(alignment: .bottom) {
            // The padding lives here, not on the timeline: the timeline is absent
            // under the cloud and fire views, and a status bar flush against the
            // bottom of the window looks like a mistake.
            VStack(spacing: 8) {
                status
                timeline
            }
            .padding(.bottom, 16)
            .animation(.easeOut(duration: 0.18), value: fieldStatus)
        }
        // NOT `driving:` — the clock is ticked from the canvas's display link, so
        // the dissolve lands on real display refreshes. Two drivers would advance
        // the loop at twice the intended speed.
        .task { await radar.run(driving: false) }
        .task { await hazards.poll(settings: settings) }
        .task { await refreshStamps() }
        .task { await watchProgress() }
        .task { await watchMotion() }
        // A motion estimate is what CREATES the forecast frames, so the ground they
        // will need has to be asked for the moment one lands — the prefetch is
        // otherwise only driven by the map reporting a new viewport, which a
        // stationary map never does.
        .onChange(of: radar.motion) { _, _ in
            prefetch(layerID: currentLayerID, tiles: visibleTiles)
        }
        .onAppear {
            FieldTileStore.shared.onRefused = { [weak radar] in
                Task { @MainActor in radar?.noteTilesRefused() }
            }
            recenterHome()
        }
    }

    private var canvas: some View {
        MapCanvas(layers: layers,
                  focus: focus,
                  onDisplayTick: tick,
                  onVisibleTiles: prefetch)
            .ignoresSafeArea()
    }

    // MARK: Driving the loop

    /// Once per display refresh: move the clock, then say where the field now is.
    /// Only radar animates; the other views are stills and report the same stamp
    /// twice, which is how `FieldRenderer` knows to skip the second draw entirely.
    ///
    /// Answers only for the CURRENT view. The canvas has no renderer for the
    /// others, so anything else here would be a number computed for nobody.
    private func tick(delta: Double) -> [String: FieldRenderer.Playhead] {
        switch surface {
        case .radar:
            // A HALF-LOADED LOOP DOES NOT PLAY. Walking onto a frame whose tiles
            // have not arrived draws it from its parent — softer, and honest, but
            // a loop that flickers between sharp and soft reads as broken. Worse,
            // the dissolve would be showing you a frame you cannot actually see
            // yet while the newest scan, which you can, slides off screen.
            //
            // This is the question the deleted `RadarWarmer` also answered, and it
            // gets a better answer now for a specific reason: the newest frame is
            // fetched FIRST, so holding means holding on current weather rather
            // than on a blank map. The wait is a second, not the eight it was.
            guard loopIsReady else {
                let head = radar.playhead
                // Crisp, not frozen mid-dissolve — a held picture that is 40%
                // blended between two scans looks like a rendering fault.
                return ["radar": playhead(head.a, head.a, blend: 0)]
            }
            radar.tick(delta: delta)
            let head = radar.playhead
            return ["radar": playhead(head.a, head.b, blend: head.blend)]
        case .cloud:
            return ["cloud": .init(stampA: satelliteStamp, stampB: satelliteStamp)]
        case .fire:
            return ["fire": .init(stampA: fireStamp, stampB: fireStamp)]
        }
    }

    /// A pair of loop frames as the renderer wants them: which scan, and where to
    /// draw it. The offset is what makes an extrapolated frame cost nothing.
    private func playhead(_ a: LoopFrame?, _ b: LoopFrame?, blend: Double) -> FieldRenderer.Playhead {
        guard let a else { return .init() }
        let b = b ?? a
        return .init(stampA: a.stamp, stampB: b.stamp, blend: blend,
                     offsetA: CGPoint(x: a.offsetX, y: a.offsetY),
                     offsetB: CGPoint(x: b.offsetX, y: b.offsetY))
    }

    /// THE PREFETCH, AND WHY IT IS DRIVEN FROM HERE. The renderer says which tiles
    /// the viewport needs; this says which STAMPS to fetch them for. For radar
    /// that is the whole loop at once — fetching only the visible frame is what
    /// made the old loop draw blanks on its first pass and after every pan.
    private func prefetch(layerID: String, tiles: [FieldTileGrid.Tile]) {
        let store = FieldTileStore.shared
        if layerID == currentLayerID { visibleTiles = tiles }
        switch layerID {
        // BY URGENCY, NOT BY TIME. See `RadarModel.stampsByUrgency` — handing the
        // prefetch the timeline's own oldest-first order put the frame on screen
        // last in a queue of two hundred.
        case "radar":
            // COARSE FIRST, AND IT IS THE DIFFERENCE BETWEEN A SECOND AND TEN.
            // A ten-frame loop over this viewport is around two hundred requests
            // and `URLSession` runs ten at a time, so the last frame lands eight
            // seconds in — eight seconds of a frozen picture and a card counting
            // "0 of 10". The same ground three zoom levels up is one or two tiles,
            // so the WHOLE LOOP is one pass of the connection pool. The renderer
            // already draws a missing tile from its parent, so the moment that
            // pass lands every frame is soft but complete and the loop starts
            // moving; the sharp tiles then arrive underneath a loop that is
            // already running.
            store.prefetch(stamps: radar.stampsByUrgency,
                           tiles: overview(of: tiles), from: radarSource)
            store.prefetch(stamps: radar.stampsByUrgency, tiles: tiles, from: radarSource)
            // Upwind ground, for the NEWEST scan alone — that is the only one any
            // forecast frame draws, so fetching the margin for all ten would be
            // nine loops' worth of tiles nothing will ever ask for.
            if let newest = radar.frames.last?.stamp {
                store.prefetch(stamps: [newest], tiles: upwindTiles(), from: radarSource)
            }
        case "cloud": store.prefetch(stamps: [satelliteStamp], tiles: tiles, from: satelliteSource)
        case "fire":  store.prefetch(stamps: [fireStamp], tiles: tiles, from: fireSource)
        default:      break
        }
    }

    // MARK: Working out where it is going

    /// THE NOWCAST'S ONLY INPUT, measured off the pixels already on screen.
    ///
    /// Run on a timer rather than on every reload, and OFF THE MAIN ACTOR, because
    /// it rasterises two scans into grids and correlates them — tens of
    /// milliseconds, which is several dropped frames if it lands in the middle of
    /// a dissolve.
    ///
    /// Every ten seconds rather than every five minutes: the scans only change on
    /// the composite cadence, but the VIEWPORT changes whenever you pan, and a
    /// motion measured over Abilene is not the motion over Waco.
    private func watchMotion() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard surface == .radar else { continue }
            let recent = radar.frames.suffix(2)
            guard recent.count == 2, let patch = visiblePatch() else { continue }
            let source = radarSource
            let gap = recent.last!.time.timeIntervalSince(recent.first!.time)
            let stamps = recent.map(\.stamp)

            let motion = await Task.detached(priority: .utility) { () -> StormMotion? in
                let store = FieldTileStore.shared
                guard let a = store.intensityGrid(source: source, stamp: stamps[0],
                                                  rectX: patch.x, rectY: patch.y,
                                                  width: patch.width, height: patch.height,
                                                  z: patch.z, cells: 256),
                      let b = store.intensityGrid(source: source, stamp: stamps[1],
                                                  rectX: patch.x, rectY: patch.y,
                                                  width: patch.width, height: patch.height,
                                                  z: patch.z, cells: 256)
                else { return nil }
                var found = MotionEstimator.estimate(from: a, to: b, over: gap, maxShift: 24)
                // Cells per second becomes MAP POINTS per second here, which is
                // the one conversion only the map can do.
                found.dx *= a.cellSize
                found.dy *= a.cellSize
                return found
            }.value

            radar.setMotion(motion)
        }
    }

    /// The patch of map space the held tiles cover, which is what there is to
    /// correlate. Derived from the tiles rather than from the map view because
    /// those are exactly the pixels `FieldTileStore` can answer for.
    private func visiblePatch() -> (x: Double, y: Double, width: Double, height: Double, z: Int)? {
        guard let z = visibleTiles.first?.z, !visibleTiles.isEmpty else { return nil }
        let span = FieldTileGrid.tileSpan(z: z)
        let xs = visibleTiles.map { Double($0.x) * span }
        let ys = visibleTiles.map { Double($0.y) * span }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        return (minX, minY, maxX - minX + span, maxY - minY + span, z)
    }

    /// The tiles the FORECAST needs that the viewport does not.
    ///
    /// An extrapolated frame slides the newest scan across the map, so the ground
    /// that ends up on screen an hour out is ground currently sitting OFF it,
    /// upwind. Without this the future half of the loop marches a clean edge in
    /// from the border of the viewport — a wall of "no rain" that is really just a
    /// wall of "not fetched".
    private func upwindTiles() -> [FieldTileGrid.Tile] {
        guard let motion = radar.motion, let patch = visiblePatch() else { return [] }
        let lead = radar.forecastHorizon
        let shiftX = motion.dx * lead, shiftY = motion.dy * lead
        guard abs(shiftX) > 1 || abs(shiftY) > 1 else { return [] }
        let known = Set(visibleTiles)
        return FieldTileGrid.tiles(inRectX: patch.x - shiftX, y: patch.y - shiftY,
                                   width: patch.width, height: patch.height, z: patch.z)
            .filter { !known.contains($0) }
    }

    /// The coarse stand-in for a viewport's tiles. TWO levels up rather than
    /// three, because the sharp level is itself two levels coarser than it used to
    /// be — a further 64x magnification off a z8 base is a wash rather than a
    /// picture. At 16x a storm is soft but unmistakably a storm in the right
    /// county, which is the whole job while the real tiles are in flight.
    private func overview(of tiles: [FieldTileGrid.Tile]) -> [FieldTileGrid.Tile] {
        FieldTileGrid.parents(of: tiles, levelsUp: 2,
                              notBelow: currentSource.zoomRange.lowerBound)
    }

    /// Neither of these services takes a TIME argument, so "refresh" means asking
    /// under a new cache key. The ABI CONUS sector lands every five minutes; a
    /// burn ban changes when a county votes, so hourly is already eager.
    private func refreshStamps() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            satelliteStamp = SatelliteFieldSource.currentStamp()
            fireStamp = TexasFireFieldSource.currentStamp()
        }
    }

    // MARK: Saying what is going on

    /// Polled at 4 Hz rather than computed on the display link. Counting progress
    /// walks every stamp against every visible tile — a couple of hundred cache
    /// lookups — and doing that sixty times a second to update a line of text
    /// nobody reads that fast would cost more than the dissolve it sits next to.
    private func watchProgress() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard !visibleTiles.isEmpty else { progress = .init(); continue }
            let now = FieldTileStore.shared.progress(stamps: currentStamps,
                                                     tiles: visibleTiles,
                                                     from: currentSource)
            progress = now
            // Counted separately, against the coarse pass, because that is what
            // actually decides whether the loop can play — see `loopIsReady`.
            let coarse = overview(of: visibleTiles)
            coarseReady = coarse.isEmpty
                ? false
                : FieldTileStore.shared.progress(stamps: currentStamps, tiles: coarse,
                                                 from: currentSource).allFramesReady
            // Counted against the ONE frame on screen. `progress.failed` is the
            // whole loop's tally, and a loop is ten frames — see `fieldStatus`.
            onScreenFailed = onScreenStamps.isEmpty
                ? 0
                : FieldTileStore.shared.progress(stamps: onScreenStamps, tiles: visibleTiles,
                                                 from: currentSource).failed
            if now.isComplete { incompleteSince = nil }
            else if incompleteSince == nil { incompleteSince = Date() }
        }
    }

    /// PLAY AS SOON AS EVERY FRAME HAS A PICTURE — NOT AS SOON AS EVERY FRAME IS
    /// SHARP.
    ///
    /// This used to wait for every full-resolution tile of every frame, which was
    /// honest about the flicker it was avoiding and wrong about the price: two
    /// hundred requests is the better part of ten seconds, and the loop sat frozen
    /// for all of it. With the coarse pass landing in about a second, "every frame
    /// can be drawn" becomes true almost immediately — softly, from parents — and
    /// the loop runs while it sharpens. Soft and moving beats sharp and stopped,
    /// because the motion IS the information.
    ///
    /// The last clause is still the escape hatch. A single tile the service will
    /// not serve — one county, one scan — must not freeze the loop forever, so an
    /// empty queue releases it too: once nothing is in flight, this is as good as
    /// it is going to get.
    private var loopIsReady: Bool {
        // NOT MEASURED YET IS NOT THE SAME AS NOTHING OUTSTANDING. Progress starts
        // empty, and an empty `inFlight` would otherwise read as "all done" for
        // the moment between the map appearing and the first prefetch being fired
        // — so the loop would play a lap over a blank map, stop, and start again.
        guard progress.frameCount > 0 else { return false }
        return coarseReady || progress.allFramesReady || progress.inFlight == 0
    }

    /// WHAT THE MAP CAN HONESTLY SAY, IN WORDS. The user's question was why it
    /// sometimes looks stuck, and the answer had better not be a tile count or an
    /// HTTP status — those name the machinery, not the situation. Each of these
    /// is a different SITUATION with a different thing worth doing about it:
    /// waiting is fine and needs no action, a refusal will heal itself, and a
    /// hole that stopped filling is worth a button.
    private var fieldStatus: FieldStatus? {
        // The INDEX failed, so there is no loop at all — a different and worse
        // problem than tiles not arriving, and it gets said first.
        if surface == .radar, radar.failure != nil {
            return FieldStatus(message: "Can't reach the radar service",
                               detail: "Check your connection", canRetry: true)
        }
        if surface == .radar, radar.tilesRefused {
            return FieldStatus(message: "The weather service is busy",
                               detail: "Some of the map may be missing", canRetry: true)
        }
        // THE ALARM IS ABOUT THE FRAME YOU ARE LOOKING AT, not about the loop's
        // whole tally. `progress.failed` counts across ten frames and hundreds of
        // tiles, so one tile the service dropped fifty minutes ago raised a
        // warning bar and a button over a map that was completely drawn — the
        // app telling you something was broken while showing you it wasn't. A
        // tile missing from a frame that isn't on screen is a soft square for a
        // fifth of a second some time later, and the parent fallback covers even
        // that. Worth retrying quietly; not worth interrupting for.
        if onScreenFailed > 0 {
            return FieldStatus(message: "Part of the map didn't load",
                               detail: "It will try again on its own", canRetry: true)
        }
        // Only after it has been incomplete for a beat. A pan that resolves in
        // 300ms should say nothing.
        if !progress.isComplete, progress.wanted > 0,
           let since = incompleteSince, Date().timeIntervalSince(since) > 0.6 {
            return FieldStatus(message: loadingMessage, detail: loadingDetail,
                               canRetry: false, fraction: progress.fraction)
        }
        if surface == .radar, radar.isStale, let newest = radar.frames.last {
            let minutes = Int(Date().timeIntervalSince(newest.time) / 60)
            return FieldStatus(message: "The newest scan is \(minutes) minutes old",
                               detail: "The radar network may be catching up", canRetry: true)
        }
        return nil
    }

    private var loadingMessage: String {
        surface == .radar ? "Loading the last hour" : "Filling in the map"
    }

    /// FRAMES, NOT TILES — a frame is a thing you can see on the scrub strip, and
    /// a tile is an implementation detail of how it got there.
    ///
    /// AND IT SAYS WHY THE LOOP IS NOT MOVING. "4 of 10 frames ready" on its own
    /// invites the reading that the app is stuck; naming what you ARE being shown
    /// makes a held picture a decision rather than a fault.
    private var loadingDetail: String? {
        guard surface == .radar, progress.frameCount > 0 else { return nil }
        let counted = "\(progress.readyFrames) of \(progress.frameCount) frames sharp"
        // THREE DIFFERENT SITUATIONS, AND THE MIDDLE ONE IS THE NEW COMMON CASE.
        // A loop running off the coarse pass is not waiting for anything you need
        // to know about — it is already showing you the weather and the detail is
        // filling in, so saying "showing the newest" there would be a lie about a
        // loop that is plainly moving.
        if coarseReady && !progress.isComplete { return counted + " · sharpening" }
        return loopIsReady ? counted : counted + " · showing the newest"
    }

    private func retry() {
        FieldTileStore.shared.clearFailures()
        incompleteSince = Date()
        if surface == .radar, radar.failure != nil || radar.isStale {
            Task { await radar.load() }
        }
        // Re-ask for everything the viewport needs. Arrivals broadcast to the
        // renderer, so the picture repairs itself without the map being touched.
        prefetch(layerID: currentLayerID, tiles: visibleTiles)
    }

    @ViewBuilder private var status: some View {
        if let state = fieldStatus {
            FieldStatusBar(state: state, retry: retry)
        }
    }

    // MARK: Layers

    /// The chosen subject, then whatever context is on. ORDER IS DRAW ORDER, so
    /// the subject goes down first and the marks that locate it go on top.
    private var layers: [MapLayer] {
        var built: [MapLayer] = [subjectLayer]

        let outlines = warningOutlines()
        built.append(MapLayer(
            id: "warnings", name: "Warnings", symbol: "exclamationmark.triangle",
            role: .context, isOn: context.contains("warnings"), content: .outlines(outlines),
            // "none" is a real answer here and worth printing, unlike on the
            // Weather banner — you came to this surface to look, so an empty
            // layer is information rather than clutter.
            caption: outlines.isEmpty ? "none" : "\(outlines.count)"))

        // YOU, last, so the dot is never buried under a field. A radar picture
        // answers "is it about to rain on me", and that question is unanswerable
        // without the "me".
        if let home = settings.homeCoordinate {
            built.append(MapLayer(
                id: "home", name: "Home", symbol: "house",
                role: .context, isOn: context.contains("home"),
                content: .pins([MapPin(id: "home", coordinate: home,
                                       title: "Home", subtitle: nil, openID: nil,
                                       tint: .white, radiusMeters: nil)]),
                caption: nil))
        }

        return built
    }

    private var subjectLayer: MapLayer {
        switch surface {
        case .radar:
            return MapLayer(
                id: "radar", name: "Radar", symbol: surface.symbol,
                role: .subject, isOn: true,
                content: .field(FieldLayer(source: radarSource,
                                           stamps: radar.stamps,
                                           playhead: playhead(radar.playhead.a,
                                                              radar.playhead.b,
                                                              blend: radar.playhead.blend))),
                caption: radarCaption)
        case .cloud:
            return MapLayer(
                id: "cloud", name: "Cloud", symbol: surface.symbol,
                role: .subject, isOn: true,
                content: .field(FieldLayer(source: satelliteSource,
                                           stamps: [satelliteStamp],
                                           playhead: .init(stampA: satelliteStamp,
                                                           stampB: satelliteStamp))),
                // "daylight" because the visible band is night-blind, and a black
                // screen at midnight would otherwise read as clear sky.
                caption: band.isNightBlind ? "daylight" : nil)
        case .fire:
            return MapLayer(
                id: "fire", name: "Fire", symbol: surface.symbol,
                role: .subject, isOn: true,
                content: .field(FieldLayer(source: fireSource,
                                           stamps: [fireStamp],
                                           playhead: .init(stampA: fireStamp,
                                                           stampB: fireStamp))),
                caption: "Texas")
        }
    }

    /// What the radar view can honestly say in one glance. STALE AND REFUSED ARE
    /// DIFFERENT SENTENCES: the index can be perfect and every tile refused, and a
    /// loop whose newest frame is old is not a picture of now.
    private var radarCaption: String? {
        if radar.failure != nil { return "unavailable" }
        if radar.tilesRefused { return "tiles refused" }
        if radar.isStale { return "stale" }
        return radar.currentObservation.map {
            $0.time.formatted(date: .omitted, time: .shortened)
        } ?? "—"
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

    // MARK: Panel

    private var panel: some View {
        // Spelled out rather than a ternary in the argument list: `hasHome ? f : nil`
        // gives the type checker a function-vs-nil unification it cannot do inside
        // a ViewBuilder, and the diagnostic it produces names none of that.
        let recenter: (() -> Void)? = settings.hasHome ? { recenterHome() } : nil
        return LayerPanel(surface: $surface,
                          context: $context,
                          band: $band,
                          fireProduct: $fireProduct,
                          captions: captions,
                          contextLayers: layers.filter { $0.role == .context },
                          recenter: recenter)
    }

    /// One caption per view, so the picker can say something true about each
    /// option WITHOUT that option having to be switched on to find out — the time
    /// of the newest scan, whether there is a warning out.
    private var captions: [MapSurface: String] {
        var out: [MapSurface: String] = [:]
        if let caption = radarCaption { out[.radar] = caption }
        out[.cloud] = band.label
        out[.fire] = fireProduct.label
        return out
    }

    // MARK: Timeline

    /// Only under the radar view, because it describes that loop and nothing else.
    /// The other two views are stills and a scrub strip under them would be a
    /// control for a dimension they do not have.
    @ViewBuilder private var timeline: some View {
        if surface == .radar, !radar.loop.isEmpty {
            RadarScrubBar(loop: radar.loop,
                          index: radar.index,
                          nowIndex: radar.nowIndex,
                          isPlaying: radar.isPlaying,
                          motion: radar.motion,
                          latitude: settings.homeCoordinate?.latitude,
                          togglePlay: { radar.isPlaying.toggle() },
                          scrub: { radar.scrub(to: $0) })
        }
    }
}

// MARK: - The panel

/// VIEW on top, ALWAYS underneath, and the shape of the control says which is
/// which: a radio list cannot express "both", and a checkbox cannot express
/// "instead of". That is the whole point — the old flat list of checkboxes
/// offered combinations that were not actually pictures.
private struct LayerPanel: View {
    @Binding var surface: MapSurface
    @Binding var context: Set<String>
    @Binding var band: SatelliteFieldSource.Band
    @Binding var fireProduct: TexasFireFieldSource.Product
    let captions: [MapSurface: String]
    let contextLayers: [MapLayer]
    let recenter: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(MapLayerRole.subject.heading)
            ForEach(MapSurface.allCases) { option in
                choice(option)
                // The chosen view's refinements, indented under it. They are not
                // peers of the view and must not read as if they were.
                if option == surface { refinements.padding(.leading, 22) }
            }

            if !contextLayers.isEmpty {
                Divider().padding(.vertical, 2)
                heading(MapLayerRole.context.heading)
                ForEach(contextLayers) { layer in toggle(layer) }
            }

            if let recenter {
                Divider().padding(.vertical, 2)
                Button(action: recenter) {
                    Label("Recentre", systemImage: "scope").font(.callout)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(width: 226)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold)).tracking(0.7)
            .foregroundStyle(.secondary)
    }

    /// A row that SELECTS rather than toggles. Drawn by hand rather than with a
    /// `Picker`, because each option carries a caption — the newest scan's time,
    /// which band — and a segmented control has nowhere to put one.
    private func choice(_ option: MapSurface) -> some View {
        let chosen = option == surface
        return Button {
            surface = option
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(chosen ? Color.accentColor : .secondary)
                        .font(.system(size: 11))
                    Image(systemName: option.symbol).frame(width: 16)
                    Text(option.label).font(.callout)
                        .fontWeight(chosen ? .medium : .regular)
                    Spacer(minLength: 4)
                    if let caption = captions[option] {
                        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if chosen {
                    Text(option.question)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 23)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var refinements: some View {
        switch surface {
        case .cloud:
            Picker("", selection: $band) {
                ForEach(SatelliteFieldSource.Band.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small)
        case .fire:
            Picker("", selection: $fireProduct) {
                ForEach(TexasFireFieldSource.Product.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small)
        case .radar:
            // Nothing yet. The loop's only control is the scrub strip, and that
            // belongs under the map where the frames are, not in a corner.
            EmptyView()
        }
    }

    private func toggle(_ layer: MapLayer) -> some View {
        Toggle(isOn: binding(for: layer.id)) {
            HStack(spacing: 6) {
                Image(systemName: layer.symbol).frame(width: 16)
                Text(layer.name).font(.callout)
                Spacer(minLength: 4)
                if let caption = layer.caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    /// One set rather than a `@Binding` per layer. The version before this
    /// switched on the id to pick between hard-wired bindings, which meant every
    /// new layer was a new binding threaded through two types — and a layer whose
    /// id was not in the switch silently toggled a different one.
    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { context.contains(id) },
                set: { on in if on { context.insert(id) } else { context.remove(id) } })
    }
}

// MARK: - The status bar

/// One situation the map is in, said in words.
///
/// `fraction` is present only while something is genuinely still arriving, and it
/// draws as a thin bar rather than a number: "62%" invites you to watch it, which
/// is precisely the wrong thing to be doing with a weather map.
struct FieldStatus: Equatable {
    var message: String
    var detail: String?
    var canRetry: Bool
    var fraction: Double?
}

/// Sits under the map, above the scrub strip, and only when there is something to
/// say. NOT an alert and not a spinner: a spinner says "wait" without saying what
/// for, and an alert would stop you looking at the weather in order to tell you
/// about the weather app.
private struct FieldStatusBar: View {
    let state: FieldStatus
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.canRetry ? "exclamationmark.triangle.fill" : "arrow.down.circle")
                .font(.system(size: 12))
                .foregroundStyle(state.canRetry ? .orange : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.message).font(.callout)
                if let detail = state.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let fraction = state.fraction {
                    // Thin, unlabelled, and capped at the width of the text above
                    // it — progress you can glance at rather than read.
                    ProgressView(value: min(1, max(0, fraction)))
                        .progressViewStyle(.linear)
                        .frame(width: 170)
                        .padding(.top, 1)
                }
            }

            if state.canRetry {
                Button("Try again", action: retry)
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .transition(.opacity)
    }
}
