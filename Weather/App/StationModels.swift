//
//  StationModels.swift  (Weather)
//
//  The models the station surfaces read, and the orchestration that keeps
//  them fed — lifted out of `WeatherView` when the tabs became destinations.
//
//  WHY THEY HAD TO MOVE — as a segmented picker inside one view, switching from
//  Now to Wind never unmounted anything, so `@StateObject` at that level was
//  free. A sidebar is not that: Radar is a different view in the detail column,
//  so navigating to it and back would have torn `WeatherView` down and rebuilt
//  it, and the `.task` on the rebuilt one would have re-fetched the forecast
//  and today's minutes every time. Owning them above the column
//  that swaps is what makes the sidebar cost nothing.
//
//  It is `ObservableObject` only because `@StateObject` requires one; it
//  publishes nothing itself. The models inside it are what views observe, and
//  they are handed down explicitly rather than pulled from the environment so
//  each surface's dependencies stay readable from its signature.
//

import Foundation
import SwiftUI
import WeatherKit

@MainActor
final class StationModels: ObservableObject {
    let weather = WeatherModel()
    let archive = WeatherArchiveModel()
    /// The station's MINUTES, and the wind climatology derived from them. Its own
    /// model rather than a corner of `archive` because the two fill on different
    /// clocks and at wildly different costs — a day of samples is 1,400 readings
    /// against the daily archive's one row — and because this one owns a cache
    /// that has to be folded after a fetch, which the daily archive has no notion of.
    let samples = WeatherSamplesModel()
    /// Today's minutes: the archive keeps a day reduced to its extremes, and
    /// everything here is a question about the shape INSIDE the day.
    let todaySamples = DayObservationsModel()
    /// NWS watches and warnings for the home point, on their own clock — a
    /// warning issued while you're reading the ten-day has to arrive unasked.
    let hazards = WeatherHazardModel()
    /// How the ten-day card has been doing: reads the forecast log and the daily
    /// archive, neither of which is the live fetch.
    let forecastCheck = ForecastCheckModel()
    /// The hardware itself: is it still reporting, is the battery holding, are
    /// all six sensors answering. Up here with the rest rather than owned by its
    /// destination because it polls — a check that restarts from nothing every
    /// time you glance at the page would make "last heard 30 seconds ago" a
    /// statement about the page rather than about the station.
    let health = StationHealthModel()
    /// What five models say about rain in the next eighteen hours. Its own model
    /// because it is the one forecast here that needs NO station — it is keyed to
    /// the home point, and it answers on an afternoon when the archive has nothing
    /// to say yet.
    let precip = PrecipOutlookModel()
    /// The Drought Monitor's weekly rating for home's county, for the Rain page.
    /// Up here so a return to Rain isn't a fetch; the map only changes Thursdays.
    let drought = DroughtModel()
    /// SPC's and WPC's storm and flood outlooks for the Forecast page, read at
    /// home. Up here so leaving the page and coming back doesn't re-fetch
    /// thirteen files; it only polls while the page is open.
    let storms = StormOutlookModel()
    /// The 500 mb pattern. Nothing to do with the station — a different source
    /// (the GFS), a different clock (four runs a day), and it works with no
    /// Tempest configured at all, which is why Pattern is its own destination.
    let upperAir = UpperAirModel()

    // MARK: Orchestration

    /// Everything a refresh means, in the order the screen wants it.
    ///
    /// Lives here rather than on the view because the view it used to live on is
    /// now one of six that can be on screen when the button is pressed, and
    /// "refresh" means the same thing from all of them.
    func refresh(settings: AppSettings, includingPattern: Bool) async {
        // An explicit refresh on the pattern asks Open-Meteo whether a newer run
        // has landed, even inside the window where one normally couldn't.
        if includingPattern { await upperAir.load(home: settings.homePoint, force: true) }
        await weather.refresh(token: settings.tempestToken, stationID: settings.tempestStationID)
        // The refresh button means "tell me what's true now", and what's active
        // over the acre is part of that — waiting out the poll interval after an
        // explicit ask is the wrong answer.
        await hazards.refresh(settings: settings)
        catchUpArchives(settings: settings)
        await loadToday(settings: settings)
    }

