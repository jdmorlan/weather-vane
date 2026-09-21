//
//  CardVisuals.swift  (tvOS)
//
//  The pictures on the cards.
//
//  WHY THESE ARE NOT THE MAC'S. `ComfortGauge`, `DaylightArc` and `WindDial`
//  already exist over there and do the same jobs. What does not survive the move
//  is their SIZE: they are built in `.caption` and `.callout`, on strokes of one
//  and two points, for a card you read at arm's length. Scaled up they are a
//  hairline and a whisper; overridden font by font they become the Mac view with
//  a dozen exceptions, which is worse than either.
//
//  So the ARITHMETIC is the shared part and it is barely any — a fraction along
//  a scale, an angle from two timestamps — while the drawing is native to the
//  room it is in. Where a rule is genuinely shared it lives in WeatherKit
//  (`dewComfortTag`, the hazard ramp) rather than being restated here.
//

import SwiftUI
import WeatherKit

// MARK: - Comfort

/// The dew-point scale with your place on it.
///
/// A dew point is a number almost nobody holds a scale for — 63° means nothing
/// until you can see that it sits just past comfortable and a long way below
/// oppressive. The bands ARE the explanation, which is why this reads as a
/// picture with a marker rather than a figure with a caption.
struct ComfortScale: View {
    let dewPoint: Double
    var compact = false

    /// Ascending upper bounds. The same thresholds `WeatherInterpreter`
    /// describes in words, so the band you are in and the word it prints can
    /// never disagree.
    private static let zones: [(upper: Double, name: String, color: Color)] = [
        (55, "Dry",         .teal),
        (60, "Comfortable", .green),
        (65, "Sticky",      Color(red: 0.85, green: 0.78, blue: 0.35)),
        (70, "Muggy",       .orange),
        (75, "Oppressive",  Color(red: 0.85, green: 0.35, blue: 0.30)),
        (80, "Brutal",      Color(red: 0.70, green: 0.20, blue: 0.45)),
    ]
    private static let lower: Double = 40
    private static let upper: Double = 80

    private var fraction: Double {
        let clamped = min(Self.upper, max(Self.lower, dewPoint))
        return (clamped - Self.lower) / (Self.upper - Self.lower)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(Self.zones.indices, id: \.self) { i in
                            let lo = i == 0 ? Self.lower : Self.zones[i - 1].upper
                            let span = (Self.zones[i].upper - lo) / (Self.upper - Self.lower)
                            Self.zones[i].color.opacity(0.55)
                                .frame(width: max(2, w * span - 2))
                        }
                    }
                    .frame(height: compact ? 16 : 26)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                    // The marker rides ON the bands rather than under them: the
                    // question is which band you are in, and a pointer below the
                    // bar makes you draw the line yourself.
                    Capsule().fill(.white)
                        .frame(width: compact ? 5 : 7, height: compact ? 26 : 40)
                        .shadow(color: .black.opacity(0.8), radius: 3)
                        .offset(x: max(0, min(w - 7, w * fraction - 3.5)))
                }
                if !compact {
                    HStack {
                        Text("\(Int(Self.lower))°").font(.system(size: 19))
                        Spacer()
                        Text("\(Int(Self.upper))°").font(.system(size: 19))
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(height: compact ? 30 : 74)
    }
}

// MARK: - Sun

/// The day's arc, with the sun where it actually is.
///
/// The one thing a sunset time cannot tell you is how much of the day is left,
/// and that is the whole question on an afternoon that is getting dark early.
/// Position along the arc answers it before any number is read.
struct SunArc: View {
    let sunrise: Date?
    let sunset: Date?
    let now: Date
    var compact = false

