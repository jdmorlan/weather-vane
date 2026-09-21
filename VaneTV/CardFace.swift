//
//  CardFace.swift  (tvOS)
//
//  The front of a card: one measure, at the size you read a row at.
//
//  A FACE IS A PICTURE WITH A NUMBER ON IT, not a number with a label. A dew
//  point of 63° means nothing to anyone who does not already hold the scale; the
//  same 63° sitting just past the green band and a long way below the red one
//  explains itself. So every face carries a small visual that does the work the
//  figure cannot — the comfort bands, the day's arc, the compass, the barometer's
//  position in its own range.
//
//  The radar face was always this: a live map rather than a number, because "is
//  there anything out there" has no numeric form and a thumbnail answers it in
//  the time it takes to look past.
//

import SwiftUI
import MapKit
import WeatherKit

struct CardFace: View {
    let card: StationCard
    let report: WeatherReport?
    @ObservedObject var radar: RadarModel
    @ObservedObject var hazards: TVHazardModel
    let home: CLLocationCoordinate2D?
    let range: RadarRange

    private let size = CGSize(width: 400, height: 280)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder private var content: some View {
        switch card {
        case .radar:    radarFace
        default:        measureFace
        }
    }

    // MARK: Radar

    @ViewBuilder private var radarFace: some View {
        ZStack(alignment: .topLeading) {
            if let home {
                TVRadarMap(center: home, radiusMeters: range.radius,
                           frames: radar.frames, index: radar.index,
                           hazards: hazards.drawable)
                    .allowsHitTesting(false)
                // The camera is fixed, so home is the exact centre of the face.
                Circle().stroke(.white, lineWidth: 3)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.7), radius: 3)
                    .frame(width: size.width, height: size.height)
            }
            LinearGradient(colors: [.black.opacity(0.75), .clear],
                           startPoint: .top, endPoint: .center)
            label("RADAR", accent: hazards.worst == nil ? nil : .orange)
                .padding(18)
        }
    }

    // MARK: Everything else

    private var measureFace: some View {
        VStack(alignment: .leading, spacing: 0) {
            label(card.title.uppercased(), accent: accent)
            Spacer(minLength: 0)
            visual
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(size: 46, weight: .medium).monospacedDigit())
                    .foregroundStyle(accent ?? .white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if card == .pressure, let arrow = detailTrend?.trendSymbol {
                    Image(systemName: arrow)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(accent ?? .secondary)
                }
                Spacer(minLength: 0)
            }
            Text(detail)
                .font(.system(size: 21))
                .foregroundStyle(accent?.opacity(0.9) ?? .secondary)
                .lineLimit(1)
        }
        .padding(22)
    }

    private var detailTrend: String? {
        card == .pressure ? report?.pressure.trend : nil
    }

    /// The picture. Each is the smallest thing that makes its number legible to
    /// someone who does not already know the scale.
    @ViewBuilder private var visual: some View {
        if let r = report {
            switch card {
            case .comfort:
                if let dew = r.comfort.dewPoint { ComfortScale(dewPoint: dew, compact: true) }
            case .sun:
                SunArc(sunrise: Self.date(r.days.first?.sunrise),
                       sunset: Self.date(r.days.first?.sunset),
                       now: Date(), compact: true)
                    .frame(height: 92)
            case .wind:
                WindCompass(direction: r.windDirection, compact: true)
                    .frame(height: 92)
            case .pressure:
                if let value = r.pressure.current {
                    PressureBar(value: value, trend: r.pressure.trend, compact: true)
                }
            case .hours:
                HourSparkline(hours: Array(r.hours.prefix(12)))
                    .frame(height: 76)
            case .days:
                DaySparkline(days: Array(r.days.prefix(5)))
                    .frame(height: 76)
            case .rain:
                RainMeter(today: r.precipToday ?? 0, expected: r.rain.totalAccum)
                    .frame(height: 76)
            case .radar:
                EmptyView()
            }
        }
    }

    private static func date(_ epoch: Int?) -> Date? {
        epoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private func label(_ text: String, accent: Color?) -> some View {
        Text(text)
            .font(.system(size: 19, weight: .semibold)).tracking(1.2)
            .foregroundStyle(accent ?? .secondary)
    }

    // MARK: What each face says

    private var value: String {
        guard let r = report else { return "—" }
        switch card {
        case .wind:
            return r.windGust.map { String(format: "%.0f", $0) }
                ?? r.windAvg.map { String(format: "%.0f", $0) } ?? "—"
        case .pressure: return r.pressure.current.map { String(format: "%.2f", $0) } ?? "—"
        case .comfort:  return r.comfort.dewPoint.map { String(format: "%.0f°", $0) } ?? "—"
        case .rain:     return WeatherAlmanac.inches(r.precipToday ?? 0)
        case .hours:
            // The shape of the next twelve hours in one figure: where it ends up.
            return r.hours.prefix(12).last?.temperature
                .map { String(format: "%.0f°", $0) } ?? "—"
        case .days:
            return r.days.first?.high.map { String(format: "%.0f°", $0) } ?? "—"
        case .sun:
            guard let set = r.days.first?.sunset else { return "—" }
            return Date(timeIntervalSince1970: TimeInterval(set))
                .formatted(date: .omitted, time: .shortened)
        case .radar:    return ""
        }
    }

    private var detail: String {
        guard let r = report else { return "" }
        switch card {
        case .wind:
            if let gust = r.windGust, gust > 0 {
                return r.windDirectionCardinal.map { "gusting, from \($0)" } ?? "gusting"
            }
            return r.windDirectionCardinal.map { "from \($0)" } ?? "mph"
        case .pressure: return r.pressure.isNotable ? r.pressure.trend : "steady"
        case .comfort:  return r.comfort.label.isEmpty ? "dew point" : r.comfort.label
        case .rain:     return r.rain.willRain ? "so far — more expected" : "so far today"
        case .hours:    return "by \(r.hours.prefix(12).last?.clock ?? "—")"
        case .days:
            let wet = r.days.prefix(5).filter { ($0.precipProbability ?? 0) >= 40 }.count
            return wet > 0 ? "\(wet) with a real chance of rain" : "nothing wet ahead"
        case .sun:
            guard let set = r.days.first?.sunset else { return "" }
            let when = Date(timeIntervalSince1970: TimeInterval(set))
            let seconds = when.timeIntervalSinceNow
            guard seconds > 0 else { return "already down" }
            return "in \(Int(seconds / 3600))h \(Int(seconds / 60) % 60)m"
        case .radar:    return ""
        }
    }

    /// Only the two measures that have a threshold worth shouting about. A card
    /// that is orange most of the time is a card that is never orange.
    private var accent: Color? {
        guard let r = report else { return nil }
        switch card {
        case .pressure: return r.pressure.stormWatch ? .orange : nil
        case .wind:     return (r.windGust ?? 0) >= 40 ? .orange : nil
        case .comfort:  return (r.comfort.dewPoint ?? 0) >= 75 ? .orange : nil
        default:        return nil
        }
    }
}
