//
//  RadarLoop.swift  (WeatherKit)
//
//  The radar loop and its tile overlay, shared by every target that draws one.
//
//  These types lived in the Mac app's view file until the TV needed the same
//  loop. Nothing in them is about a Mac — `RadarModel` owns an index of scans and
//  a clock that walks it, and `RadarTileOverlay` turns a frame and a tile path
//  into a WMS request. Keeping them here is what stops the two apps drifting into
//  two different ideas of how fast a loop runs.
//
//  TWO RENDERING PATHS, ON PURPOSE AND TEMPORARILY. The Mac draws the loop
//  through `FieldRenderer`, which owns its own pixels and dissolves between
//  frames; the TV still draws it through `RadarTileOverlay` and MapKit's tile
//  machinery. `RadarModel` serves both because it is about WHICH SCANS EXIST and
//  WHERE THE LOOP IS, and neither of those is a rendering question. The TV moves
//  over to the field renderer once the Mac's version has earned it.
//
//  WHAT WENT AWAY. `RadarWarmer` used to sit here, fetching tiles for frames
//  MapKit was not drawing, because a renderer at alpha 0 is never asked for any.
//  It solved half the problem and could not solve the other half: the tile still
//  had to be decoded and drawn at the moment it became visible. The field
//  renderer computes the viewport's tiles directly and prefetches every frame at
//  once, which is both more direct and correct across a pan — the warmer's tile
//  set was learned by watching the visible frame ask for tiles, so it was always
//  one blank pass behind the map.
//

import Foundation
import Combine
import MapKit

/// ONE STEP OF THE LOOP, observed or forecast.
///
/// THE POINT OF THE TYPE IS THAT THE LOOP DOES NOT CARE WHICH. A forecast frame
/// is the newest scan's `stamp` with an OFFSET — the same decoded tiles, drawn
/// somewhere else — so the clock walks past and future identically and the
/// renderer needs one extra pair of numbers rather than a second code path. The
/// timeline is the one place the difference is meant to show, and `lead` is how
/// it knows.
public struct LoopFrame: Identifiable, Equatable, Sendable {
    /// When this frame is a picture OF. Real clock time either way, which is what
    /// lets the timeline lay past and future out on one axis.
    public let time: Date
    /// The scan whose tiles are drawn. A forecast reuses the newest observation's.
    public let stamp: String
    /// Where to draw them, in map points. Zero for an observation.
    public let offsetX: Double
    public let offsetY: Double
    /// Seconds ahead of the newest observation. Zero and below is observed.
    public let lead: TimeInterval

    public var id: String { "\(stamp)|\(Int(lead))" }
    public var isForecast: Bool { lead > 0 }

    public init(time: Date, stamp: String, offsetX: Double = 0, offsetY: Double = 0,
                lead: TimeInterval = 0) {
        self.time = time; self.stamp = stamp
        self.offsetX = offsetX; self.offsetY = offsetY; self.lead = lead
    }
}

@MainActor
public final class RadarModel: ObservableObject {
    @Published public private(set) var frames: [RadarFrame] = []
    @Published public private(set) var failure: String?
    @Published public var isPlaying = true
    @Published public var range: RadarRange = .nearby

    /// WHERE THE LOOP IS, as a continuous position. The thing that used to be a
    /// bare `Int` advanced on a timer — see `FieldLoopClock` for why that could
    /// only ever produce cuts.
    ///
    /// DELIBERATELY NOT `@Published`. It changes on every display refresh, and
    /// publishing that would run a full SwiftUI update pass sixty times a second
    /// to move a number almost nothing on screen reads. The renderer is handed the
    /// blend directly by the display link; SwiftUI is told only when the INDEX
    /// changes, which is about twice a second and is all the timeline and the
    /// caption actually depend on.
    public private(set) var clock = FieldLoopClock()

    /// Advance the clock and publish only if the frame changed.
    private func withClock(_ change: (inout FieldLoopClock) -> Void) {
        let before = clock.index
        let beforeCount = clock.frameCount
        change(&clock)
        if clock.index != before || clock.frameCount != beforeCount { objectWillChange.send() }
    }

