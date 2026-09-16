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
//  Nothing is stored. `SampleArchive` exists in the package and the backfill
//  hasn't run, so a day's minutes are re-fetched when you look at one. If this
//  becomes a thing opened daily, THAT is when keeping them earns its disk.
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

    private var loadedKey: String?

    /// `key` folds in the refresh tick, so the Now tab's refresh button re-reads
    /// the day while a day in the archive is fetched exactly once.
    func load(day: String, key: String, token: String, stationID: Int,
              timeZone: TimeZone, now: Date = Date()) async {
        guard !token.isEmpty, stationID != 0, loadedKey != key else { return }
        loadedKey = key
        isLoading = true
        error = nil
        defer { isLoading = false }

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
            samples = fetched
            // A finished day has no "now" to be open against; today does.
            let isToday = day == DayKey.string(for: now, timeZone: timeZone)
            rain = RainEvents.find(in: fetched, day: day, timeZone: timeZone,
                                   asOf: isToday ? now : nil)
        } catch {
            self.error = error.localizedDescription
            loadedKey = nil                      // a failure must not count as loaded
        }
    }
}
