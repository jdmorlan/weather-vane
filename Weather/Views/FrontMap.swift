//
//  FrontMap.swift  (Weather)
//
//  The Front view's controls on the Mac, iPad and iPhone: the summary, the
//  metric chips, the spot card and the hours. What goes ON the map — the
//  colours, arrows, dots and numbers — is in `FrontPicture`, shared with the TV.
//
//  THE COLOUR IS THE VALUE. Temperature from blue through red, dewpoint from
//  dry brown to humid green: the scales every weather map uses, so the map can
//  be read without learning it first. The front shows as the edge where the
//  colours change. (It started as the 3-hour CHANGE in each, which a forecaster
//  reads well and nobody else could; "what do blue and yellow mean" was the
//  first question it got.) Pressure is the exception: its level means little,
//  so it stays coloured by its 3-hour change, which is the clue.
//
//  ONE METRIC AT A TIME, chosen with chips in the bar like every other view's
//  settings. Two colour fields on one map fight, for the same reason radar and
//  a burn ban can't share one. The wind arrows are always on. Everything at
//  once is the spot card: click the map and it lists all five there.
//

import SwiftUI
import MapKit
import CoreText
import WeatherKit

// MARK: - The summary

/// Where the front is, when it reaches home, and which clues agree — a summary,
/// not a control. The ⓘ opens each clue's numbers and why it changes.
struct FrontSummary: View {
    @ObservedObject var model: FrontModel
    var showsDetail: Bool = false
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            headline
            if let index = model.hourIndex, let reading = model.reading(at: index), reading.found {
                if showsDetail {
                    ForEach(reading.lines) { detail($0) }
                } else {
                    clues(reading)
                }
            }
            if model.run != nil { FrontKey(metric: model.clue) }
            if let stamp = model.stamp {
                Text(sourceLine(stamp))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var headline: some View {
        if let failure = model.failure, model.run == nil {
            Label("Can't load the HRRR: \(failure)", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.secondary)
        } else if let index = model.hourIndex, let reading = model.reading(at: index) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title(reading)).font(compact ? .callout.weight(.semibold) : .headline)
                if let arrival = arrivalLine {
                    Text(arrival).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(model.run == nil ? "Loading the HRRR…" : "Pick a later hour")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func title(_ reading: FrontReading) -> String {
        guard reading.found else { return "No front on the map at this hour" }
        let distance = reading.milesFromHome.map { "\(Int(($0 / 10).rounded()) * 10) miles" }
        if reading.throughHome {
            guard let distance, let direction = reading.directionFromHome else { return "The front is through home" }
            return "The front is through home; its edge is \(distance) \(direction)"
        }
        guard let distance, let direction = reading.directionFromHome else { return "A front is on the map" }
        return "Front about \(distance) \(direction) of home"
    }

    private var arrivalLine: String? {
        guard let passage = model.passage else { return nil }
        let when = When.moment(passage)
        return passage > Date()
            ? "The HRRR has it reaching home around \(when)"
            : "It came through home around \(when), by the HRRR"
    }

    /// One line: each clue, ticked where it agrees.
    private func clues(_ reading: FrontReading) -> some View {
        HStack(spacing: 14) {
            ForEach(reading.lines) { line in
                HStack(spacing: 4) {
                    Image(systemName: line.agrees ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(line.agrees ? Color.green : .secondary)
                        .font(.system(size: 11))
                    Text(line.clue.label).font(.caption)
                        .foregroundStyle(line.agrees ? .primary : .secondary)
                }
                .help(line.statement)
            }
        }
    }

    private func detail(_ line: FrontReading.Line) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: line.agrees ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(line.agrees ? Color.green : .secondary)
                    .font(.system(size: 11))
                Text(line.clue.label).font(.callout.weight(.medium))
                    .frame(width: 92, alignment: .leading)
                Text(line.statement).font(.callout)
            }
            Text(line.clue.mechanism)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 18)
        }
    }

    private func sourceLine(_ stamp: SourceStamp) -> String {
        var line = stamp.line()
        if let index = model.hourIndex, let run = model.run, run.hours[index].valid <= Date() {
            line += " · dots measured at airports"
        }
        return line
    }
}

/// The chosen metric's colours as a gradient, with values under it.
struct FrontKey: View {
    let metric: FrontClue

    var body: some View {
        let scale = FrontScale.of(metric)
        HStack(spacing: 10) {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(gradient: scale.gradient, startPoint: .leading, endPoint: .trailing))
                    .opacity(0.85)
                    .frame(width: 180, height: 8)
                GeometryReader { geo in
                    ForEach(scale.ticks, id: \.self) { tick in
                        Text(tickLabel(tick, scale))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .fixedSize()
                            .position(x: (tick - scale.range.lowerBound)
                                        / (scale.range.upperBound - scale.range.lowerBound) * geo.size.width,
                                      y: 5)
                    }
                }
                .frame(width: 180, height: 10)
            }
            Text(metric.shows).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tickLabel(_ tick: Double, _ scale: FrontScale) -> String {
        let whole = Int(tick)
        if scale.diverging { return whole > 0 ? "+\(whole) \(scale.unit)" : whole < 0 ? "−\(-whole)" : "0" }
        return tick == scale.ticks.last ? "\(whole)\(scale.unit == "°F" ? "°F" : " \(scale.unit)")" : "\(whole)"
    }
}

// MARK: - Choosing

/// Which metric colours the map, and whether numbers are on it — the bar's
/// chips, as every other view's settings are.
struct FrontMetricChips: View {
    @ObservedObject var model: FrontModel

