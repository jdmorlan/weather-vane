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
    @State private var context: Set<String> = ["warnings", "home", "coverage"]
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
    @State private var lastStuckReport: Date?

    /// The source and stamps for whatever is on screen, so progress is counted
    /// against the view you are actually looking at.
    /// Nil only for radar with no site chosen, where there is nothing to count.
    private var currentSource: FieldTileSource? {
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

    /// The chosen site's Level II. The model owns the choice so the frames and the
    /// tiles can never disagree about which radar they came from.
    private var radarSource: FieldTileSource? { radar.fieldSource }

    /// WHICH RADAR, as stored: "auto" for the site nearest home, or an ICAO. Per
    /// device rather than synced — the right radar for a laptop on a trip is not
    /// the one at home.
    @AppStorage("radarSite") private var radarSiteChoice: String = "auto"
    @AppStorage("radarMode") private var radarModeChoice: RadarModel.Mode = .loop

    /// Anything that is not a known site — "auto", or a value saved by an older
    /// build — means the site nearest home.
    private var resolvedSite: RadarSite? {
        if let chosen = RadarSites.site(radarSiteChoice) { return chosen }
        guard let home = settings.homeCoordinate else { return nil }
        return RadarSites.nearest(latitude: home.latitude, longitude: home.longitude).first
    }
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
            // On whether there IS a status, not on its content. Animating the
            // whole value crossfaded every text change in place — the old line
            // and the new one drawn over each other four times a second.
            .animation(.easeOut(duration: 0.18), value: fieldStatus == nil)
        }
        // NOT `driving:` — the clock is ticked from the canvas's display link, so
        // the dissolve lands on real display refreshes. Two drivers would advance
        // the loop at twice the intended speed.
        .task { await radar.run(driving: false) }
        .task { await hazards.poll(settings: settings) }
        .task { await refreshStamps() }
        .task { await watchProgress() }
        // NEW SCANS NEED FETCHING TOO, and nothing else asks for them. The list
        // reloads every couple of minutes and rotates a fresh stamp in, but the
        // only other prefetch trigger is a GROWING viewport — a map left sitting
        // still never produces one. So each reload added a frame
        // nobody fetched, and after a day of that the whole loop was scans the
        // prefetch had never heard of: "0 of 10 frames sharp", held forever. The
        // same gap swallowed the very first load whenever the viewport reported
        // before the index arrived.
        .onChange(of: radar.stamps) { _, _ in
            prefetch(layerID: currentLayerID, tiles: visibleTiles)
        }
        .onChange(of: radarSiteChoice) { _, _ in radar.site = resolvedSite }
        .onChange(of: settings.homeLat) { _, _ in radar.site = resolvedSite }
        .onChange(of: radarModeChoice) { _, new in radar.mode = new }
        .onAppear {
            radar.mode = radarModeChoice
            radar.site = resolvedSite
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
            // SWEEP MODE RUNS ON ITS OWN CLOCK. The line turns whether or not the
            // loop's tiles are all in — it only ever draws the newest scans, which
            // the prefetch fetches first.
            if radar.mode == .sweep, let head = sweepPlayhead() {
                radar.tick(delta: delta)
                return ["radar": sweepPlayhead() ?? head]
            }
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

    /// Sweep mode's picture: the scan on screen, the one being swept in over it,
    /// and where the line is. Nil until the site's coverage is known — the line
    /// is drawn from the scan's own position and reach, never assumed.
    private func sweepPlayhead() -> FieldRenderer.Playhead? {
        let clock = radar.sweepClock
        let shown = clock.shown ?? radar.frames.last?.stamp ?? ""
        // PARKED: the scan on screen as a still, and no line. See `SweepClock`.
        guard let revealing = clock.revealing, let azimuth = clock.azimuth,
              let coverage = radar.coverage else {
            return FieldRenderer.Playhead(stampA: shown, stampB: shown)
        }
        var head = FieldRenderer.Playhead(stampA: shown, stampB: revealing.scan.stamp)
        head.sweep = SweepSite(latitude: coverage.latitude, longitude: coverage.longitude,
                               reach: coverage.reach)
        head.beamAzimuth = azimuth
        head.reveal = .init(from: revealing.scan.startAzimuth, turned: revealing.turned)
        return head
    }

    /// A pair of loop frames as the renderer wants them.
    private func playhead(_ a: RadarFrame?, _ b: RadarFrame?, blend: Double) -> FieldRenderer.Playhead {
        guard let a else { return .init() }
        return .init(stampA: a.stamp, stampB: (b ?? a).stamp, blend: blend)
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
            guard let radarSource else { break }
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
        case "cloud": store.prefetch(stamps: [satelliteStamp], tiles: tiles, from: satelliteSource)
        case "fire":  store.prefetch(stamps: [fireStamp], tiles: tiles, from: fireSource)
        default:      break
        }
    }

    /// The coarse stand-in for a viewport's tiles. TWO levels up rather than
    /// three, because the sharp level is itself two levels coarser than it used to
    /// be — a further 64x magnification off a z8 base is a wash rather than a
    /// picture. At 16x a storm is soft but unmistakably a storm in the right
    /// county, which is the whole job while the real tiles are in flight.
    private func overview(of tiles: [FieldTileGrid.Tile]) -> [FieldTileGrid.Tile] {
        guard let source = currentSource else { return [] }
        return FieldTileGrid.parents(of: tiles, levelsUp: 2, notBelow: source.zoomRange.lowerBound)
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
    /// Say what is outstanding when the map has been incomplete for a while —
    /// once every fifteen seconds, in the radar log, so a stall can be read
    /// rather than guessed at.
    private func reportIfStuck(_ now: FieldTileStore.Progress) {
        guard surface == .radar, radar.scansReady < radar.frames.count,
              let since = incompleteSince, Date().timeIntervalSince(since) > 15,
              Date().timeIntervalSince(lastStuckReport ?? .distantPast) > 15 else { return }
        lastStuckReport = Date()
        let flying = FieldTileStore.shared.inFlightSample()
        let site = radar.site?.id ?? "none"
        Task {
            let frames = await Level2Frames.shared.snapshot()
            radarLog.notice("""
                STUCK \(site, privacy: .public): held \(now.held)/\(now.wanted), inFlight \(now.inFlight), \
                failed \(now.failed), frames \(now.readyFrames)/\(now.frameCount); \
                store inFlight \(flying.total) e.g. \(flying.keys, privacy: .public); \(frames, privacy: .public)
                """)
        }
    }

    private func watchProgress() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard !visibleTiles.isEmpty, let currentSource else { progress = .init(); continue }
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
            if now.isComplete { incompleteSince = nil; lastStuckReport = nil }
            else if incompleteSince == nil { incompleteSince = Date() }
            reportIfStuck(now)
            // THE BACKSTOP. Missing tiles with nothing in flight and nothing
            // recently refused means no one is going to fetch them — a trigger was
            // missed, or the cache evicted under memory pressure while the app sat
            // open. Asking again is cheap (`fetch` skips anything held or flying)
            // and it is what makes a map left open for days converge rather than
            // depend on every trigger having fired.
            if !now.isComplete, now.inFlight == 0, now.failed == 0 {
                prefetch(layerID: currentLayerID, tiles: visibleTiles)
            }
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
        // RADAR IS READY WHEN ITS SCANS ARE. Every tile is drawn from a decoded
        // scan in a few milliseconds, so "ready" is the network part only —
        // counting cached tiles made the loop stall whenever macOS emptied the
        // cache under memory pressure. A tile missing at draw time is redrawn
        // then, from its parent first, without holding anything up.
        if surface == .radar {
            return !radar.frames.isEmpty && radar.scansReady == radar.frames.count
        }
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
            return FieldStatus(message: "Can't load \(radar.site?.id ?? "the radar")",
                               detail: radar.failure, canRetry: true)
        }
        if surface == .radar, radar.site == nil {
            return FieldStatus(message: "No radar chosen",
                               detail: "Set your home, or pick a radar in the panel",
                               canRetry: false)
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
        // RADAR: SCANS, NOT TILES. See `RadarModel.scansReady`.
        if surface == .radar {
            let ready = radar.scansReady, total = radar.frames.count
            if total > 0, ready < total {
                return FieldStatus(message: "Loading the last hour",
                                   detail: "\(ready) of \(total) scans downloaded",
                                   canRetry: false, fraction: Double(ready) / Double(total))
            }
        } else if !progress.isComplete, progress.wanted > 0,
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
    private var loadingDetail: String? { nil }

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

        // What the chosen radar can see. Only under the radar view, and only once
        // a scan has decoded — the rings are read from it.
        if surface == .radar, let coverage = radar.coverage {
            built.append(MapLayer(
                id: "coverage", name: "Radar range", symbol: "scope",
                role: .context, isOn: context.contains("coverage"),
                content: .coverage(coverage),
                caption: "\(coverage.rings.last?.miles ?? 0) mi"))
        }

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
            // No site yet means nothing to draw — said in the status bar, not
            // left as an empty map that reads as clear sky.
            guard let radarSource else {
                return MapLayer(id: "radar", name: "Radar", symbol: surface.symbol,
                                role: .subject, isOn: true, content: .pins([]),
                                caption: "no radar")
            }
            return MapLayer(
                id: "radar", name: "Radar", symbol: surface.symbol,
                role: .subject, isOn: true,
                content: .field(FieldLayer(source: radarSource,
                                           stamps: radar.stamps,
                                           // Mode-aware here too: this is pushed on
                                           // every SwiftUI pass, and a loop playhead
                                           // arriving mid-sweep would tear the line
                                           // down between display ticks.
                                           playhead: (radar.mode == .sweep ? sweepPlayhead() : nil)
                                               ?? playhead(radar.playhead.a,
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
        return radar.frames.last.map {
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
                          radarSite: $radarSiteChoice,
                          radarMode: $radarModeChoice,
                          home: settings.homeCoordinate,
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
        if surface == .radar, !radar.frames.isEmpty, radar.mode == .sweep {
            SweepBar(site: radar.site?.id ?? "",
                     shown: radar.frames.first { $0.key == radar.sweepShown },
                     revealing: radar.frames.first { $0.key == radar.sweepRevealing },
                     facts: radar.scanFacts,
                     newest: radar.frames.last,
                     interval: radar.scanInterval,
                     dish: radar.dish)
        } else if surface == .radar, !radar.frames.isEmpty {
            RadarScrubBar(loop: radar.frames,
                          index: radar.index,
                          isPlaying: radar.isPlaying,
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
    @Binding var radarSite: String
    @Binding var radarMode: RadarModel.Mode
    let home: CLLocationCoordinate2D?
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
            VStack(alignment: .leading, spacing: 6) {
                RadarSitePicker(choice: $radarSite, home: home)
                // Two ways of looking: the loop reads direction, the sweep shows
                // how the picture is made. See `RadarModel.Mode`.
                Picker("", selection: $radarMode) {
                    ForEach(RadarModel.Mode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                .frame(width: 150)
            }
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

// MARK: - Which radar

/// The radar picker: the site nearest home, or a named site.
///
/// THE NEAREST FEW, NOT ALL 159. Past about the fifth-closest site the radar is
/// too far away to see anything low over you — at 250 km the 0.5° beam is 5 km
/// up, above most rain — so a list of every site would mostly be choices that
/// are wrong for where you are. The full list is one level down for the day you
/// are watching somebody else's weather.
private struct RadarSitePicker: View {
    @Binding var choice: String
    let home: CLLocationCoordinate2D?

    private var nearby: [(site: RadarSite, miles: Int)] {
        guard let home else { return [] }
        return RadarSites.nearest(latitude: home.latitude, longitude: home.longitude, count: 5).map {
            ($0, Int($0.distance(toLatitude: home.latitude, longitude: home.longitude) / 1609.34))
        }
    }

    private var label: String {
        if let site = RadarSites.site(choice) { return "\(site.id) · \(site.name)" }
        return nearby.first.map { "Nearest · \($0.site.id)" } ?? "Choose a radar"
    }

    var body: some View {
        Menu {
            if let nearest = nearby.first {
                Picker("", selection: $choice) {
                    Text("Nearest to home (\(nearest.site.id))").tag("auto")
                }
                .pickerStyle(.inline)
            }

            if !nearby.isEmpty {
                Section("Near home") {
                    Picker("", selection: $choice) {
                        ForEach(nearby, id: \.site.id) { entry in
                            Text("\(entry.site.id) · \(entry.site.name) · \(entry.miles) mi").tag(entry.site.id)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }

            Menu("All sites") {
                Picker("", selection: $choice) {
                    ForEach(RadarSites.all) { site in
                        Text("\(site.id) · \(site.name)").tag(site.id)
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Text(label).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }
}
