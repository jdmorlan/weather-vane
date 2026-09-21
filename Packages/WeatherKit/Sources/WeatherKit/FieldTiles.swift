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

    func url(stamp: String, z: Int, x: Int, y: Int) -> URL?

    /// Bytes to pixels, including whatever shading the field wants. Returning nil
    /// means the tile is unusable and the renderer leaves that square empty.
    func process(_ data: Data) -> CGImage?
}

public extension FieldTileSource {
    var tileSize: Int { 512 }
    var zoomRange: ClosedRange<Int> { 3...10 }
}

// MARK: - Tile arithmetic

/// Slippy-tile maths against MapKit's flat map space.
///
/// THIS IS THE PART THAT CANNOT BE SLIGHTLY WRONG, for the same reason
/// `Radar.tileBBox` cannot: an error here does not fail loudly, it slides the
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
        // A loop of ten frames over a laptop-sized viewport is roughly twenty
        // 512² RGBA tiles per frame — about 200 MB at the very widest. The limit
        // is sized to hold one loop plus the neighbours a pan reaches, and NSCache
        // evicts under pressure rather than growing without bound.
        cache.totalCostLimit = 320 * 1024 * 1024
        return cache
    }()

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
        return URLSession(configuration: config)
    }()

    public init() {}

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
            guard let data, let image = source.process(data) else {
                self.finish(cacheKey, failed: true)
                return
            }
            self.cache.setObject(CGImageBox(image), forKey: cacheKey as NSString,
                                 cost: image.height * image.bytesPerRow)
            self.finish(cacheKey, failed: false)

            // Outside the lock: an observer repaints a map, and holding the
            // store's lock across that invites the renderer's next `image(for:)`
            // to deadlock against it.
            self.lock.lock()
            let watchers = Array(self.observers.values)
            self.lock.unlock()
            for watcher in watchers { watcher(key) }
        }.resume()
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
    public func clearFailures() {
        lock.lock(); failures.removeAll(); lock.unlock()
    }

    public func removeAll() { cache.removeAllObjects() }
}

/// `NSCache` wants an `AnyObject`, and a boxed `CGImage` is cheaper to reason
/// about than relying on the CoreFoundation bridge to behave like one.
final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
