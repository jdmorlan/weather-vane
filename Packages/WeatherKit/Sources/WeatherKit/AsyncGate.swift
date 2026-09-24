//
//  AsyncGate.swift  (WeatherKit)
//
//  A counting semaphore for async work, first come first served.
//
//  WHY LEVEL II NEEDS ONE AND THE MOSAIC NEVER DID. A mosaic tile is a network
//  request: firing two hundred at once only queues them in `URLSession`, and
//  the CPU sits idle while the server works. A Level II tile is COMPUTED here,
//  so two hundred at once is two hundred CPU-bound tasks — enough to fill every
//  core, starve MapKit's own drawing threads, and beachball the app while the
//  map sits half drawn. A gate keeps a couple of cores free for everything else
//  and, because it is FIFO, preserves the prefetch's priority order: the frame
//  on screen is still drawn first.
//

import Foundation
import os

/// Radar diagnostics. Stream them with:
///
///     log stream --level info --predicate 'subsystem == "jdmorlan.vane" && category == "radar"'
public let radarLog = Logger(subsystem: "jdmorlan.vane", category: "radar")

public actor AsyncGate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) { self.limit = max(1, limit) }

    /// For diagnostics: slots in use, and callers queued behind them.
    public var state: (running: Int, waiting: Int) { (running, waiting.count) }

    public func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        await acquire()
        let result = await work()
        release()
        return result
    }

    private func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}