    /// Which frame is being drawn. Kept as its own published value because that
    /// is the question a timeline, a caption and the TV's overlay swap all ask,
    /// and none of them care that there is a dissolve underneath.
    public var index: Int { clock.index }

    /// THE WHOLE WALK: every observation, then every forecast step. Rebuilt
    /// whenever the scans or the motion change, and published because its LENGTH
    /// and its seam are what the timeline draws.
    @Published public private(set) var loop: [LoopFrame] = []

    /// How fast the picture is moving, in MAP POINTS per second, and how much to
    /// believe it. Set from the map, which is the only place that knows the scale
    /// the motion was measured at — see `MotionEstimator`.
    @Published public private(set) var motion: StormMotion?

    /// How far ahead to extrapolate, and at what spacing.
    ///
    /// AN HOUR, IN THE SCAN'S OWN CADENCE. Five-minute steps because that is what
    /// the observations are and a forecast that ran at a different rhythm would
    /// visibly change speed at the seam. An hour because advection stops being a
    /// forecast somewhere around there — see `Nowcast.swift`.
    public var forecastHorizon: TimeInterval = 60 * 60
    public var forecastStep: TimeInterval = 5 * 60

    /// The last frame that is an OBSERVATION — the seam. Where the loop pauses,
    /// where the timeline draws its line, and where a reload puts you back.
    public var nowIndex: Int { max(0, frames.count - 1) }

    public var current: LoopFrame? { loop.indices.contains(index) ? loop[index] : nil }

    /// The observation behind the frame on screen, which is a different question
    /// once the loop has a future: a forecast frame's returns are the newest scan's.
    public var currentObservation: RadarFrame? { frames.last }

    /// Set when the tile service refuses a tile — throttling, or the mosaic
    /// briefly unavailable. Kept separate from `failure`, which is about the
    /// INDEX: the index can be perfect and every tile still be refused, and those
    /// are different sentences.
    @Published public private(set) var tilesRefused = false

    public func noteTilesRefused() { tilesRefused = true }

    /// The index is refreshed on the scan cadence, not the alert cadence — and
    /// the NEXRAD composite lands every five minutes, so this is one scan.
    private let reloadEvery: Duration = .seconds(300)

    public init() {}

    /// True when even the newest frame is too old to be called "now".
    public var isStale: Bool {
        guard let newest = frames.last else { return false }
        return Date().timeIntervalSince(newest.time) > Radar.staleAfter
    }

    // MARK: The two frames on screen

    /// The scan dissolving out, the scan dissolving in, and how far between them.
    /// A paused or single-frame loop reports the same stamp twice, which is how
    /// the renderer knows to draw a still rather than blend a frame with itself.
    public var playhead: (a: LoopFrame?, b: LoopFrame?, blend: Double) {
        guard loop.indices.contains(clock.index) else { return (nil, nil, 0) }
        let a = loop[clock.index]
        guard isPlaying, clock.frameCount > 1,
              loop.indices.contains(clock.nextIndex) else { return (a, a, 0) }
        return (a, loop[clock.nextIndex], clock.blend)
    }

    /// Every stamp in the loop, oldest first — the timeline's own order.
    public var stamps: [String] { frames.map(\.stamp) }

    /// The same stamps, IN THE ORDER THE LOOP WILL NEED THEM — what a prefetch
    /// should ask for.
    ///
    /// `frames` sorts oldest-first because that is what a timeline is, and handing
    /// that straight to the prefetch was a real and very visible bug: ten frames
    /// of twenty tiles is two hundred requests, `URLSession` runs ten at a time,
    /// so position in the list is close to arrival time. Oldest-first put the
    /// NEWEST scan — the one the clock holds on and the only one anybody is
    /// looking at — in the last twenty requests, about eight seconds out. The app
    /// spent that whole time showing an empty map and calling it weather.
    ///
    /// Starting at the current index and wrapping is both the fix and exactly the
    /// play order: the frame on screen, then the one it dissolves into, and so on
    /// round the loop.
    /// OBSERVATIONS ONLY, and the clamp is why this needs saying. The loop now
    /// runs past the observations into a forecast, and a forecast frame draws the
    /// NEWEST scan's tiles — so there is nothing extra to fetch for it, and a
    /// playhead out in the future is, for fetching purposes, sitting on the last
    /// observation.
    public var stampsByUrgency: [String] {
        guard !frames.isEmpty else { return [] }
        let start = min(clock.index, frames.count - 1)
        return (0..<frames.count).map { frames[(start + $0) % frames.count].stamp }
    }