    /// 0 at sunrise, 1 at sunset, nil when the sun is down — which is a real
    /// answer and draws as an arc with no sun on it rather than one pinned to
    /// an end.
    private var progress: Double? {
        guard let sunrise, let sunset, sunset > sunrise else { return nil }
        let span = sunset.timeIntervalSince(sunrise)
        let elapsed = now.timeIntervalSince(sunrise)
        guard elapsed >= 0, elapsed <= span else { return nil }
        return elapsed / span
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let r = min(w / 2, h - (compact ? 6 : 14))
            let c = CGPoint(x: w / 2, y: h - (compact ? 2 : 8))
            ZStack {
                // The path the sun takes, dashed where it has not been yet.
                Path { p in
                    p.addArc(center: c, radius: r, startAngle: .degrees(180),
                             endAngle: .degrees(0), clockwise: false)
                }
                .stroke(.white.opacity(0.22),
                        style: StrokeStyle(lineWidth: compact ? 3 : 4, lineCap: .round,
                                           dash: [compact ? 3 : 5, compact ? 6 : 10]))

                if let progress {
                    // The travelled part, solid, so how far through the day you
                    // are is a length and not an inference.
                    Path { p in
                        // TWO CONVENTIONS, AND THEY ARE NOT THE SAME ONE.
                        // `addArc` measures with y pointing DOWN, so the top of
                        // the circle is 270° and sunrise→sunset runs 180 → 360.
                        // The sun's own position below is computed the other way
                        // (y flipped by hand, top at 90°). Subtracting here —
                        // correct for the sun — sent the stroke the long way
                        // round and drew a loop beneath the horizon.
                        p.addArc(center: c, radius: r, startAngle: .degrees(180),
                                 endAngle: .degrees(180 + 180 * progress), clockwise: false)
                    }
                    .stroke(LinearGradient(colors: [Color(red: 1, green: 0.72, blue: 0.3),
                                                    Color(red: 1, green: 0.55, blue: 0.2)],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: compact ? 4 : 6, lineCap: .round))

                    let angle = (180 - 180 * progress) * .pi / 180
                    Circle()
                        .fill(LinearGradient(colors: [Color(red: 1, green: 0.88, blue: 0.45),
                                                      Color(red: 1, green: 0.6, blue: 0.22)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: compact ? 16 : 26, height: compact ? 16 : 26)
                        .shadow(color: Color(red: 1, green: 0.6, blue: 0.2).opacity(0.7),
                                radius: compact ? 6 : 12)
                        .position(x: c.x + r * cos(angle), y: c.y - r * sin(angle))
                }

                // The horizon, so the arc has something to rise from.
                Path { p in
                    p.move(to: CGPoint(x: c.x - r, y: c.y))
                    p.addLine(to: CGPoint(x: c.x + r, y: c.y))
                }
                .stroke(.white.opacity(0.28), lineWidth: 1.5)
            }
        }
    }
}

// MARK: - Wind

/// Which way it is coming FROM, which is the meteorological convention and the
/// one thing about wind direction that is easy to get backwards.
struct WindCompass: View {
    /// Degrees true the wind blows FROM.
    let direction: Double?
    var compact = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let r = side / 2 - (compact ? 4 : 8)
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: compact ? 2 : 3)
                    .frame(width: r * 2, height: r * 2)
                ForEach(0..<8) { i in
                    Rectangle().fill(.white.opacity(i % 2 == 0 ? 0.35 : 0.16))
                        .frame(width: 2, height: i % 2 == 0 ? (compact ? 8 : 12) : (compact ? 5 : 7))
                        .offset(y: -r + (compact ? 4 : 6))
                        .rotationEffect(.degrees(Double(i) * 45))
                }
                Text("N").font(.system(size: compact ? 13 : 17, weight: .bold))
                    .foregroundStyle(.red.opacity(0.85))
                    .position(x: c.x, y: c.y - r - (compact ? 2 : 4))
                if let direction {
                    // Points the way the AIR goes — the arrow leaves the
                    // direction it came from — because an arrow drawn INTO the
                    // circle reads as pointing at you.
                    Image(systemName: "arrow.down")
                        .font(.system(size: compact ? 26 : 44, weight: .semibold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(direction))
                        .position(c)
                }
            }
        }
    }
}

// MARK: - Pressure

/// Where the barometer sits in the band this station actually lives in, and
/// which way it is going. The absolute number means little; the position and the
/// direction are the whole signal.
struct PressureBar: View {
    let value: Double
    let trend: String
    var compact = false

    private static let lower = 29.4
    private static let upper = 30.6

    private var fraction: Double {
        let clamped = min(Self.upper, max(Self.lower, value))
        return (clamped - Self.lower) / (Self.upper - Self.lower)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                LinearGradient(colors: [Color(red: 0.35, green: 0.45, blue: 0.75),
                                        Color(red: 0.45, green: 0.55, blue: 0.60),
                                        Color(red: 0.85, green: 0.72, blue: 0.35)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: compact ? 14 : 22)
                    .opacity(0.5)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Capsule().fill(.white)
                    .frame(width: compact ? 5 : 7, height: compact ? 24 : 36)
                    .shadow(color: .black.opacity(0.8), radius: 3)
                    .offset(x: max(0, min(w - 7, w * fraction - 3.5)))
            }
        }
        .frame(height: compact ? 26 : 40)
    }
}

