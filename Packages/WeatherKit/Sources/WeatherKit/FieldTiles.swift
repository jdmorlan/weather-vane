//
//  FieldTiles.swift  (WeatherKit)
//
//  THE SUBSTRATE EVERY RASTER FIELD SHARES — radar, satellite cloud, fire danger.
//
//  A "field" is data ABOUT space rather than data at a point: keyed by time,
//  fetched, expiring. `MapCanvas` already drew that distinction in its layer
//  model; this file is what makes it one implementation instead of three.
//
//  WHY THIS EXISTS RATHER THAN `MKTileOverlay`. MapKit's tile overlay owns its
//  own loading, and that ownership is precisely what made the radar loop flutter:
//  a renderer at alpha 0 is never asked for tiles, so every frame began
//  materialising at the moment it became visible and popped in partway through
//  its hold. Warming the NETWORK could not fix it, because the network was never
//  the slow part after the first pass — the decode and the draw were, and those
//  only happen when MapKit decides they happen.
//
//  So the field owns its pixels. `FieldTileStore` holds DECODED `CGImage`s, and a
//  renderer can draw any frame at any moment without asking MapKit's permission
//  or waiting for a download — which is what lets two overlays hold two scans and
//  crossfade between them. Re-encoding to PNG after shading and handing the bytes
//  back for MapKit to decode a second time also goes away with it.
//
//  AND THE COARSE PASS. `FieldTileGrid.parents` turns a viewport's twenty tiles
//  into one or two, three zoom levels up. Fetching those for the WHOLE LOOP first
//  costs one pass of the connection pool, and because the renderer draws a missing
//  tile from its parent, it is what lets the loop start moving in about a second
//  instead of ten.
//
//  THE PREFETCH IS DRIVEN BY WHAT IS ON SCREEN. `FieldTileGrid.tiles(in:z:)`
//  answers "which tiles does this viewport need" directly, so the loop no longer
//  has to learn its warm set by watching the visible frame ask for tiles — which
//  was why panning always cost a blank pass. Pan, get a new tile set, prefetch
//  every frame at once.
//

import Foundation
import CoreGraphics
import ImageIO

// MARK: - What a field is

/// One raster field: where its tiles come from and how its pixels are treated.
///
/// `stamp` is deliberately an opaque string rather than a `Date`. Radar addresses
/// a frame by a five-minute valid time, GOES by its own scan time, and a static
/// field — county lines, a fire-danger snapshot — by the empty string. The store
/// only ever compares stamps; it never reads one.
public protocol FieldTileSource: Sendable {
    /// Stable across launches and unique per rendering treatment. Two sources
    /// that differ only in colour ramp must NOT share an id, or the cache will
    /// hand one of them the other's pixels.
    var id: String { get }

    /// Tile edge in pixels. 512 costs a quarter the requests of 256 for the same
    /// ground; see `Radar.tileSize` for the measurement that settled it.
    var tileSize: Int { get }

    /// Zoom levels worth fetching. UNLIKE `MKTileOverlay`'s min/max this is a
    /// real clamp and not a blanking rule: outside the range the renderer draws
    /// the nearest level scaled, which is the honest picture anyway once you are
    /// zoomed past what the underlying observation resolves.
    var zoomRange: ClosedRange<Int> { get }

    /// The most tile pixels worth drawing per SCREEN POINT. Nil means match the
    /// display (2 on retina). A field coarser than the screen gains nothing from
    /// retina tiles but four times the tiles — see `Level2FieldSource`.
    var maxPixelScale: Double? { get }

    func url(stamp: String, z: Int, x: Int, y: Int) -> URL?

    /// Bytes to pixels, including whatever shading the field wants. Returning nil
    /// means the tile is unusable and the renderer leaves that square empty.
    func process(_ data: Data) -> CGImage?
}

public extension FieldTileSource {
    var tileSize: Int { 512 }
    var zoomRange: ClosedRange<Int> { 3...10 }
    var maxPixelScale: Double? { nil }
}

