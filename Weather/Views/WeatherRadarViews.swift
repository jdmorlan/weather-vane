//
//  WeatherRadarViews.swift  (macOS)
//
//  The radar loop, over your acre, with any active warning polygon drawn on top.
//  That composition is the point of the card — the alert half tells you something
//  is coming and this half is where you see what it is.
//
//  THE VIEWPORT IS FIXED. Because this is one place and not a map you browse,
//  scroll/zoom/rotate/pitch are all off and the only spatial control is how far
//  out to reach (`RadarRange`). That is most of what makes a map feature
//  expensive, deleted by the fact that Jay asked for his acre rather than a place
//  he picks.
//
//  The honesty carry-over from the alert half: a loop whose newest frame is old
//  is not a picture of now, and says so rather than quietly showing stale
//  returns. Every frame here IS an observation — the NEXRAD feed has no nowcast —
//  so there is no longer a forecast boundary for this card to mark.
//
//  A LOOP THAT ISN'T LOADED YET MUST NOT PLAY. See `RadarWarmer`: the frames are
//  held on the newest scan until every one of them has its tiles, because a frame
//  drawn before its tiles arrive is a blank square, and a blank square on this
//  card is indistinguishable from clear sky. Freezing is honest; flickering is a
//  lie told ten times a loop.
//

import SwiftUI
import Combine
import MapKit
import WeatherKit

/// Fetches every frame's tiles BEFORE the loop is allowed to advance onto them.
///
/// THE BUG THIS EXISTS FOR. The card installs all ten frames as overlays at once
/// and shows one by setting its renderer's alpha, which was supposed to spare
/// each step a tile fetch. It doesn't: MapKit does not request tiles for a
/// renderer it isn't drawing, and nine of the ten sit at alpha 0. So every frame
/// began loading at the exact moment it became visible — the first pass through
/// the loop drew blanks, and the picture popped in partway through a 450 ms hold.
/// Frames going blank and the timing feeling uneven were never two problems.
///
/// THE WARM SET DOES NOT HAVE TO BE COMPUTED. When MapKit asks the visible
/// overlay for tile z/x/y, that request is already a precise statement about the
/// viewport — and the tile every other frame needs is the same z/x/y. So the
/// visible frame teaches the loop what to fetch. No zoom arithmetic to get subtly
/// wrong, no guess about how MapKit picks a level, and it re-teaches itself for
/// free when the range changes.
@MainActor
final class RadarWarmer: ObservableObject {
    /// True while frames still have tiles outstanding. The loop reads this and
    /// holds rather than advancing onto a frame that would draw empty.
    @Published private(set) var isWarming = false

    private struct TilePath: Hashable { let z, x, y: Int }

    private var frames: [RadarFrame] = []
    private var known: Set<TilePath> = []
    private var outstanding = 0
    private var settle: Task<Void, Never>?

    /// UNTIL A TILE IS ACTUALLY REQUESTED, THIS GATES NOTHING. That is what keeps
    /// the Map surface working: it swaps a single overlay per step instead of
    /// pre-installing a loop, so nothing there ever calls `note` — `isWarming`
    /// stays false and its animation is untouched by any of this.
    func note(z: Int, x: Int, y: Int, requestedBy frameID: String) {
        let path = TilePath(z: z, x: x, y: y)
        guard known.insert(path).inserted else { return }
        fetch(frames.filter { $0.id != frameID }, at: path)
    }

    /// A reload replaces one frame and keeps nine, so warm ONLY what arrived.
    func setFrames(_ incoming: [RadarFrame]) {
        let existing = Set(frames.map(\.id))
        let added = incoming.filter { !existing.contains($0.id) }
        frames = incoming
        guard !added.isEmpty else { return }

        if existing.isEmpty {
            // The first loop, where `known` is still empty because MapKit hasn't
            // drawn anything to learn from. Start warming on faith so the very
            // first pass can't march through frames before the map has even asked
            // for a tile; `scheduleSettle` releases it if no one ever does.
            isWarming = true
            scheduleSettle()
        }
        for path in known { fetch(added, at: path) }
    }

