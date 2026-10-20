//
//  Charts.swift  (tvOS)
//
//  The full-width picture of the next twelve hours on Now. It carries its
//  axis, its labels, and the second series that explains it, because a whole
//  screen is there to spend. Forecast draws the Mac's `HourTimeline`.
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
