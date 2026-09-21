//
//  TVModels.swift  (tvOS)
//
//  Two pollers, and nothing else. Everything the TV shows is fetched now and
//  kept for minutes — there is no store, no catch-up, no archive. That is what
//  makes a tvOS target possible at all: the system may purge an app's container,
//  and an app whose whole premise was "years of readings on this machine" could
//  not have survived that. Storm mode never wanted them.
//

import Foundation
import Combine
import WeatherKit

/// NWS watches and warnings for the home point.
@MainActor
final class TVHazardModel: ObservableObject {
    @Published private(set) var watch = HazardWatch()

    /// Five minutes against `HazardWatch.freshness` of fifteen: two consecutive
    /// failures before the screen stops claiming to know. Enough slack for one
    /// blip, not enough to sit blind through a storm.
    static let pollInterval: Duration = .seconds(300)
    private static let contact = "vane.app"

    var active: [Hazard] {
        if case .active(let live) = watch.state() { return live }
        return []
    }
    var worst: Hazard? { watch.top() }
    var drawable: [Hazard] { watch.state().drawable }

    func poll(point: GeoPoint?) async {
        guard let point else { return }
        while !Task.isCancelled {
            await refresh(point: point)
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func refresh(point: GeoPoint) async {
        let client = NWSClient(point: point, contact: Self.contact)
        let attempt = Date()
        do {
            let hazards = try await client.activeHazards()
            watch = HazardWatch(hazards: hazards, lastReached: attempt, lastAttempt: attempt)
        } catch {
            // A failed poll does not retract a warning. It only stops the clock
            // on our right to call the sky quiet, which `state()` works out from
            // `lastReached`.
            watch = HazardWatch(hazards: watch.hazards,
                                lastReached: watch.lastReached,
                                lastAttempt: attempt,
                                failure: error.localizedDescription)
        }
    }
}

/// The station's current conditions, for the strip along the bottom.
@MainActor
final class TVConditionsModel: ObservableObject {
    @Published private(set) var report: WeatherReport?

    /// Slower than the radar: a Tempest reports every minute, but nothing in the
    /// strip changes fast enough to be worth asking that often from a screen
    /// nobody is touching.
    static let pollInterval: Duration = .seconds(180)

    func poll(token: String, stationID: Int) async {
        while !Task.isCancelled {
            let client = TempestClient(token: token, stationID: stationID)
            // A failed fetch leaves the LAST report on screen rather than
            // blanking the strip. Stale conditions beside a live radar loop are
            // still worth more than an empty bar, and the radar's own clock is
            // what says whether the picture is current.
            if let fresh = try? await client.report() { report = fresh }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}
