//
//  TVFront.swift  (tvOS)
//
//  The Front view's controls on the TV: two more menus beside the view and
//  zoom — which metric colours the map, and which hour — and a card in the
//  corner where the outlooks put theirs. The map itself is the Mac's
//  (`FrontPicture`), drawn twice the size.
//
//  MENUS, NOT CHIPS OR A SLIDER. A row of chips is a focus container on tvOS
//  that left and right can't swipe out of, and a slider wants a pointer. A menu
//  is one button that opens a list, which is how every other choice on the TV
//  map is made. No spot card either: there's nothing to point at the map with.
//

import SwiftUI
import WeatherKit

struct TVFrontMenus: View {
    @ObservedObject var model: FrontModel

    var body: some View {
        HStack(spacing: 16) {
            metricMenu
            if model.run != nil { hourMenu }
        }
    }

    private var metricMenu: some View {
        Menu {
            Picker("Colours", selection: $model.clue) {
                ForEach(FrontClue.displayOrder) { Text($0.label).tag($0) }
            }
            Toggle("Numbers on the map", isOn: $model.showsNumbers)
        } label: {
            MenuLabel(symbol: "thermometer.medium", text: model.clue.label)
        }
    }

    /// Every third hour, plus now: forty-odd single hours is a list nobody
    /// scrolls with a remote.
    private var hourMenu: some View {
        let run = model.run
        let first = model.firstHour
        let now = model.nowIndex
        let hours = run.map { r in
            r.hours.indices.filter { $0 >= first && ($0 == now || ($0 - (now ?? first)) % 3 == 0) }
        } ?? []
        return Menu {
            Picker("Hour", selection: Binding(get: { model.hourIndex ?? first },
                                              set: { model.select($0) })) {
                ForEach(hours, id: \.self) { i in
                    Text(hourName(i)).tag(i)
                }
            }
        } label: {
            MenuLabel(symbol: "clock", text: model.hourIndex.map(hourName) ?? "Now")
        }
    }

    private func hourName(_ index: Int) -> String {
        guard let run = model.run else { return "" }
        if index == model.nowIndex { return "Now" }
        return When.moment(run.hours[index].valid)
    }
}

/// Where the front is and when it reaches home, which clues agree, and what
/// the colours mean.
struct TVFrontCard: View {
    @ObservedObject var model: FrontModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure = model.failure, model.run == nil {
                Text("Couldn't load the HRRR: \(failure)").foregroundStyle(.secondary)
            } else if model.run == nil {
                Text("Loading the HRRR…").foregroundStyle(.secondary)
            } else if let index = model.hourIndex, let reading = model.reading(at: index) {
                Text(title(reading)).font(.system(size: 26, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let arrival = arrivalLine {
                    Text(arrival).foregroundStyle(.secondary)
                }
                if reading.found {
                    HStack(spacing: 18) {
                        ForEach(reading.lines) { line in
                            HStack(spacing: 6) {
                                Image(systemName: line.agrees ? "checkmark.circle.fill" : "circle.dashed")
                                    .foregroundStyle(line.agrees ? Color.green : .secondary)
                                Text(line.clue.label)
                                    .foregroundStyle(line.agrees ? .primary : .secondary)
                            }
                        }
                    }
                    .font(.system(size: 19))
                }
            }
            if model.run != nil { key }
            if let stamp = model.stamp {
                Text(stamp.line()).font(.system(size: 18)).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 22))
        .frame(width: 680, alignment: .leading)
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var key: some View {
        let scale = FrontScale.of(model.clue)
        return VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(gradient: scale.gradient, startPoint: .leading, endPoint: .trailing))
                .frame(height: 14)
            HStack {
                ForEach(scale.ticks, id: \.self) { tick in
                    Text(tickLabel(tick, scale)).font(.system(size: 16).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if tick != scale.ticks.last { Spacer() }
                }
            }
            Text(model.clue.shows).font(.system(size: 18)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tickLabel(_ tick: Double, _ scale: FrontScale) -> String {
        let whole = Int(tick)
        if scale.diverging { return whole > 0 ? "+\(whole) mb" : whole < 0 ? "−\(-whole) mb" : "0" }
        return "\(whole)\(scale.unit == "°F" ? "°" : "")"
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
}
