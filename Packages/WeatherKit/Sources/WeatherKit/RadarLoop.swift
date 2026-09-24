//
//  RadarLoop.swift  (WeatherKit)
//
//  The radar loop and its tile overlay, shared by every target that draws one.
//
//  These types lived in the Mac app's view file until the TV needed the same
//  loop. Nothing in them is about a Mac — `RadarModel` owns a list of scans and a
//  clock that walks it. Keeping them here is what stops the apps drifting into
//  different ideas of how fast a loop runs.
//
//  ONE RENDERING PATH. Mac, iPad and TV all draw the loop through the app's
//  `FieldRenderer`, which owns its own pixels and dissolves between frames. The
//  TV used to have its own `MKTileOverlay` path — hard cuts between frames and a
//  PNG round-trip per tile — and it was retired when the TV moved over.
//
//  OBSERVATIONS ONLY. The loop used to run on past the newest scan into an hour
//  of "forecast" — the newest picture slid along a measured motion vector. It
//  was removed because it did not do the job: a blob translated across the map
//  does not grow, decay, split or turn, which is everything storms actually do,
//  and it looked exactly like what it was. Every frame here is now something a
//  radar measured.
//

import Foundation
import Combine
import MapKit

@MainActor
public final class RadarModel: ObservableObject {
    @Published public private(set) var frames: [RadarFrame] = []
    @Published public private(set) var failure: String?
    @Published public var isPlaying = true
    @Published public var range: RadarRange = .nearby

    /// WHICH RADAR. Nil only when none has been chosen yet — with no home set
    /// there is no "nearest", and the view says so rather than guessing a site.
    ///
    /// Setting it reloads: the loop's frames are a different list of scans. The
    /// field source follows from it (see `fieldSource`), so a view never has to
    /// keep the two in step itself.
    @Published public var site: RadarSite? {
        didSet {
            guard site != oldValue else { return }
            frames = []
            archiveFrames = []
            livePasses = []
            dish = nil
            live = site.map { Level2Live(site: $0.id) }
            coverage = nil
            failure = nil
            scanFacts = [:]
            sweepClock = SweepClock()
            publishSweep()
            rebuildLoop(keepingEnd: true)
            Task { await load() }
        }
    }

    /// The tiles to draw for this loop, or nil with no site chosen.
    public var fieldSource: Level2FieldSource? { site.map { Level2FieldSource(site: $0.id) } }

    /// What the chosen radar can see — its reach and how high its beam is at
    /// each distance. Nil until the first scan decodes: the rings are read from
    /// the data, never assumed.
    @Published public private(set) var coverage: RadarCoverage?

    // MARK: Sweep mode