    /// The viewport moved, so every tile path learned for the old one is wrong.
    /// Warming starts immediately rather than waiting to be taught again —
    /// otherwise the loop would spend the gap between the range change and
    /// MapKit's first request advancing through frames that have nothing to draw.
    func viewportChanged() {
        known.removeAll()
        isWarming = true
        scheduleSettle()
    }

    private func fetch(_ frames: [RadarFrame], at path: TilePath) {
        var started = 0
        for frame in frames {
            guard let url = Radar.tileURL(frame: frame, z: path.z, x: path.x, y: path.y),
                  !RadarTileOverlay.isWarm(url) else { continue }
            started += 1
            outstanding += 1
            Task { [weak self] in
                await RadarTileOverlay.warm(url)
                self?.finished()
            }
        }
        if started > 0 {
            settle?.cancel()
            isWarming = true
        } else {
            scheduleSettle()
        }
    }

    private func finished() {
        outstanding -= 1
        if outstanding <= 0 { outstanding = 0; scheduleSettle() }
    }

    /// A BEAT OF QUIET, NOT AN EMPTY QUEUE. MapKit asks for the viewport's tiles
    /// in bursts, so `outstanding` touches zero between them; clearing on that
    /// alone would start the loop early and put back the blank frames this whole
    /// type exists to remove. It doubles as the safety net on `viewportChanged`,
    /// which optimistically starts warming before anyone has asked for a tile —
    /// if nothing does, this releases the loop instead of freezing it forever.
    private func scheduleSettle() {
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, self.outstanding == 0 else { return }
            self.isWarming = false
        }
    }
}

@MainActor
final class RadarModel: ObservableObject {
    @Published private(set) var frames: [RadarFrame] = []
    @Published var index: Int = 0
    @Published var isPlaying = true
    @Published private(set) var failure: String?
    @Published var range: RadarRange = .nearby { didSet { warmer.viewportChanged() } }
    /// Mirrored off `warmer` so the card can observe one object. A nested
    /// `ObservableObject` publishes nothing through its parent, and finding that
    /// out on screen costs more than the two lines to avoid it.
    @Published private(set) var isWarming = false

    let warmer = RadarWarmer()

    init() { warmer.$isWarming.assign(to: &$isWarming) }
    /// Set when the tile service refuses a tile — throttling, or the mosaic
    /// briefly unavailable. Kept separate from `failure`, which is about the
    /// INDEX: the index can be perfect and every tile still be refused, and those
    /// are different sentences.
    @Published private(set) var tilesRefused = false

    func noteTilesRefused() { tilesRefused = true }

    /// How long each frame holds, and the extra beat at the end of the loop so the
    /// most recent frame — the one you actually came to read — doesn't flash past.
    private let frameHold: Duration = .milliseconds(450)
    private let endHold: Duration = .milliseconds(1300)
    /// The index is refreshed on the scan cadence, not the alert cadence — and
    /// the NEXRAD composite lands every five minutes, so this is one scan.
    private let reloadEvery: Duration = .seconds(300)

    var current: RadarFrame? { frames.indices.contains(index) ? frames[index] : nil }

    /// True when even the newest frame is too old to be called "now".
    var isStale: Bool {
        guard let newest = frames.last else { return false }
        return Date().timeIntervalSince(newest.time) > Radar.staleAfter
    }

    func load() async {
        do {
            let fetched = try await NEXRADClient().frames()
            let wasAtEnd = index >= frames.count - 1
            frames = fetched
            warmer.setFrames(fetched)
            // Hold the newest frame across a reload. Snapping back to the start of
            // the loop every five minutes would yank the picture out from under
            // someone watching a storm approach.
            if wasAtEnd || index >= fetched.count { index = max(0, fetched.count - 1) }
            failure = nil
            tilesRefused = false
        } catch {
            failure = (error as? NEXRADClient.Failure)?.errorDescription ?? error.localizedDescription
        }
    }

