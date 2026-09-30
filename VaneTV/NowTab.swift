//
//  NowTab.swift  (tvOS)
//
//  What it is doing outside, as ONE screen rather than eight tiles.
//
//  Top to bottom in the order you want the answers: the temperature and the
//  interpreter's headline; the four readings, side by side in one panel; then
//  the next twelve hours, drawn full width because a trend is a shape and a
//  shape wants the whole screen.
//
//  THE READINGS ARE ALWAYS THERE, IN THE SAME PLACES. The card grid dropped the
//  Rain card on dry days, which made the screen change shape and taught you to
//  stop looking where it had been. Here all four keep their positions, and a
//  reading that is DOING something says so in orange: gusts past forty, a
//  barometer the interpreter is watching, oppressive air. Quiet readings stay
//  quiet rather than disappearing.
//
//  NOTHING HERE IS FOCUSABLE. There is nothing to press — every answer is
//  already on the screen — so focus stays on the tab bar and a swipe goes
//  straight to Forecast or Map.
//

import SwiftUI
import WeatherKit

struct NowTab: View {
    let report: WeatherReport?
    let hasStation: Bool

    var body: some View {
        if !hasStation {
            NoStationNotice()
        } else if let r = report {
            VStack(alignment: .leading, spacing: 28) {
                hero(r)
                readings(r)
                hours(r)
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            WaitingNotice()
        }
    }

    // MARK: Hero

    private func hero(_ r: WeatherReport) -> some View {
        HStack(alignment: .center, spacing: 36) {
            Text(r.temperature.map { String(format: "%.0f°", $0) } ?? "—")
                .font(.system(size: 112, weight: .thin).monospacedDigit())
            VStack(alignment: .leading, spacing: 6) {
                Text(r.headline)
                    .font(.system(size: 40, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Text(r.conditions)
                    if let today = r.days.first {
                        Text("·").foregroundStyle(.tertiary)
                        Text("High \(Self.degrees(today.high)) · Low \(Self.degrees(today.low))")
                            .monospacedDigit()
                    }
                    if let set = r.days.first?.sunset {
                        Text("·").foregroundStyle(.tertiary)
                        Text("Sunset \(Self.time(set))")
                    }
                }
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Readings

    /// Four readings in one panel. Each is a number, a word, and the small
    /// picture that makes the number legible to someone who does not hold its
    /// scale — the compass, the dew-point bands, the barometer's range.
    private func readings(_ r: WeatherReport) -> some View {
        HStack(alignment: .top, spacing: 0) {
            reading("WIND",
                    value: Self.mph(r.windGust ?? r.windAvg),
                    word: windWord(r),
                    accent: (r.windGust ?? 0) >= 40 ? .orange : nil) {
                WindCompass(direction: r.windDirection, compact: true)
                    .frame(width: 56, height: 56)
            }
            divider
            reading("RAIN TODAY",
                    value: WeatherAlmanac.inches(r.precipToday ?? 0),
                    word: rainWord(r),
                    accent: nil) {
                RainMeter(today: r.precipToday ?? 0, expected: r.rain.totalAccum)
                    .frame(height: 36)
            }
            divider
            reading("DEW POINT",
                    value: Self.degrees(r.comfort.dewPoint),
                    word: r.comfort.label.isEmpty ? "—" : r.comfort.label,
                    accent: (r.comfort.dewPoint ?? 0) >= 75 ? .orange : nil) {
                if let dew = r.comfort.dewPoint { ComfortScale(dewPoint: dew, compact: true) }
            }
            divider
            reading("PRESSURE",
                    value: r.pressure.current.map { String(format: "%.2f", $0) } ?? "—",
                    word: r.pressure.isNotable ? r.pressure.trend : "steady",
                    symbol: r.pressure.trend.trendSymbol,
                    accent: r.pressure.stormWatch ? .orange : nil) {
                if let value = r.pressure.current {
                    PressureBar(value: value, trend: r.pressure.trend, compact: true)
                }
            }
        }
        .padding(.vertical, 22)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(width: 2).padding(.vertical, 4)
    }

    private func reading<Visual: View>(_ label: String, value: String, word: String,
                                       symbol: String? = nil, accent: Color?,
                                       @ViewBuilder visual: () -> Visual) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 20, weight: .semibold)).tracking(1.2)
                .foregroundStyle(accent ?? .secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(size: 50, weight: .medium).monospacedDigit())
                    .foregroundStyle(accent ?? .white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(accent ?? .secondary)
                }
            }
            Text(word)
                .font(.system(size: 24))
                .foregroundStyle(accent?.opacity(0.9) ?? .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            // A fixed slot, bottom-aligned, so the compass and the three bars
            // sit on one line across the panel whatever their own heights.
            visual()
                .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .bottomLeading)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 196)
    }

    private func windWord(_ r: WeatherReport) -> String {
        let from = r.windDirectionCardinal.map { "from \($0)" }
        if let gust = r.windGust, gust > 0 {
            return ["mph gusts", from].compactMap { $0 }.joined(separator: ", ")
        }
        return ["mph", from].compactMap { $0 }.joined(separator: ", ")
    }

    private func rainWord(_ r: WeatherReport) -> String {
        if r.rain.willRain { return "more expected" }
        return (r.precipToday ?? 0) > 0 ? "done for now" : "none expected"
    }

    // MARK: Hours

    @ViewBuilder private func hours(_ r: WeatherReport) -> some View {
        if r.hours.count > 1 {
            VStack(alignment: .leading, spacing: 12) {
                Text("NEXT 12 HOURS")
                    .font(.system(size: 20, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(.secondary)
                // Whatever height is left after the hero and the readings.
                HourChart(hours: Array(r.hours.prefix(12)))
                    .frame(minHeight: 240, maxHeight: .infinity)
                Text(r.rain.text.isEmpty
                     ? "Temperature · chance of rain in cyan · gusts above 18 mph in orange"
                     : r.rain.text)
                    .font(.system(size: 24)).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } else {
            Text("No hourly forecast yet.")
                .font(.system(size: 26)).foregroundStyle(.secondary)
        }
    }

    // MARK: Formatting

    private static func degrees(_ value: Double?) -> String {
        value.map { String(format: "%.0f°", $0) } ?? "—"
    }

    private static func mph(_ value: Double?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "—"
    }

    private static func time(_ epoch: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch))
            .formatted(date: .omitted, time: .shortened)
    }
}
