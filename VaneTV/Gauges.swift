//
//  Gauges.swift  (tvOS)
//
//  The small pictures beside the readings on Now.
//
//  WHY THESE ARE NOT THE MAC'S. `ComfortGauge`, `DaylightArc` and `WindDial`
//  already exist over there and do the same jobs. What does not survive the move
//  is their SIZE: they are built in `.caption` and `.callout`, on strokes of one
//  and two points, for a Mac card you read at arm's length. Scaled up they are a
//  hairline and a whisper; overridden font by font they become the Mac view with
//  a dozen exceptions, which is worse than either.
//
//  So the ARITHMETIC is the shared part and it is barely any — a fraction along
//  a scale, an angle — while the drawing is native to the
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
        (80, "Extreme",     Color(red: 0.70, green: 0.20, blue: 0.45)),
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

// MARK: - Rain

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