    /// LOOP OR SWEEP — two ways of looking, not a setting on one. The loop plays
    /// the last ten scans in quick order so your eye reads DIRECTION; sweep mode
    /// turns a line round the radar and draws each new scan in as it passes, so
    /// you see how the picture is MADE. See `SweepClock`.
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case loop, sweep
        public var id: String { rawValue }
        public var label: String { self == .loop ? "Loop" : "Sweep" }
    }

    @Published public var mode: Mode = .loop {
        didSet {
            guard mode != oldValue, mode == .sweep else { return }
            // In with a demonstration: the scan before the newest on screen, so
            // the first turn sweeps the newest in rather than turning over a
            // picture that never changes.
            sweepClock.show(frames.count > 1 ? frames[frames.count - 2].key : frames.last?.key)
            publishSweep()
        }
    }

    /// The line's clock. NOT `@Published` — it moves every display refresh.
    /// `sweepShown` and `sweepRevealing` are what SwiftUI watches.
    public private(set) var sweepClock = SweepClock()
    @Published public private(set) var sweepShown: String?
    @Published public private(set) var sweepRevealing: String?

    /// What each scan's own sweep was like: where the dish started and how long
    /// it took. Read from the decoded scans as they arrive — the same decode the
    /// tiles use — and needed before a scan can be swept in, because the line
    /// waits for the scan's real starting azimuth.
    public struct ScanFacts: Equatable, Sendable {
        public let startAzimuth: Double
        public let duration: Double
    }
    @Published public private(set) var scanFacts: [String: ScanFacts] = [:]

    /// HOW MANY OF THE LOOP'S SCANS ARE DOWNLOADED AND DECODED — the only part
    /// of loading that waits on the network, and so the only honest measure of
    /// it. Tiles are drawn from these in milliseconds; counting tiles instead
    /// meant that when macOS emptied the tile cache under memory pressure (the
    /// log showed 269 tiles dropped at once) the map claimed to be "loading" a
    /// loop it already had every byte of.
    public var scansReady: Int { frames.filter { scanFacts[$0.key] != nil }.count }

    /// How often this site has been finishing volumes lately — the median gap
    /// between the loop's scans. Four to five minutes in rain, closer to ten in
    /// clear air.
    public var scanInterval: TimeInterval? {
        let gaps = zip(frames, frames.dropFirst()).map { $1.time.timeIntervalSince($0.time) }.sorted()
        return gaps.isEmpty ? nil : gaps[gaps.count / 2]
    }

    private func publishSweep() {
        if sweepShown != sweepClock.shown { sweepShown = sweepClock.shown }
        let revealing = sweepClock.revealing?.scan.stamp
        if sweepRevealing != revealing { sweepRevealing = revealing }
    }

    private func advanceSweep(by delta: Double) {
        var next: SweepClock.Scan?
        if sweepClock.revealing == nil,
           let stamp = SweepClock.next(after: sweepClock.shown, in: stamps),
           let facts = scanFacts[stamp] {
            next = SweepClock.Scan(stamp: stamp, startAzimuth: facts.startAzimuth)
        }
        sweepClock.advance(by: delta, next: next)
        publishSweep()
    }

    /// Read each scan's start azimuth and sweep time. Cheap: every one of these
    /// is already decoded, or about to be, for its tiles.
    private func learnScanFacts() async {
        for frame in frames.reversed() where scanFacts[frame.key] == nil {
            guard let decoded = await Level2Frames.shared.frame(for: frame.key),
                  let first = decoded.sweep.path.first else { continue }
            scanFacts[frame.key] = ScanFacts(startAzimuth: Double(first.azimuth),
                                             duration: decoded.sweep.duration)
        }
    }

    // MARK: Live

    /// Scans from the archive: finished volumes, seven or more minutes old.
    private var archiveFrames: [RadarFrame] = []
    /// Lowest-tilt passes from the realtime feed, seconds to a minute old. Each
    /// supersedes the archive file for the same volume, and in SAILS mode a
    /// volume contributes more than one.
    private var livePasses: [RadarFrame] = []
    private var live: Level2Live?

    /// What the dish is doing right now, from the realtime feed's listing. Nil
    /// until the first poll, or when the feed has nothing for this site.
    @Published public private(set) var dish: Level2Live.Dish?

    /// How often to look at the realtime bucket. Chunks post about every ten
    /// seconds; one listing request per look.
    private let liveEvery: Duration = .seconds(10)

    private func pollLive() async {
        guard let live, let site else { return }
        let (passes, state) = await live.poll()
        guard self.site == site else { return }
        if state != dish { dish = state }
        let new = passes.map { RadarFrame(time: $0.time, key: $0.stamp) }
            .filter { pass in !livePasses.contains { $0.key == pass.key } }
        guard !new.isEmpty else { return }
        livePasses = Array((livePasses + new).sorted { $0.time < $1.time }.suffix(12))
        mergeFrames()
        await learnScanFacts()
    }

    /// The loop: archive files not superseded by a live pass, plus the live
    /// passes, newest ten.
    private func mergeFrames() {
        let superseded = Set(livePasses.compactMap { $0.key.split(separator: "#").first.map(String.init) })
        let merged = (archiveFrames.filter { !superseded.contains($0.key) } + livePasses)
            .sorted { $0.time < $1.time }
            .suffix(10)
        let next = Array(merged)
        guard next != frames else { return }
        frames = next
        rebuildLoop(keepingEnd: true)
    }

    /// Who to credit on screen.
    public var credit: String { Level2Client.credit }

    /// WHERE THE LOOP IS, as a continuous position. See `FieldLoopClock` for why
    /// a bare `Int` advanced on a timer could only ever produce cuts.
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

    /// Which frame is being drawn.
    public var index: Int { clock.index }

    /// The newest scan's position — where the loop pauses and where a reload
    /// puts you back.
    public var nowIndex: Int { max(0, frames.count - 1) }

    public var current: RadarFrame? { frames.indices.contains(index) ? frames[index] : nil }

    /// Set when a tile could not be drawn because its scan would not download.
    /// Kept separate from `failure`, which is about the LIST of scans: the list
    /// can be fine and a scan still fail to arrive.
    @Published public private(set) var tilesRefused = false

    public func noteTilesRefused() { tilesRefused = true }

    /// Re-listed on roughly the volume cadence. A new volume lands every four
    /// to ten minutes, so this never misses one by more than a couple.
    private let reloadEvery: Duration = .seconds(120)

    public init() {}

    /// True when even the newest frame is too old to be called "now".
    public var isStale: Bool {
        guard let newest = frames.last else { return false }
        return Date().timeIntervalSince(newest.time) > Radar.staleAfter
    }

    // MARK: The two frames on screen

    /// The scan dissolving out, the scan dissolving in, and how far between them.
    /// A paused or single-frame loop reports the same frame twice, which is how
    /// the renderer knows to draw a still rather than blend a frame with itself.
    public var playhead: (a: RadarFrame?, b: RadarFrame?, blend: Double) {
        guard frames.indices.contains(clock.index) else { return (nil, nil, 0) }
        let a = frames[clock.index]
        guard isPlaying, clock.frameCount > 1,
              frames.indices.contains(clock.nextIndex) else { return (a, a, 0) }
        return (a, frames[clock.nextIndex], clock.blend)
    }

    /// Every stamp in the loop, oldest first — the timeline's own order.
    public var stamps: [String] { frames.map(\.stamp) }

    /// The same stamps, IN THE ORDER THE LOOP WILL NEED THEM — what a prefetch
    /// should ask for.
    ///
    /// Oldest-first put the NEWEST scan — the one the clock holds on and the only
    /// one anybody is looking at — at the back of the queue. Starting at the
    /// current index and wrapping is both the fix and exactly the play order: the
    /// frame on screen, then the one it dissolves into, and so on round the loop.
    public var stampsByUrgency: [String] {
        guard !frames.isEmpty else { return [] }
        let start = min(clock.index, frames.count - 1)
        return (0..<frames.count).map { frames[(start + $0) % frames.count].stamp }
    }

    // MARK: Loading

    public func load() async {
        guard let site else { return }
        do {
            // The last ten volumes: roughly fifty minutes when it is raining
            // (five-minute patterns) and longer in clear air.
            let fetched = try await Level2Client().scans(site: site.id)
                .suffix(10)
                .map { RadarFrame(time: $0.time, key: $0.name) }
            // A slow answer for a site the viewer has since switched away from
            // must not overwrite the new site's loop.
            guard self.site == site else { return }
            archiveFrames = fetched
            // Hold the newest frame across a reload (`rebuildLoop` keeps the
            // end). Snapping back to the start of the loop every reload would
            // yank the picture out from under someone watching a storm approach.
            mergeFrames()
            failure = nil
            tilesRefused = false
            await refreshCoverage()
            await learnScanFacts()
        } catch {
            guard self.site == site else { return }
            failure = error.localizedDescription
        }
    }

    /// Read coverage off the newest scan. The decode is shared with the tiles
    /// through `Level2Frames`, so this costs nothing the map was not already
    /// going to pay.
    private func refreshCoverage() async {
        guard let site, let stamp = frames.last?.key else { coverage = nil; return }
        guard let frame = await Level2Frames.shared.frame(for: stamp),
              self.site == site else { return }
        let found = RadarCoverage(site: site.id, latitude: frame.latitude,
                                  longitude: frame.longitude, sweep: frame.sweep)
        if found != coverage { coverage = found }
    }

    /// Fetch the list, then keep it fresh.
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
                    await self?.pollLive()
                    try? await Task.sleep(for: self?.liveEvery ?? .seconds(10))
                }
            }
            group.addTask { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: self?.reloadEvery ?? .seconds(120))
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
        if mode == .sweep { advanceSweep(by: delta); return }
        guard isPlaying else { return }
        withClock { $0.advance(by: delta) }
    }

    /// Seeds the loop without the network, for tests about ORDER and timing.
    func setFramesForTesting(_ incoming: [RadarFrame]) {
        frames = incoming
        rebuildLoop(keepingEnd: true)
    }

    public func scrub(to newIndex: Int) {
        guard frames.indices.contains(newIndex) else { return }
        isPlaying = false
        withClock { $0.jump(to: newIndex) }
    }

    private func rebuildLoop(keepingEnd: Bool) {
        withClock {
            $0.resize(to: frames.count, keepingEnd: keepingEnd, holdIndex: nowIndex)
            $0.frameHold = FieldLoopClock.hold(forFrames: frames.count)
        }
    }
}
