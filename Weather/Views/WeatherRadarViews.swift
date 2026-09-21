//
//  WeatherRadarViews.swift  (macOS)
//
//  The scrub strip. The loop itself is drawn by `MapCanvas`, and everything about
//  HOW it is drawn lives in `FieldRenderer`.
//
//  WHAT THIS HAD TO BECOME, AND WHY THE OLD ONE COULD NOT. It used to be a row of
//  equal-width bars, one per scan — a perfectly good control for a loop where
//  every frame is the same KIND of thing. The loop is not that any more: it runs
//  from fifty minutes ago, through now, into an hour of extrapolation. Equal
//  widths cannot express that, for two separate reasons:
//
//   · THERE IS A SEAM. One of those bars is the boundary between what was
//     measured and what is guessed, and it has to be visible without reading a
//     legend. Equal bars make it exactly as prominent as every other gap.
//   · THE AXIS IS TIME, NOT COUNT. Scans go missing — the mosaic waits on a site
//     and the index skips five minutes. Equal widths silently close that gap and
//     draw an hour of weather as though it were continuous; a time axis shows the
//     hole, which is the truth.
//
//  So the strip is laid out in TIME, with a seam at now, and the future half is
//  drawn in a way that could never be mistaken for an observation. See
//  `Nowcast.swift` for what the future half actually is and what it cannot do.
//
//  THE HONESTY RULE, RESTATED FOR A LOOP THAT NOW HAS A FUTURE. Nothing to the
//  left of the seam is a claim about anything but what the radar saw. Nothing to
//  the right of it is a claim about anything but where those same returns would
//  be if they carried on exactly as they have been. The strip's job is to make
//  which side you are looking at impossible to get wrong.
//

import SwiftUI
import Combine
import MapKit
import WeatherKit

// MARK: - Timeline

struct RadarTimeline: View {
    let loop: [LoopFrame]
    let index: Int
    /// The last observation — where the seam goes.
    let nowIndex: Int
    let scrub: (Int) -> Void

    /// Room for the playhead to sit at either end without being clipped.
    private let inset: CGFloat = 5
    private let trackHeight: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Canvas { context, size in draw(in: &context, size: size) }

                playhead
                    .offset(x: x(of: index, width: width) - 1.5)
                    .animation(.easeOut(duration: 0.16), value: index)
            }
            .contentShape(Rectangle())
            .gesture(
                // A DRAG RATHER THAN A TAP PER BAR. Scrubbing a loop is a
                // continuous gesture — you sweep back and forth across the seam to
                // see what changes — and a row of individually tappable targets
                // makes that impossible however many of them there are.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if let hit = frame(nearest: value.location.x, width: width) {
                            scrub(hit)
                        }
                    }
            )
        }
        .frame(height: trackHeight)
    }

    private var playhead: some View {
        Capsule()
            .fill(Color.primary)
            .frame(width: 3, height: trackHeight)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 0)
    }

    // MARK: Laying it out in time

    private var span: (start: Date, end: Date)? {
        guard let first = loop.first?.time, let last = loop.last?.time,
              last > first else { return nil }
        return (first, last)
    }

    private func x(of frameIndex: Int, width: CGFloat) -> CGFloat {
        guard loop.indices.contains(frameIndex) else { return inset }
        return x(at: loop[frameIndex].time, width: width)
    }

    private func x(at time: Date, width: CGFloat) -> CGFloat {
        guard let span else { return inset }
        let usable = max(1, width - inset * 2)
        let fraction = time.timeIntervalSince(span.start) / span.end.timeIntervalSince(span.start)
        return inset + usable * CGFloat(min(1, max(0, fraction)))
    }

    private func frame(nearest pointer: CGFloat, width: CGFloat) -> Int? {
        guard !loop.isEmpty else { return nil }
        return loop.indices.min {
            abs(x(of: $0, width: width) - pointer) < abs(x(of: $1, width: width) - pointer)
        }
    }

    // MARK: Drawing it

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !loop.isEmpty, span != nil else { return }
        let width = size.width
        let midY = size.height / 2
        let seamX = x(of: min(nowIndex, loop.count - 1), width: width)

        let barHeight: CGFloat = 9
        let track = CGRect(x: inset, y: midY - barHeight / 2,
                           width: width - inset * 2, height: barHeight)

        // The observed half: a solid bed the ticks sit in.
        let observed = CGRect(x: track.minX, y: track.minY,
                              width: seamX - track.minX, height: track.height)
        context.fill(Path(roundedRect: observed, cornerRadius: barHeight / 2),
                     with: .color(.primary.opacity(0.16)))

        // The forecast half: HATCHED, not merely paler. A lighter shade of the
        // same bar reads as "less important"; a different texture reads as "a
        // different kind of thing", which is what it is.
        let future = CGRect(x: seamX, y: track.minY,
                            width: max(0, track.maxX - seamX), height: track.height)
        if future.width > 1 {
            context.fill(Path(roundedRect: future, cornerRadius: barHeight / 2),
                         with: .color(.primary.opacity(0.07)))
            context.drawLayer { layer in
                layer.clip(to: Path(roundedRect: future, cornerRadius: barHeight / 2))
                var hatch = Path()
                var offset = future.minX - future.height
                while offset < future.maxX {
                    hatch.move(to: CGPoint(x: offset, y: future.maxY))
                    hatch.addLine(to: CGPoint(x: offset + future.height, y: future.minY))
                    offset += 5
                }
                layer.stroke(hatch, with: .color(.primary.opacity(0.22)), lineWidth: 1)
            }
        }

        // One tick per frame, so the loop's real cadence — and any scan the mosaic
        // dropped — is visible as spacing rather than assumed to be even.
        for (position, frame) in loop.enumerated() {
            let tickX = x(of: position, width: width)
            let tick = Path(roundedRect: CGRect(x: tickX - 1, y: track.minY + 1.5,
                                                width: 2, height: track.height - 3),
                            cornerRadius: 1)
            context.fill(tick, with: .color(.primary.opacity(frame.isForecast ? 0.28 : 0.42)))
        }

        // THE SEAM. Full height, brighter than anything else on the strip, and it
        // is the only mark here that is not a frame.
        var seam = Path()
        seam.move(to: CGPoint(x: seamX, y: midY - size.height / 2 + 2))
        seam.addLine(to: CGPoint(x: seamX, y: midY + size.height / 2 - 2))
        context.stroke(seam, with: .color(.primary.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }
}

