//
//  WeatherFacing.swift  (macOS)
//
//  EGOCENTRIC weather. Every weather product is issued north-up — the polygon, the
//  radar sweep, "wind out of the SW" — and that's correct for the issuer, who is
//  describing a piece of the earth. It is the wrong frame for a person standing in
//  the yard trying to work out whether the thing is coming at them. That person is
//  not north-up. They're facing whichever way they're facing.
//
//  The seam is this: FACING IS AN INPUT, NOT A SENSOR. One number — true degrees
//  you're looking toward — and every relative rendering reads it without caring
//  where it came from. A phone will one day feed it from the magnetometer. A Mac
//  can't (no Mac has one; `CLLocationManager.headingAvailable()` is false on all of
//  them), and doesn't need to: a Mac sits in a fixed spot, and you know perfectly
//  well which way the porch faces. So on the Mac the facing is STATED, once, and
//  then it's just as good an input as a sensed one — better, since it doesn't drift.
//
//  Nothing here knows about wind specifically. It converts bearings into what's in
//  front of you, and says it in body words.
//

import SwiftUI

enum Compass {
    static let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                         "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    /// The eight a person actually says out loud when stating which way they face.
    static let cardinals = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    static func degrees(_ cardinal: String) -> Double? {
        points.firstIndex(of: cardinal.uppercased()).map { Double($0) * 22.5 }
    }

    static func cardinal(_ degrees: Double) -> String {
        points[Int((normalize(degrees) / 22.5).rounded()) % 16]
    }

    /// Facings are stated, not measured, so they land on the 16 points people actually
    /// say. It also makes the ring feel detented instead of greasy.
    static func snap(_ degrees: Double) -> Double {
        normalize((normalize(degrees) / 22.5).rounded() * 22.5)
    }

    /// The same angle expressed as a turn: -180…180, so "how far did it move" doesn't
    /// read as 359° when it moved one degree backwards.
    static func signed(_ degrees: Double) -> Double {
        let d = normalize(degrees)
        return d > 180 ? d - 360 : d
    }

    static func normalize(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    /// Where `bearing` sits once you turn to face `facing`: 0 = dead ahead, 90 = hard
    /// right, 180 = behind. This is the whole conversion, and everything below is
    /// vocabulary on top of it.
    static func relative(_ bearing: Double, facing: Double) -> Double {
        normalize(bearing - facing)
    }

    /// Which side, in body words. The clock-face alternative was tempting and wrong:
    /// "at your two o'clock" is precise and nobody feels it.
    static func side(_ relative: Double) -> String {
        switch normalize(relative) {
        case ..<22.5:   return "straight ahead"
        case ..<67.5:   return "ahead and to your right"
        case ..<112.5:  return "off your right shoulder"
        case ..<157.5:  return "behind you to the right"
        case ..<202.5:  return "directly behind you"
        case ..<247.5:  return "behind you to the left"
        case ..<292.5:  return "off your left shoulder"
        case ..<337.5:  return "ahead and to your left"
        default:        return "straight ahead"
        }
    }

    /// The wind is the one case where the body word beats the position word, because
    /// you feel a wind rather than see it — "in your face" is a fact about your skin.
    /// `from` is the meteorological bearing (where it BLOWS FROM).
    static func windFeel(from: Double, facing: Double) -> String {
        switch normalize(relative(from, facing: facing)) {
        case ..<30:   return "straight into your face"
        case ..<75:   return "into your right cheek"
        case ..<105:  return "across you, right to left"
        case ..<150:  return "over your right shoulder"
        case ..<210:  return "at your back"
        case ..<255:  return "over your left shoulder"
        case ..<285:  return "across you, left to right"
        case ..<330:  return "into your left cheek"
        default:      return "straight into your face"
        }
    }
}


/// The wind as it meets YOU — one self-contained instrument, no caption alongside.
///
/// The ring turns so the way you're looking is up, so the arrow's position on screen IS
/// where the wind is in the room. N stays marked in red, because the moment you talk to
/// anyone else about the weather you're back in the issued frame and the reading has to
/// be checkable. The number lives in the middle, where you look first; the direction is
/// the picture, so it doesn't also need saying in words.
///
/// You set the facing by pointing at the ring — click the compass in the direction
/// you're looking. That's the same gesture as turning a paper map to match the road,
/// which is exactly what this is.
struct WindDial: View {
    /// Meteorological bearing the wind comes FROM, true degrees.
    let from: Double
    let speed: Double?
    let gust: Double?
    /// True degrees you're looking toward. nil = not stated; the dial stays north-up.
    let facing: Double?
    var size: CGFloat = 132
    /// Committed once on release, so turning the ring is one write however far it spins.
    var onFace: ((Double) -> Void)?

    @State private var draft: Double?
    /// Where the ring was grabbed — the cursor's bearing on screen, and the facing at
    /// that moment. A rotation is meaningless without them: you need to know what was
    /// under the finger to keep it there.
    @State private var grab: (angle: Double, facing: Double)?

    private var effective: Double { draft ?? facing ?? 0 }
    private var isOriented: Bool { facing != nil || draft != nil }

    var body: some View {
        VStack(spacing: 8) {
            dial
            caption
        }
        .frame(maxWidth: .infinity)
    }

