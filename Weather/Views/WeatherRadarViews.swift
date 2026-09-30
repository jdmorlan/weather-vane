//
//  WeatherRadarViews.swift  (macOS)
//
//  The scrub strip. The loop itself is drawn by `MapCanvas`, and everything about
//  HOW it is drawn lives in `FieldRenderer`.
//
//  THE AXIS IS TIME, NOT COUNT. Volumes do not arrive on a fixed grid — a site
//  in clear-air mode scans every ten minutes, one in precipitation mode every
//  four or five, and a volume is sometimes skipped. Equal-width bars would
//  silently close those gaps and draw an uneven hour as though it were
//  continuous; a time axis shows the spacing, which is the truth.
//
//  EVERY FRAME IS A MEASUREMENT. The strip used to carry a hatched "forecast"
//  half after the newest scan — the newest picture slid along a motion vector.
//  It came out with the extrapolation itself (see `RadarLoop.swift`), so the
//  right-hand end of the strip is simply the newest thing the radar saw.
//

import SwiftUI
import Combine
import MapKit
import WeatherKit

// MARK: - Timeline

struct RadarTimeline: View {
    let loop: [RadarFrame]
    let index: Int
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
                // continuous gesture — you sweep back and forth to see what
                // changes — and a row of individually tappable targets makes
                // that impossible however many of them there are.
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

        let barHeight: CGFloat = 9
        let track = CGRect(x: inset, y: midY - barHeight / 2,
                           width: width - inset * 2, height: barHeight)
        context.fill(Path(roundedRect: track, cornerRadius: barHeight / 2),
                     with: .color(.primary.opacity(0.16)))

        // One tick per volume, so the site's real cadence — and any volume it
        // skipped — is visible as spacing rather than assumed to be even.
        for position in loop.indices {
            let tickX = x(of: position, width: width)
            let tick = Path(roundedRect: CGRect(x: tickX - 1, y: track.minY + 1.5,
                                                width: 2, height: track.height - 3),
                            cornerRadius: 1)
            context.fill(tick, with: .color(.primary.opacity(0.42)))
        }
    }
}

/// The bar the timeline lives in: what you are looking at, and when it is.
struct RadarScrubBar: View {
    let loop: [RadarFrame]
    let index: Int
    let isPlaying: Bool
    let togglePlay: () -> Void
    let scrub: (Int) -> Void

    private var current: RadarFrame? { loop.indices.contains(index) ? loop[index] : nil }

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
                RadarTimeline(loop: loop, index: index, scrub: scrub)
                ends
            }

            readout
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    /// The axis labelled at its two ends. The strip is for sweeping, not for
    /// reading a value off.
    private var ends: some View {
        HStack(spacing: 0) {
            Text(When.moment(loop.first?.time ?? Date()))
            Spacer(minLength: 4)
            Text("newest")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
    }

    /// The frame's clock time, and how old it is. THE AGE IS NOT DECORATION: a
    /// Level II volume is posted about seven minutes after it starts, so even the
    /// newest frame is a picture of a few minutes ago, and a storm moving at
    /// 40 mph has travelled five miles since. Saying so is the honest version of
    /// what the old extrapolated frames were trying to paper over.
    @ViewBuilder private var readout: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(When.moment(current?.time ?? Date()))
                .font(.callout).monospacedDigit()
            if let current {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(age(of: current.time, at: context.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 110, alignment: .trailing)
    }

    private func age(of time: Date, at now: Date) -> String {
        let minutes = Int((now.timeIntervalSince(time) / 60).rounded())
        return minutes <= 0 ? "just now" : "\(minutes) min ago"
    }
}

// MARK: - Sweep mode

/// Sweep mode's bar: which scan is on screen, which is coming in, and what the
/// real sweep was like. THE REAL NUMBERS ARE THE POINT: the line turns at one
/// calm pace, so the bar is where the radar's own pace — twelve seconds in rain,
/// over a minute in clear air — gets said.
struct SweepBar: View {
    let site: String
    let shown: RadarFrame?
    let revealing: RadarFrame?
    let facts: [String: RadarModel.ScanFacts]
    let newest: RadarFrame?
    /// The site's recent gap between scans, for saying when the next is due.
    let interval: TimeInterval?
    /// What the dish is doing now, from the realtime feed. Nil without it.
    let dish: Level2Live.Dish?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.right")
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.45, green: 1.0, blue: 0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.callout)
                Text(detail).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            if let frame = revealing ?? shown {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(When.moment(frame.time))
                            .font(.callout).monospacedDigit()
                        Text(age(of: frame.time, at: context.date))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var headline: String {
        if let revealing {
            return "Sweeping in \(site)'s \(revealing.time.formatted(date: .omitted, time: .shortened)) scan"
        }
        if let dish, let angle = dish.angle {
            if dish.onLowestTilt { return "\(site)'s dish is sweeping the lowest tilt now" }
            return "\(site)'s dish is up at \(String(format: "%.1f", angle))°"
        }
        return "Waiting for \(site)'s next scan"
    }

    private var detail: String {
        if let revealing, let f = facts[revealing.key] {
            return "The dish took \(Int(f.duration.rounded())) s for this sweep; shown at a steady pace"
        }
        if let shown, shown.key != newest?.key {
            return "Catching up — newer scans are waiting their turn"
        }
        // FROM THE REALTIME FEED, WHEN WE HAVE IT: which tilt the newest posted
        // chunk is from. That IS watching the dish, ten seconds behind.
        if let dish, let cut = dish.cut {
            if dish.onLowestTilt {
                return "It appears here as soon as the pass is posted — within a minute"
            }
            let back = dish.untilNextLowest.map { " · back to the lowest tilt in about \(max(1, Int(($0 / 60).rounded()))) min" } ?? ""
            return "Tilt \(cut + 1) of \(dish.cuts), climbing through the higher tilts\(back)"
        }
        // WITHOUT IT, WHAT WE ACTUALLY KNOW. The archive is minutes behind, so
        // it does not show the dish; it shows how often scans have been finishing.
        if let interval {
            let minutes = max(1, Int((interval / 60).rounded()))
            return "\(site) has been finishing a scan about every \(minutes) min; the line turns when one arrives"
        }
        return "The line turns when a new scan arrives"
    }

    private func age(of time: Date, at now: Date) -> String {
        let minutes = Int((now.timeIntervalSince(time) / 60).rounded())
        return minutes <= 0 ? "just now" : "\(minutes) min ago"
    }
}

// MARK: - Map objects

/// Carries the COLOUR rather than the level, so the one ramp in
/// `Hazard.tint(forLevel:)` is applied once at construction and both maps draw the
/// same warning identically.
final class HazardPolygon: MKPolygon {
    var tintColor: Color = .orange
}
