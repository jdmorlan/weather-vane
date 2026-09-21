//
//  StormSurface.swift  (tvOS)
//
//  The window: a hero, a row of cards, and whatever you pressed.
//
//  WHAT THIS REPLACED, TWICE. First a full-bleed radar with a conditions strip,
//  which made the thing you check every thirty seconds the smallest item on a
//  hundred-inch screen. Then a single dense dashboard, which worked until it
//  didn't — it overflowed while being built, clipped its own headline, and every
//  further addition had to take something else off. Both were layouts with one
//  axis, where the only way to add was to shrink.
//
//  The deck has a second axis. `StationDeck` shows the summary of everything and
//  a press opens as much detail as that measure deserves, so nothing competes
//  for the same square inch and a ninth card costs the other eight nothing.
//
//  THE MODE PICKER IS GONE with it. Radar was a mode because there was nowhere
//  else to put a map; it is a card now, and full screen is what pressing it
//  does — which also retired the two segmented controls that were trapping
//  focus at the bottom of the screen.
//

import SwiftUI
import WeatherKit

struct StormSurface: View {
    @EnvironmentObject private var settings: TVSettings
    @StateObject private var radar = RadarModel()
    @StateObject private var hazards = TVHazardModel()
    @StateObject private var conditions = TVConditionsModel()

    /// Owned here rather than inside the radar page so the range survives
    /// leaving and re-entering it — a zoom you have to set again every time you
    /// come back is a zoom you stop using.
    @State private var range: RadarRange = .nearby

    var body: some View {
        StationDeck(report: conditions.report,
                    radar: radar,
                    hazards: hazards,
                    home: settings.homeCoordinate,
                    range: $range)
            .task { await radar.run() }
            .task { await hazards.poll(point: settings.homePoint) }
            .task {
                guard settings.hasStation else { return }
                await conditions.poll(token: settings.tempestToken,
                                      stationID: settings.tempestStationID)
            }
    }
}

/// What the station is doing, riding on the radar — and only when it is worth
/// saying.
///
/// This is not the station panel shrunk. It is a filter: a measure appears here
/// because it is DOING something, not because it exists. On a still, dry
/// afternoon it is a temperature. In a squall it is a temperature, a gust, a
/// rain total and a lightning warning, and by then every one of them is a thing
/// you would have gone looking for.
struct ConditionsOverlay: View {
    let report: WeatherReport?

    var body: some View {
        if let r = report {
            HStack(spacing: 30) {
                reading(r.temperature.map { String(format: "%.0f°", $0) } ?? "—",
                        r.conditions, accent: nil)

                // Gusts only once they are worth noticing. Printing "4 mph" over
                // a radar picture is using the loudest moment on the screen to
                // say nothing.
                if let gust = r.windGust, gust >= 18 {
                    reading(String(format: "%.0f mph", gust), "gusting",
                            accent: gust >= 40 ? .orange : nil)
                }

                if let precip = r.precipToday, precip > 0 {
                    reading(WeatherAlmanac.inches(precip), "today", accent: nil)
                }

                // The interpreter decides this one, not a threshold here — it is
                // the same `stormWatch` the station panel colours.
                if r.pressure.stormWatch {
                    reading(r.pressure.current.map { String(format: "%.2f", $0) } ?? "—",
                            "falling", accent: .orange)
                }

                if let alert = r.alerts.first {
                    Label(alert, systemImage: "bolt.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 20)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private func reading(_ value: String, _ label: String, accent: Color?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 40, weight: .medium).monospacedDigit())
                .foregroundStyle(accent ?? .white)
            Text(label)
                .font(.system(size: 21))
                .foregroundStyle(accent?.opacity(0.9) ?? .secondary)
        }
    }
}

extension RadarRange {
    /// How far the picture reaches, in the units the question is asked in.
    var miles: String {
        switch self {
        case .overhead: return "7 mi"
        case .close:    return "19 mi"
        case .nearby:   return "56 mi"
        case .regional: return "150 mi"
        }
    }
}
