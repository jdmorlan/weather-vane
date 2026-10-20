//
//  PhoneForecastView.swift  (iPhone)
//
//  The next three days on the phone, two ways in.
//
//  TURN THE PHONE SIDEWAYS ON NOW and the three days fill the screen. Now's
//  cards gain nothing from a wide screen; the three-day figure gains
//  everything — seventy-two hours across a portrait phone is five points an
//  hour, and the rain and the storm lane are what get squeezed. So rotating is
//  how you ask the next question, and the phone needs no third tab for it.
//
//  OR TAP THROUGH from the card at the foot of Now, for anyone who keeps
//  rotation locked or never thinks to turn the phone. That pushes the Mac's
//  Forecast page, which already stacks its tiles on a narrow width. Not a
//  teaching page either way; see [[forecast-page-is-practical]].
//
//  NO MODEL-AGREEMENT STRIP. It needs the eleven-model rain poll, one more feed
//  for a phone to keep alive for a subtle strip over eighteen hours. The TV
//  leaves it off for the same reason.
//

import SwiftUI
import WeatherKit

/// The Forecast page, pushed from Now in portrait.
struct PhoneForecastPage: View {
    @ObservedObject var weather: WeatherModel
    @ObservedObject var storms: StormOutlookModel
    @EnvironmentObject private var settings: AppSettings
    var openSetup: () -> Void

    var body: some View {
        Group {
            if let r = weather.report, !r.days.isEmpty {
                ScrollView {
                    ForecastPage(report: r, forecastFetched: weather.lastUpdated,
                                 storms: storms, precip: nil,
                                 home: settings.homePoint, openSetup: openSetup) {
                        EmptyView()
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView("No forecast yet", systemImage: "calendar",
                                       description: Text("The station’s forecast hasn’t arrived."))
            }
        }
        .navigationTitle("Next three days")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The three-day figure, full screen — what Now becomes in landscape.
struct PhoneForecastFigure: View {
    @ObservedObject var weather: WeatherModel
    @ObservedObject var storms: StormOutlookModel
    @EnvironmentObject private var settings: AppSettings

    /// The figure's TALLEST height at scale 1 — every lane but the model strip,
    /// which the phone doesn't pass — from `HourTimeline.Lanes`. Lanes with
    /// nothing to say stand down and the figure comes out shorter; this is
    /// only used to shrink it to fit, and the figure sets its own height.
    private static let figureHeight: CGFloat = 330
    /// The narrowest an hour may be before the figure scrolls sideways —
    /// `HourTimeline`'s own threshold at scale 1.
    private static let hourWidth: CGFloat = 11

    var body: some View {
        Group {
            if !settings.hasWeatherStation {
                ContentUnavailableView("No station connected", systemImage: "sensor.tag.radiowaves.forward",
                                       description: Text("Turn the phone upright to connect one."))
            } else if let r = weather.report, !r.threeDays.isEmpty {
                content(r)
            } else if weather.report == nil {
                ProgressView("Reading the forecast…")
            } else {
                ContentUnavailableView("No forecast yet", systemImage: "calendar",
                                       description: Text("The hourly forecast hasn’t arrived."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task { await storms.keepCurrent() }
    }

    private func content(_ r: WeatherReport) -> some View {
        let tz = r.timezone ?? .current
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("NEXT THREE DAYS")
                    .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                if let updated = weather.lastUpdated {
                    Text("\(settings.stationLabel) · updated \(When.moment(updated))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            // FIT, DON'T SCROLL. Below eleven points an hour the figure turns
            // into a sideways scroll, and on a 6.1-inch phone the width between
            // the notch and the home indicator is just under that. Shrinking it
            // a tenth keeps all three days on one screen, which is the reason
            // to have turned the phone.
            GeometryReader { geo in
                let byWidth = geo.size.width / (CGFloat(r.threeDays.count) * Self.hourWidth)
                let byHeight = geo.size.height / Self.figureHeight
                let scale = min(1, byWidth, byHeight)
                HourTimeline(hours: r.threeDays, timezone: tz, precip: nil,
                                 risks: risks(r, tz), scale: scale,
                                 textScale: max(scale, 0.9))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func risks(_ r: WeatherReport, _ tz: TimeZone) -> [String: StormRisk] {
        guard let home = settings.homePoint else { return [:] }
        var out: [String: StormRisk] = [:]
        for d in r.days.prefix(3) {
            let k = DayKey.string(for: Date(timeIntervalSince1970: TimeInterval(d.epoch)), timeZone: tz)
            out[k] = storms.risk(day: k, home: home, timeZone: tz)
        }
        return out
    }
}
