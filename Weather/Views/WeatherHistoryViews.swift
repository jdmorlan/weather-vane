//
//  WeatherHistoryViews.swift  (macOS)
//
//  The archive, on screen. Three registers, each answering a different question
//  the forecast alone can't:
//
//    · NormalComparisonStrip — "is this hot, or just summer?"
//    · PastYearsStrip        — "what does this date usually do here?"
//    · StreaksAndRecords     — "how long has it been, and what's the ceiling?"
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

// MARK: - Compared to normal

/// Today against the usual for the date. Sits inside the Right-now card, because
/// "96°" and "12° warmer than usual" are the same fact at two altitudes and
/// splitting them across the screen makes the reader do the joining.
struct NormalComparisonStrip: View {
    let comparison: ClimateComparison
    let todayHigh: Double?
    let todayLow: Double?

    var body: some View {
        if comparison.hasSomethingToSay {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(.tint).font(.caption)
                    if let headline = comparison.headline {
                        Text(headline).font(.callout.weight(.medium))
                    }
                    if let rank = comparison.rankText {
                        Text(rank)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                if let normalHigh = comparison.normal.high, let normalLow = comparison.normal.low {
                    // Two bars on one scale: what today is doing, and what this
                    // date usually does. The offset between them IS the story.
                    let scale = bounds(normalLow, normalHigh)
                    VStack(alignment: .leading, spacing: 5) {
                        row("Today", low: todayLow, high: todayHigh, scale: scale, dimmed: false)
                        row("Usual", low: normalLow, high: normalHigh, scale: scale, dimmed: true)
                    }
                }
                if let detail = comparison.detail {
                    Text(detail).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func row(_ label: String, low: Double?, high: Double?,
                     scale: ClosedRange<Double>, dimmed: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .leading)
            TempRangeBar(low: low, high: high, scale: scale, dimmed: dimmed)
            Text(rangeText(low: low, high: high))
                .font(.caption.monospacedDigit())
                .foregroundStyle(dimmed ? .tertiary : .secondary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private func rangeText(low: Double?, high: Double?) -> String {
        guard let low, let high else { return "—" }
        return "\(Int(high.rounded()))° / \(Int(low.rounded()))°"
    }

    /// Pad the scale past both spans so neither bar ends flush against an edge,
    /// where a difference of a few degrees stops being visible.
    private func bounds(_ normalLow: Double, _ normalHigh: Double) -> ClosedRange<Double> {
        let values = [normalLow, normalHigh, todayLow, todayHigh].compactMap { $0 }
        let lower = (values.min() ?? normalLow) - 6
        let upper = (values.max() ?? normalHigh) + 6
        return lower...max(lower + 1, upper)
    }

    private var symbol: String {
        guard let delta = comparison.highDelta else { return "calendar" }
        if abs(delta) < 2 { return "equal.circle" }
        return delta > 0 ? "arrow.up.right.circle" : "arrow.down.right.circle"
    }
}

// MARK: - This day in past years

/// Every year's version of today's date, as points on ONE temperature axis.
///
/// A row of bars per year answered the wrong question. The thing you want is a
/// COMPARISON — was this year's Aug 6 hot for an Aug 6? — and a comparison of a
/// handful of values belongs on a single shared scale where the spacing between
/// them IS the answer. Stacked bars force the eye to measure edges against each
/// other; points on an axis are already measured.
///
/// The axis shows one measure at a time, because the day's high and its low
/// answer different questions and overlaying them halves the resolution of both.
/// Which one leads is seasonal: in August "how hot did it get" is the fact, in
/// January it's "how cold" — asked of the record rather than hardcoded.
struct PastYearsStrip: View {
    let history: [HistoricalDay]
    let normal: DailyNormal
    let dateLabel: String
    let todayHigh: Double?
    let todayLow: Double?
    let defaultEmphasis: Climatology.TemperatureEmphasis

    @State private var chosen: Climatology.TemperatureEmphasis?
    private var mode: Climatology.TemperatureEmphasis { chosen ?? defaultEmphasis }

    /// Labels need roughly this share of the axis; anything closer stacks onto
    /// the next lane. Expressed as a fraction of the value range rather than in
    /// points so the lane count — and therefore the height — is known before
    /// layout.
    private let minGapFraction = 0.13

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if points.isEmpty {
                Text("No \(mode == .high ? "highs" : "lows") recorded for \(dateLabel) yet.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        usualBand(width: geo.size.width)
                        axis(width: geo.size.width)
                        ForEach(laidOut, id: \.point.year) { entry in
                            yearMarker(entry.point)
                                .offset(x: x(entry.point.value, width: geo.size.width) - 26,
                                        y: 42 + CGFloat(entry.lane) * 26)
                        }
                        if let todayValue {
                            todayMarker(todayValue)
                                .offset(x: x(todayValue, width: geo.size.width) - 30, y: 0)
                        }
                    }
                }
                .frame(height: 42 + CGFloat(laneCount) * 26 + 6)
                footnote
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(mode == .high ? "How hot \(dateLabel) gets" : "How cold \(dateLabel) gets")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: Binding(get: { mode }, set: { chosen = $0 })) {
                Text("High").tag(Climatology.TemperatureEmphasis.high)
                Text("Low").tag(Climatology.TemperatureEmphasis.low)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 120)
        }
    }

    // MARK: Points

    private struct Point {
        let year: Int
        let value: Double
        let reliable: Bool
        let precip: Double?
    }

    private var points: [Point] {
        history.compactMap { entry in
            guard let value = mode == .high ? entry.record.tempMax : entry.record.tempMin
            else { return nil }
            return Point(year: entry.year, value: value,
                         reliable: entry.record.isReliable, precip: entry.record.precipTotal)
        }
    }

    private var todayValue: Double? { mode == .high ? todayHigh : todayLow }
    private var normalValue: Double? { mode == .high ? normal.high : normal.low }
    private var normalSpread: Double? { mode == .high ? normal.highSpread : normal.lowSpread }

    /// Points assigned to lanes so labels never collide, coldest first.
    private var laidOut: [(point: Point, lane: Int)] {
        let sorted = points.sorted { $0.value < $1.value }
        let gap = (bounds.upperBound - bounds.lowerBound) * minGapFraction
        var laneValues: [Double] = []
        var result: [(Point, Int)] = []
        for point in sorted {
            var lane = 0
            while lane < laneValues.count && point.value - laneValues[lane] < gap { lane += 1 }
            if lane == laneValues.count { laneValues.append(point.value) } else { laneValues[lane] = point.value }
            result.append((point, lane))
        }
        return result
    }

    private var laneCount: Int { max(1, (laidOut.map(\.lane).max() ?? 0) + 1) }

    private var bounds: ClosedRange<Double> {
        var values = points.map(\.value)
        if let todayValue { values.append(todayValue) }
        if let normalValue, let spread = normalSpread { values += [normalValue - spread, normalValue + spread] }
        else if let normalValue { values.append(normalValue) }
        guard let low = values.min(), let high = values.max() else { return 0...100 }
        let padding = max(4, (high - low) * 0.18)
        return (low - padding)...(high + padding)
    }

    private func x(_ value: Double, width: CGFloat) -> CGFloat {
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0 else { return 0 }
        return width * CGFloat((value - bounds.lowerBound) / span)
    }

    // MARK: Chrome

    /// The band of ordinary outcomes for this date. Its width is the point: a
    /// year outside it was genuinely unusual, and one inside it wasn't, however
    /// far apart two such years look.
    @ViewBuilder private func usualBand(width: CGFloat) -> some View {
        if let normalValue, let spread = normalSpread, spread > 0 {
            let start = x(normalValue - spread, width: width)
            let end = x(normalValue + spread, width: width)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.06))
                .frame(width: max(2, end - start), height: 26)
                .offset(x: start, y: 30)
                .help("Two thirds of \(dateLabel)s land in this range.")
        }
    }

