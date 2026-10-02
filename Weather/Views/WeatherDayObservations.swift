//
//  WeatherDayObservations.swift  (macOS)
//
//  ONE DAY'S MINUTES, FETCHED ONCE, READ SEVERAL WAYS.
//
//  This started life as `RainDayModel` inside the rain card, and the name was
//  true for exactly as long as rain was the only question anyone asked of a
//  day's samples. `DayStrip` made it two: the same 1,440 readings answer "when
//  did it rain" and "how cool was it at eight this morning", and fetching them
//  twice to ask twice would be paying the network for a distinction that only
//  exists in the view layer.
//
//  So the model holds the SAMPLES and the projections hang off them, which is
//  [[samples-are-the-record]] applied at the seam where the app actually reads.
//  A future reader that wants pressure through the day, or the wind's turn
//  behind a front, adds a computed property here and no request at all.
//
//  Keyed by a DAY, not by a tab: on Now the key is today and a rain spell is
//  read live at its open end; under History's day grain it's whatever day you
//  walked to. One code path, two placements — and the only reason any of it is
//  testable on a clear afternoon.
//
//  A FINISHED DAY IS READ OFF DISK. `SampleArchive` holds every minute of the
//  record, so History's day grain hands over the store and the network is only
//  asked when the day isn't there yet. Today is never in it — the archive stops
//  at yesterday — so Now passes no store and always fetches.
//

import SwiftUI
import Combine
import WeatherKit

/// Fetches a single day of one-minute observations and keeps them.
@MainActor
final class DayObservationsModel: ObservableObject {
    @Published private(set) var samples: [StationSample] = []
    @Published private(set) var rain: RainDay?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    /// The day `samples` belong to. A reader walking the archive checks this
    /// rather than trusting that what's held is the day it asked for — the
    /// previous day's minutes must never sit under the next day's date.
    @Published private(set) var day: String?

    private var loadedKey: String?

    /// `key` folds in the refresh tick, so the Now tab's refresh button re-reads
    /// the day while a day in the archive is fetched exactly once.
    func load(day: String, key: String, token: String, stationID: Int,
              timeZone: TimeZone, store: (any SampleArchiveStore)? = nil,
              now: Date = Date()) async {
        let canFetch = !token.isEmpty && stationID != 0
        guard loadedKey != key, store != nil || canFetch else { return }
        loadedKey = key
        if self.day != day { samples = []; rain = nil; self.day = nil }
        isLoading = true
        error = nil
        defer { isLoading = false }

        if let store {
            let held = await Task.detached(priority: .userInitiated) {
                (try? store.samples(onDay: day)) ?? []
            }.value
            // A slower read for a day already walked past must not land on top
            // of the one now asked for.
            guard loadedKey == key else { return }
            if !held.isEmpty {
                show(held, day: day, timeZone: timeZone, now: now)
                return
            }
        }

        guard canFetch else {
            samples = []; rain = nil; self.day = day
            loadedKey = nil                      // a station connected later can still fill it
            return
        }
        let windows = SampleSync.windows(ofDay: day, timeZone: timeZone)
        guard !windows.isEmpty else { return }

        do {
            let client = TempestClient(token: token, stationID: stationID)
            var fetched: [StationSample] = []
            for window in windows {
                let response = try await client.observations(start: window.start, end: window.end,
                                                             bucketMinutes: SampleSync.bucketMinutes)
                fetched += StationSample.samples(from: response,
                                                 bucketMinutes: SampleSync.bucketMinutes)
            }
            guard loadedKey == key else { return }
            show(fetched, day: day, timeZone: timeZone, now: now)
        } catch {
            self.error = error.localizedDescription
            loadedKey = nil                      // a failure must not count as loaded
        }
    }

    private func show(_ found: [StationSample], day: String, timeZone: TimeZone, now: Date) {
        samples = found
        self.day = day
        // A finished day has no "now" to be open against; today does.
        let isToday = day == DayKey.string(for: now, timeZone: timeZone)
        rain = RainEvents.find(in: found, day: day, timeZone: timeZone,
                               asOf: isToday ? now : nil)
    }
}
