//
//  CardDetail.swift  (tvOS)
//
//  What pressing a card opens.
//
//  THE POINT OF THE DECK IS THAT THESE CAN BE AS LONG AS THEY DESERVE. Nothing
//  here competes for space with anything else, so every page leads with a
//  full-size PICTURE — the hour chart with its rain bars and gust row, the
//  barometer's coming shape, the day's arc at a size you can read across a room
//  — and the numbers support it rather than the other way round.
//
//  These were rows of labelled text for a while, which was the fastest thing to
//  write and the least useful thing to look at. A page of `Label: value` is a
//  settings screen, and nobody puts a settings screen on a television during a
//  storm.
//
//  Each page still ends with the interpreter's own sentence about that measure —
//  the same prose the Mac app writes under its cards. That is the half a number
//  cannot carry, and a detail page is exactly where it stops being clutter.
//

import SwiftUI
import MapKit
import WeatherKit

struct CardDetail: View {
    let card: StationCard
    let report: WeatherReport?
    @ObservedObject var radar: RadarModel
    @ObservedObject var hazards: TVHazardModel
    let home: CLLocationCoordinate2D?
    @Binding var range: RadarRange

    var body: some View {
        Group {
            switch card {
            case .radar: radarPage
            case .hours: page { hoursPage }
            case .days:  page { daysPage }
            default:     page { measurePage }
            }
        }
        .background(Color.black)
    }

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(card.title).font(.system(size: 52, weight: .semibold))
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 90)
        .padding(.vertical, 60)
    }

    // MARK: Radar, full screen

    @ViewBuilder private var radarPage: some View {
        if let home {
            ZStack {
                TVRadarMap(center: home, radiusMeters: range.radius,
                           radar: radar, hazards: hazards.drawable, coverage: radar.coverage)
                    .ignoresSafeArea()
                    .focusable(false)
                Circle().stroke(.white, lineWidth: 5).frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.7), radius: 5)
                    .overlay { Circle().fill(.white).frame(width: 10, height: 10) }
                VStack {
                    HStack { Spacer(); clock }
                    Spacer()
                    // The ranges are the only control on the page, and they are
                    // plain buttons for the same reason the deck is: a Picker on
                    // tvOS captures left/right and there is then no way out of it.
                    TVSegment(options: RadarRange.allCases.map { ($0, $0.label) },
                              selection: $range)
                }
                .padding(52)
            }
        }
    }

    @ViewBuilder private var clock: some View {
        if let current = radar.current {
            HStack(spacing: 10) {
                Circle().fill(radar.isStale ? Color.orange : Color.green)
                    .frame(width: 12, height: 12)
                // HOW OLD, not what o'clock. Nobody watching a storm converts
                // "2:05 PM" into "twenty minutes ago" — and twenty minutes is
                // the whole question, because it is how far the thing on screen
                // has already moved since the picture was taken. The clock time
                // stays as the smaller half, for anyone checking it against
                // another source.
                VStack(alignment: .leading, spacing: 0) {
                    // Scans still arriving is said, not left as a loop that
                    // mysteriously will not move.
                    Text(radar.scansReady < radar.frames.count
                         ? "Loading scans · \(radar.scansReady) of \(radar.frames.count)"
                         : RadarAge.describe(current.time))
                        .font(.system(size: 28, weight: .medium))
                    Text(current.time, format: .dateTime.hour().minute())
                        .font(.system(size: 19).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(range.miles).font(.system(size: 22)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
        }
    }

    // MARK: Hours

    @ViewBuilder private var hoursPage: some View {
        if let r = report {
            VStack(alignment: .leading, spacing: 22) {
                HourChart(hours: Array(r.hours.prefix(12)))
                    .frame(height: 420)
                legend("temperature · chance of rain in cyan · gusts above 18 mph in orange")
                if !r.rain.text.isEmpty { sentence(r.rain.text) }
            }
        }
    }

    // MARK: Days

    @ViewBuilder private var daysPage: some View {
        if let r = report {
            VStack(alignment: .leading, spacing: 34) {
                DayChart(days: Array(r.days.prefix(8)))
                    .frame(height: 540)
                if let week = r.weekComfort, !week.isEmpty { sentence(week) }
                // The per-day shape notes used to sit here as five lines of
                // prose. On a page whose whole point is a picture they were the
                // one thing you had to stop and READ, and the chart above
                // already says everything they said about temperature.
                legend("chance of rain in cyan, with how much is expected")
            }
        }
    }

    // MARK: One measure

    @ViewBuilder private var measurePage: some View {
        if let r = report {
            VStack(alignment: .leading, spacing: 30) {
                switch card {
                case .wind:
                    HStack(alignment: .top, spacing: 70) {
                        WindCompass(direction: r.windDirection)
                            .frame(width: 300, height: 300)
                        VStack(alignment: .leading, spacing: 26) {
                            big(r.windGust.map { String(format: "%.0f mph", $0) } ?? "—",
                                "gusting now")
                            row("Sustained", r.windAvg.map { String(format: "%.0f mph", $0) } ?? "—")
                            row("From", r.windDirectionCardinal ?? "—")
                            row("Peak today", String(format: "%.0f mph", r.wind.peakGust))
                        }
                        Spacer(minLength: 0)
                    }
                    if !r.wind.text.isEmpty { sentence(r.wind.text) }

                case .pressure:
                    HStack(alignment: .firstTextBaseline, spacing: 26) {
                        big(r.pressure.current.map { String(format: "%.2f", $0) } ?? "—",
                            "inHg · \(r.pressure.trend)")
                        if let arrow = r.pressure.trend.trendSymbol {
                            Image(systemName: arrow)
                                .font(.system(size: 54, weight: .semibold))
                                .foregroundStyle(r.pressure.stormWatch ? .orange : .secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    if let value = r.pressure.current {
                        PressureBar(value: value, trend: r.pressure.trend)
                    }
                    // The coming shape, which is the half that predicts anything.
                    if r.hours.contains(where: { $0.pressure != nil }) {
                        Text("NEXT 12 HOURS")
                            .font(.system(size: 21, weight: .semibold)).tracking(1)
                            .foregroundStyle(.secondary)
                        PressureCurve(hours: Array(r.hours.prefix(12)), current: r.pressure.current)
                            .frame(height: 230)
                    }
                    if !r.pressure.text.isEmpty { sentence(r.pressure.text) }

                case .comfort:
                    HStack(alignment: .firstTextBaseline, spacing: 40) {
                        big(r.comfort.dewPoint.map { String(format: "%.0f°", $0) } ?? "—",
                            r.comfort.label)
                        if let humidity = r.comfort.humidity {
                            big(String(format: "%.0f%%", humidity), "relative humidity")
                        }
                        Spacer(minLength: 0)
                    }
                    if let dew = r.comfort.dewPoint {
                        ComfortScale(dewPoint: dew)
                        // The bands named, so the marker's position is readable
                        // as a word and not just a colour.
                        Text("Dry · Comfortable · Sticky · Muggy · Oppressive · Brutal")
                            .font(.system(size: 22)).foregroundStyle(.tertiary)
                    }
                    if !r.comfort.text.isEmpty { sentence(r.comfort.text) }

                case .rain:
                    big(WeatherAlmanac.inches(r.precipToday ?? 0), "so far today")
                    RainMeter(today: r.precipToday ?? 0, expected: r.rain.totalAccum)
                        .frame(height: 70)
                    if !r.rain.windows.isEmpty {
                        Text("WHEN")
                            .font(.system(size: 21, weight: .semibold)).tracking(1)
                            .foregroundStyle(.secondary)
                        RainWindowChart(windows: r.rain.windows)
                    }
                    if !r.rain.text.isEmpty { sentence(r.rain.text) }

                case .sun:
                    if let day = r.days.first {
                        SunArc(sunrise: Self.date(day.sunrise),
                               sunset: Self.date(day.sunset), now: Date())
                            .frame(height: 320)
                        HStack(spacing: 80) {
                            if let rise = day.sunrise {
                                big(Self.time(rise), "sunrise")
                            }
                            if let set = day.sunset {
                                big(Self.time(set), "sunset")
                            }
                            if let rise = day.sunrise, let set = day.sunset {
                                big(Self.length(rise, set), "of daylight")
                            }
                            Spacer(minLength: 0)
                        }
                    }

                default: EmptyView()
                }
            }
        }
    }

    private static func date(_ epoch: Int?) -> Date? {
        epoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private static func time(_ epoch: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch))
            .formatted(date: .omitted, time: .shortened)
    }

    private static func length(_ rise: Int, _ set: Int) -> String {
        let seconds = max(0, set - rise)
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    private func big(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 84, weight: .medium).monospacedDigit())
            Text(label).font(.system(size: 26)).foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 22) {
            Text(label).font(.system(size: 26)).foregroundStyle(.secondary)
                .frame(width: 220, alignment: .leading)
            Text(value).font(.system(size: 30, weight: .medium).monospacedDigit())
            Spacer(minLength: 0)
        }
    }

    private func sentence(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 27)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func legend(_ text: String) -> some View {
        Text(text).font(.system(size: 21)).foregroundStyle(.tertiary)
    }
}