extension String {
    /// The arrow for a pressure trend, or none when it is steady — a sideways
    /// arrow is a symbol that says "nothing is happening" loudly.
    var trendSymbol: String? {
        switch self {
        case "falling": return "arrow.down.right"
        case "rising":  return "arrow.up.right"
        default:        return nil
        }
    }
}

// MARK: - Sparklines

/// The next twelve hours as a shape. Temperature is a LINE rather than twelve
/// figures because on a face the only question is which way it is going.
struct HourSparkline: View {
    let hours: [HourSlice]

    var body: some View {
        GeometryReader { geo in
            let temps = hours.compactMap(\.temperature)
            if let lo = temps.min(), let hi = temps.max(), hi > lo, hours.count > 1 {
                let w = geo.size.width, h = geo.size.height
                let points = hours.enumerated().compactMap { index, hour -> CGPoint? in
                    guard let t = hour.temperature else { return nil }
                    return CGPoint(x: w * Double(index) / Double(hours.count - 1),
                                   y: h - h * (t - lo) / (hi - lo))
                }
                ZStack(alignment: .bottomLeading) {
                    // Filled under the line: the area is what makes a shallow
                    // slope legible at a glance on a small face.
                    Path { p in
                        guard let first = points.first else { return }
                        p.move(to: CGPoint(x: first.x, y: h))
                        for point in points { p.addLine(to: point) }
                        p.addLine(to: CGPoint(x: points.last?.x ?? w, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [.orange.opacity(0.35), .orange.opacity(0.03)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        guard let first = points.first else { return }
                        p.move(to: first)
                        for point in points.dropFirst() { p.addLine(to: point) }
                    }
                    .stroke(.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round,
                                                        lineJoin: .round))
                    // Any hour with a real chance of rain, marked. The shape says
                    // temperature; these say whether to care about the shape.
                    ForEach(Array(hours.enumerated()), id: \.offset) { index, hour in
                        if (hour.precipProbability ?? 0) >= 40, index < points.count {
                            Circle().fill(.cyan)
                                .frame(width: 7, height: 7)
                                .position(x: points[index].x, y: h - 4)
                        }
                    }
                }
            }
        }
    }
}

/// Five days as paired high/low bars on one scale, so a cooling trend is a slope
/// rather than ten numbers to compare in your head.
struct DaySparkline: View {
    let days: [DayNote]

    var body: some View {
        GeometryReader { geo in
            let values = days.flatMap { [$0.high, $0.low].compactMap { $0 } }
            if let lo = values.min(), let hi = values.max(), hi > lo {
                let h = geo.size.height
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        VStack(spacing: 2) {
                            // One bar spanning low to high rather than two bars:
                            // the SPREAD is the day, and two bars invite reading
                            // them as separate quantities.
                            Capsule()
                                .fill(LinearGradient(colors: [.orange.opacity(0.9),
                                                              .blue.opacity(0.7)],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(width: 10,
                                       height: max(6, h * (((day.high ?? lo) - (day.low ?? lo))
                                                           / (hi - lo))))
                                .offset(y: -h * (((day.low ?? lo) - lo) / (hi - lo)))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
        }
    }
}

/// What has fallen against what is still expected. Two lengths on one scale,
/// because "0.4 so far, 1.2 expected" is a ratio and a ratio wants a picture.
struct RainMeter: View {
    let today: Double
    let expected: Double

    var body: some View {
        GeometryReader { geo in
            let total = max(0.01, max(today, today + expected))
            let w = geo.size.width
            VStack(alignment: .leading, spacing: 8) {
                Spacer(minLength: 0)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white.opacity(0.10))
                        .frame(height: 22)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: [.cyan.opacity(0.85), .blue.opacity(0.85)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, w * today / total), height: 22)
                    if expected > 0 {
                        // Where it is expected to reach, as a line rather than a
                        // second bar — it has not happened yet and must not look
                        // like it has.
                        Rectangle().fill(.cyan.opacity(0.8))
                            .frame(width: 3, height: 34)
                            .offset(x: min(w - 3, w * (today + expected) / total - 1.5))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Radar age

/// How old a radar frame is, in words.
///
/// The loop walks back through fifty minutes of scans, so the frame on screen is
/// usually NOT the newest one — and "2:05 PM" tells you nothing about that
/// without arithmetic you should not have to do from a sofa. Minutes ago is the
/// form the question is asked in: how far has this already moved.
enum RadarAge {
    static func describe(_ time: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(time)
        // A future stamp means clock skew between here and the tile service, not
        // a forecast. Calling it "now" is the honest rounding.
        guard seconds > 30 else { return "now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
    }
}
