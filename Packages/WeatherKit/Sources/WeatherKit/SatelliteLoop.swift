//
//  SatelliteLoop.swift  (WeatherKit)
//
//  The satellite loop: which scans to show for the chosen band, and the clock
//  that walks them. The same shape as `RadarModel` and the same clock, so the
//  map drives both with one display link and one dissolve.
//
//  THE CLOUD VIEW WAS A STILL until this existed, because its old source had no
//  timeline to offer. Motion is most of what satellite is for — a trough, a
//  dry slot or an outflow boundary is obvious moving and invisible still — so a
//  loop is the default, and it holds on the newest scan like the radar does.
//

import Foundation
import Combine

@MainActor
public final class SatelliteLoopModel: ObservableObject {
    /// The frames, oldest first. `RadarFrame` because it is exactly a time and
    /// a stamp, and the scrub bar already knows how to draw a list of them.
    @Published public private(set) var frames: [RadarFrame] = []
    @Published public private(set) var failure: String?
    @Published public var isPlaying = true

    /// Changing band is a different list of scans, so it reloads.
    @Published public var band: SatelliteFieldSource.Band = .infrared {
        didSet {
            guard band != oldValue else { return }
            frames = []
            rebuildLoop(keepingEnd: true)
            Task { await load() }
        }
    }

    public var source: SatelliteFieldSource { SatelliteFieldSource(band: band) }

    /// nowCOAST lists a new scan every five minutes.
    private let reloadEvery: Duration = .seconds(150)

    public init() {}

    // MARK: Loading

    public func run() async {
        await load()
        while !Task.isCancelled {
            try? await Task.sleep(for: reloadEvery)
            await load()
        }
    }

    public func load() async {
        let band = self.band
        do {
            var request = URLRequest(url: SatelliteFieldSource.capabilitiesURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let times = SatelliteScans.times(in: String(decoding: data, as: UTF8.self), layer: band.layer)
            // A slow answer for a band since switched away from must not
            // replace the new band's loop.
            guard self.band == band else { return }
            guard !times.isEmpty else {
                failure = "nowCOAST listed no \(band.label.lowercased()) scans"
                return
            }
            let next = SatelliteScans.frames(from: times).map {
                RadarFrame(time: $0, key: SatelliteScans.stamp($0))
            }
            failure = nil
            guard next != frames else { return }
            frames = next
            rebuildLoop(keepingEnd: true)
        } catch {
            guard self.band == band else { return }
            failure = error.localizedDescription
        }
    }

    // MARK: The clock

    /// Not `@Published`, for the reason given on `RadarModel.clock`.
    public private(set) var clock = FieldLoopClock()

    private func withClock(_ change: (inout FieldLoopClock) -> Void) {
        let before = clock.index, beforeCount = clock.frameCount
        change(&clock)
        if clock.index != before || clock.frameCount != beforeCount { objectWillChange.send() }
    }

    public var index: Int { clock.index }
    public var newest: RadarFrame? { frames.last }

    /// The scan dissolving out, the scan dissolving in, and how far between.
    public var playhead: (a: RadarFrame?, b: RadarFrame?, blend: Double) {
        guard frames.indices.contains(clock.index) else { return (nil, nil, 0) }
        let a = frames[clock.index]
        guard isPlaying, clock.frameCount > 1,
              frames.indices.contains(clock.nextIndex) else { return (a, a, 0) }
        return (a, frames[clock.nextIndex], clock.blend)
    }

    public var stamps: [String] { frames.map(\.stamp) }

    /// The frame on screen first, then round the loop in play order. See
    /// `RadarModel.stampsByUrgency`.
    public var stampsByUrgency: [String] {
        guard !frames.isEmpty else { return [] }
        let start = min(clock.index, frames.count - 1)
        return (0..<frames.count).map { frames[(start + $0) % frames.count].stamp }
    }

    public func tick(delta: Double) {
        guard isPlaying else { return }
        withClock { $0.advance(by: delta) }
    }

    public func scrub(to newIndex: Int) {
        guard frames.indices.contains(newIndex) else { return }
        isPlaying = false
        withClock { $0.jump(to: newIndex) }
    }

    /// A lap of about six seconds rather than radar's five: nineteen frames of
    /// slow-moving cloud read as drift at radar's pace, and as flow at this one.
    private func rebuildLoop(keepingEnd: Bool) {
        withClock {
            $0.resize(to: frames.count, keepingEnd: keepingEnd, holdIndex: max(0, frames.count - 1))
            $0.frameHold = FieldLoopClock.hold(forFrames: frames.count, lap: 6.0)
        }
    }
}