    func run() async {
        await load()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: self?.reloadEvery ?? .seconds(300))
                    await self?.load()
                }
            }
            group.addTask { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let atEnd = self.index >= self.frames.count - 1
                    try? await Task.sleep(for: atEnd ? self.endHold : self.frameHold)
                    // HOLDING IS THE POINT. While the loop is warming, the newest
                    // scan stays on screen instead of the animation walking onto
                    // frames that would draw nothing.
                    guard self.isPlaying, !self.isWarming, !self.frames.isEmpty else { continue }
                    self.index = (self.index + 1) % self.frames.count
                }
            }
        }
    }

    func scrub(to newIndex: Int) {
        guard frames.indices.contains(newIndex) else { return }
        isPlaying = false
        index = newIndex
    }
}

// MARK: - The card

struct RadarCard: View {
    let home: CLLocationCoordinate2D
    let hazards: [Hazard]
    @StateObject private var model = RadarModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            RadarMap(center: home,
                     range: model.range,
                     frames: model.frames,
                     currentIndex: model.index,
                     hazards: hazards,
                     warmer: model.warmer,
                     onTilesRefused: { [weak model] in
                         Task { @MainActor in model?.noteTilesRefused() }
                     })
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
                .overlay(alignment: .bottomTrailing) {
                    Text(Radar.credit)
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }

            if let failure = model.failure {
                Label(failure, systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                RadarTimeline(frames: model.frames, index: model.index) { model.scrub(to: $0) }
                footer
            }
        }
        // Without this the card is a blank basemap that never says why: `frames`
        // stays empty, so there are no overlays AND no `failure` to report. The
        // Map surface had its `.task` and this one didn't, which is exactly the
        // shape of bug a silent empty state hides.
        .task { await model.run() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // A spinner rather than a pause icon while warming, because the loop
            // genuinely isn't running and a pause glyph would blame the user for
            // stopping it.
            if model.isWarming {
                ProgressView().controlSize(.small).frame(width: 14)
            } else {
                Button { model.isPlaying.toggle() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(model.frames.isEmpty)
            }

            // The frame's own time is the only number on this card, so it gets to
            // be the one that's legible from across the room.
            if let current = model.current {
                Text(current.time, format: .dateTime.hour().minute())
                    .font(.title3.weight(.medium)).monospacedDigit()
            }

            Spacer()

            Picker("", selection: $model.range) {
                ForEach(RadarRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 230)
        }
    }

    /// EVERY WAY THIS CARD CAN BE WRONG HAS TO HAVE WORDS. An empty radar map and
    /// a clear sky are the same picture, so silence here is a claim the card is not
    /// entitled to make — the same rule the archive follows about coverage and the
    /// alert half follows about reachability. Note this is the one card where
    /// "nothing drawn" is the ORDINARY answer, which is exactly why the failures
    /// have to be spelled out rather than left to look ordinary too.
    @ViewBuilder private var footer: some View {
        if model.frames.isEmpty {
            note("Waiting for the first scan…", icon: "antenna.radiowaves.left.and.right")
        } else if model.tilesRefused {
            note("The radar service refused some tiles — this loop may be missing returns.",
                 icon: "exclamationmark.triangle")
        } else if model.isWarming {
            note("Loading the loop — holding on the newest scan until every frame has its tiles.",
                 icon: "arrow.down.circle")
        } else if model.isStale, let newest = model.frames.last {
            note("Newest scan is from \(newest.time.formatted(date: .omitted, time: .shortened)) — this isn't a picture of right now.",
                 icon: "clock.badge.exclamationmark")
        }
    }

    private func note(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Timeline

/// A tick per frame rather than a `Slider`, because a stepped macOS slider draws
/// a native tick per step and turns into grey hatch at ten frames. The strip's
/// job is to be a scrubbable position in a fifty-minute loop, not a value.
struct RadarTimeline: View {
    let frames: [RadarFrame]
    let index: Int
    let scrub: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let width = max(1, (geo.size.width - gap * CGFloat(max(0, frames.count - 1)))
                               / CGFloat(max(1, frames.count)))
            HStack(spacing: gap) {
                ForEach(Array(frames.enumerated()), id: \.element.id) { position, frame in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(position == index ? Color.primary.opacity(0.75)
                                                : Color.primary.opacity(0.18))
                        .frame(width: width, height: position == index ? 18 : 10)
                        .frame(height: 18)
                        .contentShape(Rectangle())
                        .onTapGesture { scrub(position) }
                        .help(frame.time.formatted(date: .omitted, time: .shortened))
                }
            }
            .animation(.easeOut(duration: 0.12), value: index)
        }
        .frame(height: 18)
    }
}

// MARK: - The map

private struct RadarMap: NSViewRepresentable {
    let center: CLLocationCoordinate2D
    let range: RadarRange
    let frames: [RadarFrame]
    let currentIndex: Int
    let hazards: [Hazard]
    let warmer: RadarWarmer
    let onTilesRefused: @Sendable () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // Muted, because the basemap's job is to tell you WHERE the returns are —
        // roads and town names — not to compete with them for colour.
        map.mapType = .mutedStandard
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        map.showsZoomControls = false
        // Fixed viewport: this is one place, not a map you browse.
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.register(HomeDotView.self,
                     forAnnotationViewWithReuseIdentifier: HomeDotView.reuseID)
        map.setRegion(MKCoordinateRegion(center: center,
                                         latitudinalMeters: range.radius * 2,
                                         longitudinalMeters: range.radius * 2),
                      animated: false)
        let home = MKPointAnnotation()
        home.coordinate = center
        map.addAnnotation(home)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator

