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
//  The shape isn't lost: each column's bar sits on one scale shared by all ten
//  days, so a cool spell is a row of bars set lower without reading a number.
//  That is the one thing the ribbon did well, kept.
//

import SwiftUI
import WeatherKit

struct DayColumns: View {
    let days: [DayNote]
    let timezone: TimeZone?
    /// False for the Forecast page's long range, which starts on day four.
    var firstIsToday = true

    private static let columnWidth: CGFloat = 78

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) { columns(fixed: false) }
            // Too narrow for every column at a readable width — a phone, a
            // narrow window: scroll sideways rather than squeeze the numbers.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) { columns(fixed: true) }
            }
        }
    }

    @ViewBuilder private func columns(fixed: Bool) -> some View {
        ForEach(Array(days.enumerated()), id: \.element.id) { i, day in
            column(day, index: i)
                .frame(minWidth: Self.columnWidth, maxWidth: fixed ? Self.columnWidth : .infinity)
        }
    }

    // MARK: One day

    private func column(_ d: DayNote, index: Int) -> some View {
        let isToday = index == 0 && firstIsToday
        return VStack(spacing: 6) {
            VStack(spacing: 1) {
                Text(isToday ? "TODAY" : d.weekday.uppercased())
                    .font(.caption.weight(.semibold)).tracking(0.5)
                    .foregroundStyle(isToday ? .primary : .secondary)
                Text(shortDate(d))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Image(systemName: WeatherView.symbol(d.icon))
                .symbolRenderingMode(.multicolor)
                .font(.title2)
                .frame(height: 30)
            Text(d.high.map { "\(Int($0.rounded()))°" } ?? "—")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
            rangeBar(d)
            Text(d.low.map { "\(Int($0.rounded()))°" } ?? "—")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            rainLines(d)
            comfortLine(d)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10).padding(.horizontal, 4)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(isToday ? 0.07 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(isToday ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06)))
        .help(tooltip(d))
    }

    /// Low to high on the scale every column shares — the week's shape, read
    /// across the row without reading the numbers.
    private func rangeBar(_ d: DayNote) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.06)).frame(width: 5)
                if let low = d.low, let high = d.high {
                    let top = (1 - fraction(high)) * h
                    let bottom = (1 - fraction(low)) * h
                    Capsule()
                        .fill(LinearGradient(colors: [tempColor(high), tempColor(low)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 5, height: max(4, bottom - top))
                        .offset(y: top)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 44)
    }

    private var scale: ClosedRange<Double> {
        let values = days.flatMap { [$0.high, $0.low].compactMap { $0 } }
        guard let lo = values.min(), let hi = values.max(), hi > lo else { return 0...100 }
        return lo...hi
    }

    private func fraction(_ value: Double) -> CGFloat {
        let span = scale.upperBound - scale.lowerBound
        guard span > 0 else { return 0.5 }
        return CGFloat((value - scale.lowerBound) / span)
    }

    /// Only when there's a chance worth naming. The amount is the hourly
    /// forecast's total — plain inches, and only where the hours reach.
    @ViewBuilder private func rainLines(_ d: DayNote) -> some View {
        let chance = Int((d.precipProbability ?? 0).rounded())
        VStack(spacing: 1) {
            if chance >= 10 {
                Label("\(chance)%", systemImage: "drop.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.blue)
                if let total = d.precipTotal, total >= 0.01 {
                    Text(String(format: "%.2f″", total))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.blue.opacity(0.8))
                }
            } else {
                // "no rain", not "dry" — dry is a word about the AIR, and it
                // sat directly above "muggy" on the same day.
                Text("no rain").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 30, alignment: .top)
    }

    /// Named only when it's sticky or worse — "comfortable" on nine columns is
    /// nine labels saying nothing.
    @ViewBuilder private func comfortLine(_ d: DayNote) -> some View {
        let tag = d.comfortTag
        if ["Sticky", "Muggy", "Oppressive"].contains(tag) {
            Text(tag.lowercased())
                .font(.caption2.weight(.medium))
                .foregroundStyle(tag == "Oppressive" ? Color.orange : .secondary)
        } else {
            Text(" ").font(.caption2)
        }
    }

    private func shortDate(_ d: DayNote) -> String {
        let f = DateFormatter()
        f.timeZone = timezone
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "M/d"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(d.epoch)))
    }

    /// The day's words on hover — its conditions and how it changes shape.
    private func tooltip(_ d: DayNote) -> String {
        var parts = [d.conditions]
        if !d.shape.isEmpty { parts.append(d.shape) }
        if let dew = d.dewPoint { parts.append("Peak dew point \(Int(dew.rounded()))°") }
        return parts.joined(separator: " · ")
    }
}