    private func axis(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.primary.opacity(0.12))
                .frame(width: width, height: 1).offset(y: 43)
            ForEach(ticks, id: \.self) { value in
                VStack(spacing: 2) {
                    Text("\(Int(value))°").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 5)
                }
                .offset(x: x(value, width: width) - 10, y: 26)
            }
            if let normalValue {
                Rectangle().fill(Color.primary.opacity(0.35))
                    .frame(width: 1.5, height: 26)
                    .offset(x: x(normalValue, width: width), y: 30)
                    .help("Usual \(mode == .high ? "high" : "low") for \(dateLabel): \(Int(normalValue.rounded()))°")
            }
        }
    }

    /// Round degree marks inside the range — enough to read position, not so many
    /// they compete with the year labels.
    private var ticks: [Double] {
        let span = bounds.upperBound - bounds.lowerBound
        let step: Double = span > 40 ? 10 : span > 18 ? 5 : 2
        let first = (bounds.lowerBound / step).rounded(.up) * step
        return stride(from: first, through: bounds.upperBound, by: step).map { $0 }
    }

    private func yearMarker(_ point: Point) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) {
                Circle()
                    .fill(point.reliable ? tempColor(point.value) : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(String(point.year)).font(.system(size: 10, weight: .medium).monospacedDigit())
                Text("\(Int(point.value.rounded()))°")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(width: 78, alignment: .leading)
        .help(help(point))
    }

    private func help(_ point: Point) -> String {
        var text = "\(point.year): \(mode == .high ? "high" : "low") \(Int(point.value.rounded()))°"
        if let precip = point.precip, precip >= 0.01 {
            text += ", \(WeatherAlmanac.inches(precip)) of rain"
        }
        if !point.reliable {
            text += ". The station only reported part of this day, so this is the extreme of the hours it saw."
        }
        return text
    }

    private func todayMarker(_ value: Double) -> some View {
        VStack(spacing: 1) {
            Text("today \(Int(value.rounded()))°")
                .font(.system(size: 10, weight: .semibold))
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 8)).foregroundStyle(.primary)
        }
        .frame(width: 60)
        .help("Today's forecast \(mode == .high ? "high" : "low").")
    }

    @ViewBuilder private var footnote: some View {
        HStack(spacing: 10) {
            if let normalValue {
                Text("Usual \(Int(normalValue.rounded()))°")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if normal.years > 0 {
                // NOT "\(normal.years) years of record" — that counts the years
                // in the ±7-day window the normal is pooled from, which near the
                // end of the archive is more years than hold this date. It read
                // as "4 years of record" beside three points, with nothing on
                // the card to explain the missing one.
                Text("shaded band = where two thirds of the surrounding fortnight land · "
                     + "\(points.count) \(points.count == 1 ? "year holds" : "years hold") this date")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if points.contains(where: { !$0.reliable }) {
                Text("grey = partial day").font(.caption2).foregroundStyle(.tertiary)
            }
        }
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
