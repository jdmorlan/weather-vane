//
//  RainDashboard.swift
//
//  The top of the Rain page: four answers readable at a glance.
//
//  WHAT THE PAGE IS FOR, which is what decided the four. Explore answers the
//  questions you bring; Rain answers the ones anyone with a yard already has,
//  asked for you and kept current:
//
//      This year   are we wet or dry, and where did the year go wrong?
//      Lately      how long since it rained, and is this month's dry normal?
//      Drought     what the Drought Monitor calls it — which can disagree
//                  with "this year", and the disagreement is the lesson
//      Coming      is rain on the way, in hours and in days
//
//  Everything under these on the page explains or backs them up. Records are
//  further down, because nobody opens Rain to read a record.
//
//  Each tile leads with a number, draws its shape under it, and prints the
//  numbers that matter on the marks — the Forecast boxes' grammar, not rows of
//  labelled text.
//

import SwiftUI
import WeatherKit

// MARK: - The drought model

/// The Drought Monitor's weeks for the county home is in.
///
/// Up in `StationModels` beside the precip outlook so leaving Rain and coming
/// back isn't a fetch. The map is weekly, so a few hours between asks is plenty
/// and any more often is asking a Thursday product what changed since lunch.
@MainActor
final class DroughtModel: ObservableObject {
    @Published private(set) var report: DroughtReport?
    @Published private(set) var failure: String?
    @Published private(set) var isLoading = false
    /// No home point, so no county to ask about.
    @Published private(set) var needsHome = false

    static let refreshAfter: TimeInterval = 6 * 3600