/// A field whose tiles are DRAWN HERE rather than fetched as pictures.
///
/// Level II radar is the reason: the service hands over measurements, not
/// tiles, so there is no URL for "z9/118/210" — the tile is made on this device
/// from a decoded scan. Everything past that point is the same as any other
/// field: the store caches the image under the same key, broadcasts its arrival
/// the same way, and the renderer never knows where it came from.
public protocol RenderedFieldTileSource: FieldTileSource {
    /// The finished tile, or nil when this stamp cannot be drawn (the scan would
    /// not download or decode). A tile with nothing in it is a clear image, not
    /// nil — clear sky is an answer, and nil is remembered as a failure.
    func render(stamp: String, z: Int, x: Int, y: Int) async -> CGImage?
}

public extension RenderedFieldTileSource {
    func url(stamp: String, z: Int, x: Int, y: Int) -> URL? { nil }
    func process(_ data: Data) -> CGImage? { nil }
}

// MARK: - Tile arithmetic

/// Slippy-tile maths against MapKit's flat map space.
///
/// THIS IS THE PART THAT CANNOT BE SLIGHTLY WRONG, for the same reason
/// `bbox3857` cannot: an error here does not fail loudly, it slides the
/// returns off the town they are actually over. Kept free of MapKit types so it
/// can be checked against known values in a test rather than on screen.
public enum FieldTileGrid {

    /// MapKit's flat map is 2^28 map points on a side, at every zoom.
    public static let worldSize: Double = 268_435_456

    /// One tile addressed in the standard web-Mercator scheme.
    public struct Tile: Hashable, Sendable {
        public let z: Int, x: Int, y: Int
        public init(z: Int, x: Int, y: Int) { self.z = z; self.x = x; self.y = y }
    }

    /// Web-Mercator half-circumference in metres — the edge of the EPSG:3857 world.
    static let mercatorExtent = 20_037_508.342789244

    /// The EPSG:3857 bounding box of a slippy tile, as a WMS wants it:
    /// `minX,minY,maxX,maxY`. What the satellite and fire sources ask for.
    ///
    /// ARITHMETIC THAT CANNOT BE SLIGHTLY WRONG. A tile service is handed z/x/y
    /// and works the projection out itself; a WMS is handed metres and draws
    /// exactly what you asked for, so an error here does not fail — it shifts the
    /// field off the ground it is actually over.
    public static func bbox3857(z: Int, x: Int, y: Int) -> String {
        let span = 2 * mercatorExtent / pow(2, Double(z))
        let minX = -mercatorExtent + Double(x) * span
        let maxY = mercatorExtent - Double(y) * span
        return "\(minX),\(maxY - span),\(minX + span),\(maxY)"
    }

    /// Which zoom level to draw, for a MapKit zoom scale.
    ///
    /// `zoomScale` is screen points per map point. At zoom `z` the world is
    /// `2^z * tileSize` pixels across, so matching pixel density to the screen
    /// means `2^z * tileSize == zoomScale * scale * worldSize`.
    public static func zoom(forZoomScale zoomScale: Double,
                            tileSize: Int,
                            scale: Double = 1,
                            clampedTo range: ClosedRange<Int>) -> Int {
        guard zoomScale > 0, tileSize > 0, scale > 0 else { return range.lowerBound }
        let exact = log2(zoomScale * scale * worldSize / Double(tileSize))
        let rounded = Int(exact.rounded())
        return min(range.upperBound, max(range.lowerBound, rounded))
    }

    /// Edge of one tile, in map points.
    public static func tileSpan(z: Int) -> Double { worldSize / pow(2, Double(z)) }

    /// WHERE a tile is fetched from versus WHERE it is drawn. Those are the same
    /// thing everywhere except across the antimeridian, and conflating them is
    /// how a field tears at the date line: the world wraps, so the tile east of
    /// the edge is fetched as x=0 — but it must be DRAWN a world-width to the
    /// right of x=0, not on top of it.
    public struct Placement: Hashable, Sendable {
        /// Wrapped into the valid range. This is what addresses the service.
        public let tile: Tile
        /// Un-wrapped map-space origin of the tile's top-left, in map points.
        /// This is what positions it on screen, and it can legitimately sit
        /// outside `0..<worldSize`.
        public let mapX: Double, mapY: Double

        public init(tile: Tile, mapX: Double, mapY: Double) {
            self.tile = tile; self.mapX = mapX; self.mapY = mapY
        }
    }

