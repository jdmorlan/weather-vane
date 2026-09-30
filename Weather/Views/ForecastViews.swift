//
//  ForecastViews.swift  (Weather)
//
//  THE NEXT THREE DAYS, for someone who wants to know the weather.
//
//  The ten-day on Now answers "what's the week like". This answers the four
//  questions a person actually acts on, for the stretch where a forecast is
//  good enough to act on: how warm, will it rain, will it be windy, and should
//  I be ready for storms — hail means the car goes in the garage, a tornado
//  means knowing where you'd shelter. Past day three it is LONG RANGE, drawn
//  quieter and said to be less reliable, because it is.
//
//  NOT A TEACHING PAGE, deliberately. Every other destination explains a
//  mechanism; this one is the exception — pictures first, sources only as
//  inputs to what is drawn. See [[forecast-page-is-practical]].
//
//  WHAT FEEDS IT: the station's own hourly forecast (temperature, rain, wind),
//  the eleven-model rain spread for the first eighteen hours (whether the
//  models agree), SPC's outlooks — the category and, for days 1 and 2, tornado,
//  hail and wind separately — and WPC's Excessive Rainfall Outlook. WPC's rain
//  TOTALS are left out on purpose: their days run 7 PM to 7 PM, so beside the
//  station's midnight-to-midnight amounts they would be two numbers for "the
//  same day" that don't describe the same hours.
//

import SwiftUI
import WeatherKit

// MARK: - The page

struct ForecastPage<Grade: View>: View {
    let report: WeatherReport
    /// When the station's forecast was fetched — WeatherFlow says nothing
    /// about when it made it, so this is the only time there is to give.
    var forecastFetched: Date?
    @ObservedObject var storms: StormOutlookModel
    let precip: PrecipOutlook?
    let home: GeoPoint?
    var openSetup: () -> Void
    /// The ten-day's report card, as on Now. A slot for the same reason.
    @ViewBuilder var grade: Grade

    private var tz: TimeZone { report.timezone ?? .current }
    private var threeDays: [DayNote] { Array(report.days.prefix(3)) }

    private func key(_ d: DayNote) -> String {
        DayKey.string(for: Date(timeIntervalSince1970: TimeInterval(d.epoch)), timeZone: tz)
    }

    private var risks: [String: StormRisk] {
        guard let home else { return [:] }
        var out: [String: StormRisk] = [:]
        for d in threeDays {
            let k = key(d)
            out[k] = storms.risk(day: k, home: home, timeZone: tz)
        }
        return out
    }

    var body: some View {
        let risks = self.risks
        VStack(alignment: .leading, spacing: 18) {
            DayTiles(days: threeDays, hours: report.threeDays, timezone: tz,
                     risks: risks, keyOf: key)

            StationCard(label: "Next three days") {
                VStack(alignment: .leading, spacing: 12) {
                    grade
                    if report.threeDays.isEmpty {
                        Text("The hourly forecast hasn't arrived yet.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ThreeDayTimeline(hours: report.threeDays, timezone: tz,
                                         precip: precip, risks: risks)
                        Text("\(Platform.pointVerb) the chart to read any hour")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            StationCard(label: "Storms and flooding") {
                StormDays(days: threeDays, risks: risks, keyOf: key, home: home,
                          model: storms, openSetup: openSetup)
            }

            if report.days.count > 3 {
                StationCard(label: "Long range · days 4–\(report.days.count)") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Less reliable past three days — read it as a trend, not a plan.")
                            .font(.callout).foregroundStyle(.secondary)
                        OutlookRibbon(days: Array(report.days.dropFirst(3)), timezone: tz,
                                      firstIsToday: false)
                            .opacity(0.8)
                    }
                }
            }

            sources
        }
        .task { await storms.keepCurrent() }
    }

    /// WHERE EACH PART OF THE PAGE CAME FROM, AND HOW OLD IT IS. Not teaching —
    /// just the dates, so a forecast read at 1 AM says whose, and from when.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(stationLine)
            if let precip {
                Text(modelLine(precip))
            }
            ForEach(storms.sourceLines(), id: \.self) { Text($0) }
        }
        .font(.caption2).foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var stationLine: String {
        let fetched = forecastFetched.map { " · fetched \(When.moment($0))" } ?? ""
        return "Temperature, rain and wind: WeatherFlow's forecast for the station\(fetched) · WeatherFlow doesn't publish when it was made"
    }

    /// The spread shading the first eighteen hours comes from eleven runs of
    /// different ages; the newest and oldest bound them.
    private func modelLine(_ precip: PrecipOutlook) -> String {
        let runs = precip.runs.filter { $0.value.isPlausible() }.map(\.value.initialised)
        var line = "Model agreement, first 18 hours: eleven models via Open-Meteo · fetched \(When.moment(precip.fetched))"
        if let newest = runs.max(), let oldest = runs.min() {
            line += newest == oldest
                ? " · all run \(When.moment(newest))"
                : " · runs from \(When.moment(oldest)) to \(When.moment(newest))"
        }
        return line
    }
}

// MARK: - Day tiles