        if coordinator.range != range {
            coordinator.range = range
            map.setRegion(MKCoordinateRegion(center: center,
                                             latitudinalMeters: range.radius * 2,
                                             longitudinalMeters: range.radius * 2),
                          animated: true)
        }

        // SET THE VISIBLE FRAME BEFORE INSTALLING ANYTHING. MapKit builds a
        // renderer asynchronously after `addOverlay`, and the renderer decides its
        // own starting alpha from `shownFrameID` — so doing this afterwards leaves
        // every renderer born at alpha 0 and the card blank until the loop happens
        // to tick. Order is the whole fix.
        coordinator.shownFrameID = frames[safe: currentIndex]?.id

        // ALL frames are installed as overlays at once and shown by ALPHA rather
        // than added and removed per step, so a step is a property change instead
        // of a fetch. NOTE THAT THIS ALONE WAS NOT ENOUGH: an overlay at alpha 0
        // is never drawn, so MapKit never asked for its tiles and the fetch simply
        // moved to the moment the frame appeared. `RadarWarmer` is the half that
        // makes this design actually pay off.
        // INSTALL THE DIFFERENCE, NOT THE LIST. Every five minutes the index
        // reload replaces one frame and keeps nine, and tearing all ten down meant
        // re-requesting nine frames' worth of tiles for no new picture. A frame is
        // identified by its valid time, so identity is exact and the diff is
        // trustworthy.
        let wanted = frames.map(\.id)
        if coordinator.installedFrames != wanted {
            let keep = Set(wanted)
            for overlay in map.overlays {
                guard let tiles = overlay as? RadarTileOverlay else { continue }
                if !keep.contains(tiles.frame.id) {
                    map.removeOverlay(tiles)
                    coordinator.renderers[tiles.frame.id] = nil
                }
            }
            let present = Set(map.overlays.compactMap { ($0 as? RadarTileOverlay)?.frame.id })
            for frame in frames where !present.contains(frame.id) {
                let overlay = RadarTileOverlay(frame: frame)
                overlay.warmer = warmer
                overlay.onTilesRefused = onTilesRefused
                map.addOverlay(overlay, level: .aboveRoads)
            }
            coordinator.installedFrames = wanted
        }

