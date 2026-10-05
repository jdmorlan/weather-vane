//
//  WeatherDayColumns.swift
//
//  THE TEN DAYS AS TEN BOXES — one column a day, every number printed.
//
//  This replaced `OutlookRibbon`, a single figure: highs and lows as a band
//  labelled only where it turned, one icon per run of unchanging sky, humidity
//  as a wash and rain as a lane. Its premise was that nobody asks "what is
//  Thursday's high", only about the week's shape. In use it was the other way
//  round: a ten-day is LOOKED UP — "what's Thursday like?" — and the ribbon
//  made you read the chart first and find the day second, with half the days
//  carrying no number and no icon at all.
//
//  Each column used to carry a low-to-high bar on a scale shared by all ten
//  days, to keep the ribbon's sense of the week's shape. It was dropped: the
//  two numbers beside it already said it, and the bar couldn't say the thing
//  a low hides — whether it's the usual dawn or a front coming through that
//  night. The 7 AM temperature between the high and the low says that: when
//  they match, the low is the morning; when the low is well under it, the
//  cold arrives later.
//
//  Then the box itself was rebuilt, because ten columns of labelled numbers
//  read as text run down a box. The numbers people look up stay big — high
//  and low on one line — and under them the day is DRAWN in the Forecast
//  chart's grammar: its hours as a curve on one scale for all ten boxes (so
//  the row still reads as the week), a dot at 7 AM, night shaded, and rain
//  bars whose height is the chance and whose fill is the water. The 7 AM row
//  became a mark on the low: a sunrise when the low IS the morning, a moon and
//  the hour when it comes later. The comfort word became the box's bottom edge.
//

import SwiftUI
import WeatherKit

struct DayColumns: View {
    let days: [DayNote]
    let timezone: TimeZone?
    /// False for the Forecast page's long range, which starts on day four.
    var firstIsToday = true

    private static let columnWidth: CGFloat = 84

    /// What the marks mean, for the caption under a row of boxes.
    static let key = "Line: the day's hours, on one scale for all the boxes; the dot is \(WeatherInterpreter.wakeHour) AM. Rain bars: height is the chance, fill is the water (full is 0.1″ in an hour). Bottom edge: sticky, muggy, oppressive. A sunrise by the low means it's the morning low; a moon means it comes later, at the hour shown."

