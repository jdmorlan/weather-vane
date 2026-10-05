//
//  SatelliteKey.swift
//
//  WHAT THE SATELLITE'S COLOURS MEAN, AND WHAT THEY SAY ABOUT HOME.
//
//  The forecast maps always had this — `OutlookLegend`, under the map, home's
//  category first — and the satellite didn't, so a water vapour loop was a
//  brown picture with nothing to say which brown was which. Same place, same
//  order: where home is, then the colours, then what the band is measuring.
//
//  HOME IS READ FROM THE NEWEST SCAN, NOT THE FRAME ON SCREEN. The loop shows
//  the last three hours; the line under it is about now, and holds still while
//  the loop plays rather than changing every half second.
//

import SwiftUI
import WeatherKit

struct SatelliteKey: View {
    let source: SatelliteFieldSource
    /// The newest scan, which the home line reads.
    let newest: RadarFrame?
    let home: GeoPoint?
    /// Inside `MapViewBar`: no card of its own, and the colours and the
    /// explanation only when the bar's ⓘ is on. The scan's time is the scrub
    /// strip's to say there.
    var inBar = false
    var showsKey = true

    @State private var reading: Reading = .waiting
    @State private var explaining = false
    @State private var readBand: SatelliteFieldSource.Band?

    private enum Reading: Equatable {
        case waiting
        case read(SatelliteReading)
        case unreadable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !inBar { header }
            homeLine
            if showsKey {
                ramp
                explanation
            }
        }
        .mapCard(!inBar, maxWidth: 440)
        .padding(.horizontal, inBar ? 0 : 16)
        .task(id: readKey) { await readHome() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("GOES · \(source.band.label) · \(wavelength)")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 8)
            if let newest {
                Text("newest scan \(time(newest.time))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    // MARK: Home

    /// WHERE YOU ARE FIRST, as on the forecast maps: the colour you are
    /// standing in, named, and what that air is doing.
    @ViewBuilder private var homeLine: some View {
        if home != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "house.fill").font(.system(size: 11))
                    .foregroundStyle(homeColour ?? .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    // Two lines held for the meaning in the bar, whatever the
                    // state, so a new reading never changes the bar's height.
                    switch reading {
                    case .waiting:
                        Text("Home: reading the newest scan…")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        meaning("")
                    case .unreadable:
                        Text("Home: no reading from the newest scan")
                            .font(.callout.weight(.medium)).lineLimit(1)
                        meaning(source.band.isNightBlind
                                ? "Visible imagery is dark until sunrise."
                                : "The scan has no value over home. The next one comes in five minutes.")
                    case .read(let r):
                        Text("Home: \(r.name.prefix(1).lowercased() + r.name.dropFirst())")
                            .font(.callout.weight(.medium)).lineLimit(1)
                        meaning(r.meaning)
                    }
                }
            }
        }
    }

    @ViewBuilder private func meaning(_ text: String) -> some View {
        if inBar {
            Text(text).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        } else if !text.isEmpty {
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var homeColour: Color? {
        guard case .read(let r) = reading,
              let entry = SatelliteFieldSource.table(for: source.band)[r.grey] else { return nil }
        return Color(red: Double(entry.0) / 255, green: Double(entry.1) / 255, blue: Double(entry.2) / 255)
    }

    private var readKey: String {
        "\(source.band.rawValue)|\(newest?.stamp ?? "")|\(home.map { "\($0.latitude),\($0.longitude)" } ?? "")"
    }

    private func readHome() async {
        guard let home, let newest else { reading = .waiting; return }
        // The old reading stays up while the new one is read — a new scan
        // every five minutes shouldn't blink the line. A new BAND clears it,
        // since the old words would be about a different picture.
        if readBand != source.band { reading = .waiting; readBand = source.band }
        let grey = await source.grey(stamp: newest.stamp, latitude: home.latitude,
                                     longitude: home.longitude)
        guard !Task.isCancelled else { return }
        reading = grey.map { .read(source.band.reading(grey: $0)) } ?? .unreadable
    }

    // MARK: The colours

    /// The band's own colour table, drawn as the map draws it, with home as a
    /// tick on it.
    private var ramp: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                let stops = source.legendStops().map {
                    Gradient.Stop(color: Color(red: Double($0.r) / 255, green: Double($0.g) / 255,
                                               blue: Double($0.b) / 255, opacity: Double($0.alpha)),
                                  location: $0.location)
                }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.12))
                    if case .read(let r) = reading {
                        let x = geo.size.width * CGFloat(r.grey) / 255
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.primary)
                            .position(x: x, y: -4)
                        Rectangle().fill(Color.primary).frame(width: 1.5, height: geo.size.height)
                            .position(x: x, y: geo.size.height / 2)
                    }
                }
            }
            .frame(height: 10)
            .padding(.top, 6)
            GeometryReader { geo in
                ForEach(keyWords, id: \.grey) { word in
                    Text(word.text)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: min(max(geo.size.width * CGFloat(word.grey) / 255, 18),
                                         geo.size.width - 18),
                                  y: 6)
                }
            }
            .frame(height: 12)
        }
    }

    /// A few words along the ramp — the reading names are sentences, too long
    /// to sit under a ten-point bar.
    private var keyWords: [(grey: Int, text: String)] {
        switch source.band {
        case .waterVapor: return [(12, "dry"), (60, "drier"), (115, "moist"), (175, "deep moisture"), (235, "storms")]
        case .infrared:   return [(40, "clear / low"), (150, "cloud"), (196, "high"), (232, "tall storms")]
        case .visible:    return [(40, "clear"), (135, "cloud"), (215, "thick cloud")]
        }
    }

    // MARK: What it measures

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { explaining.toggle() }
            } label: {
                Label(explaining ? "What is this showing" : "What is this showing?",
                      systemImage: explaining ? "chevron.down" : "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            if explaining {
                Text(measures)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SatelliteFieldSource.credit)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var wavelength: String {
        switch source.band {
        case .waterVapor: return "6.2 µm"
        case .infrared:   return "10.3 µm"
        case .visible:    return "0.64 µm"
        }
    }

    private var measures: String {
        switch source.band {
        case .waterVapor:
            return "Moisture in the upper air, roughly 20,000 to 35,000 feet — not clouds, and not the humidity you feel. Brown is dry air sinking from high up; white and grey is moist air; blue and green is moisture lifted high by rising air, where storms grow. Played as a loop, the edges between dry and moist show the troughs and jet streams that steer the weather, moving across the map."
        case .infrared:
            return "How cold the top of whatever the satellite sees is. Cold means high, so the colours climb with the cloud tops: grey and white for ordinary cloud, then blue, green, yellow and red for the tallest storms. Works day and night."
        case .visible:
            return "Sunlight reflected off clouds, the closest thing to a photograph. The sharpest picture of the three, and blank after sunset."
        }
    }

    private func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
