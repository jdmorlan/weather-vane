//
//  DetailCharts.swift  (tvOS)
//
//  The full-size pictures, for pages that have a whole screen to spend.
//
//  A card face has room for a shape and a number. A page has room for the shape
//  WITH its axis, its labels, and the second series that explains it — which is
//  the entire reason the deck is worth having. These are not the faces scaled
//  up; they show things the faces deliberately leave out.
//

import SwiftUI
import WeatherKit

// MARK: - Hours

/// Twelve hours: temperature as a line, rain as bars beneath it, gusts marked.
///
/// THREE SERIES ON ONE CLOCK, because the question is never about one of them.
/// "Will it rain before it cools off" and "does the wind pick up with the front"
/// are both comparisons ACROSS series, and three separate charts make you hold
/// the x-axis in your head to answer either.
struct HourChart: View {
    let hours: [HourSlice]

    var body: some View {
        GeometryReader { geo in
            let temps = hours.compactMap(\.temperature)
            if let lo = temps.min(), let hi = temps.max(), hours.count > 1 {
                let w = geo.size.width
                let plot = geo.size.height - 92          // room for the labels
                let span = max(1, hi - lo)
                let step = w / CGFloat(hours.count)
                let x = { (i: Int) in step * (CGFloat(i) + 0.5) }
                let y = { (t: Double) in plot - (plot - 40) * ((t - lo) / span) - 12 }

                ZStack(alignment: .topLeading) {
                    // Rain first, underneath everything: it is context for the
                    // line, not a competitor to it.
                    ForEach(Array(hours.enumerated()), id: \.offset) { i, hour in
                        if let p = hour.precipProbability, p >= 5 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.cyan.opacity(0.28))
                                .frame(width: step * 0.5, height: plot * CGFloat(p / 100) * 0.8)
                                .position(x: x(i), y: plot - plot * CGFloat(p / 100) * 0.4)
                        }
                    }

                    Path { p in
                        for (i, hour) in hours.enumerated() {
                            guard let t = hour.temperature else { continue }
                            let point = CGPoint(x: x(i), y: y(t))
                            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                        }
                    }
                    .stroke(.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round,
                                                        lineJoin: .round))

                    ForEach(Array(hours.enumerated()), id: \.offset) { i, hour in
                        if let t = hour.temperature {
                            Circle().fill(.orange).frame(width: 10, height: 10)
                                .position(x: x(i), y: y(t))
                            Text("\(Int(t.rounded()))°")
                                .font(.system(size: 24, weight: .medium).monospacedDigit())
                                .position(x: x(i), y: y(t) - 28)
                        }
                    }

                    // The labels, on their own band under the plot.
                    ForEach(Array(hours.enumerated()), id: \.offset) { i, hour in
                        VStack(spacing: 4) {
                            // Gusts only where they are worth reading — a row of
                            // single digits is a row nobody scans.
                            Text(hour.windGust.map { $0 >= 18 ? String(format: "%.0f", $0) : "" } ?? "")
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(.orange)
                            Text(hour.precipProbability.map { $0 >= 20 ? "\(Int($0))%" : "" } ?? "")
                                .font(.system(size: 21)).foregroundStyle(.cyan)
                            Text(hour.clock)
                                .font(.system(size: 22)).foregroundStyle(.secondary)
                        }
                        .frame(width: step)
                        .position(x: x(i), y: plot + 46)
                    }
                }
            }
        }
    }
}

// MARK: - Days

/// Each day's low-to-high span on one shared scale, so a cooling trend is a
/// staircase rather than sixteen numbers to compare in your head.
struct DayChart: View {
    let days: [DayNote]