    /// Today's minutes. Re-read on every refresh, because while it's raining the
    /// card IS the live end of an open spell — but no more often than every five
    /// minutes, which is finer than the answer can change.
    /// The live half of a refresh — the forecast and today's minutes — for the
    /// automatic loop in `RootView`. Not the hazards, which poll on their own;
    /// not the archives, which the day-change task catches up; not the Pattern,
    /// which is a model run and changes every few hours at best.
    ///
    /// Skipped while fresh, so that returning to the app a few seconds after
    /// leaving it, or a launch racing the loop's first pass, is not a fetch.
    func refreshLive(settings: AppSettings, ifOlderThan age: TimeInterval = 60) async {
        guard settings.hasWeatherStation else { return }
        if let updated = weather.lastUpdated, Date().timeIntervalSince(updated) < age { return }
        await weather.refresh(token: settings.tempestToken, stationID: settings.tempestStationID)
        await loadToday(settings: settings)
    }

    func loadToday(settings: AppSettings) async {
        guard let r = weather.report else { return }
        let day = DayKey.string(for: Date(), timeZone: r.timezone ?? .current)
        let bucket = Int(Date().timeIntervalSince1970 / 300)
        await todaySamples.load(day: day, key: "\(day)|\(bucket)",
                                token: settings.tempestToken,
                                stationID: settings.tempestStationID,
                                timeZone: r.timezone ?? .current)
    }

    /// Bring the daily archive and the sample store up to yesterday. Runs
    /// alongside the live fetch rather than gating it: the forecast is what you
    /// opened this app for, and the archive filling in behind it is background
    /// work. Both models ignore a call while one is already running.
    ///
    /// THE SAMPLES GO SECOND, AND THEY HAVE TO WAIT. These two used to be fired
    /// side by side, which reads as harmless — two independent fetches — and is
    /// not, because they are not independent. `fillMatchingDailyArchive` asks the
    /// DAILY archive which days exist and fetches the minutes behind exactly
    /// those; started in the same breath as the daily catch-up it read a store
    /// with nothing in it yet, fetched nothing, folded nothing, and handed Wind a
    /// climatology of zero days. Wind then said "No wind history yet", which is a
    /// sentence about the station and was really a sentence about the ordering.
    ///
    /// Invisible on a Mac that has been running for months, because there the
    /// daily archive is already full before the app opens and the empty read
    /// never happens. It is the FIRST DAY on a new device that has nothing on
    /// disk — a fresh iPad — and on that device it never came right on its own:
    /// the fold had already run and left a non-nil, empty climate behind it.
    func catchUpArchives(settings: AppSettings) {
        archive.catchUp(token: settings.tempestToken, stationID: settings.tempestStationID)
        Task {
            await archive.waitForCatchUp()
            samples.catchUp(token: settings.tempestToken, stationID: settings.tempestStationID,
                            daily: archive.store)
        }
    }

    /// The cold start, run once from the root and never from a destination.
    func start(settings: AppSettings) async {
        guard settings.hasWeatherStation else { return }
        if weather.report == nil {
            await refresh(settings: settings, includingPattern: false)
        }
        // The cache first and separately: it's a small file read, it paints Wind
        // immediately, and it must not wait behind a network catch-up that on a
        // cold archive takes the better part of an hour.
        samples.loadCached()
        catchUpArchives(settings: settings)
    }

    /// What the forecast check depends on: the last measured day, the station's
    /// zone, and the moment of the newest capture.
    var checkKey: String {
        let tz = weather.report?.timezone?.identifier ?? "—"
        let updated = weather.lastUpdated.map { String(Int($0.timeIntervalSince1970)) } ?? "—"
        return "\(archive.latestDay ?? "—")|\(tz)|\(updated)"
    }
}

extension AppSettings {
    /// The home point in WeatherKit's terms. Same optionality as
    /// `homeCoordinate`, for the same reason.
    var homePoint: GeoPoint? {
        hasHome ? GeoPoint(latitude: homeLat, longitude: homeLon) : nil
    }
}