    private var dial: some View {
        let r = size / 2
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.13), lineWidth: 1)
            Circle().stroke(Color.primary.opacity(0.06), lineWidth: 1).padding(11)

            // One rotation for everything in world bearings, so no mark does its own
            // arithmetic and adding a mark later costs nothing.
            ZStack {
                ForEach(Compass.points, id: \.self) { point in
                    let deg = Compass.degrees(point) ?? 0
                    let major = point.count <= 2
                    Group {
                        if major {
                            Text(point)
                                .font(.system(size: point == "N" ? 10 : 9,
                                              weight: point == "N" ? .bold : .medium))
                                .foregroundStyle(point == "N" ? Color.red.opacity(0.85)
                                                              : Color.secondary.opacity(0.7))
                        } else {
                            // The in-between points are ticks, not labels — they give the
                            // ring enough resolution to aim at without crowding it.
                            Rectangle().frame(width: 1, height: 3)
                                .foregroundStyle(Color.secondary.opacity(0.35))
                        }
                    }
                    .rotationEffect(.degrees(-(deg - effective)))
                    .offset(y: -(r - (major ? 6 : 4)))
                    .rotationEffect(.degrees(deg - effective))
                }
                windArrow(radius: r)
                    .rotationEffect(.degrees(Compass.normalize(from) - effective))
            }

            centerReadout
            facingMarker(radius: r)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        // The ring TURNS UNDER YOUR FINGER: whatever point of the compass you grab
        // stays under the cursor, exactly like turning a paper map to match the road.
        // The earlier version set the facing to wherever you pointed on screen, which
        // meant the top of the dial was permanently north and no drag could ever bring
        // S up to the marker — the one thing the gesture is for.
        //
        // A press that never moves is the other half: it faces you at whatever compass
        // point you clicked. One gesture, both readings of "set my direction".
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard let angle = screenAngle(g.location, r: r) else { return }
                    guard let grab else {
                        self.grab = (angle: angle, facing: effective)
                        return
                    }
                    draft = Compass.snap(grab.facing - (angle - grab.angle))
                }
                .onEnded { g in
                    if let d = draft {
                        onFace?(d)
                    } else if let grab, let angle = screenAngle(g.location, r: r),
                              abs(Compass.signed(angle - grab.angle)) < 1 {
                        // Never moved: the compass point under the cursor is where you
                        // want to be looking. Screen angle + current facing = its bearing.
                        onFace?(Compass.snap(angle + grab.facing))
                    }
                    draft = nil
                    grab = nil
                }
        )
        .help(isOriented
              ? "Facing \(Compass.cardinal(effective)) — drag the ring to turn it, or click a point to face it"
              : "Drag the ring until the way you're facing is under the marker")
    }

    /// The cursor's angle from the top of the dial, clockwise. nil in the middle —
    /// that's the readout, and aiming at it names no direction.
    private func screenAngle(_ p: CGPoint, r: CGFloat) -> Double? {
        let dx = Double(p.x - size / 2), dy = Double(p.y - size / 2)
        guard (dx * dx + dy * dy).squareRoot() > Double(r) * 0.34 else { return nil }
        return Compass.normalize(atan2(dx, -dy) * 180 / Double.pi)
    }

    /// The number you actually want, where you look first.
    private var centerReadout: some View {
        VStack(spacing: 0) {
            Text(speed.map { "\(Int($0.rounded()))" } ?? "—")
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text("MPH").font(.system(size: 8, weight: .semibold)).tracking(1.2)
                .foregroundStyle(.secondary)
            // A gust only earns a line when it's meaningfully above the average —
            // "gusting 8 over a 7 mph wind" is noise.
            if let gust, let avg = speed, gust - avg >= 4 {
                Text("gusts \(Int(gust.rounded()))")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
    }

    /// You, at the top of the dial, looking up the page. A notch rather than a figure:
    /// it marks the direction, and the whole ring below it is the thing that turned.
    private func facingMarker(radius r: CGFloat) -> some View {
        Image(systemName: "triangle.fill")
            .font(.system(size: 7))
            .foregroundStyle(isOriented ? Color.primary.opacity(0.7)
                                        : Color.secondary.opacity(0.35))
            .offset(y: -(r + 6))
    }

    /// An arrow flying downwind through the ring: it enters on the side the wind comes
    /// FROM and points at you. Thickens as the wind picks up, so strength reads before
    /// the number is even parsed.
    private func windArrow(radius r: CGFloat) -> some View {
        let strength = min(1, max(0, (speed ?? 0) / 25))
        return VStack(spacing: 0) {
            Rectangle().frame(width: 1.5 + 1.5 * strength, height: r * 0.28)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 8 + 3 * strength))
        }
        .foregroundStyle(Color.accentColor.opacity(0.5 + 0.5 * strength))
        .offset(y: -(r * 0.66))
    }

    /// The one thing the picture can't say: what it does to you. Everything else the
    /// dial already shows, so this stays a single line and never repeats the numbers.
    @ViewBuilder private var caption: some View {
        if isOriented {
            // The phrase is stored lowercase because it reads mid-sentence elsewhere
            // ("the wind is at your back"); it's only a sentence here.
            let feel = Compass.windFeel(from: from, facing: effective)
            Text(feel.prefix(1).uppercased() + feel.dropFirst())
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Click the ring to say which way you face")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
