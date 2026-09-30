//
//  PhoneNowView.swift  (iPhone)
//
//  The Now scroll, minus everything that reads the archive.
//
//  WHAT IS MISSING, AND WHY IT IS NOT A LOSS YET. The Mac's Now carries three
//  things this does not: this date across past years, what the season does
//  next, and the pressure band behind the barometer. All three compare today
//  with a record, and a phone keeps no record. If they are missed, the answer is
//  a small per-day-of-year summary synced from a device that has an archive —
//  not the archive itself.
//
//  ORDER, top to bottom: anything the NWS is warning about, then the station's
//  own alerts, then this second, then the rain if there is any, then the rest of
//  today, then the ten days. The same order as the Mac, with the gaps closed.
//

import SwiftUI
import WeatherKit

struct PhoneNowView: View {
    @ObservedObject var weather: WeatherModel
    @ObservedObject var today: DayObservationsModel
    @ObservedObject var hazards: WeatherHazardModel
    @EnvironmentObject private var settings: AppSettings

    /// Pull to refresh. A closure rather than the models object, so this view
    /// observes only the three models it draws from.
    var refresh: () async -> Void
    var openSetup: () -> Void

    var body: some View {
        Group {
            if !settings.hasWeatherStation {
                needsStation
            } else if let report = weather.report {
                dashboard(report)
            } else if let error = weather.error {
                ContentUnavailableView("Couldn’t load weather", systemImage: "cloud.bolt",
                                       description: Text(error))
            } else {
                ProgressView("Reading your station…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(Destination.now.title)
        // HERE AND NOT ON THE ROOT, which is the bug this placement fixes: the
        // root observes `PhoneModels`, not the `WeatherModel` inside it, so a
        // subtitle computed there never heard `lastUpdated` move and sat on the
        // caption forever. This view observes the weather model directly.
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard settings.hasWeatherStation else { return "No station connected" }
        if let updated = weather.lastUpdated {
            return "\(settings.stationLabel) · updated \(When.moment(updated))"
        }
        return Destination.now.caption
    }

    private func dashboard(_ r: WeatherReport) -> some View {
        let strip = DayStrip.today(r, samples: today.samples)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HazardBanner(watch: hazards.watch)
                StationAlertsBanner(report: r)
                RightNowCard(report: r, strip: strip)
                rainCard
                TodayCard(report: r, strip: strip)
                if !r.days.isEmpty { TenDayCard(report: r) }
            }
            .padding(16)
        }
        .refreshable { await refresh() }
    }

    /// Only on a day that has seen rain; never silent when the day's minutes
    /// could not be read. See the Mac's `rainCard` for why both.
    @ViewBuilder private var rainCard: some View {
        if let rain = today.rain, rain.hasSomethingToSay {
            RainDayCard(rain: rain)
        } else if let error = today.error {
            Text("Couldn’t read today’s rain — \(error)")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var needsStation: some View {
        ContentUnavailableView {
            Label("Connect your Tempest station", systemImage: "sensor.tag.radiowaves.forward")
        } description: {
            Text("Now reads your own station’s measurements. Radar works without one.")
        } actions: {
            Button("Connect a station", action: openSetup)
                .buttonStyle(.borderedProminent)
        }
    }
}
