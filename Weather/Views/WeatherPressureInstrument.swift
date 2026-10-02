//
//  WeatherPressureInstrument.swift  (macOS)
//
//  Two questions, and they need two different pictures — which is why one number could
//  never answer either.
//
//  WHERE IT SITS is a question about the station's whole record: the band from the
//  lowest reading ever taken here to the highest, with the ordinary middle shaded and
//  today marked in it. This is the picture that teaches the thing you can't learn from
//  digits — the band really is about an inch and a half wide, so a tenth is a genuine
//  move and half an inch is a storm.
//
//  WHERE IT'S GOING is a question about the next day: the forecast trace, drawn on its
//  OWN tight scale because on the record scale a real 0.15" fall is three pixels. Two
//  scales is normally a sin (see the dataviz rule about dual axes) — but these are two
//  separate figures answering two separate questions, not two series sharing one frame,
//  and each is labelled with what it spans.
//
//  The rule the old tile broke: a number needs a referent or it is decoration.
//

import SwiftUI
import WeatherKit

struct PressureInstrument: View {
    let current: Double?
    let trend: String
    let delta3h: Double?
    /// The station's own record. nil = not enough archive yet; the band simply doesn't
    /// draw, rather than inventing a range from a fortnight of data.
    let band: PressureBand?
    /// Forecast pressure for the coming hours, oldest first.
    let trace: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let band, let current {
                bandStrip(band: band, current: current)
                Text(WeatherInterpreter.pressureMeaning(current, band: band, trend: trend))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The reading and the trace on one line where they fit, the trace on its
    /// own line where they don't — a phone, once "+0.10 over 3h" is showing.
    ///
    /// THE GAP THIS CLOSES. The trace's "next 24h" label was the only flexible
    /// thing in the row, so when the row ran short SwiftUI squeezed it to nearly
    /// no width and it wrapped a letter per line: invisible, but tall, with the
    /// sparkline centred against it. That hung the trace below the reading and
    /// left a blank band under it — on the Mac too, not only the phone.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                reading
                Spacer(minLength: 0)
                if trace.count > 2 { traceSpark }
            }
            VStack(alignment: .leading, spacing: 6) {
                reading
                if trace.count > 2 { traceSpark }
            }
        }
    }

    private var reading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("PRESSURE").font(.caption2.weight(.semibold)).tracking(0.5)
                .foregroundStyle(.tertiary)
            Image(systemName: symbol).font(.callout.weight(.semibold)).foregroundStyle(tint)
            if let current {
                Text(String(format: "%.2f", current)).font(.callout.weight(.semibold))
                Text("inHg").font(.caption2).foregroundStyle(.tertiary)
            }
            if let delta3h, abs(delta3h) >= 0.01 {
                // FORECAST, and said so. The arrow beside it is the measured
                // trend of the last few hours; this is the next three. Printed
                // as bare "+0.10 over 3h" beside a falling arrow it read as a
                // contradiction (Oct 2, 2026: falling, forecast to rise after
                // the rain) when it was two different times.
                Text(String(format: "%+.2f next 3h", delta3h))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// The record as a rail: the ends are the extremes ever measured here, the lit
    /// stretch is the ordinary middle 80%, and the needle is now. Being able to see how
    /// little of the rail today's reading can travel IS the lesson.
    private func bandStrip(band: PressureBand, current: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (v: Double) in CGFloat(band.position(v)) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07)).frame(height: 8)
                Capsule().fill(tint.opacity(0.22))
                    .frame(width: max(2, x(band.usualHigh) - x(band.usualLow)), height: 8)
                    .offset(x: x(band.usualLow))
                // The median as a hairline, so "normal" is a place and not a mood.
                Rectangle().fill(Color.primary.opacity(0.22))
                    .frame(width: 1, height: 12).offset(x: x(band.median))
                Capsule().fill(tint)
                    .frame(width: 3, height: 16)
                    .offset(x: min(max(x(current) - 1.5, 0), w - 3))
            }
            .frame(height: 16)
        }
        .frame(height: 16)
        .overlay(alignment: .bottomLeading) { endLabel(band.lowest, "lowest", .leading) }
        .overlay(alignment: .bottomTrailing) { endLabel(band.highest, "highest", .trailing) }
        .padding(.bottom, 13)
        .help("\(band.days) days on record · the whole span is "
              + String(format: "%.2f inHg", band.span))
    }

    private func endLabel(_ extreme: WeatherExtreme,
                          _ word: String,
                          _ align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 0) {
            Text(String(format: "%.2f", extreme.value))
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(word) \(DayKey.monthDay(of: extreme.day))")
                .font(.system(size: 8)).foregroundStyle(.tertiary)
        }
        .offset(y: 13)
    }

    /// Where it's going, on its own scale — the shape is the signal, so it carries no
    /// axis. What it spans is said in words beside it instead.
    private var traceSpark: some View {
        let lo = trace.min() ?? 0, hi = trace.max() ?? 1
        let range = max(hi - lo, 0.02)
        return HStack(spacing: 6) {
            Canvas { ctx, size in
                var path = Path()
                for (i, v) in trace.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(trace.count - 1)
                    let y = size.height - CGFloat((v - lo) / range) * size.height
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(path, with: .color(tint.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .frame(width: 74, height: 18)
            Text("next \(trace.count)h").font(.system(size: 9)).foregroundStyle(.tertiary)
                .fixedSize()
        }
        .help(String(format: "Forecast pressure spans %.2f–%.2f inHg over the next %dh",
                     lo, hi, trace.count))
    }

    private var symbol: String {
        switch trend {
        case "falling": return "arrow.down.right"
        case "rising":  return "arrow.up.right"
        default:        return "equal"
        }
    }

    private var tint: Color {
        switch trend {
        case "falling": return .orange
        case "rising":  return .teal
        default:        return .secondary
        }
    }
}