        // Renderers that already exist have to be told; ones MapKit hasn't built
        // yet read `shownFrameID` themselves when it does. `appliedFrameID` keeps
        // this from redrawing every overlay on every unrelated SwiftUI update.
        if coordinator.appliedFrameID != coordinator.shownFrameID {
            coordinator.appliedFrameID = coordinator.shownFrameID
            for (id, renderer) in coordinator.renderers {
                renderer.alpha = (id == coordinator.shownFrameID) ? 0.8 : 0
                renderer.setNeedsDisplay()
            }
        }

        let shapeIDs = hazards.compactMap { $0.shape != nil ? $0.id : nil }
        if coordinator.installedHazards != shapeIDs {
            for overlay in map.overlays where overlay is HazardPolygon { map.removeOverlay(overlay) }
            for hazard in hazards {
                guard let shape = hazard.shape else { continue }
                for ring in shape.rings where ring.count > 2 {
                    let coords = ring.map { CLLocationCoordinate2D(latitude: $0.latitude,
                                                                  longitude: $0.longitude) }
                    let polygon = HazardPolygon(coordinates: coords, count: coords.count)
                    polygon.tintColor = hazard.tint
                    // ABOVE the radar, because the warning is the point and a
                    // heavy cell drawn over its own polygon hides the boundary
                    // you're trying to place yourself against.
                    map.addOverlay(polygon, level: .aboveLabels)
                }
            }
            coordinator.installedHazards = shapeIDs
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var range: RadarRange?
        var installedFrames: [String] = []
        var installedHazards: [String] = []
        var shownFrameID: String?
        var appliedFrameID: String?
        var renderers: [String: MKTileOverlayRenderer] = [:]

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? RadarTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
                renderer.alpha = (tiles.frame.id == shownFrameID) ? 0.8 : 0
                renderers[tiles.frame.id] = renderer
                return renderer
            }
            if let polygon = overlay as? HazardPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                let tint = NSColor(polygon.tintColor)
                renderer.strokeColor = tint
                renderer.lineWidth = 2.5
                // Outline only. A filled warning polygon would bury the returns
                // inside it, which are the reason there's a warning at all.
                renderer.fillColor = tint.withAlphaComponent(0.08)
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            mapView.dequeueReusableAnnotationView(withIdentifier: HomeDotView.reuseID,
                                                  for: annotation)
        }
    }
}

// MARK: - Map objects

/// Shared by BOTH postures — the Weather card's fixed loop and the Map surface's
/// browsable single frame. Building the tile layer separately from the card is
/// what made the second posture nearly free.
final class RadarTileOverlay: MKTileOverlay {
    let frame: RadarFrame

    /// Called on the main actor when the tile service refuses a tile. The loop
    /// cannot fix that on its own, so the only useful thing it can do is stop
    /// claiming the sky is clear. See `RadarModel.tilesRefused`.
    var onTilesRefused: (@Sendable () -> Void)?

    /// Told about every tile this frame is asked for, so the same tile can be
    /// fetched for the rest of the loop before the loop walks onto it. Nil on the
    /// Map surface, which shows one frame at a time and has nothing to warm.
    var warmer: RadarWarmer?

