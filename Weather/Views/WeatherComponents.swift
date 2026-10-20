//
//  WeatherComponents.swift  (macOS)
//
//  Visual instruments for the Weather surface — the "informative without being wordy"
//  pieces. A gauge shows where today sits on a scale AND passively teaches the scale's
//  bounds (what counts as muggy vs oppressive). A daylight arc shows the day's shape.
//

import SwiftUI
import WeatherKit

// `dewBandColor` lives in HourTimeline.swift, which the TV compiles too.

struct GaugeZone: Identifiable {
    let id = UUID()
    let upper: Double        // inclusive upper bound of this band, in the gauge's units
    let label: String
    let color: Color
}

/// A horizontal scale with labeled comfort bands and a marker at the current value —
/// e.g. dew point (Dry → Oppressive) or feels-like (Cold → Dangerous). An optional
/// secondary marker shows a companion value (the actual temperature under feels-like).
struct ComfortGauge: View {
    let title: String
    let value: Double
    let valueLabel: String
    let range: ClosedRange<Double>
    let zones: [GaugeZone]              // ascending; last .upper should be range.upperBound
    var secondary: (value: Double, label: String)? = nil

    private func fraction(_ v: Double) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, v))
        return (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func segmentWidth(_ i: Int, _ total: CGFloat) -> CGFloat {
        let lower = i == 0 ? range.lowerBound : zones[i - 1].upper
        let frac = (zones[i].upper - lower) / (range.upperBound - range.lowerBound)
        return max(1, CGFloat(frac) * total - 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
                Spacer()
                if let s = secondary {
                    Text(s.label).font(.caption).foregroundStyle(.tertiary)
                }
                Text(valueLabel).font(.callout.weight(.semibold))
            }
            GeometryReader { geo in
                let w = geo.size.width
                VStack(alignment: .leading, spacing: 5) {
                    ZStack(alignment: .leading) {
                        HStack(spacing: 2) {
                            ForEach(zones.indices, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(zones[i].color.opacity(0.55))
                                    .frame(width: segmentWidth(i, w), height: 10)
                            }
                        }
                        if let s = secondary {
                            marker(filled: false).offset(x: fraction(s.value) * w - 1.5)
                        }
                        marker(filled: true).offset(x: fraction(value) * w - 1.5)
                    }
                    .frame(height: 10)
                    HStack(spacing: 2) {
                        ForEach(zones.indices, id: \.self) { i in
                            Text(zones[i].label)
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(width: segmentWidth(i, w))
                        }
                    }
                }
            }
            .frame(height: 28)
        }
    }

    private func marker(filled: Bool) -> some View {
        Capsule()
            .fill(filled ? Color.primary : Color.clear)
            .overlay(Capsule().stroke(Color.primary, lineWidth: filled ? 0 : 1.5))
            .frame(width: 3, height: 16)
            .shadow(color: .black.opacity(filled ? 0.25 : 0), radius: 1)
    }
}

/// A sun arc from sunrise to sunset with the current sun position, plus how much
/// daylight (and darkness) the day holds.
struct DaylightArc: View {
    let sunrise: Date?
    let sunset: Date?
    /// Next morning's sunrise, so an after-dark countdown has a target.
    var nextSunrise: Date? = nil
    let now: Date
    /// Station-local formatter for the endpoint times.
    let time: (Date?) -> String

    private var daylight: TimeInterval? {
        guard let sunrise, let sunset, sunset > sunrise else { return nil }
        return sunset.timeIntervalSince(sunrise)
    }

    private var fraction: Double {
        guard let sunrise, let daylight else { return 0 }
        return min(1, max(0, now.timeIntervalSince(sunrise) / daylight))
    }

    /// How much of the current phase is left: until sunset while it's day, until
    /// sunrise while it's night. (icon, phrase) — nil if we can't tell.
    private var remaining: (icon: String, text: String)? {
        guard let sunrise, let sunset else { return nil }
        if now < sunrise {
            return ("sunrise.fill", "\(shortDuration(sunrise.timeIntervalSince(now))) until sunrise")
        }
        if now < sunset {
            return ("sunset.fill", "\(shortDuration(sunset.timeIntervalSince(now))) until sunset")
        }
        if let next = nextSunrise, next > now {
            return ("sunrise.fill", "\(shortDuration(next.timeIntervalSince(now))) until sunrise")
        }
        return nil
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600, m = (Int(seconds) % 3600) / 60
        return "\(h)h \(m)m"
    }