/// The bar the timeline lives in: what you are looking at, when it is, and — when
/// the loop has a future — what is carrying it there.
struct RadarScrubBar: View {
    let loop: [LoopFrame]
    let index: Int
    let nowIndex: Int
    let isPlaying: Bool
    let motion: StormMotion?
    /// Where to measure ground speed. Mercator stretch depends on latitude, and
    /// "near you" is the honest place to evaluate it.
    let latitude: Double?
    let togglePlay: () -> Void
    let scrub: (Int) -> Void

    private var current: LoopFrame? { loop.indices.contains(index) ? loop[index] : nil }
    private var hasForecast: Bool { loop.last?.isForecast ?? false }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])

            VStack(alignment: .leading, spacing: 3) {
                RadarTimeline(loop: loop, index: index, nowIndex: nowIndex, scrub: scrub)
                ends
            }

            readout
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    /// The axis labelled at both ends and at the seam. Three marks rather than a
    /// scale: the strip is for sweeping, not for reading a value off.
    private var ends: some View {
        HStack(spacing: 0) {
            Text(relative(loop.first?.time))
            Spacer(minLength: 4)
            // Only once there is something on the far side of it. Until a motion
            // estimate lands the seam IS the right-hand end, and labelling both
            // "now" reads as a rendering fault rather than as a loop that has no
            // future yet.
            if hasForecast {
                Text("now")
                Spacer(minLength: 4)
                Text(relative(loop.last?.time))
            } else {
                Text("now")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
    }

    /// Minutes either side of now, which is the question being asked. An absolute
    /// clock time is on the readout for the frame you are actually on.
    private func relative(_ time: Date?) -> String {
        guard let time, loop.indices.contains(nowIndex) else { return "" }
        let minutes = Int((time.timeIntervalSince(loop[nowIndex].time) / 60).rounded())
        if minutes == 0 { return "now" }
        return minutes > 0 ? "+\(minutes) min" : "\(minutes) min"
    }

    @ViewBuilder private var readout: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(current?.time ?? Date(), format: .dateTime.hour().minute())
                .font(.callout).monospacedDigit()

            // WHICH SIDE OF THE SEAM, IN WORDS. The strip says it graphically, but
            // the number above is a clock time either way and a clock time an hour
            // from now looks exactly like an observation. This is the line that
            // stops someone reading a forecast as a measurement.
            if let current, current.isForecast {
                Text("forecast")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let track {
                Text(track)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 62, alignment: .trailing)
    }

    /// What the extrapolation is built on, said plainly. It is also the fastest
    /// way to spot that the estimate has gone wrong — "SW 4 mph" under a squall
    /// line is visibly nonsense in a way a drawn forecast is not.
    private var track: String? {
        guard let motion, let latitude else { return nil }
        let (metresPerSecond, bearing) = motion.groundTrack(atLatitude: latitude)
        let mph = metresPerSecond * 2.236936
        guard mph >= 1 else { return "stationary" }
        return "\(StormMotion.compass(bearing)) \(Int(mph.rounded())) mph"
    }
}

// MARK: - Map objects

/// Carries the COLOUR rather than the level, so the one ramp in
/// `Hazard.tint(forLevel:)` is applied once at construction and both maps draw the
/// same warning identically.
final class HazardPolygon: MKPolygon {
    var tintColor: Color = .orange
}
