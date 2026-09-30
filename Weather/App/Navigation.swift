//
//  Navigation.swift  (Weather)
//
//  Six destinations, all peers.
//
//  WHAT THIS REPLACES — two tabs (Weather, Map) with a five-way segmented picker
//  buried inside the first one's `ScrollView`. That shape was inherited: Weather
//  was one surface inside Almanac, and a surface gets one tab, so its own
//  registers had to be a control INSIDE it. Standing alone, the nesting has
//  nothing left to justify it and two things against it — the picker scrolled
//  away with the cards under it, so on History the way back was off-screen; and
//  the map, which is a peer of Now by every measure, sat a level above four views
//  it has no authority over.
//
//  WHY GROUPED, AND BY WHAT — by the oldest distinction in the subject: CLIMATE
//  is what you expect, WEATHER is what you get, and the record is what you got.
//
//    TODAY    a moment, and the days it leads into. Now is this second at the
//             station and its ten-day; Forecast is the next three days, drawn
//             for deciding things — rain, wind, storms — with the rest of the
//             ten days marked as long range; Map is this second over the county —
//             radar, satellite, fire — and the storms, flooding and rain the
//             forecasters see coming. All of it stops being true within hours.
//    CLIMATE  what this place usually does. Rhythms is when things happen here;
//             Rain is how much and how often; Wind is where it comes from and
//             when that turns. None of them takes a date — they're the shape
//             you'd describe to someone moving in. Rain arrived last and proved
//             the group was the right idea: it had been stranded in History's
//             All-time grain, and the questions it answers were otherwise only
//             reachable by building a query in Explore.
//    RECORD   what actually happened. History is a stretch you name, Explore is
//             a question asked over everything.
//    BEYOND   not this acre at all — the wave upstairs that steers it, from a
//             model run rather than the station.
//    STATION  none of the above: the instrument rather than the weather. It sits
//             apart because it is the only destination whose subject is the app's
//             own source of truth — everything above reads the station, and this
//             one asks whether the station is worth reading. Last, and grouped
//             alone, because you go there when you already suspect something.
//
//  Map sits under TODAY rather than beside Pattern because a user reaching for
//  it is asking "is something coming at me", which is a question about now and
//  the next few days.
//
//  WHY "MAP" AND NOT "RADAR". It was Radar while the radar was most of it, and
//  the old note here said the map was only a fact about the renderer. That
//  stopped being true: the destination now holds six views — storm and flood
//  outlooks, rain totals, radar, cloud, fire — and what they have in common is
//  not any one source but that each is a picture of the area AROUND you, the
//  axis every other destination lacks. "Radar" had become a generic-sounding
//  name quietly meaning one of its six. See [[explicit-platform-naming]].
//

import SwiftUI

