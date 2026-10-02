//
//  PhoneRainView.swift  (iPhone)
//
//  The phone's Rain tab: what the station measured today, and your own gauge.
//
//  NOT THE iPad's RAIN PAGE. That page is built on years of archive — totals
//  against usual, how often it rains, how long between — and the phone keeps
//  no archive (see `PhoneRoot`). What the phone is for is standing in the yard:
//  is it raining at the station, and here is what my gauge caught. So the tab
//  is today's rain card, the note that says when the station's sensor is
//  missing rain WeatherFlow's radar sees, and the gauge log, synced with the
//  Mac's.
//

import SwiftUI
import WeatherKit

struct PhoneRainView: View {
    @ObservedObject var weather: WeatherModel
    @ObservedObject var today: DayObservationsModel
    var refresh: () async -> Void = {}

    @State private var loggingGauge = false
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var rainLog: RainLogStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let r = weather.report {
                    todayCard(r)
                    StationCard(label: "Your rain gauge") {
                        RainGaugeCard(timeZone: r.timezone ?? .current)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(16)
        }
        .navigationTitle("Rain")
        .refreshable { await refresh() }
        .sheet(isPresented: $loggingGauge) {
            GaugeEntrySheet(timeZone: weather.report?.timezone ?? .current)
                .environmentObject(settings).environmentObject(rainLog)
        }
    }

    /// Today at the station — the measured rain, or a plain statement that
    /// there wasn't any, or the mismatch with WeatherFlow's radar. Never blank.
    @ViewBuilder private func todayCard(_ r: WeatherReport) -> some View {
        if let rain = today.rain, rain.hasSomethingToSay {
            RainDayCard(rain: rain, climate: nil)
        } else {
            StationCard(label: "Rain today") {
                VStack(alignment: .leading, spacing: 8) {
                    if r.conditionsSayPrecipitation && (r.precipToday ?? 0) < 0.01 {
                        Text("Your gauge hasn't measured any rain today.")
                            .font(.callout.weight(.medium))
                        Text("WeatherFlow's radar shows \(r.conditions.lowercased()) here. If rain is falling at the station, its rain sensor isn't registering it.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            loggingGauge = true
                        } label: {
                            Label("Log what your rain gauge caught", systemImage: "drop.fill")
                        }
                    } else if let total = r.precipToday, total >= 0.01 {
                        Text(String(format: "%.2f″ at the station so far today.", total))
                            .font(.callout.weight(.medium))
                    } else {
                        Text("No rain at the station today.")
                            .font(.callout.weight(.medium))
                    }
                }
            }
        }
    }
}