    /// The tiles covering a rect of map space, as placements.
    ///
    /// The rect is given in map points as `(x, y, width, height)` with the origin
    /// at the top-left of the world.
    public static func placements(inRectX x: Double, y: Double,
                                  width: Double, height: Double, z: Int) -> [Placement] {
        let span = tileSpan(z: z)
        guard span > 0, width > 0, height > 0 else { return [] }
        let count = Int(pow(2, Double(z)))

        // THE FAR EDGE IS EXCLUSIVE. Without the epsilon a viewport that lands
        // exactly on a tile boundary fetches an extra row and column it never
        // draws a pixel of — at the widest range that is a third more tiles for
        // nothing.
        let minX = Int(floor(x / span)), maxX = Int(floor((x + width - 0.0001) / span))
        let minY = Int(floor(y / span)), maxY = Int(floor((y + height - 0.0001) / span))
        guard maxX >= minX, maxY >= minY else { return [] }

        var out: [Placement] = []
        out.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for ty in minY...maxY {
            // The world does not wrap vertically — off the top or bottom is
            // nothing, not the other pole.
            guard ty >= 0, ty < count else { continue }
            for tx in minX...maxX {
                let wrapped = ((tx % count) + count) % count
                out.append(Placement(tile: Tile(z: z, x: wrapped, y: ty),
                                     mapX: Double(tx) * span, mapY: Double(ty) * span))
            }
        }
        return out
    }

    /// Just the distinct tiles a rect needs — what a prefetch wants, where the
    /// same wrapped tile appearing twice on screen is still one download.
    public static func tiles(inRectX x: Double, y: Double,
                             width: Double, height: Double, z: Int) -> [Tile] {
        var seen = Set<Tile>()
        return placements(inRectX: x, y: y, width: width, height: height, z: z)
            .compactMap { seen.insert($0.tile).inserted ? $0.tile : nil }
    }

    /// The ancestors of a tile set, `levelsUp` zoom levels coarser.
    ///
    /// WHAT THIS IS FOR: A FIRST PASS THAT ARRIVES IN ONE ROUND TRIP. A viewport
    /// is about twenty tiles at its own zoom, so a ten-frame loop is two hundred
    /// requests and the better part of ten seconds before the last frame can be
    /// drawn at all. Three levels up the same ground is one or two tiles, so the
    /// WHOLE LOOP is ten to twenty requests — one pass of `URLSession`'s ten
    /// connections, about a second.
    ///
    /// Those coarse tiles are not a throwaway: `FieldRenderer` already draws a
    /// missing tile from its parent, so the moment they land every frame has a
    /// soft but complete picture and the loop can start moving. The full-
    /// resolution pass then sharpens it underneath a loop that is already running,
    /// instead of in front of one that is frozen.
    public static func parents(of tiles: [Tile], levelsUp: Int, notBelow minZ: Int) -> [Tile] {
        guard levelsUp > 0 else { return tiles }
        var seen = Set<Tile>()
        var out: [Tile] = []
        for tile in tiles {
            let step = min(levelsUp, tile.z - minZ)
            guard step > 0 else { continue }
            let parent = Tile(z: tile.z - step, x: tile.x >> step, y: tile.y >> step)
            if seen.insert(parent).inserted { out.append(parent) }
        }
        return out
    }

    /// Map-space origin of a tile, in map points: `(x, y)` of its top-left.
    public static func origin(of tile: Tile) -> (x: Double, y: Double) {
        let span = tileSpan(z: tile.z)
        return (Double(tile.x) * span, Double(tile.y) * span)
    }
}

// MARK: - The store

/// Decoded field tiles, held outright.
///
/// NOT `URLCache`, AND THE REASON IS SPECIFIC. The WMS sends no caching headers
/// at all, so whether a header-less response survives in `URLCache` is a policy
/// question with a subtle answer — and the entire point of prefetching is that
/// the answer must be YES, every time, or the blank frames come back. Holding the
/// pixels ourselves makes it a fact rather than a hope. A warmed radar loop is a
/// few megabytes.
///
/// DECODED, NOT BYTES. The old path shaded a tile, re-encoded it to PNG, handed
/// it to MapKit, and MapKit decoded it again — twice the work for a picture that
/// then had to be redrawn on every alpha change anyway.
public final class FieldTileStore: @unchecked Sendable {
    public static let shared = FieldTileStore()