    var body: some View {
        HStack(spacing: 8) {
            BarChoices(options: FrontClue.displayOrder.map { metric in
                BarOption(value: metric, icon: nil, text: metric.chip, title: metric.label, detail: metric.shows)
            }, selection: $model.clue)
            Button { model.showsNumbers.toggle() } label: {
                Image(systemName: "textformat.123").font(.system(size: 13, weight: .medium))
                    .frame(width: 18, height: 18)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .foregroundStyle(model.showsNumbers ? Color.accentColor : .secondary)
                    .background(Capsule().fill(model.showsNumbers ? Color.accentColor.opacity(0.18)
                                                                  : Color.primary.opacity(0.06)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .barHint("Numbers", "The value at each point on the map. Bold beside a dot: measured at an airport. Lighter under an arrow: the HRRR's forecast.")
            .accessibilityLabel(model.showsNumbers ? "Hide numbers" : "Show numbers")
        }
    }
}

// MARK: - The spot card

/// Everything at one place, for the hour on the map: click the map to open it.
struct FrontSpotCard: View {
    @ObservedObject var model: FrontModel
    let home: GeoPoint?

    var body: some View {
        if let spot = model.spot, let index = model.hourIndex, let run = model.run {
            let hour = run.hours[index]
            let reading = model.readingAt(spot, index: index)
            let airport = model.airportNear(spot, at: hour.valid)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(place(spot)).font(.headline)
                        Text(When.moment(hour.valid)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button { model.spot = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                if let airport {
                    column("Measured at \(airport.station)", airport.reading, change: nil)
                }
                if let reading {
                    column(airport == nil ? "HRRR forecast" : "HRRR here", reading.now, change: reading.pressureChange)
                }
            }
            .frame(width: 250, alignment: .leading)
            .mapCard(maxWidth: 280)
        }
    }

    private func column(_ title: String, _ r: SurfaceReading, change: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                row("Temperature", "\(Int(r.temperature.rounded()))°F")
                row("Dewpoint", "\(Int(r.dewPoint.rounded()))°F")
                row("Wind", wind(r))
                row("Gusts", r.gust.map { "\(Int($0.rounded())) mph" } ?? "none reported")
                if let p = r.pressure {
                    row("Pressure", String(format: "%.0f mb", p) + (change.map { String(format: " (%+.0f in 3 h)", $0) } ?? ""))
                }
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private func wind(_ r: SurfaceReading) -> String {
        guard let from = r.windFrom else { return r.windSpeed < 3 ? "calm" : "\(Int(r.windSpeed.rounded())) mph" }
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return "\(names[Int((from / 45).rounded()) % 8]) \(Int(r.windSpeed.rounded())) mph"
    }

    private func place(_ p: GeoPoint) -> String {
        guard let home else { return String(format: "%.2f°, %.2f°", p.latitude, p.longitude) }
        let miles = FrontReader.miles(home, p)
        if miles < 3 { return "Home" }
        let bearing = atan2(sin((p.longitude - home.longitude) * .pi / 180) * cos(p.latitude * .pi / 180),
                            cos(home.latitude * .pi / 180) * sin(p.latitude * .pi / 180)
                            - sin(home.latitude * .pi / 180) * cos(p.latitude * .pi / 180)
                            * cos((p.longitude - home.longitude) * .pi / 180)) * 180 / .pi
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        return "\(Int(miles.rounded())) miles \(names[Int(((bearing + 360).truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8]) of home"
    }
}

// MARK: - The hours

/// Play, then the hours of the run as a strip: past on the left, a line at now,
/// and a mark where the front reaches home.
struct FrontHourStrip: View {
    @ObservedObject var model: FrontModel
    var chrome = true

    var body: some View {
        if let run = model.run, let index = model.hourIndex {
            HStack(spacing: 10) {
                Button { model.isPlaying.toggle() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play the hours")

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(When.moment(run.hours[index].valid)).font(.callout.weight(.medium))
                        Text(run.hours[index].valid <= Date() ? "measured and modelled" : "forecast")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    track(run: run, index: index)
                }
            }
            .modifier(StripChrome(on: chrome))
        }
    }

    private func track(run: SurfaceRun, index: Int) -> some View {
        let first = model.firstHour, last = run.hours.count - 1
        let span = max(1, last - first)
        func x(_ i: Int, _ w: CGFloat) -> CGFloat { CGFloat(i - first) / CGFloat(span) * w }
        let nowIndex = model.nowIndex
        let passageIndex = model.passage.flatMap { p in run.hours.firstIndex { $0.valid >= p } }
        return GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 4)
                // Midnights, so the days read.
                ForEach(Array(run.hours.indices.filter {
                    $0 >= first && Calendar.current.component(.hour, from: run.hours[$0].valid) == 0
                }), id: \.self) { i in
                    Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1, height: 10)
                        .offset(x: x(i, w))
                }
                if let nowIndex {
                    Rectangle().fill(Color.accentColor).frame(width: 2, height: 14)
                        .offset(x: x(nowIndex, w) - 1)
                }
                if let passageIndex, passageIndex >= first {
                    Image(systemName: "house.fill").font(.system(size: 9))
                        .foregroundStyle(Color(red: 0.18, green: 0.45, blue: 0.95))
                        .offset(x: x(passageIndex, w) - 5, y: -11)
                }
                Circle().fill(Color.primary).frame(width: 12, height: 12)
                    .offset(x: x(index, w) - 6)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                model.isPlaying = false
                let f = min(1, max(0, drag.location.x / max(1, w)))
                model.select(first + Int((f * CGFloat(span)).rounded()))
            })
        }
        .frame(height: 22)
    }

    private struct StripChrome: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            content.mapCard(on, maxWidth: 760)
        }
    }
}
