//
//  WeatherHazardViews.swift  (macOS)
//
//  Watches, warnings and advisories over your acre. All the judgement lives in
//  WeatherKit's `Hazards.swift`; this file decides only how loudly to say it.
//
//  The three states are deliberately unequal, because they aren't equally worth
//  your attention:
//
//  ACTIVE  — a banner ABOVE the tab picker, so a warning cannot be hidden by
//            being on the History tab. It is the one thing on this screen that
//            outranks whatever you came here to look at.
//  CLEAR   — nothing at all. 350 days a year this is the answer, and a card that
//            says "no alerts" every one of those days is a card you stop seeing,
//            which is exactly when you need it to be the thing that isn't there.
//            (See [[controls-earn-their-space]].)
//  UNKNOWN — a quiet line, never a scare. But never silence either: an unreached
//            feed reading as a clear sky is the failure this whole feature exists
//            to avoid.
//

import SwiftUI
import Combine
import WeatherKit

@MainActor
final class WeatherHazardModel: ObservableObject {
    @Published private(set) var watch = HazardWatch()

    /// Warnings are issued and expire on a scale of minutes. Five minutes of poll
    /// against fifteen minutes of `HazardWatch.freshness` means two consecutive
    /// failures before the surface stops claiming to know — enough slack for one
    /// blip, not enough to sit blind through a storm.
    static let pollInterval: Duration = .seconds(300)

    /// NWS asks for a User-Agent that identifies the app. It is deliberately NOT
    /// the user's email address: this is an unrelated third-party service, and the
    /// API is satisfied by anything that identifies the client.
    private static let contact = "almanac.app"

    func refresh(settings: AppSettings) async {
        guard settings.hasHome else { return }
        let point = GeoPoint(latitude: settings.homeLat, longitude: settings.homeLon)
        let client = NWSClient(point: point, contact: Self.contact)
        let attempt = Date()
        do {
            let hazards = try await client.activeHazards()
            watch = HazardWatch(hazards: hazards, lastReached: attempt, lastAttempt: attempt)
        } catch {
            // Keep the last known hazards and the last time we heard. A failed poll
            // does not retract a warning — it just stops the clock on our right to
            // call the sky quiet, which `state()` handles from `lastReached`.
            watch = HazardWatch(hazards: watch.hazards,
                                lastReached: watch.lastReached,
                                lastAttempt: attempt,
                                failure: (error as? NWSClient.Failure)?.errorDescription
                                    ?? error.localizedDescription)
        }
    }

    /// Poll for as long as the view is on screen.
    func poll(settings: AppSettings) async {
        while !Task.isCancelled {
            await refresh(settings: settings)
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}

// MARK: - Presentation

extension HazardKind {
    var symbol: String {
        switch self {
        case .tornado:      return "tornado"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        case .flood:        return "water.waves"
        case .winter:       return "snowflake"
        case .heat:         return "thermometer.sun.fill"
        case .cold:         return "thermometer.snowflake"
        case .wind:         return "wind"
        case .fire:         return "flame.fill"
        case .marine:       return "sailboat.fill"
        case .air:          return "aqi.medium"
        case .other:        return "exclamationmark.triangle.fill"
        }
    }
}

extension HazardWatch.State {
    /// The active hazards that can actually be drawn — i.e. the ones NWS gave an
    /// outline for. A zone product has no finer boundary than a county, and
    /// inventing one on the map would claim a precision the product doesn't have.
    /// Same refusal as `resolution`, one layer out.
    var drawable: [Hazard] {
        if case .active(let live) = self { return live.filter { $0.shape != nil } }
        return []
    }
}

extension Hazard {
    /// Colour reads off `level`, not off the kind — so the normalized scale is
    /// what the eye sorts by, and a heat advisory can never out-shout a warning
    /// just because fire is red.
    var tint: Color { Self.tint(forLevel: level) }

    /// Static because the radar draws warning polygons in the same colours from a
    /// `MKPolygon` subclass that carries only the level. One ramp, so the outline
    /// on the map and the row in the banner can never disagree about how serious
    /// the same warning is.
    static func tint(forLevel level: Double) -> Color {
        switch level {
        case 0.9...:    return .red
        case 0.7..<0.9: return .orange
        case 0.45..<0.7:return .yellow
        default:        return .secondary
        }
    }
}

struct HazardBanner: View {
    let watch: HazardWatch

    var body: some View {
        switch watch.state() {
        case .active(let live):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(live) { HazardRow(hazard: $0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .clear:
            EmptyView()
        case .unknown(let since, let reason):
            // Nothing has been tried yet — starting up isn't a state worth
            // reporting, and flashing this on every launch would teach you to
            // ignore the one time it means something.
            if watch.lastAttempt != nil { UnknownHazardLine(since: since, reason: reason) }
        }
    }
}

private struct HazardRow: View {
    let hazard: Hazard
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: hazard.kind.symbol)
                    .foregroundStyle(hazard.tint)
                    .font(.callout.weight(.semibold))

                Text(hazard.event)
                    .font(.callout.weight(.semibold))

                // The resolution, said out loud. "You're in it" and "your county"
                // are different facts and only one of them means go inside.
                Text(hazard.resolution.phrase)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(hazard.tint.opacity(0.22), in: Capsule())

                Spacer(minLength: 8)

                let timing = hazard.timing()
                if !timing.isEmpty {
                    Text(timing).font(.caption).foregroundStyle(.secondary)
                }
            }

            // A warning's instruction is the only part that tells you what to DO,
            // so it is shown without asking. Everything below a warning has to be
            // opened, because an advisory's boilerplate crowding out a warning is
            // how the banner stops being read.
            if let instruction = hazard.instruction, !instruction.isEmpty {
                if hazard.tier == .warning || expanded {
                    Text(instruction)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("What to do") { withAnimation(.easeInOut(duration: 0.15)) { expanded = true } }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hazard.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(hazard.tint.opacity(0.35)))
    }
}

private struct UnknownHazardLine: View {
    let since: Date?
    let reason: String?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
            Text(sentence).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Says what we DON'T know, never what's happening. The distinction is the
    /// point: "no alerts" would be a claim, and we haven't earned it.
    private var sentence: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        if let since {
            return "Alerts last checked \(formatter.localizedString(for: since, relativeTo: Date())) — can't confirm what's active right now."
        }
        return "Haven't reached the National Weather Service yet — no alert status for your location."
            + (reason.map { " (\($0))" } ?? "")
    }
}