enum Destination: String, CaseIterable, Identifiable, Hashable {
    case now = "Now"
    case forecast = "Forecast"
    case map = "Map"
    case rhythms = "Rhythms"
    case rain = "Rain"
    case history = "History"
    case wind = "Wind"
    case explore = "Explore"
    case pattern = "Pattern"
    case station = "Station"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .now:     return "cloud.sun"
        case .forecast: return "calendar.day.timeline.left"
        case .map:     return "map"
        case .rhythms: return "repeat"
        case .rain:    return "drop"
        case .history: return "calendar"
        case .wind:    return "wind"
        case .explore: return "magnifyingglass"
        case .pattern: return "globe.americas"
        case .station: return "gauge.with.dots.needle.bottom.50percent"
        }
    }

    /// The window title, which is not always the sidebar label: "Now" alone in a
    /// title bar says nothing, and the titles are where the app gets to be
    /// specific about what you're looking at.
    var title: String {
        switch self {
        case .now:     return "Right Now"
        case .forecast: return "Next Three Days"
        case .map:     return "Weather Map"
        case .rhythms: return "Rhythms"
        case .rain:    return "Rain"
        case .history: return "History"
        case .wind:    return "Wind"
        case .explore: return "Explore"
        case .pattern: return "Upper Air"
        case .station: return "Station Health"
        }
    }

    /// One line under the title. Short on purpose — this is orientation, not
    /// documentation, and it's the only place the app explains what a
    /// destination is FOR before you've opened it.
    var caption: String {
        switch self {
        case .now:     return "Conditions, today's shape, and the ten-day"
        case .forecast: return "Temperature, rain, wind and storms, three days out"
        case .map:     return "What's around you, and what's on the way"
        case .rhythms: return "When things usually happen here"
        case .rain:    return "How much falls, how often, and how long between"
        case .history: return "A month, a season, or the whole record"
        case .wind:    return "Where it comes from, and when that turns"
        case .explore: return "The days when anything happened"
        case .pattern: return "The 500 mb wave that steers all of it"
        case .station: return "Whether the instrument itself is well"
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case today = "Today"
        case climate = "Climate"
        case record = "The Record"
        case beyond = "Beyond"
        case equipment = "The Station"
        var id: String { rawValue }

        var destinations: [Destination] {
            switch self {
            case .today:   return [.now, .forecast, .map]
            case .climate: return [.rhythms, .rain, .wind]
            case .record:  return [.history, .explore]
            case .beyond:  return [.pattern]
            case .equipment: return [.station]
            }
        }
    }

    /// Whether this destination can say anything at all without a Tempest token.
    ///
    /// Two of nine can, and that is the whole reason setup is skippable: Map
    /// and Pattern need only a home point, and the app is genuinely useful
    /// before you have found your token. The sidebar dims the rest rather than
    /// hiding them — a destination that vanishes reads as a missing feature,
    /// where a dim one with a reason reads as something you have yet to do.
    var needsStation: Bool {
        switch self {
        case .map, .pattern: return false
        case .now, .forecast, .rhythms, .rain, .history, .wind, .explore, .station: return true
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Binding var selection: Destination
    @EnvironmentObject private var settings: AppSettings
    /// Opens setup. Passed in rather than toggling a binding here because the
    /// sheet belongs to the window, not to the source list.
    var onSetUp: () -> Void

    /// iOS's `List(selection:)` takes an OPTIONAL binding and has no
    /// non-optional overload; macOS accepts both. Using the optional form on
    /// both platforms keeps this a single call site, and the setter drops nil —
    /// a deselect is not a destination, and the detail column always has to be
    /// showing something.
    private var chosen: Binding<Destination?> {
        Binding(get: { selection }, set: { if let new = $0 { selection = new } })
    }

    var body: some View {
        List(selection: chosen) {
            ForEach(Destination.Group.allCases) { group in
                Section(group.rawValue) {
                    ForEach(group.destinations) { destination in
                        row(destination)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 172, ideal: 194, max: 260)
        .safeAreaInset(edge: .bottom) { footer }
    }

    @ViewBuilder private func row(_ destination: Destination) -> some View {
        let blocked = destination.needsStation && !settings.hasWeatherStation
        Label(destination.rawValue, systemImage: destination.symbol)
            .tag(destination)
            // Not `.disabled`: a disabled row in a `List(selection:)` can't be
            // selected, and the screen behind it is the one place that explains
            // what's missing and offers the button that fixes it. Dimming says
            // "there's nothing here yet" while leaving the explanation reachable.
            .foregroundStyle(blocked ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .help(blocked ? "Needs a connected Tempest station" : destination.caption)
    }

    /// The station this app is pointed at, and the way to change it.
    ///
    /// Bottom-of-sidebar because it is ambient: true of the whole app rather
    /// than of any one destination, which is the same reason the old blurb at
    /// the top of the Now scroll was in the wrong place — it made "no station"
    /// look like a fact about the forecast.
    @ViewBuilder private var footer: some View {
        Divider()
        Button(action: onSetUp) {
            HStack(spacing: 8) {
                Image(systemName: settings.needsSetup
                      ? "exclamationmark.circle.fill" : "sensor.tag.radiowaves.forward")
                    .foregroundStyle(settings.needsSetup ? AnyShapeStyle(.orange)
                                                         : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(settings.needsSetup ? "Finish setup" : settings.stationLabel)
                        .font(.callout)
                        .lineLimit(1)
                    if !settings.needsSetup {
                        Text("Connected").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        #if !os(macOS)
        // OPAQUE, AND ONLY HERE. A `safeAreaInset` reserves space but draws
        // nothing behind itself; the Mac's sidebar material covers for that, and
        // iPadOS has nothing there. In landscape the nine rows are taller than
        // the column, so without this the station name is drawn over whatever
        // row happens to have scrolled under it — "Station", in practice.
        .background(.bar)
        #endif
        .help(settings.needsSetup ? "Connect a Tempest station" : "Change station")
    }
}
