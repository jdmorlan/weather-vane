//
//  ForecastTab.swift  (tvOS)
//
//  The next three days, drawn — the Mac's Forecast page at ten-foot size.
//
//  Same four questions, same stretch: how warm, will it rain, will it be
//  windy, and should I be ready for storms. A tile per day with the numbers
//  and what to DO about any storm risk (the car in the garage, a place to
//  shelter), then the three days as one figure. Not a teaching page; see
//  [[forecast-page-is-practical]].
//
//  NO LONG RANGE, unlike the Mac. A fourth tile for days four on took a
//  quarter of the row from the three days this page is about, and squeezed
//  their storm badges onto separate lines.
//
//  THE FIGURE IS THE MAC'S, not a second chart: `ThreeDayTimeline` compiled in
//  from the Mac's sources and drawn at `scale`. The models' rain agreement
//  strip is left off here — eighteen hours of a subtle strip, one more feed for
//  the TV to poll, and nothing you could read from the sofa.
//
//  SOURCES AT THE FOOT, SMALL. Every source in the app says when it was made
//  and when the next is due, so an outlook read at 1 AM says it was
//  yesterday's. Here that is a few quiet lines in the space under the figure,
//  not a panel. A day with no outlook still says so on its tile.
//
//  NOTHING IS FOCUSABLE, as on Now: every answer is already on the screen.
//

import SwiftUI
import WeatherKit

struct ForecastTab: View {
    let report: WeatherReport?
    let hasStation: Bool
    @ObservedObject var storms: StormOutlookModel
    let home: GeoPoint?

    var body: some View {
        if !hasStation {
            NoStationNotice()
        } else if let r = report, !r.days.isEmpty {
            content(r)
        } else if report == nil {
            WaitingNotice()
        } else {
            Text("No forecast from the station yet.")
                .font(.system(size: 28)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ r: WeatherReport) -> some View {
        let tz = r.timezone ?? .current
        let days = Array(r.days.prefix(3))
        let risks = self.risks(days, tz)
        return VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 20) {
                ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                    DayTile(title: ForecastDayTitle.title(index: i, day: d), day: d,
                            peakGust: peakGust(d, r.threeDays, tz),
                            risk: risks[key(d, tz)], outlook: outlookState)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if r.threeDays.isEmpty {
                Text("The hourly forecast hasn't arrived yet.")
                    .font(.system(size: 26)).foregroundStyle(.secondary)
            } else {
                ThreeDayTimeline(hours: r.threeDays, timezone: tz, precip: nil,
                                 risks: risks, scale: 1.45, textScale: 2)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("Forecast: WeatherFlow, for the station · current as of \(When.moment(r.asOf))")
                ForEach(storms.sourceLines(), id: \.self) { Text($0) }
            }
            .font(.system(size: 18)).foregroundStyle(.tertiary)
        }
        // Clear of the tab bar and the warning beside it, which float over
        // the page rather than pushing it down. On top of the safe area's own
        // margin, which already keeps the bottom off the edge of the screen.
        .padding(.top, 75)
        .padding(.horizontal, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Data

    private func key(_ d: DayNote, _ tz: TimeZone) -> String {
        DayKey.string(for: Date(timeIntervalSince1970: TimeInterval(d.epoch)), timeZone: tz)
    }

    private func risks(_ days: [DayNote], _ tz: TimeZone) -> [String: StormRisk] {
        guard let home else { return [:] }
        var out: [String: StormRisk] = [:]
        for d in days {
            let k = key(d, tz)
            out[k] = storms.risk(day: k, home: home, timeZone: tz)
        }
        return out
    }

    private func peakGust(_ d: DayNote, _ hours: [HourSlice], _ tz: TimeZone) -> Double? {
        let k = key(d, tz)
        return hours.filter {
            DayKey.string(for: Date(timeIntervalSince1970: TimeInterval($0.epoch)), timeZone: tz) == k
        }.compactMap(\.windGust).max()
    }

    /// Why a day has no storm answer, when it has none — never left to read
    /// as a quiet day.
    private var outlookState: DayTile.OutlookState {
        if home == nil { return .noHome }
        if storms.failure != nil && storms.fetched == nil { return .failed }
        return .loading
    }
}

// MARK: - A day

private struct DayTile: View {
    enum OutlookState { case loading, failed, noHome }

    let title: String
    let day: DayNote
    let peakGust: Double?
    let risk: StormRisk?
    let outlook: OutlookState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 22, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: WeatherSymbol.name(day.icon))
                    .symbolRenderingMode(.multicolor).font(.system(size: 40))
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(day.high.map { "\(Int($0.rounded()))°" } ?? "—")
                    .font(.system(size: 54, weight: .medium).monospacedDigit())
                Text(day.low.map { "\(Int($0.rounded()))°" } ?? "")
                    .font(.system(size: 36).monospacedDigit()).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                row("drop.fill", .cyan, rainText)
                row("wind", (peakGust ?? 0) >= 25 ? .orange : .secondary,
                    peakGust.map { "Gusts to \(Int($0.rounded())) mph" } ?? "—")
            }
            .font(.system(size: 26))
            storms
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))
    }

    /// The day's storm category and flood risk, then what to do about the
    /// likeliest hazard — the line that tells you to put the car away.
    @ViewBuilder private var storms: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Side by side when they fit, stacked when they don't — never cut
            // to "Storms: Ma…".
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { badges }
                VStack(alignment: .leading, spacing: 8) { badges }
            }
            .font(.system(size: 22, weight: .semibold))
            if let top = risk?.notable.first, let action = top.action {
                // The icon carries the level's colour; the words stay white,
                // because SPC's Marginal green is unreadable as text on black.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: symbol(top.hazard))
                        .foregroundStyle(levelColor(top.level))
                    Text(top.hazard == .any ? action
                         : "\(top.hazard.label) \(Int((top.probability * 100).rounded()))% · \(action)")
                        .lineLimit(2)
                }
                .font(.system(size: 22))
            }
        }
    }

    @ViewBuilder private var badges: some View {
        if let risk {
            if let c = risk.category, c.level > 0 {
                Badge(text: "Storms: \(c.name)", color: c.fill.color)
            } else if risk.category != nil {
                Badge(text: "Thunderstorms", color: .secondary)
            } else {
                Text("No storms expected").foregroundStyle(.secondary)
            }
            if let flood = risk.flood {
                Badge(text: "Flooding: \(flood.name)", color: flood.fill.color)
            }
        } else {
            switch outlook {
            case .loading: Text("Storm outlook loading…").foregroundStyle(.tertiary)
            case .failed:  Text("Storm outlook unavailable").foregroundStyle(.secondary)
            case .noHome:  Text("Set a home for storm outlooks").foregroundStyle(.secondary)
            }
        }
    }

    private var rainText: String {
        let chance = Int((day.precipProbability ?? 0).rounded())
        guard chance > 0 || (day.precipTotal ?? 0) > 0 else { return "Dry" }
        var s = "\(chance)% rain"
        if let total = day.precipTotal, total >= 0.01 { s += " · \(WeatherAlmanac.inches(total))" }
        return s
    }

    private func row(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 30)
            Text(text).lineLimit(1).minimumScaleFactor(0.7)
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

private struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.35)))
            .overlay(Capsule().stroke(color.opacity(0.8), lineWidth: 2))
    }
}
