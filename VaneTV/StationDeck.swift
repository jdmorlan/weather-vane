//
//  StationDeck.swift  (tvOS)
//
//  A ROW OF CARDS, which is what a television's focus engine was built for.
//
//  The dashboard before this put everything on one screen at once, and it worked
//  right up until it didn't: it overflowed twice while being built, clipped its
//  own headline, and every further addition had to take something else off.
//  That is the signature of a layout with no depth — the only axis left is
//  smaller.
//
//  Cards give the second axis. A grid shows the SUMMARY of everything, and
//  pressing one opens as much detail as that measure actually deserves. Nothing
//  competes for the same square inch, and adding a ninth card costs nothing that
//  the other eight own.
//
//  A GRID AND NOT A SHELF. This started as one horizontal row, which is the
//  familiar tvOS pattern and the wrong one here: it left about sixty percent of
//  the screen black, and everything past the fourth card sat off the right edge
//  where you cannot know it exists. A shelf is for BROWSING a collection you
//  expect to be long — films, albums. This is a fixed set of eight things you
//  want to take in at a glance, and the focus engine moves up and down as
//  happily as it moves sideways.
//
//  IT ALSO RETIRES THE MODE PICKER. Radar was a mode because there was nowhere
//  else to put a map; now it is a card like the others, and full-screen radar is
//  what pressing it does. One less piece of chrome, and the thing you reach for
//  in weather sits in the same row as everything else rather than behind a
//  control you have to find first.
//
//  THE HERO STAYS PUT. Temperature, conditions and the interpreter's sentence
//  are above the row and never scroll, because they are the answer you wanted
//  before you decided to look at anything.
//

import SwiftUI
import WeatherKit

enum StationCard: String, CaseIterable, Identifiable {
    case radar, wind, pressure, comfort, rain, hours, days, sun
    var id: String { rawValue }

    var title: String {
        switch self {
        case .radar:    return "Radar"
        case .wind:     return "Wind"
        case .pressure: return "Pressure"
        case .comfort:  return "Comfort"
        case .rain:     return "Rain"
        case .hours:    return "Next 12 Hours"
        case .days:     return "Five Days"
        case .sun:      return "Sun"
        }
    }
}

struct StationDeck: View {
    let report: WeatherReport?
    @ObservedObject var radar: RadarModel
    @ObservedObject var hazards: TVHazardModel
    let home: CLLocationCoordinate2D?
    @Binding var range: RadarRange

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if let worst = hazards.worst {
                    HazardBannerTV(hazard: worst, others: hazards.active.count - 1)
                }
                hero
                    .padding(.horizontal, 72)
                    .padding(.top, hazards.worst == nil ? 44 : 30)
                // The deck sits just under the hero rather than being centred in
                // what is left. Two Spacers put it in the middle of the screen
                // with a band of nothing above and below — which reads as a row
                // that got lost rather than a row you are meant to walk.
                deck
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.black)
            .navigationDestination(for: StationCard.self) { card in
                CardDetail(card: card, report: report, radar: radar,
                           hazards: hazards, home: home, range: $range)
            }
        }
    }

    // MARK: Hero

    @ViewBuilder private var hero: some View {
        if let r = report {
            VStack(alignment: .leading, spacing: 10) {
                Text(r.headline)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 22) {
                    Text(r.temperature.map { String(format: "%.0f°", $0) } ?? "—")
                        .font(.system(size: 108, weight: .thin).monospacedDigit())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.conditions).font(.system(size: 32, weight: .medium))
                        if let today = r.days.first {
                            HStack(spacing: 7) {
                                Text(today.high.map { String(format: "%.0f°", $0) } ?? "—")
                                    .font(.system(size: 26, weight: .medium).monospacedDigit())
                                Text("/").foregroundStyle(.tertiary)
                                Text(today.low.map { String(format: "%.0f°", $0) } ?? "—")
                                    .font(.system(size: 26).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("No station connected").font(.system(size: 40, weight: .medium))
                Text("Radar and warnings work without one.")
                    .font(.system(size: 26)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: The grid

    private var deck: some View {
        // Four across. At 1920 points wide that is a card of about 400, which is
        // the smallest a live radar thumbnail survives at and still leaves the
        // measure cards room for a picture rather than just a figure.
        let columns = Array(repeating: GridItem(.flexible(), spacing: 30), count: 4)
        return LazyVGrid(columns: columns, spacing: 30) {
            ForEach(cards) { card in
                NavigationLink(value: card) {
                    CardFace(card: card, report: report, radar: radar,
                             hazards: hazards, home: home, range: range)
                }
                // tvOS's own card style: the lift and parallax on focus are what
                // tell you a thing is enterable, and they are exactly what a
                // hand-rolled focus ring fails to imply.
                .buttonStyle(.card)
            }
        }
        .padding(.horizontal, 72)
        .padding(.top, 34)
    }

    /// Cards with nothing to say do not appear. A "Rain" card reading 0.00 every
    /// dry week is a card you learn to swipe past, and then keep swiping past on
    /// the day it finally matters.
    private var cards: [StationCard] {
        StationCard.allCases.filter { card in
            switch card {
            case .radar:    return home != nil
            case .rain:     return (report?.precipToday ?? 0) > 0 || (report?.rain.willRain ?? false)
            case .hours:    return !(report?.hours.isEmpty ?? true)
            case .days:     return !(report?.days.isEmpty ?? true)
            case .sun:      return report?.days.first?.sunset != nil
            case .wind, .pressure, .comfort: return report != nil
            }
        }
    }
}