    // MARK: Loading

    public func load() async {
        do {
            let fetched = try await NEXRADClient().frames()
            frames = fetched
            // Hold the newest frame across a reload. Snapping back to the start of
            // the loop every five minutes would yank the picture out from under
            // someone watching a storm approach.
            rebuildLoop(keepingEnd: true)
            failure = nil
            tilesRefused = false
        } catch {
            failure = (error as? NEXRADClient.Failure)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Fetch the index, then keep it fresh.
    ///
    /// `driving` is whether the model should also run the animation itself. The
    /// Mac says NO and ticks the clock from a display link instead, because a
    /// dissolve has to land on real display refreshes to look like one; the TV,
    /// which still swaps whole frames, says yes and lets a plain timer do it.
    /// Both drivers must never run at once or the loop advances twice as fast.
    public func run(driving: Bool = true) async {
        await load()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: self?.reloadEvery ?? .seconds(300))
                    await self?.load()
                }
            }
            guard driving else { return }
            group.addTask { @MainActor [weak self] in
                let step = Duration.milliseconds(50)
                var last = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: step)
                    guard let self else { return }
                    let now = ContinuousClock.now
                    let delta = Double((now - last).components.attoseconds) / 1e18
                        + Double((now - last).components.seconds)
                    last = now
                    guard self.isPlaying else { continue }
                    self.withClock { $0.advance(by: delta) }
                }
            }
        }
    }

    /// Move the loop on by `delta` seconds. THE MAC'S DRIVER — called from a
    /// display link so the dissolve is sampled on the refreshes it will be shown
    /// on, rather than on a timer that drifts against them.
    public func tick(delta: Double) {
        guard isPlaying else { return }
        withClock { $0.advance(by: delta) }
    }

    /// Seeds the loop without the network, for tests about ORDER and timing —
    /// the parts that have nothing to do with whether IEM answered.
    func setFramesForTesting(_ incoming: [RadarFrame]) {
        frames = incoming
        rebuildLoop(keepingEnd: true)
    }

    /// Seeds a motion without a map, for tests about the SHAPE of the loop.
    func setMotionForTesting(_ new: StormMotion?) {
        motion = new
        rebuildLoop(keepingEnd: false)
    }

    public func scrub(to newIndex: Int) {
        guard loop.indices.contains(newIndex) else { return }
        isPlaying = false
        withClock { $0.jump(to: newIndex) }
    }

    // MARK: The future

    /// Hand the loop a storm motion, in map points per second.
    ///
    /// MEASURED ON THE MAP, APPLIED HERE. The estimator works in grid cells
    /// because that is what it can correlate; only the map knows how big a cell
    /// is. Keeping the conversion at the boundary means this model never has to
    /// know a viewport exists.
    public func setMotion(_ new: StormMotion?) {
        let usable = (new?.isUsable ?? false) ? new : nil
        // Compared loosely: the estimate jitters by a fraction of a cell between
        // scans, and rebuilding the loop — which resizes the clock — for a change
        // nobody can see would make the strip twitch every few seconds.
        if let a = motion, let b = usable,
           abs(a.dx - b.dx) < 1e-4, abs(a.dy - b.dy) < 1e-4 { return }
        if motion == nil, usable == nil { return }
        motion = usable
        rebuildLoop(keepingEnd: false)
    }

    /// Observations, then the extrapolation, as one walk.
    private func rebuildLoop(keepingEnd: Bool) {
        var built = frames.map { LoopFrame(time: $0.time, stamp: $0.stamp) }

        if let motion, let newest = frames.last {
            var lead = forecastStep
            while lead <= forecastHorizon {
                built.append(LoopFrame(time: newest.time.addingTimeInterval(lead),
                                       stamp: newest.stamp,
                                       offsetX: motion.dx * lead,
                                       offsetY: motion.dy * lead,
                                       lead: lead))
                lead += forecastStep
            }
        }
        loop = built

        withClock {
            // The pause belongs on the newest OBSERVATION, not on the last frame —
            // which is now an hour of extrapolation. Handed to `resize` rather
            // than set after it, because the resize needs both the old seam and
            // the new one to put the playhead back where the viewer was.
            $0.resize(to: built.count, keepingEnd: keepingEnd, holdIndex: nowIndex)
            $0.frameHold = FieldLoopClock.hold(forFrames: built.count)
        }
    }
}