    /// Like `duration` but drops a leading "0h" (e.g. "42m", "3h 12m").
    private func shortDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600, m = (Int(seconds) % 3600) / 60
        return h == 0 ? "\(m)m" : "\(h)h \(m)m"
    }

    var body: some View {
        VStack(spacing: 10) {
            if let remaining {
                HStack(spacing: 7) {
                    Image(systemName: remaining.icon).foregroundStyle(.orange)
                    Text(remaining.text).font(.title3.weight(.semibold))
                }
            }
            if let daylight {
                HStack(spacing: 6) {
                    Text("\(duration(daylight)) of daylight").font(.callout).foregroundStyle(.secondary)
                    Text("· \(duration(86_400 - daylight)) of darkness")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let pad: CGFloat = 20
                let baseY = h - 6
                let r = min((w - 2 * pad) / 2, baseY - 10)
                let cx = w / 2
                ZStack {
                    arc(cx: cx, cy: baseY, r: r, from: 0, to: 1)
                        .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                        .foregroundStyle(.secondary.opacity(0.4))
                    arc(cx: cx, cy: baseY, r: r, from: 0, to: fraction)
                        .stroke(LinearGradient(colors: [.orange.opacity(0.5), .yellow],
                                               startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    Path { p in
                        p.move(to: CGPoint(x: cx - r - 8, y: baseY))
                        p.addLine(to: CGPoint(x: cx + r + 8, y: baseY))
                    }.stroke(.secondary.opacity(0.35), lineWidth: 1)

                    let pt = arcPoint(cx: cx, cy: baseY, r: r, f: fraction)
                    Circle().fill(.yellow)
                        .frame(width: 16, height: 16)
                        .shadow(color: .yellow.opacity(0.6), radius: 6)
                        .position(pt)

                    Text(time(sunrise)).font(.caption2).foregroundStyle(.secondary)
                        .position(x: cx - r, y: baseY + 14)
                    Text(time(sunset)).font(.caption2).foregroundStyle(.secondary)
                        .position(x: cx + r, y: baseY + 14)
                }
            }
            .frame(height: 96)
        }
        .frame(maxWidth: .infinity)
    }

    private func arc(cx: CGFloat, cy: CGFloat, r: CGFloat, from: Double, to: Double) -> Path {
        Path { p in
            p.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                     startAngle: .degrees(180 + 180 * from),
                     endAngle: .degrees(180 + 180 * to),
                     clockwise: false)
        }
    }

    private func arcPoint(cx: CGFloat, cy: CGFloat, r: CGFloat, f: Double) -> CGPoint {
        let theta = Double.pi + Double.pi * f
        return CGPoint(x: cx + r * CGFloat(cos(theta)), y: cy + r * CGFloat(sin(theta)))
    }
}

// MARK: - Empty states inside the card scroll

extension View {
    /// Give a `ContentUnavailableView` room to centre itself in.
    ///
    /// WHY IT NEEDS SAYING. `ContentUnavailableView` centres its content within
    /// ITS OWN bounds, and the card scroll is a `LazyVStack(alignment: .leading)`
    /// — which hands every child its intrinsic size. So an empty state took the
    /// width of its own longest line and the height of its own three elements,
    /// and rendered exactly as it was asked to: shoved against the left edge,
    /// pinned to the top, with the rest of the column empty beneath it. It read
    /// as a layout bug because it looked like one; the view was centring
    /// perfectly inside a box the size of its own text.
    ///
    /// `maxWidth: .infinity` gives it the column to centre across. `minHeight`
    /// rather than `maxHeight: .infinity` because inside a `ScrollView` the
    /// latter resolves to the ideal height and changes nothing.
    func emptyStatePanel(minHeight: CGFloat = 320) -> some View {
        frame(maxWidth: .infinity, minHeight: minHeight)
    }
}

// MARK: - Hover readout line

extension View {
    /// The line under a chart that names the hovered point. ONE LINE, ALWAYS
    /// THERE: it used to appear only while hovering — and wrap when it listed
    /// several years — so every card grew under the pointer and the page
    /// jumped. Now the space is reserved whether or not anything is hovered,
    /// and a long readout truncates instead of wrapping.
    func readoutLine() -> some View {
        self
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
    }
}