    var body: some View {
        let scale = self.scale
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 6) { columns(fixed: false, scale: scale) }
            // Too narrow for every column at a readable width — a phone, a
            // narrow window: scroll sideways rather than squeeze the numbers.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 6) { columns(fixed: true, scale: scale) }
            }
        }
    }

    @ViewBuilder private func columns(fixed: Bool, scale: ClosedRange<Double>) -> some View {
        ForEach(Array(days.enumerated()), id: \.element.id) { i, day in
            column(day, index: i, fixed: fixed, scale: scale)
        }
    }

    /// One temperature scale for every box, so a cool spell is a row of
    /// curves set lower without reading a number.
    private var scale: ClosedRange<Double> {
        let values = days.flatMap { d in d.hours.compactMap(\.temperature) + [d.high, d.low].compactMap { $0 } }
        guard let lo = values.min(), let hi = values.max(), hi > lo else { return 0...100 }
        return lo...hi
    }

    // MARK: One day

    private func column(_ d: DayNote, index: Int, fixed: Bool, scale: ClosedRange<Double>) -> some View {
        let isToday = index == 0 && firstIsToday
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(isToday ? "TODAY" : d.weekday.uppercased())
                        .font(.caption.weight(.semibold)).tracking(0.5)
                        .foregroundStyle(isToday ? .primary : .secondary)
                    Text(shortDate(d))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 2)
                Image(systemName: WeatherView.symbol(d.icon))
                    .symbolRenderingMode(.multicolor)
                    .font(.title3)
            }
            temperatures(d)
            DayCurve(day: d, scale: scale, timezone: timezone)
                .frame(height: 40)
            rainLine(d)
        }
        .padding(.top, 8).padding(.horizontal, 8).padding(.bottom, 9)
        // The width before the box is drawn, so the box fills the column's
        // share of the row — sized after, the box hugged its numbers and the
        // row became narrow boxes adrift in wide gaps.
        .frame(minWidth: Self.columnWidth, maxWidth: fixed ? Self.columnWidth : .infinity,
               maxHeight: .infinity, alignment: .top)
        .background(alignment: .bottom) {
            // The day's peak dew point, as the box's bottom edge.
            Rectangle().fill(comfortColor(d.comfortTag)).frame(height: 3)
        }
        .background(Color.primary.opacity(isToday ? 0.07 : 0.035))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(isToday ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06)))
        .help(tooltip(d))
    }

    /// High and low on one line. The low carries a sunrise when it's the
    /// morning low, or a moon and the hour when it comes later in the day —
    /// what the 7 AM row used to say, said only where it's worth saying.
    private func temperatures(_ d: DayNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(degrees(d.high))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(degrees(d.low))
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.secondary)
                if let hour = d.lateLowHour {
                    Image(systemName: "moon.fill").font(.system(size: 9)).foregroundStyle(.orange)
                    Text(clock(hour)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                } else if let wake = d.wakeTemp, let low = d.low, abs(wake - low) <= 2 {
                    Image(systemName: "sunrise.fill").symbolRenderingMode(.multicolor)
                        .font(.system(size: 9))
                }
            }
        }
        .monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.8)
    }

    /// The chance and, where the hours reach, the amount — plain inches.
    @ViewBuilder private func rainLine(_ d: DayNote) -> some View {
        let chance = Int((d.precipProbability ?? 0).rounded())
        HStack {
            if chance >= 10 {
                Text("\(chance)%")
                Spacer(minLength: 2)
                if let total = d.precipTotal, total >= 0.01 {
                    Text(String(format: "%.2f″", total))
                }
            } else {
                // "no rain", not "dry" — dry is a word about the AIR.
                Text("no rain").foregroundStyle(.tertiary)
            }
        }
        .font(.caption2.weight(chance >= 10 ? .semibold : .regular).monospacedDigit())
        .foregroundStyle(.blue)
    }

    /// Only sticky or worse is coloured — a strip on every comfortable day
    /// would be ten edges saying nothing.
    private func comfortColor(_ tag: String) -> Color {
        switch tag {
        case "Sticky": return .yellow.opacity(0.75)
        case "Muggy": return .orange.opacity(0.85)
        case "Oppressive": return .red.opacity(0.85)
        default: return .primary.opacity(0.06)
        }
    }

    private func degrees(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))°" } ?? "—"
    }

    private func clock(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h) \(hour < 12 ? "AM" : "PM")"
    }

    private func shortDate(_ d: DayNote) -> String {
        let f = DateFormatter()
        f.timeZone = timezone
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "M/d"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(d.epoch)))
    }

    /// The day's words on hover — its conditions, how muggy, and how it
    /// changes shape.
    private func tooltip(_ d: DayNote) -> String {
        var parts = [d.conditions]
        if !d.comfortTag.isEmpty { parts.append(d.comfortTag) }
        if !d.shape.isEmpty { parts.append(d.shape) }
        if let dew = d.dewPoint { parts.append("Peak dew point \(Int(dew.rounded()))°") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The day drawn

/// A day's hours in the Forecast chart's grammar, at box size: the
/// temperature curve, a dot at 7 AM, night shaded, and rain bars whose height
/// is the chance and whose fill is the water. Midnight to midnight across the
/// box, so today's curve starts at the current hour rather than stretching.
private struct DayCurve: View {
    let day: DayNote
    let scale: ClosedRange<Double>
    let timezone: TimeZone?

    /// The Forecast chart's referent: a full bar is a tenth of an inch in the
    /// hour, so a filled bar means the same thing in every box.
    private static let wetHour = 0.10
    private static let rainHeight: CGFloat = 10

    var body: some View {
        Canvas { ctx, size in
            let plotBottom = size.height - Self.rainHeight - 3
            let x = { (hour: Double) in 1 + hour / 23 * (size.width - 2) }
            let y = { (t: Double) in
                2 + (scale.upperBound - t) / (scale.upperBound - scale.lowerBound) * (plotBottom - 4)
            }

            // Night, from the day's own sun times.
            let (rise, set) = sunHours
            let night = Color.primary.opacity(0.05)
            ctx.fill(Path(CGRect(x: 0, y: 0, width: x(rise), height: plotBottom)), with: .color(night))
            ctx.fill(Path(CGRect(x: x(set), y: 0, width: size.width - x(set), height: plotBottom)),
                     with: .color(night))

            let pts: [CGPoint?] = day.hours.map { h in
                h.temperature.map { CGPoint(x: x(Double(h.hour)), y: y($0)) }
            }
            let line = SmoothCurve.path(pts)
            if let first = pts.compactMap({ $0 }).first, let last = pts.compactMap({ $0 }).last {
                var fill = line
                fill.addLine(to: CGPoint(x: last.x, y: plotBottom))
                fill.addLine(to: CGPoint(x: first.x, y: plotBottom))
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [.orange.opacity(0.22), .orange.opacity(0.02)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: plotBottom)))
                ctx.stroke(line, with: .color(.orange.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            if let wake = day.hours.first(where: { $0.hour == WeatherInterpreter.wakeHour }),
               let t = wake.temperature {
                let p = CGPoint(x: x(Double(wake.hour)), y: y(t))
                let dot = Path(ellipseIn: CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4))
                ctx.fill(dot, with: .color(.windowBackground))
                ctx.stroke(dot, with: .color(.primary), lineWidth: 1.1)
            }

            // Rain: a baseline, so a dry day reads as dry rather than blank.
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(base, with: .color(.blue.opacity(0.15)), lineWidth: 1)
            let barW = max(1.5, size.width / 24 - 1)
            for h in day.hours {
                let prob = h.precipProbability ?? 0, amount = h.precip ?? 0
                guard prob >= 10 || amount > 0 else { continue }
                let bh = max(2, CGFloat(prob / 100) * Self.rainHeight)
                let rect = CGRect(x: x(Double(h.hour)) - barW / 2, y: size.height - 1 - bh,
                                  width: barW, height: bh)
                ctx.fill(Path(rect), with: .color(.blue.opacity(0.22)))
                let wet = min(1, amount / Self.wetHour)
                if wet > 0 {
                    let fh = max(1, CGFloat(wet) * bh)
                    ctx.fill(Path(CGRect(x: rect.minX, y: rect.maxY - fh, width: barW, height: fh)),
                             with: .color(.blue.opacity(0.85)))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Sunrise and sunset as fractional local hours; 6 and 20 if unknown.
    private var sunHours: (Double, Double) {
        var cal = Calendar(identifier: .gregorian)
        if let timezone { cal.timeZone = timezone }
        func hour(_ epoch: Int?) -> Double? {
            epoch.map {
                let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval($0)))
                return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
            }
        }
        return (hour(day.sunrise) ?? 6, hour(day.sunset) ?? 20)
    }
}