    func load(home: GeoPoint?) async {
        guard let home else { needsHome = true; return }
        needsHome = false
        // The county comes from where home is, never from a setting: the bundled
        // outlines answer it offline.
        await CountyLines.shared.load()
        guard let county = CountyLines.shared.county(containing: home) else {
            failure = "Home isn’t inside a US county, so there’s no drought map for it."
            return
        }
        if let report, report.fips == county.geoid,
           Date().timeIntervalSince(report.fetched) < Self.refreshAfter { return }
        isLoading = true
        defer { isLoading = false }
        do {
            report = try await DroughtMonitorClient().report(for: county)
            failure = nil
        } catch {
            // Last week's map is still last week's map; keep it.
            failure = (error as? DroughtMonitorClient.Failure)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - The dashboard

struct RainDashboard: View {
    let climate: Climatology?
    let isLoadingArchive: Bool
    let today: String
    let days: [DayNote]
    @ObservedObject var precip: PrecipOutlookModel
    @ObservedObject var drought: DroughtModel
    var onSetUpHome: () -> Void = {}

    @State private var built: Built?

    private struct Built: Equatable {
        var pace: RainPace
        var summary: RainfallSummary
        var lately: RainLately
    }

    var body: some View {
        // Two columns where there's room, one where there isn't.
        ViewThatFits(in: .horizontal) {
            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    yearTile
                    latelyTile
                }
                GridRow {
                    droughtTile
                    comingTile
                }
            }
            .frame(minWidth: 700)
            VStack(spacing: 14) {
                yearTile
                latelyTile
                droughtTile
                comingTile
            }
        }
        .task(id: "\(today)|\(climate?.dayCount ?? 0)") {
            guard let climate, climate.dayCount >= 90 else { built = nil; return }
            let day = today
            // The archive stops at yesterday, so the recent window does too —
            // ending it today would count today as a day the station missed.
            let recent = min(climate.latestDay ?? day, DayKey.previous(day) ?? day)
            built = await Task.detached(priority: .userInitiated) {
                Built(pace: climate.rainPace(asOf: day),
                      summary: climate.rainfallSummary(asOf: day),
                      lately: climate.rainLately(asOf: recent))
            }.value
        }
    }

    // MARK: Tiles

    private var yearTile: some View {
        RainTile(label: "This year") {
            if let built, built.pace.isMeaningful {
                RainYearPace(pace: built.pace, summary: built.summary)
            } else {
                pending(built == nil && (isLoadingArchive || climate != nil)
                        ? nil : "Two years of record make a usual to compare against. It fills in as the archive grows.")
            }
        }
    }

    private var latelyTile: some View {
        RainTile(label: "Lately") {
            if let built {
                RainLatelyView(lately: built.lately)
            } else {
                pending(isLoadingArchive || climate != nil ? nil : "Needs the station’s archive, which is still catching up.")
            }
        }
    }

    private var droughtTile: some View {
        RainTile(label: "Drought") {
            DroughtView(model: drought, yearDeparture: built?.pace.departure, onSetUpHome: onSetUpHome)
        }
    }

    private var comingTile: some View {
        RainTile(label: "Coming") {
            RainComingView(outlook: precip.outlook, failure: precip.failure, isLoading: precip.isLoading,
                           needsHome: precip.needsHome, days: days,
                           onSetUpHome: onSetUpHome)
        }
    }

    /// A tile's body before it has anything — still the tile, so it's still missed.
    @ViewBuilder private func pending(_ reason: String?) -> some View {
        if let reason {
            Text(reason).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the years behind you").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// A smaller `StationCard`, sized to sit four to a screen.
struct RainTile<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
            content
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }
}

/// Blue for wetter than usual, orange for drier — the same pair the old
/// Rainfall card used for its "ahead"/"behind" chip.
private func departureColor(_ value: Double) -> Color { value >= 0 ? .blue : .orange }

private func signedInches(_ value: Double) -> String {
    (value >= 0 ? "+" : "−") + String(format: "%.2f″", abs(value))
}

// MARK: - This year

/// This year's running total against the usual one, and each month's share of the gap.
struct RainYearPace: View {
    let pace: RainPace
    let summary: RainfallSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(WeatherAlmanac.inches(pace.toDate ?? 0))
                    .font(.system(size: 30, weight: .light, design: .rounded).monospacedDigit())
                if let departure = pace.departure {
                    Text("\(signedInches(departure)) vs usual")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(departureColor(departure).opacity(0.16), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            chart.frame(height: 96)
            months
            if summary.daysMissedThisYear > 0 {
                Text("\(summary.daysMissedThisYear) \(summary.daysMissedThisYear == 1 ? "day" : "days") not recorded this year, so the total is a floor.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var top: Double {
        let peak = max(pace.usualYear ?? 0, pace.thisYear.compactMap { $0 }.max() ?? 0)
        // Room above the highest line for its label.
        return max(1, peak * 1.2)
    }

    private var chart: some View {
        Canvas { context, size in
            let n = Double(pace.thisYear.count - 1)
            func x(_ i: Int) -> CGFloat { CGFloat(Double(i) / max(1, n)) * size.width }
            func y(_ v: Double) -> CGFloat { size.height * CGFloat(1 - v / top) }
            func line(_ values: [Double?]) -> Path {
                var path = Path(); var on = false
                for (i, v) in values.enumerated() {
                    guard let v else { on = false; continue }
                    let p = CGPoint(x: x(i), y: y(v))
                    if on { path.addLine(to: p) } else { path.move(to: p); on = true }
                }
                return path
            }

            for start in pace.monthStarts.dropFirst() {
                var tick = Path(); tick.move(to: CGPoint(x: x(start), y: 0)); tick.addLine(to: CGPoint(x: x(start), y: size.height))
                context.stroke(tick, with: .color(.primary.opacity(0.06)), lineWidth: 1)
            }
            var floor = Path(); floor.move(to: CGPoint(x: 0, y: size.height)); floor.addLine(to: CGPoint(x: size.width, y: size.height))
            context.stroke(floor, with: .color(.primary.opacity(0.25)), lineWidth: 1)

            // The gap, shaded the colour of whichever side is winning.
            for i in 0..<min(pace.throughSlot, pace.thisYear.count - 1) {
                guard let a = pace.thisYear[i], let b = pace.thisYear[i + 1],
                      let ua = pace.usual[i], let ub = pace.usual[i + 1] else { continue }
                var band = Path()
                band.move(to: CGPoint(x: x(i), y: y(a))); band.addLine(to: CGPoint(x: x(i + 1), y: y(b)))
                band.addLine(to: CGPoint(x: x(i + 1), y: y(ub))); band.addLine(to: CGPoint(x: x(i), y: y(ua)))
                band.closeSubpath()
                context.fill(band, with: .color(departureColor(b - ub).opacity(0.3)))
            }

            context.stroke(line(pace.usual), with: .color(.secondary.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            context.stroke(line(pace.thisYear), with: .color(.blue), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

            if let usualYear = pace.usualYear {
                context.draw(Text("usual year \(WeatherAlmanac.inches(usualYear))").font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: size.width, y: y(usualYear) - 3), anchor: .bottomTrailing)
            }
            if let now = pace.toDate {
                let p = CGPoint(x: x(pace.throughSlot), y: y(now))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.blue))
            }
        }
    }

    /// Each finished month's departure from its usual, under its stretch of the line.
    private var months: some View {
        HStack(spacing: 0) {
            ForEach(summary.months) { month in
                VStack(spacing: 1) {
                    Text(String(month.name.prefix(1)))
                        .font(.system(size: 9)).foregroundStyle(month.isInProgress ? .primary : .tertiary)
                    Text(label(month))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(color(month))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .help(help(month))
            }
        }
    }

    private func departure(_ m: MonthlyRainfall) -> Double? {
        guard let a = m.thisYear, let b = m.typical, !m.isInProgress, m.isTrustworthy else { return nil }
        return a - b
    }

    private func label(_ m: MonthlyRainfall) -> String {
        guard let d = departure(m) else { return m.isInProgress ? "so far" : "" }
        return abs(d) < 0.05 ? "0" : (d > 0 ? "+" : "−") + String(format: "%.1f", abs(d))
    }

    private func color(_ m: MonthlyRainfall) -> Color {
        guard let d = departure(m), abs(d) >= 0.05 else { return .secondary }
        return departureColor(d)
    }

    private func help(_ m: MonthlyRainfall) -> String {
        var text = WeatherAlmanac.monthName(String(format: "%02d", m.month))
        if let a = m.thisYear { text += ": \(WeatherAlmanac.inches(a))\(m.isInProgress ? " so far" : "")" }
        if let b = m.typical { text += ", usually \(WeatherAlmanac.inches(b)) (\(m.years) years)" }
        if m.thisYear != nil && !m.isTrustworthy && !m.isInProgress {
            text += ". Only \(Int((m.coverage * 100).rounded()))% of it was recorded."
        }
        return text
    }
}

// MARK: - Lately

struct RainLatelyView: View {
    let lately: RainLately

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(lately.dryDays)")
                    .font(.system(size: 30, weight: .light, design: .rounded).monospacedDigit())
                Text(lately.dryDays == 1 ? "day since it rained" : "days since it rained")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            bars.frame(height: 56)
            HStack(alignment: .firstTextBaseline) {
                Text(lately.days.first.map { WeatherAlmanac.dayLabel($0.day) } ?? "")
                Spacer()
                Text("yesterday")
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(lately.window) days: \(WeatherAlmanac.inches(lately.total))")
                    .font(.callout.weight(.medium).monospacedDigit())
                if let usual = lately.usual {
                    Text("usually \(WeatherAlmanac.inches(usual))")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(signedInches(lately.total - usual))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(departureColor(lately.total - usual))
                }
            }
            if lately.daysMissed > 0 {
                Text("\(lately.daysMissed) of these days weren’t recorded.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var peak: Double { max(0.5, lately.days.compactMap(\.amount).max() ?? 0) }

    /// A bar per day, its height the rain; the biggest one labelled.
    private var bars: some View {
        Canvas { context, size in
            let n = CGFloat(max(1, lately.days.count))
            let w = size.width / n
            let labelRoom: CGFloat = 12
            let h = size.height - labelRoom
            let biggest = lately.days.filter { ($0.amount ?? 0) >= Climatology.measurableRain }
                .max { ($0.amount ?? 0) < ($1.amount ?? 0) }
            for (i, day) in lately.days.enumerated() {
                let x0 = CGFloat(i) * w
                guard let amount = day.amount else {
                    // Not recorded: a hollow mark on the floor, not a dry day.
                    context.stroke(Path(CGRect(x: x0 + w * 0.2, y: size.height - 3, width: w * 0.6, height: 3)),
                                   with: .color(.secondary.opacity(0.5)), lineWidth: 0.5)
                    continue
                }
                if amount >= Climatology.measurableRain {
                    let bh = max(2, h * CGFloat(min(1, amount / peak)))
                    let rect = CGRect(x: x0 + w * 0.15, y: size.height - bh, width: w * 0.7, height: bh)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.blue.opacity(0.8)))
                    if day.id == biggest?.id {
                        let atEnd = x0 > size.width - 80
                        context.draw(Text("\(WeatherAlmanac.dayLabel(day.day)) · \(WeatherAlmanac.inches(amount))").font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.primary),
                                     at: CGPoint(x: atEnd ? x0 + w : x0, y: rect.minY - 2), anchor: atEnd ? .bottomTrailing : .bottomLeading)
                    }
                } else {
                    context.fill(Path(CGRect(x: x0 + w * 0.15, y: size.height - 1, width: w * 0.7, height: 1)),
                                 with: .color(.secondary.opacity(0.35)))
                }
            }
        }
    }
}

// MARK: - Drought

struct DroughtView: View {
    @ObservedObject var model: DroughtModel
    /// This year's rain against the usual, for the one case worth explaining:
    /// the station and the map disagreeing.
    var yearDeparture: Double? = nil
    var onSetUpHome: () -> Void = {}

    var body: some View {
        if let report = model.report, let latest = report.latest {
            answer(report, latest)
        } else if model.needsHome {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set a home point and this shows the Drought Monitor’s rating for its county.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set up home", action: onSetUpHome).buttonStyle(.link).font(.callout)
            }
        } else if let failure = model.failure {
            Text(failure).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking the Drought Monitor").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func answer(_ report: DroughtReport, _ latest: DroughtWeek) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(latest.prevailing?.name ?? "Not in drought")
                    .font(.system(size: 22, weight: .regular, design: .rounded))
                if let level = latest.prevailing {
                    Text(level.code)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Self.color(level), in: Capsule())
                        .foregroundStyle(level >= .d3 ? .white : .black)
                }
                Spacer(minLength: 0)
            }
            if let line = change(report, latest) {
                Text(line).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            strip(report)
            HStack(alignment: .firstTextBaseline) {
                Text(report.weeks.first.map { WeatherAlmanac.dayLabel($0.mapDate) } ?? "")
                Spacer()
                Text("as of \(WeatherAlmanac.dayLabel(latest.mapDate))")
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary)
            key(report)
            if let lesson = lesson(latest) {
                Text(lesson).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Text("\(report.countyName) County · \(DroughtMonitorClient.credit), weekly")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// What changed, or how much of the county is worse than most of it.
    private func change(_ report: DroughtReport, _ latest: DroughtWeek) -> String? {
        var parts: [String] = []
        if let (week, from) = report.lastChange {
            let now = latest.prevailing, was = from
            let verb = (now?.rawValue ?? -1) < (was?.rawValue ?? -1) ? "Eased" : "Worsened"
            parts.append("\(verb) from \(was?.name.lowercased() ?? "no drought") on the \(WeatherAlmanac.dayLabel(week.mapDate)) map.")
        } else if report.weeks.count > 1 {
            parts.append("The same for all \(report.weeks.count) weeks shown.")
        }
        if let worst = latest.worst, worst != latest.prevailing {
            parts.append("\(Int(latest.share(atLeast: worst).rounded()))% of the county is \(worst.name.lowercased()).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Only the levels the strip actually uses, in order.
    private func key(_ report: DroughtReport) -> some View {
        let used = Set(report.weeks.compactMap(\.prevailing))
        return HStack(spacing: 10) {
            ForEach(DroughtLevel.allCases.filter { used.contains($0) }) { level in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Self.color(level)).frame(width: 10, height: 8)
                    Text(level.name).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if report.weeks.contains(where: { $0.prevailing == nil }) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.15)).frame(width: 10, height: 8)
                    Text("none").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Why the map and the station's own total can point different ways.
    private func lesson(_ latest: DroughtWeek) -> String? {
        guard let yearDeparture, abs(yearDeparture) >= 0.25 else { return nil }
        let inDrought = (latest.prevailing ?? .d0) >= .d1
        if inDrought && yearDeparture > 0 {
            return "Ahead on rain this year and still in drought: the rating weighs months of soil, streams and heat, not inches since January."
        }
        if !inDrought && yearDeparture < 0 {
            return "Behind on rain this year but not in drought: the rating weighs months of soil, streams and heat, not inches since January."
        }
        return nil
    }

    /// A cell per week, coloured by the level most of the county was in.
    private func strip(_ report: DroughtReport) -> some View {
        HStack(spacing: 2) {
            ForEach(report.weeks) { week in
                RoundedRectangle(cornerRadius: 2)
                    .fill(week.prevailing.map(Self.color) ?? Color.secondary.opacity(0.15))
                    .frame(maxWidth: .infinity)
                    .frame(height: 16)
                    .help("\(WeatherAlmanac.dayLabel(week.mapDate)): \(week.prevailing?.name ?? "not in drought")")
            }
        }
    }

    /// The Drought Monitor's own palette, so this reads like the map people know.
    static func color(_ level: DroughtLevel) -> Color {
        switch level {
        case .d0: return Color(red: 1.00, green: 1.00, blue: 0.00)
        case .d1: return Color(red: 0.99, green: 0.83, blue: 0.50)
        case .d2: return Color(red: 1.00, green: 0.67, blue: 0.00)
        case .d3: return Color(red: 0.90, green: 0.00, blue: 0.00)
        case .d4: return Color(red: 0.45, green: 0.00, blue: 0.00)
        }
    }
}

// MARK: - Coming

struct RainComingView: View {
    let outlook: PrecipOutlook?
    let failure: String?
    let isLoading: Bool
    let needsHome: Bool
    let days: [DayNote]
    var onSetUpHome: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            hours
            Divider().opacity(0.5)
            daysAhead
        }
    }

    @ViewBuilder private var hours: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("NEXT \(PrecipOutlookClient.hours) HOURS")
                .font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.tertiary)
            if let outlook {
                Text(outlook.headline).font(.callout.weight(.medium))
                if let detail = outlook.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            } else if needsHome {
                Button("Set up home to ask the models", action: onSetUpHome).buttonStyle(.link).font(.callout)
            } else if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            } else if isLoading {
                Text("Asking eleven models…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Today and the two days after: the bar is the chance, the number the amount.
    private var daysAhead: some View {
        let shown = Array(days.prefix(3))
        return VStack(alignment: .leading, spacing: 4) {
            Text("NEXT 3 DAYS")
                .font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.tertiary)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, day in
                    let chance = max(0, min(1, (day.precipProbability ?? 0) / 100))
                    VStack(spacing: 3) {
                        Text("\(Int((chance * 100).rounded()))%")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(chance >= 0.3 ? .primary : .secondary)
                        ZStack(alignment: .bottom) {
                            Rectangle().fill(Color.primary.opacity(0.2)).frame(height: 1)
                            RoundedRectangle(cornerRadius: 2).fill(Color.blue.opacity(0.75))
                                .frame(width: 14, height: max(chance > 0 ? 2 : 0, 34 * chance))
                        }
                        .frame(maxWidth: 60)
                        .frame(height: 34, alignment: .bottom)
                        Text((day.precipTotal ?? 0) >= 0.01 ? WeatherAlmanac.inches(day.precipTotal ?? 0) : "—")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        Text(index == 0 ? "Today" : day.weekday)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Text("Chance and amount from the Tempest forecast")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