    var body: some View {
        GeometryReader { geo in
            let values = days.flatMap { [$0.high, $0.low].compactMap { $0 } }
            if let lo = values.min(), let hi = values.max(), hi > lo {
                // 190, not 110. Below the bar sit a low label, an icon, two
                // lines of rain and a weekday — about 150 points of stack that
                // the old reservation did not account for, so the column ran off
                // the bottom of its frame and the weekday labels landed on top
                // of the sentence underneath the chart.
                let plot = geo.size.height - 190
                let span = hi - lo
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        VStack(spacing: 8) {
                            Text(day.high.map { "\(Int($0.rounded()))°" } ?? "—")
                                .font(.system(size: 28, weight: .medium).monospacedDigit())
                            ZStack(alignment: .bottom) {
                                Capsule().fill(.white.opacity(0.06))
                                    .frame(width: 22, height: plot)
                                Capsule()
                                    .fill(LinearGradient(colors: [.orange, .blue.opacity(0.8)],
                                                         startPoint: .top, endPoint: .bottom))
                                    .frame(width: 22,
                                           height: max(10, plot * (((day.high ?? lo) - (day.low ?? lo)) / span)))
                                    .offset(y: -plot * (((day.low ?? lo) - lo) / span))
                            }
                            .frame(height: plot)
                            Text(day.low.map { "\(Int($0.rounded()))°" } ?? "—")
                                .font(.system(size: 24).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: WeatherSymbol.name(day.icon))
                                .font(.system(size: 26)).symbolRenderingMode(.multicolor)
                            // PROBABILITY AND AMOUNT TOGETHER, never one alone.
                            // "20%" is the same label on a day that might drop a
                            // hundredth and a day that might drop an inch, and
                            // those are not the same day. The chance is the
                            // smaller half because the amount is what you plan
                            // around once you know it is coming at all.
                            VStack(spacing: 1) {
                                if let p = day.precipProbability, p >= 20 {
                                    // Three states, and they are different. A
                                    // real amount prints. Zero prints as
                                    // "nothing" — a 20% chance of 0.00" is a day
                                    // to ignore, and saying so plainly beats a
                                    // row of zeroes that look like missing data.
                                    // Beyond the hourly forecast there is no
                                    // amount at all, and that prints as the
                                    // chance alone rather than inventing one.
                                    if let total = day.precipTotal, total >= 0.005 {
                                        Text(WeatherAlmanac.inches(total))
                                            .font(.system(size: 23, weight: .medium).monospacedDigit())
                                            .foregroundStyle(.cyan)
                                    } else if day.precipTotal != nil {
                                        Text("nothing")
                                            .font(.system(size: 21))
                                            .foregroundStyle(.cyan.opacity(0.55))
                                    } else {
                                        Text(" ").font(.system(size: 23))
                                    }
                                    Text("\(Int(p))%")
                                        .font(.system(size: 19))
                                        .foregroundStyle(.cyan.opacity(0.7))
                                } else {
                                    Text(" ").font(.system(size: 23))
                                    Text(" ").font(.system(size: 19))
                                }
                            }
                            Text(index == 0 ? "Today" : day.weekday)
                                .font(.system(size: 23, weight: index == 0 ? .semibold : .regular))
                                .foregroundStyle(index == 0 ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

// MARK: - Pressure

/// The barometer's coming SHAPE, which is the half of pressure that predicts
/// anything. A single reading says almost nothing; the slope over the next
/// twelve hours is the whole signal, and `HourSlice` has carried it all along
/// without anything drawing it.
struct PressureCurve: View {
    let hours: [HourSlice]
    /// The station's reading right now, drawn as the first point.
    ///
    /// Without it the curve starts at the first FORECAST hour, which can sit a
    /// tenth away from the number printed directly above it — so the page read
    /// "30.20, falling" over a line starting at 30.10 and climbing, and looked
    /// broken. Anchoring to the live reading makes the picture continue the
    /// headline instead of contradicting it.
    let current: Double?

    private var points: [(label: String, value: Double)] {
        var out: [(String, Double)] = []
        if let current { out.append(("now", current)) }
        out += hours.compactMap { hour in hour.pressure.map { (hour.clock, $0) } }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let values = points.map(\.value)
            if let lo = values.min(), let hi = values.max(), values.count > 1 {
                let w = geo.size.width
                let plot = geo.size.height - 46
                // A GENEROUS floor on the span. Forecast pressure is quantised
                // to a hundredth, so a span of 0.08 turned two adjacent values
                // into a staircase across the whole plot — drama manufactured
                // out of rounding. 0.30 is about what a real storm drop looks
                // like over this window, so anything smaller draws small.
                let span = max(0.30, hi - lo)
                let step = w / CGFloat(points.count)
                let x = { (i: Int) in step * (CGFloat(i) + 0.5) }
                let y = { (p: Double) in plot - (plot - 30) * ((p - lo) / span) - 10 }

                ZStack(alignment: .topLeading) {
                    Path { p in
                        for (i, entry) in points.enumerated() {
                            let point = CGPoint(x: x(i), y: y(entry.value))
                            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                        }
                    }
                    .stroke(LinearGradient(colors: [Color(red: 0.45, green: 0.6, blue: 0.95),
                                                    Color(red: 0.95, green: 0.65, blue: 0.3)],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    ForEach(Array(points.enumerated()), id: \.offset) { i, entry in
                        if i == 0 || i % 3 == 0 {
                            Text(String(format: "%.2f", entry.value))
                                .font(.system(size: 21).monospacedDigit())
                                .foregroundStyle(i == 0 ? .primary : .secondary)
                                .position(x: x(i), y: y(entry.value) - 26)
                            Text(entry.label)
                                .font(.system(size: 21)).foregroundStyle(.tertiary)
                                .position(x: x(i), y: plot + 26)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Rain windows

/// When it is expected to rain, as blocks on a clock rather than a sentence.
/// "2pm–5pm, heaviest around 3" is a shape, and a shape drawn is a shape you do
/// not have to parse.
struct RainWindowChart: View {
    let windows: [RainWindow]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                HStack(spacing: 22) {
                    Text("\(Self.clock(window.startHour))–\(Self.clock(window.endHour))")
                        .font(.system(size: 28, weight: .medium).monospacedDigit())
                        .frame(width: 220, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white.opacity(0.08)).frame(height: 30)
                            RoundedRectangle(cornerRadius: 6)
                                .fill(LinearGradient(colors: [.cyan.opacity(0.85),
                                                              .blue.opacity(0.85)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(8, geo.size.width
                                                  * CGFloat(window.peakProbability / 100)),
                                       height: 30)
                        }
                    }
                    .frame(height: 30)
                    Text("\(Int(window.peakProbability))%")
                        .font(.system(size: 26).monospacedDigit())
                        .foregroundStyle(.cyan).frame(width: 90, alignment: .trailing)
                    Text(WeatherAlmanac.inches(window.accum))
                        .font(.system(size: 26).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
                }
            }
        }
    }

    private static func clock(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h)\(hour < 12 || hour == 24 ? "am" : "pm")"
    }
}
