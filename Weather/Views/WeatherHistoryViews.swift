//
//  WeatherHistoryViews.swift  (macOS)
//
//  The range bar Compare's day rows are drawn with, and the records board
//  Compare shows under All time.
//
//  Two strips used to live here — `NormalComparisonStrip` and `PastYearsStrip`,
//  the Now tab's "Today for Oct 2" card. That card became one line in Right Now
//  with a door to Compare, which draws the same date across every year with
//  today's forecast among them.
//
//  All the judgement lives in WeatherKit (`Climatology`, `WeatherAlmanac`);
//  these are presentation. The one rule they enforce themselves is VISIBLE
//  UNCERTAINTY: a day the station only half-saw is drawn faintly and says so on
//  hover, rather than sitting in a list of years looking like a measurement.
//

import SwiftUI
import WeatherKit

// MARK: - Shared scale

/// Warm/cool colour for a temperature, so a range bar reads before it's read.
func tempColor(_ value: Double) -> Color {
    switch value {
    case ..<20:  return .indigo
    case ..<33:  return .blue
    case ..<50:  return .teal
    case ..<70:  return .green
    case ..<85:  return .yellow
    case ..<95:  return .orange
    default:     return .red
    }
}

/// A low→high span drawn on a scale shared by everything stacked around it —
/// that shared scale is the whole point, since it's what makes one year's bar
/// comparable to another's at a glance.
struct TempRangeBar: View {
    let low: Double?
    let high: Double?
    let scale: ClosedRange<Double>
    var dimmed = false

    private func fraction(_ value: Double) -> Double {
        let span = scale.upperBound - scale.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - scale.lowerBound) / span))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                if let low, let high {
                    let start = fraction(low) * width
                    let end = fraction(high) * width
                    Capsule()
                        .fill(LinearGradient(colors: [tempColor(low), tempColor(high)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, end - start))
                        .offset(x: start)
                        .opacity(dimmed ? 0.35 : 1)
                }
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Streaks & records

/// The almanac page: what's running right now, and the ceilings behind it.
struct StreaksAndRecords: View {
    let climate: Climatology
    let today: String
    let precipToday: Double?

    @State private var scope: Scope = .allTime

    enum Scope: String, CaseIterable, Identifiable {
        case allTime = "All time"
        case thisYear = "This year"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let highlights = WeatherAlmanac.highlights(climate, today: today, precipToday: precipToday)
            if !highlights.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(highlights) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: line.symbol).foregroundStyle(.tint).frame(width: 20)
                            Text(line.text).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                Divider()
            }

            HStack {
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                Spacer()
                Text(coverage).font(.caption).foregroundStyle(.tertiary)
            }

            let extremes = climate.extremes(inYear: scope == .thisYear ? DayKey.year(of: today) : nil)
            let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                extremeTile("Hottest", extremes.hottest, symbol: "thermometer.sun.fill",
                            format: { "\(Int($0.rounded()))°" })
                extremeTile("Coldest", extremes.coldest, symbol: "thermometer.snowflake",
                            format: { "\(Int($0.rounded()))°" })
                extremeTile("Wettest day", extremes.wettestDay, symbol: "cloud.heavyrain.fill",
                            format: { WeatherAlmanac.inches($0) })
                extremeTile("Strongest gust", extremes.strongestGust, symbol: "wind",
                            format: { "\(Int($0.rounded())) mph" })
                extremeTile("Muggiest", extremes.muggiest, symbol: "humidity.fill",
                            format: { "\(Int($0.rounded()))° dew" })
            }
        }
    }

    @ViewBuilder
    private func extremeTile(_ label: String, _ extreme: WeatherExtreme?,
                             symbol: String, format: (Double) -> String) -> some View {
        if let extreme {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.caption2).foregroundStyle(.tint)
                    Text(label.uppercased())
                        .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.tertiary)
                }
                Text(format(extreme.value)).font(.title3.weight(.semibold))
                Text(WeatherAlmanac.dayLabel(extreme.day, includeYear: true))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }

    /// Records are only as old as the record — say how deep it goes rather than
    /// letting "hottest ever" imply more history than the station has.
    private var coverage: String {
        guard let first = climate.earliestDay else { return "" }
        if scope == .thisYear { return "\(climate.dayCount.formatted()) days archived" }
        let years = climate.yearsOfRecord
        return "from \(WeatherAlmanac.dayLabel(first, includeYear: true)) · \(years) \(years == 1 ? "year" : "years")"
    }
}