/// The three days at a glance: the numbers you'd want if you read nothing else.
private struct DayTiles: View {
    let days: [DayNote]
    let hours: [HourSlice]
    let timezone: TimeZone
    let risks: [String: StormRisk]
    let keyOf: (DayNote) -> String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) { tiles }
            VStack(spacing: 12) { tiles }
        }
    }

    @ViewBuilder private var tiles: some View {
        ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
            tile(d, title: ForecastDayTitle.title(index: i, day: d))
        }
    }

    private func peakGust(_ d: DayNote) -> Double? {
        let k = keyOf(d)
        return hours.filter {
            DayKey.string(for: Date(timeIntervalSince1970: TimeInterval($0.epoch)), timeZone: timezone) == k
        }.compactMap(\.windGust).max()
    }

    private func tile(_ d: DayNote, title: String) -> some View {
        let risk = risks[keyOf(d)]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: WeatherView.symbol(d.icon))
                    .symbolRenderingMode(.multicolor).font(.title3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(d.high.map { "\(Int($0.rounded()))°" } ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(d.low.map { "\(Int($0.rounded()))°" } ?? "")
                    .font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                row("drop.fill", .blue, rainText(d))
                row("wind", .secondary, peakGust(d).map { "Gusts to \(Int($0.rounded())) mph" } ?? "—")
            }
            .font(.callout)
            HStack(spacing: 6) {
                StormBadge(risk: risk)
                if let flood = risk?.flood {
                    Badge(text: "Flooding: \(flood.name)", color: flood.fill.color)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }

    private func rainText(_ d: DayNote) -> String {
        let chance = Int((d.precipProbability ?? 0).rounded())
        guard chance > 0 || (d.precipTotal ?? 0) > 0 else { return "Dry" }
        var s = "\(chance)% rain"
        if let total = d.precipTotal, total >= 0.01 { s += " · \(WeatherAlmanac.inches(total))" }
        return s
    }

    private func row(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
            Text(text)
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.35)))
            .overlay(Capsule().stroke(color.opacity(0.8), lineWidth: 1))
    }
}

/// The day's storm category, or what we know short of one.
private struct StormBadge: View {
    let risk: StormRisk?
    var body: some View {
        if let risk {
            if let c = risk.category, c.level > 0 {
                Badge(text: "Storms: \(c.name)", color: c.fill.color)
            } else if risk.category != nil {
                Badge(text: "Thunderstorms", color: .secondary)
            } else {
                Text("No storms expected").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Storm outlook loading…").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Storms, hazard by hazard

private struct StormDays: View {
    let days: [DayNote]
    let risks: [String: StormRisk]
    let keyOf: (DayNote) -> String
    let home: GeoPoint?
    @ObservedObject var model: StormOutlookModel
    var openSetup: () -> Void

    var body: some View {
        if home == nil {
            // Never silently absent: say what it needs, and offer it.
            HStack {
                Text("Storm and flood outlooks are read at your home point, and none is set.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Set home") { openSetup() }
            }
        } else if risks.isEmpty, let failure = model.failure {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't load the storm outlooks: \(failure)")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Try again") { Task { await model.load(force: true) } }
            }
        } else if risks.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading SPC and WPC outlooks…").font(.callout).foregroundStyle(.secondary)
            }
        } else if days.allSatisfy({ risks[keyOf($0)]?.isQuiet ?? true }) {
            Label("No severe storms or flooding expected through \(days.last?.weekday ?? "the weekend").",
                  systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                    if let risk = risks[keyOf(d)], !risk.isQuiet {
                        day(ForecastDayTitle.title(index: i, day: d), risk)
                    }
                }
            }
        }
    }

    private func day(_ title: String, _ risk: StormRisk) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                StormBadge(risk: risk)
                if let flood = risk.flood {
                    Badge(text: "Flooding: \(flood.name)", color: flood.fill.color)
                }
            }
            ForEach(risk.notable) { h in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: symbol(h.hazard))
                        .foregroundStyle(levelColor(h.level)).frame(width: 18)
                    Text(h.hazard.label).fontWeight(.medium).frame(minWidth: 110, alignment: .leading)
                    Text("\(Int((h.probability * 100).rounded()))% within 25 mi")
                        .foregroundStyle(.secondary).monospacedDigit()
                        .frame(minWidth: 120, alignment: .leading)
                    if let action = h.action { Text(action) }
                    Spacer(minLength: 0)
                }
                .font(.callout)
            }
            if let flood = risk.flood {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "water.waves").foregroundStyle(flood.fill.color).frame(width: 18)
                    Text("Flash flooding").fontWeight(.medium).frame(minWidth: 110, alignment: .leading)
                    Text(flood.meaning).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .font(.callout)
            }
        }
    }

    private func symbol(_ h: SevereHazard) -> String {
        switch h {
        case .tornado: return "tornado"
        case .hail:    return "cloud.hail.fill"
        case .wind:    return "wind"
        case .any:     return "cloud.bolt.fill"
        }
    }

    /// The hazard's level in the categorical map's own colours.
    private func levelColor(_ level: Int) -> Color {
        OutlookCategory.spc.first { $0.level == level }?.stroke.color ?? .secondary
    }
}