    /// A tile is addressed by source, stamp and position. The stamp is in the key
    /// because a finished five-minute composite never changes, so a tile fetched
    /// for 20:55Z stays the right picture of 20:55Z forever.
    public struct Key: Hashable, Sendable {
        public let source: String, stamp: String
        public let z: Int, x: Int, y: Int

        public init(source: String, stamp: String, z: Int, x: Int, y: Int) {
            self.source = source; self.stamp = stamp
            self.z = z; self.x = x; self.y = y
        }

        /// A `String` rather than an `NSString` because it crosses into the
        /// fetch completion, and `NSString` is not `Sendable`.
        var cacheKey: String { "\(source)|\(stamp)|\(z)/\(x)/\(y)" }
    }

    private let cache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        // The FLOOR. `prefetch` raises it to fit the loop actually in view; see
        // `reserve`. NSCache still evicts under system memory pressure.
        cache.totalCostLimit = FieldTileStore.floorBytes
        return cache
    }()

    static let floorBytes = 320 * 1024 * 1024
    /// An eighth of the device's memory: ~2 GB on an 18 GB Mac, ~1 GB on an
    /// 8 GB iPad. Past this a loop is allowed to thrash rather than crowd out
    /// everything else on the machine.
    static let ceilingBytes = Int(min(Double(Int.max), Double(ProcessInfo.processInfo.physicalMemory) / 8))

    /// THE CACHE HAS TO HOLD THE LOOP, OR THE LOOP NEVER FINISHES. Measured in
    /// the running app: a ten-frame Level II loop over a large window wanted 280
    /// tiles (~280 MB) against a fixed 320 MB limit that also held the coarse
    /// pass. NSCache evicts before its limit, so tiles were dropped, redrawn and
    /// dropped again — "held" hovered at 220 of 280 and the frame count ticked
    /// DOWN on screen. The limit now grows to the loop's own size, with room for
    /// the coarse pass, and never shrinks while the app runs.
    private func reserve(bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        let wanted = min(ceilingBytes, max(floorBytes, bytes))
        if wanted > cache.totalCostLimit {
            radarLog.info("tile cache limit \(self.cache.totalCostLimit / 1_048_576) → \(wanted / 1_048_576) MB")
            cache.totalCostLimit = wanted
        }
        // A LOOP THE CAP CANNOT HOLD, said once per size. The eviction count
        // shows the churn; this is the number that explains it.
        if bytes > ceilingBytes, bytes != lastOverCap {
            lastOverCap = bytes
            radarLog.notice("loop wants \(bytes / 1_048_576) MB of tiles; the cap is \(self.ceilingBytes / 1_048_576) MB, so tiles will be redrawn")
        }
    }

    private var lastOverCap = 0

    private var floorBytes = FieldTileStore.floorBytes
    private var ceilingBytes = FieldTileStore.ceilingBytes

    /// A HARD CAP, for a device where an eighth of physical memory is still too
    /// much. Apple TV 4K has 4 GB and kills an app at about 1.3 GB, and MapKit
    /// alone takes a third of that at 4K. The Mac's rule — the cache grows to
    /// hold the loop — would give the tiles 512 MB there, and it did: measured on
    /// the device, walking the ranges took the app from 440 MB to over a
    /// gigabyte. Past the cap a large loop re-draws tiles rather than holding
    /// them, which costs CPU and never costs the app.
    public func limit(toBytes bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        floorBytes = bytes
        ceilingBytes = bytes
        cache.totalCostLimit = bytes
    }

    private let lock = NSLock()
    private var inFlight: Set<String> = []

    /// WHEN A TILE ARRIVED, NOT WHO ASKED FOR IT. This used to be a completion
    /// handed to `fetch`, and that was the bug behind a field that drew half of
    /// itself and stopped:
    ///
    ///   · the prefetch started tile T, passing no completion
    ///   · the renderer painted, found T missing, and called `fetch(T)` WITH the
    ///     completion that would have repainted it
    ///   · `fetch` saw T already in flight and returned — dropping that callback
    ///   · T landed in the cache, and nothing ever redrew to show it
    ///
    /// Radar usually recovered because a dissolve repaints constantly. A STILL
    /// layer — satellite, a burn ban — has nothing else to trigger a repaint, so
    /// it stayed half-drawn until you happened to pan. Broadcasting decouples the
    /// question "did this arrive" from the accident of who requested it first.
    private var observers: [Int: @Sendable (Key) -> Void] = [:]
    private var nextObserverToken = 0

    /// Tiles the service would not give us, and when we gave up on them.
    ///
    /// A FAILURE HAS TO BE REMEMBERED OR IT BECOMES A FLOOD. Without this, a tile
    /// that fails is simply absent, so the next paint asks again — and during a
    /// dissolve that is up to sixty requests a second, per tile, aimed at a free
    /// academic service that just told us no. The record is also what lets the app
    /// say something honest instead of showing a hole.
    private var failures: [String: Date] = [:]

    /// How long a refusal stands before it is worth asking again. Long enough not
    /// to hammer, short enough that a blip heals itself while you are still
    /// looking at the map.
    public static let retryAfter: TimeInterval = 20

    /// Called on an arbitrary thread when the service ANSWERED and refused. Kept
    /// separate from transport failures: a status of 0 is offline or timed out,
    /// and saying "the service refused tiles" about dropped Wi-Fi blames the
    /// wrong thing.
    public var onRefused: (@Sendable () -> Void)?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Nothing is cached by URLSession — the store above is the cache, and a
        // second copy of every tile on disk buys nothing.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // THE COST IS PER REQUEST, NOT PER PIXEL, so concurrency is the only lever
        // on the wait. Measured against IEM: one tile takes about 0.6 s whatever
        // its zoom or size — 5 KB at z10, 16 KB at z6, same 0.6 s — because what
        // takes the time is the service rendering it, not the wire.
        //
        // So a loop's wall time is (requests / connections) x 0.6 s. The same
        // forty-request loop took 2.6 s over ten connections and 1.5 s over
        // twenty. Sixteen takes most of that gain, and now that the radar clamp
        // cut the request count by sixteenfold it is a far smaller ask of a free
        // academic service than ten used to be.
        config.httpMaximumConnectionsPerHost = 16
        // A HARD CEILING ON A WHOLE REQUEST, not just on silence. The per-request
        // timeout is an IDLE timeout, and the resource default is seven days — so
        // a connection that went half-dead across a sleep could keep a tile "in
        // flight" indefinitely, and an in-flight tile is exactly what holds the
        // loop on "showing the newest". Past this it fails, which the retry path
        // already handles.
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    public init() {
        cache.delegate = evictionWatcher
    }

    /// DIAGNOSTICS: counts what NSCache throws away, and says so in the radar
    /// log at most every few seconds. A loop whose tiles are evicted as fast as
    /// they land looks exactly like one that never loads, and only this can tell
    /// the two apart.
    private let evictionWatcher = EvictionWatcher()

    // MARK: Reading

    public func image(for key: Key) -> CGImage? { cache.object(forKey: key.cacheKey as NSString)?.image }

    public func has(_ key: Key) -> Bool { cache.object(forKey: key.cacheKey as NSString) != nil }

    // MARK: Watching

    /// Called on an arbitrary thread whenever any tile lands. Returns a token to
    /// unregister with; a renderer that outlives its map would otherwise keep
    /// being told about tiles for a view nobody is looking at.
    public func observe(_ block: @escaping @Sendable (Key) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextObserverToken += 1
        observers[nextObserverToken] = block
        return nextObserverToken
    }

    public func stopObserving(_ token: Int) {
        lock.lock(); defer { lock.unlock() }
        observers.removeValue(forKey: token)
    }

    // MARK: Fetching

    /// Fetch one tile if it is neither held nor already on its way.
    ///
    /// `completion` runs on an arbitrary thread, only on a tile that ARRIVED.
    /// Failures are silent by design: the renderer draws what it has, and a tile
    /// that did not land is a square it simply does not paint this pass.
    /// Fetch one tile unless it is held, already on its way, or recently refused.
    ///
    /// No completion argument, deliberately — see `observers`. A caller that wants
    /// to know when tiles land subscribes with `observe`, which is correct however
    /// many callers there are and whichever of them asked first.
    public func fetch(_ key: Key, from source: FieldTileSource) {
        let cacheKey = key.cacheKey
        guard cache.object(forKey: cacheKey as NSString) == nil else { return }

        lock.lock()
        if let failedAt = failures[cacheKey] {
            guard Date().timeIntervalSince(failedAt) > Self.retryAfter else {
                lock.unlock(); return
            }
            failures.removeValue(forKey: cacheKey)
        }
        guard inFlight.insert(cacheKey).inserted else { lock.unlock(); return }
        lock.unlock()

        if let rendered = source as? RenderedFieldTileSource {
            // USER-INITIATED, AND CAPPED RATHER THAN DEMOTED. At utility QoS
            // Apple Silicon keeps this work on the efficiency cores, which made
            // a slow render several times slower still. The render gate
            // (`Level2Frames.renders`) is what leaves cores for MapKit and the
            // interface; the priority only decides which cores the rest get.
            Task.detached(priority: .userInitiated) { [weak self] in
                let image = await rendered.render(stamp: key.stamp, z: key.z, x: key.x, y: key.y)
                self?.land(image, key: key, cacheKey: cacheKey)
            }
            return
        }

        guard let url = source.url(stamp: key.stamp, z: key.z, x: key.x, y: key.y) else {
            finish(cacheKey, failed: true)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let refused = onRefused

        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                // Only when the SERVICE answered. A status of 0 is a transport
                // failure — offline, timed out — and saying "the service refused
                // tiles" about a dropped Wi-Fi connection blames the wrong thing.
                if status > 0 { refused?() }
                self.finish(cacheKey, failed: true)
                return
            }
            // Shaded and decoded ONCE, however many frames, pans and dissolve
            // ticks go on to draw it.
            self.land(data.flatMap { source.process($0) }, key: key, cacheKey: cacheKey)
        }.resume()
    }

    /// A tile has arrived, fetched or drawn: cache it and tell whoever is watching.
    private func land(_ image: CGImage?, key: Key, cacheKey: String) {
        guard let image else {
            finish(cacheKey, failed: true)
            return
        }
        cache.setObject(CGImageBox(image), forKey: cacheKey as NSString,
                        cost: image.height * image.bytesPerRow)
        finish(cacheKey, failed: false)

        // Outside the lock: an observer repaints a map, and holding the
        // store's lock across that invites the renderer's next `image(for:)`
        // to deadlock against it.
        lock.lock()
        let watchers = Array(observers.values)
        lock.unlock()
        for watcher in watchers { watcher(key) }
    }

    private func finish(_ cacheKey: String, failed: Bool) {
        lock.lock()
        inFlight.remove(cacheKey)
        if failed { failures[cacheKey] = Date() } else { failures.removeValue(forKey: cacheKey) }
        lock.unlock()
    }

    /// Every frame of a loop, over the tiles a viewport actually needs.
    ///
    /// `stamps` IS A PRIORITY ORDER, AND THE CALLER OWES US A GOOD ONE. Two
    /// things make that the single most important input here:
    ///
    /// · tiles are walked stamp-major, so each frame gets its whole viewport
    ///   before the next frame starts — fetching tile-major instead would leave
    ///   every frame partly drawn for the length of the whole prefetch, which
    ///   looks exactly like the flutter this all replaces;
    /// · `URLSession` runs ten of these at a time and a loop is two hundred, so
    ///   position in this list is close to arrival time.
    ///
    /// MEASURED AGAINST IEM: 200 tiles, all answered 200, 8.7s wall, 23 tiles/s,
    /// no throttling anywhere — but per-tile latency reads p50 4.5s and p90 8.0s,
    /// which is queueing and not the service. Handed the loop oldest-first, as
    /// `frames` naturally sorts, the NEWEST scan is the last twenty requests and
    /// lands at about eight seconds. That is the frame the clock is holding on and
    /// the only one anybody is looking at. Handed it newest-first it arrives in
    /// under a second and the remaining nine fill in behind it.
    public func prefetch(stamps: [String], tiles: [FieldTileGrid.Tile],
                         from source: FieldTileSource) {
        // Half again for the coarse pass and the tiles a small pan reaches.
        reserve(bytes: stamps.count * tiles.count * source.tileSize * source.tileSize * 4 * 3 / 2)
        for stamp in stamps {
            for tile in tiles {
                fetch(Key(source: source.id, stamp: stamp, z: tile.z, x: tile.x, y: tile.y),
                      from: source)
            }
        }
    }

    /// WHAT THE MAP CAN HONESTLY SAY ABOUT ITSELF. Counted rather than guessed,
    /// so a "still loading" line stops when loading actually stops and a "some of
    /// this didn't arrive" line only appears when something actually didn't.
    public struct Progress: Equatable, Sendable {
        /// Tiles the viewport needs, across every frame asked for.
        public var wanted: Int
        /// Tiles we hold and can draw right now.
        public var held: Int
        /// Tiles currently on their way.
        public var inFlight: Int
        /// Tiles the service refused or that never arrived, still inside their
        /// retry window.
        public var failed: Int

        /// Frames whose EVERY tile is held — the ones that can be drawn in full.
        ///
        /// COUNTED, NOT DIVIDED. Estimating this as `held / tilesPerFrame` reads
        /// the same most of the time and is wrong in the way that matters: eight
        /// half-loaded frames and four whole ones give the same number, and only
        /// one of those loops can actually be played.
        public var readyFrames: Int
        /// How many frames were asked about, so `readyFrames` has a denominator.
        public var frameCount: Int

        public var isComplete: Bool { wanted > 0 && held >= wanted }
        /// 0...1, and 1 when there is nothing to want.
        public var fraction: Double { wanted > 0 ? Double(held) / Double(wanted) : 1 }

        /// True when every frame can be drawn in full. What playback waits for.
        public var allFramesReady: Bool { frameCount > 0 && readyFrames >= frameCount }

        public init(wanted: Int = 0, held: Int = 0, inFlight: Int = 0, failed: Int = 0,
                    readyFrames: Int = 0, frameCount: Int = 0) {
            self.wanted = wanted; self.held = held
            self.inFlight = inFlight; self.failed = failed
            self.readyFrames = readyFrames; self.frameCount = frameCount
        }
    }

    public func progress(stamps: [String], tiles: [FieldTileGrid.Tile],
                         from source: FieldTileSource) -> Progress {
        var out = Progress(wanted: stamps.count * tiles.count)
        out.frameCount = stamps.count
        lock.lock()
        let flying = inFlight, failed = failures
        lock.unlock()

        let now = Date()
        for stamp in stamps {
            var wholeFrame = !tiles.isEmpty
            for tile in tiles {
                let key = Key(source: source.id, stamp: stamp, z: tile.z, x: tile.x, y: tile.y)
                let cacheKey = key.cacheKey
                if cache.object(forKey: cacheKey as NSString) != nil { out.held += 1 }
                else {
                    wholeFrame = false
                    if flying.contains(cacheKey) { out.inFlight += 1 }
                    else if let at = failed[cacheKey],
                            now.timeIntervalSince(at) <= Self.retryAfter { out.failed += 1 }
                }
            }
            if wholeFrame { out.readyFrames += 1 }
        }
        return out
    }

    /// Forget every refusal, so the next paint asks again immediately. What a
    /// "Try again" button does.
    /// For diagnostics: how many tiles are in flight, and a few of their keys.
    public func inFlightSample(_ count: Int = 5) -> (total: Int, keys: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (inFlight.count, Array(inFlight.prefix(count)))
    }

    public func clearFailures() {
        lock.lock(); failures.removeAll(); lock.unlock()
    }

    public func removeAll() { cache.removeAllObjects() }
}

final class EvictionWatcher: NSObject, NSCacheDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var bytes = 0
    private var lastReport = Date.distantPast

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        lock.lock()
        count += 1
        if let box = obj as? CGImageBox { bytes += box.image.height * box.image.bytesPerRow }
        let due = Date().timeIntervalSince(lastReport) > 3
        let (c, b) = (count, bytes)
        if due { lastReport = Date(); count = 0; bytes = 0 }
        lock.unlock()
        if due {
            radarLog.notice("tile cache evicted \(c) tiles (\(b / 1_048_576) MB) in the last few seconds; limit \(cache.totalCostLimit / 1_048_576) MB")
        }
    }
}

/// `NSCache` wants an `AnyObject`, and a boxed `CGImage` is cheaper to reason
/// about than relying on the CoreFoundation bridge to behave like one.
final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