/// The tile layer for MapKit's own tile machinery.
///
/// STILL HERE FOR THE TV, and nothing else. The Mac draws its fields through
/// `FieldRenderer`, which holds decoded pixels and can therefore dissolve; this
/// hands PNG bytes to MapKit, which cannot. See the header for why both exist.
public final class RadarTileOverlay: MKTileOverlay {
    /// How intensity becomes opacity. Static because the tile cache is static —
    /// changing it has to clear the cache, which `setCurve` does.
    public private(set) static var curve: RadarTileShading.Curve = .standard

    public static func setCurve(_ new: RadarTileShading.Curve) {
        guard new != curve else { return }
        curve = new
        store.removeAllObjects()
    }

    public let frame: RadarFrame

    /// Called on the main actor when the tile service refuses a tile.
    public var onTilesRefused: (@Sendable () -> Void)?

    public init(frame: RadarFrame) {
        self.frame = frame
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: Radar.tileSize, height: Radar.tileSize)
        // NO minimumZ/maximumZ. An earlier guess of 3…10 was wrong in the way
        // guesses about someone else's service usually are: MapKit renders
        // "Zoom level not supported" for any zoom outside the declared range, so
        // the constraint didn't clamp the view, it blanked it. Behind a WMS the
        // question doesn't even arise — it renders whatever bounding box you name
        // at whatever size you ask for. (`FieldTileSource.zoomRange` CAN clamp,
        // because the field renderer scales the nearest level instead of
        // blanking.)
    }

    public override func url(forTilePath path: MKTileOverlayPath) -> URL {
        Radar.tileURL(frame: frame, z: path.z, x: path.x, y: path.y)
            ?? URL(string: "about:blank")!
    }

    /// AN HTTP ERROR IS NOT A TILE, and the default `loadTile` cannot tell the
    /// difference. An error body served as a normal response gets accepted by
    /// MapKit, fails to decode as an image, and comes out as its own grey "Zoom
    /// level not supported" square — a message about zoom for a problem that has
    /// nothing to do with zoom. Turning a non-2xx into an actual error makes
    /// MapKit draw nothing and lets the card say what really happened.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024,
                                   diskPath: "radar-tiles")
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 10
        return URLSession(configuration: config)
    }()

    /// Shaded tiles, held outright rather than left to `URLCache`. The WMS sends
    /// no caching headers at all, so whether a header-less response survives is a
    /// policy question with a subtle answer, and the blank frames come back if
    /// the answer is ever no.
    private static let store: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    public override func loadTile(at path: MKTileOverlayPath,
                                  result: @escaping (Data?, Error?) -> Void) {
        let url = url(forTilePath: path)

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
            // Shaded BEFORE caching, so a tile is processed once however many
            // frames and pans ask for it. `shade` returning nil means the bytes
            // wouldn't decode, and the original is used — a tile drawn the old
            // way beats a hole in the map.
            let shaded = data.flatMap { RadarTileShading.shade($0, curve: Self.curve) } ?? data
            if let shaded { Self.store.setObject(shaded as NSData, forKey: url as NSURL, cost: shaded.count) }
            result(shaded, error)
        }.resume()
    }
}
