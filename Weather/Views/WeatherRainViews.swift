//
//  WeatherRainViews.swift  (macOS)
//
//  The rain card. It appears on a day that saw rain and says two things the app
//  has never said: WHEN it rained, and what the rate actually means.
//
//  It is keyed by a DAY, not by a tab and not by "is it raining". That is the
//  whole design decision. On Now the key is today, and while a spell is still
//  open the card is reading the live end of it; under History's day grain the key
//  is whatever day you walked to, and the same card describes a storm from two
//  years ago. One code path, two placements — and, not incidentally, the only
//  reason this is testable on a clear afternoon.
//
//  The fetch lives in `DayObservationsModel` (WeatherDayObservations.swift),
//  which used to live here as `RainDayModel`. It moved out once the same day's
//  samples started answering a second question — the hourly strip's measured
//  half — because a day's minutes are the record and rain is one reading of it.
//

import SwiftUI
import Combine
import WeatherKit

// MARK: - The card

/// A day's rain, already loaded.
///
/// A PURE VIEW, and it has to be. The first cut owned its own `DayObservationsModel` and
/// hung the fetch off a `.task` attached to a `Group` that renders nothing on a
/// dry day — and SwiftUI doesn't keep modifiers on a view that resolves to
/// `EmptyView`, so on the one day it mattered the fetch never ran and the card
/// was invisible with nothing to debug. A view whose job is to disappear can't
/// also be the thing that decides to load.
///
/// So the caller owns the model and asks the question, which is also what lets
/// both call sites hand it a day from wherever they get one.
struct RainDayCard: View {
    let rain: RainDay
    /// For the "how does this compare" line. Nil where there's no archive yet.
    var climate: Climatology?

    var body: some View { card(rain) }

    private func card(_ rain: RainDay) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(rain.isRaining ? "RAINING NOW" : "THE RAIN")
                .font(.caption.weight(.semibold)).tracking(0.8)
                .foregroundStyle(rain.isRaining ? Color.accentColor : .secondary)

            Text(rain.headline)
                .font(.title3.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            // What you're standing in, when you're standing in it. This is the
            // line the whole card exists for.
            if let now = rain.nowSentence {
                Text(now)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }

            RainProfileChart(rain: rain)

            ForEach(rain.events) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.sentence).font(.callout.weight(.medium))
                    Text(event.peakSentence)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Where the day sits in the record. Only the total can be ranked:
            // the daily archive keeps totals, and a RATE has no history to be
            // compared against until the sample archive is filled.
            if let rank = climate?.rainDayRank(rain.total, excludingDay: rain.day) {
                Divider()
                Text(rank.sentence)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = rain.coverageNote {
                Text(note)
                    .font(.caption).foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }
}

// MARK: - The profile

/// A hyetograph: rain rate against clock time, the ordinary form for this and
/// the one a reader doesn't have to decode.
///
/// The teaching is in the GRIDLINES. Drawing the moderate and heavy thresholds
/// across the plot is what turns the words into something you can check — you
/// see the burst cross the line rather than being told it did.
struct RainProfileChart: View {
    let rain: RainDay

    /// Five-minute bins. A thousand one-minute bars is noise at this width, and
    /// binning by time (rather than by pixel) keeps the bar heights honest rates
    /// rather than whatever the layout happened to average.
    private static let binMinutes = 5

    private struct Bin: Identifiable {
        var minute: Int
        var rate: Double
        var id: Int { minute }
    }

    /// The stretch worth drawing: the rain, with half an hour of context either
    /// side. A whole 24-hour axis for a 40-minute shower is mostly blank.
    private var span: ClosedRange<Int> {
        guard let first = rain.firstMinute, let last = rain.lastMinute else { return 0...1_440 }
        return max(0, first - 30)...min(1_440, max(last + 30, first + 90))
    }

    private var bins: [Bin] {
        let all = rain.events.flatMap(\.samples)
        var totals: [Int: Double] = [:]
        for sample in all {
            let bin = (sample.minuteOfDay / Self.binMinutes) * Self.binMinutes
            totals[bin, default: 0] += sample.amount
        }
        return stride(from: (span.lowerBound / Self.binMinutes) * Self.binMinutes,
                      through: span.upperBound, by: Self.binMinutes).map {
            // Inches in the bin → inches per hour.
            Bin(minute: $0, rate: (totals[$0] ?? 0) / Double(Self.binMinutes) * 60)
        }
    }

    /// Top of the axis. Always at least far enough to show the "heavy" line, so
    /// a light-rain day and a downpour are read on the same mental scale.
    private var ceiling: Double {
        max(0.4, (bins.map(\.rate).max() ?? 0) * 1.15)
    }

    private var thresholds: [(rate: Double, label: String)] {
        [(0.10, "moderate"), (0.30, "heavy"), (2.00, "torrential")]
            .filter { $0.0 <= ceiling }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                axis
                GeometryReader { geo in
                    ZStack(alignment: .bottomLeading) {
                        thresholdLines(in: geo.size)
                        bars(in: geo.size)
                    }
                }
                .frame(height: 120)
            }
            clockLabels
        }
    }

    private var axis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(String(format: "%.2f", ceiling))
            Spacer(minLength: 0)
            Text("in/hr").foregroundStyle(.quaternary)
            Spacer(minLength: 0)
            Text("0")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .frame(width: 34, height: 120)
    }

    private func thresholdLines(in size: CGSize) -> some View {
        ForEach(thresholds, id: \.label) { line in
            let y = size.height - size.height * (line.rate / ceiling)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                .stroke(Color.primary.opacity(0.18),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Text(line.label)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .offset(x: 2, y: y + 1)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    private func bars(in size: CGSize) -> some View {
        let all = bins
        let width = all.isEmpty ? 0 : size.width / CGFloat(all.count)
        return ZStack(alignment: .bottomLeading) {
            ForEach(Array(all.enumerated()), id: \.offset) { index, bin in
                let height = max(bin.rate > 0 ? 1.5 : 0,
                                 size.height * CGFloat(min(1, bin.rate / ceiling)))
                Rectangle()
                    .fill(Self.color(for: bin.rate))
                    .frame(width: max(1, width - 1), height: height)
                    .offset(x: CGFloat(index) * width, y: 0)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
    }

    /// Colour carries the same scale the words do, so the two can't disagree.
    private static func color(for rate: Double) -> Color {
        switch RainIntensity.of(rate: rate) {
        case .trace:    return .blue.opacity(0.25)
        case .light:    return .blue.opacity(0.45)
        case .moderate: return .blue.opacity(0.70)
        case .heavy:    return .blue
        case .violent:  return .purple
        }
    }

    private var clockLabels: some View {
        HStack {
            Text(RainEvents.clock(span.lowerBound))
            Spacer()
            Text(RainEvents.clock((span.lowerBound + span.upperBound) / 2))
            Spacer()
            Text(RainEvents.clock(span.upperBound))
        }
        .font(.caption2).foregroundStyle(.tertiary)
        .padding(.leading, 42)
    }
}