    init(frame: RadarFrame) {
        self.frame = frame
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: Radar.tileSize, height: Radar.tileSize)
        // NO minimumZ/maximumZ. An earlier guess of 3…10 was wrong in the way
        // guesses about someone else's service usually are: MapKit renders
        // "Zoom level not supported" for any zoom outside the declared range, so
        // the constraint didn't clamp the view, it blanked it. Behind a WMS the
        // question doesn't even arise — it renders whatever bounding box you name
        // at whatever size you ask for, so there is no level to be outside of.
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        Radar.tileURL(frame: frame, z: path.z, x: path.x, y: path.y)
            ?? URL(string: "about:blank")!
    }

    /// AN HTTP ERROR IS NOT A TILE, and the default `loadTile` cannot tell the
    /// difference. An error body served as a normal response gets accepted by
    /// MapKit, fails to decode as an image, and comes out as its own grey "Zoom
    /// level not supported" square — a message about zoom for a problem that has
    /// nothing to do with zoom, which is how the last one of these stayed
    /// mysterious for so long. Turning a non-2xx into an actual error makes MapKit
    /// draw nothing and lets the card say what really happened.
    ///
    /// A CACHE HIT IS A RENDER THE SERVICE DOESN'T HAVE TO DO. The WMS sends no
    /// caching headers, so `.returnCacheDataElseLoad` is what makes the cache
    /// work at all — and it is SAFE here for a reason that belongs to this source
    /// specifically: a tile is addressed by a scan's valid time, and a finished
    /// five-minute composite does not change afterwards. That matters because the
    /// loop re-adds its overlays whenever the index reloads; without a cache big
    /// enough to hold the whole loop, every reload would re-render fifty minutes
    /// of weather that is already on disk.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024,
                                   diskPath: "radar-tiles")
        config.requestCachePolicy = .returnCacheDataElseLoad
        // WARMING A LOOP IS 80-120 TILES AND THE DEFAULT IS SIX AT A TIME.
        // Measured against IEM at the nearby range — ten frames, eight tiles each,
        // about 300 KB all told — six connections take 7.4s and twelve take 4.0s,
        // with per-tile latency flat at half a second either way. The wait is what
        // the card shows instead of a moving loop, so it is worth buying down; ten
        // is most of the gain and still a small ask of a free service, and it is
        // paid once on open, not per frame, because a five-minute reload only adds
        // one frame's worth.
        config.httpMaximumConnectionsPerHost = 10
        return URLSession(configuration: config)
    }()

    /// TILES THE LOOP HAS WARMED, HELD OUTRIGHT RATHER THAN LEFT TO `URLCache`.
    /// The WMS sends no caching headers at all, so whether a header-less response
    /// survives in `URLCache` is a policy question with a subtle answer — and the
    /// whole point of warming is that the answer must be YES, every time, or the
    /// blank frames come back. Holding the bytes ourselves makes it a fact. A
    /// warmed loop is a few megabytes; the limit is far above what one can cost.
    private static let store: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static func isWarm(_ url: URL) -> Bool { store.object(forKey: url as NSURL) != nil }

    /// Fetch a tile purely to have it. Failures are silent on purpose: this is
    /// speculative work for a frame nobody is looking at yet, and if it didn't
    /// land, `loadTile` will ask again for real and report it then.
    static func warm(_ url: URL) async {
        guard !isWarm(url) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        guard let (data, response) = try? await session.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        else { return }
        store.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let url = url(forTilePath: path)

        // Every request is also a statement about the viewport: whatever tile
        // this frame needs, so does every other frame in the loop.
        if let warmer {
            let (z, x, y, id) = (path.z, path.x, path.y, frame.id)
            Task { @MainActor in warmer.note(z: z, x: x, y: y, requestedBy: id) }
        }

        if let warm = Self.store.object(forKey: url as NSURL) {
            result(warm as Data, nil)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let notify = onTilesRefused
        Self.session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                // Only when the SERVICE answered. A status of 0 is a transport
                // failure — offline, timed out — and saying "the service refused
                // tiles" about a dropped Wi-Fi connection blames the wrong thing.
                if status > 0 { notify?() }
                result(nil, error ?? URLError(.badServerResponse))
                return
            }
            if let data { Self.store.setObject(data as NSData, forKey: url as NSURL, cost: data.count) }
            result(data, error)
        }.resume()
    }
}

/// Carries the COLOUR rather than the level, so the one ramp in
/// `Hazard.tint(forLevel:)` is applied once at construction and both maps draw the
/// same warning identically.
final class HazardPolygon: MKPolygon {
    var tintColor: Color = .orange
}

/// A small ring-and-dot rather than a pin. You are looking for whether the green
/// is ON you, and a pin's point sits above the thing it marks.
private final class HomeDotView: MKAnnotationView {
    static let reuseID = "home-dot"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 14, height: 14)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderColor = NSColor.black.withAlphaComponent(0.85).cgColor
        layer?.borderWidth = 3
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 2
        layer?.shadowOffset = .zero
        canShowCallout = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
