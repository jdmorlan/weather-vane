//
//  StationHealthView.swift  (macOS)
//
//  The instrument, not the sky. Every other destination in this app reads the
//  station as an oracle; this is the one that asks whether the oracle is well.
//
//  WHY IT LEADS WITH A SENTENCE. The temptation with a hardware page is a wall
//  of fields — voltage, firmware, serial, interval — and a wall of fields makes
//  the reader do the diagnosis. The numbers are all here, but underneath an
//  actual verdict, because the question being asked is "is my station OK" and
//  that has an answer. `StationHealth.standing` is where the answer lives; this
//  file is presentation, as everywhere else.
//
//  THE THING IT EXISTS TO CATCH is not a station that has obviously died. It's
//  the one that is reporting punctually, showing plausible numbers, and has
//  quietly dropped into a power-saving mode where the wind is sampled once a
//  minute — a failure with no symptom anywhere else in the app, which the
//  archive will absorb as a run of oddly gust-free weeks. Hence the battery card
//  is a week of nightly lows rather than one big number: the current voltage is
//  the least informative thing on this screen and gets the smallest treatment it
//  can while still being present.
//

import SwiftUI
import WeatherKit

// MARK: - Model

@MainActor
final class StationHealthModel: ObservableObject {
    @Published private(set) var health: StationHealth?
    @Published private(set) var error: String?
    /// The last time the check itself completed, successfully or not. Distinct
    /// from `health.checkedAt`, which belongs to the data being shown: after a
    /// failure the two diverge, and the gap between them is precisely the thing
    /// a reader needs — "this is what I know, and it's from an hour ago".
    @Published private(set) var lastAttempt: Date?

    /// Re-checked on a timer while the page is open, because "how long since the
    /// last report" is the whole subject and a static answer to it goes stale as
    /// you read it. Two minutes is slower than the station's one-minute cadence
    /// on purpose — a page that repaints faster than the data changes is just
    /// flicker — and the age line ticks on its own between refreshes.
    static let refreshInterval: Duration = .seconds(120)

    func refresh(settings: AppSettings) async {
        guard settings.hasWeatherStation else { return }
        let client = TempestClient(token: settings.tempestToken, stationID: settings.tempestStationID)
        do {
            health = try await client.health()
            error = nil
        } catch {
            // The last known health is KEPT. A failed check is not evidence that
            // the station is fine, and it is not evidence that it's broken
            // either — it's a gap in our own knowledge, and blanking the screen
            // would dress that up as news about the hardware. Same posture as
            // `WeatherHazardModel`: stop the clock, don't retract the reading.
            self.error = (error as? TempestClient.Failure)?.errorDescription ?? error.localizedDescription
        }
        lastAttempt = Date()
    }

    func poll(settings: AppSettings) async {
        while !Task.isCancelled {
            await refresh(settings: settings)
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }
}

// MARK: - Surface

struct StationHealthView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var model: StationHealthModel

    /// Ticks once a minute so the ages on screen stay true without a fetch. The
    /// numbers this page shows are almost all durations since something, and a
    /// duration that only updates when the network does is wrong for most of the
    /// time it's on screen.
    @State private var tick = Date()

    private var now: Date { tick }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let health = model.health {
                    verdict(health)
                    if let failure = model.error { staleNotice(failure) }
                    ForEach(health.sensingDevices) { device in
                        contact(device)
                        battery(device)
                        sensors(device)
                    }
                    inventory(health)
                    limits
                } else if let failure = model.error {
                    unreachable(failure)
                } else {
                    ProgressView("Checking the station…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(20)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await model.poll(settings: settings) }
        .task {
            for await instant in Timer.publish(every: 60, on: .main, in: .common)
                .autoconnect().values {
                tick = instant
            }
        }
    }

    // MARK: Verdict

    @ViewBuilder private func verdict(_ health: StationHealth) -> some View {
        let (standing, why) = health.standing(now: now)
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: standing.symbol)
                .font(.system(size: 34))
                .foregroundStyle(standing.tint)
                .frame(width: 42)
            VStack(alignment: .leading, spacing: 5) {
                Text(standing.headline)
                    .font(.title2.weight(.semibold))
                Text(why)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(checkedLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(standing.tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(standing.tint.opacity(0.25)))
    }

    private var checkedLine: String {
        guard let attempt = model.lastAttempt else { return "Checking…" }
        let age = now.timeIntervalSince(attempt)
        return age < 90 ? "Checked just now" : "Checked \(StationHealthView.spell(age)) ago"
    }

    /// Shown only when there IS older health to be stale. The verdict above is
    /// still drawn from it, so the notice's job is to say how old "still" is.
    private func staleNotice(_ failure: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("The last check didn't get through, so this is what was true earlier.")
                Text(failure).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "wifi.exclamationmark")
        }
        .font(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
    }

    /// Nothing known at all — a first check that failed. Distinct from the
    /// notice above, which has data behind it.
    private func unreachable(_ failure: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't reach the station", systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text(failure)
        } actions: {
            Button("Try again") { Task { await model.refresh(settings: settings) } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    // MARK: Contact

    @ViewBuilder private func contact(_ device: DeviceHealth) -> some View {
        card(label: "Last heard") {
            if let vitals = device.vitals {
                let contact = vitals.contact(now: now)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // Under a minute the duration stops being the interesting
                    // part — "43 seconds" invites arithmetic where "just now"
                    // answers the question — so the big number gives way to the
                    // verdict it was standing in for.
                    let fresh = contact.age < 60
                    Text(fresh ? "Just now" : StationHealthView.spell(contact.age))
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .foregroundStyle(contact.isHealthy ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.orange))
                    if !fresh {
                        Text("ago")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(clock(vitals.observedAt))
                            .font(.callout.weight(.medium))
                        Text(cadence(vitals))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(contactNote(contact, vitals: vitals))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(device.note ?? "No readings to check.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cadence(_ vitals: DeviceVitals) -> String {
        guard let interval = vitals.reportInterval else { return "Reporting interval unknown" }
        return interval == 1 ? "Reports every minute" : "Reports every \(interval) minutes"
    }

    private func contactNote(_ contact: Contact, vitals: DeviceVitals) -> String {
        switch contact {
        case .reporting:
            return "On schedule. Everything else in the app is this fresh."
        case .late:
            return "Later than it should be. One missed report is usually wifi; a run of them is the hub or the unit."
        case .silent:
            return "Every reading in this app — the Now card, the ten-day check, today's archive — is at least this old. Nothing here will say so on its own."
        }
    }

    // MARK: Battery

    @ViewBuilder private func battery(_ device: DeviceHealth) -> some View {
        if let vitals = device.vitals, let volts = vitals.battery {
            let mode = PowerMode.forTempest(volts: volts)
            card(label: "Battery") {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(format: "%.2f V", volts))
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                    Text(mode.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(mode.tint.opacity(0.18)))
                        .foregroundStyle(mode.tint)
                    Spacer(minLength: 0)
                }
                Text(mode.effect)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !vitals.trend.isEmpty {
                    BatteryTrace(trend: vitals.trend)
                        .frame(height: 96)
                    Text(trendNote(vitals.trend))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The sentence the chart is FOR. A solar station swings a third of a volt
    /// every day and is fine; the only reading that carries information is the
    /// nightly floor, and whether it's holding.
    private func trendNote(_ trend: BatteryTrend) -> String {
        guard let low = trend.low, let high = trend.high else { return "" }
        let span = String(format: "%.2f–%.2f V", low, high)
        let base = "Over the past week it ran \(span). A solar station swings like this every day — it's the low, not the swing, that matters."
        if trend.isFalling, let drift = trend.driftVolts {
            return base + " This one is down \(String(format: "%.2f", -drift)) V across the window: it isn't fully recovering."
        }
        if let worst = trend.worstMode, worst > .normal {
            return base + " It touched \(worst.title.localizedLowercase) at the bottom, so some readings that night were coarser than usual."
        }
        return base + " This one is recovering fully each day."
    }

    // MARK: Sensors

    @ViewBuilder private func sensors(_ device: DeviceHealth) -> some View {
        if let vitals = device.vitals, !vitals.sensors.isEmpty {
            card(label: "Sensors") {
                VStack(spacing: 0) {
                    ForEach(vitals.sensors) { sensor in
                        HStack(spacing: 10) {
                            Image(systemName: sensor.isReporting
                                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(sensor.isReporting ? Color.green : Color.red)
                            Text(sensor.kind.rawValue)
                            Spacer(minLength: 0)
                            Text(sensor.isReporting ? "Reporting" : "No reading")
                                .font(.callout)
                                .foregroundStyle(sensor.isReporting ? AnyShapeStyle(.secondary)
                                                                    : AnyShapeStyle(Color.red))
                        }
                        .padding(.vertical, 7)
                        if sensor.id != vitals.sensors.last?.id { Divider() }
                    }
                }
                Text("Read from the latest observation. A quiet day still counts as reporting — a working lightning sensor says “zero strikes”, a failed one says nothing at all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Hardware

    private func inventory(_ health: StationHealth) -> some View {
        card(label: "Hardware") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(health.devices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: device.kind.symbol)
                                .foregroundStyle(.secondary)
                            Text(device.name).font(.callout.weight(.semibold))
                            Text(device.serial)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        Text(specs(device))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let note = device.note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let elevation = health.elevation {
                    Divider()
                    Text("Station at \(Int((elevation * 3.28084).rounded())) ft"
                         + (health.timeZone.map { ", \($0.identifier.replacingOccurrences(of: "_", with: " "))" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Firmware, hardware revision and — the one that can silently invalidate a
    /// reading — how high off the ground the unit is mounted. A Tempest at a
    /// foot measures a different wind than the same unit at two metres, and
    /// nothing else in this app would ever mention it.
    private func specs(_ device: DeviceHealth) -> String {
        var parts: [String] = []
        if let firmware = device.firmware { parts.append("Firmware \(firmware)") }
        if let hardware = device.hardware { parts.append("Hardware rev \(hardware)") }
        if let agl = device.heightAboveGround, agl > 0 {
            parts.append(String(format: "%.1f ft above ground", agl * 3.28084))
        }
        if let environment = device.environment { parts.append(environment.localizedCapitalized) }
        return parts.isEmpty ? "No details registered" : parts.joined(separator: " · ")
    }

    /// What this page cannot tell you, said out loud.
    ///
    /// The REST API serves no signal strength, no uptime and no sensor fault
    /// register — those ride the local UDP broadcast. A row reading "Signal: —"
    /// would look like a broken feature; naming the boundary is the honest
    /// version, and it's the same rule the rest of the app follows about a day
    /// it only half-saw.
    private var limits: some View {
        Text("Signal strength, uptime and the unit's own fault register are only broadcast on your local network, not through the web API this page uses — so they aren't shown rather than shown blank.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // MARK: Chrome

    private func card<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }

    /// Station-local, like every other clock in this app. A reading timestamped
    /// in the reader's zone when the station is in another is a number that
    /// looks right and is off by hours.
    private func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = model.health?.timeZone ?? .current
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    /// Coarsest grain that's still true — this is read as prose, not compared.
    static func spell(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "moments" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        return "\(hours / 24) days"
    }
}

// MARK: - The week of battery

/// A week of voltage with the power-mode floors drawn behind it.
///
/// THE BANDS ARE THE POINT. A bare sparkline of a solar battery is a sawtooth
/// that tells you nothing — it looks alarming when it's healthy and calm when
/// it's dying, because the eye reads the swing and the swing is always there.
/// Drawn against the mode thresholds, the same trace answers the only question
/// worth asking: does the bottom of each night stay above the line where the
/// station starts cutting corners.
///
/// Hand-drawn rather than charted, as everything else in this app is: the y
/// scale isn't the data's range, it's the hardware's — fixed to the mode floor
/// below and a full charge above — so a healthy week sits visibly near the top
/// instead of being auto-scaled to fill the box and look dramatic.
struct BatteryTrace: View {
    let trend: BatteryTrend

    /// Mode 3's floor below, a sunny full charge above. FIXED, not fitted: an
    /// auto-scaled axis would redraw the same station as a cliff or a flat line
    /// depending only on how still the week was, which is exactly the misreading
    /// the bands exist to prevent.
    private let floor = 2.30
    private let ceiling = 2.85

    private func y(_ volts: Double, _ height: CGFloat) -> CGFloat {
        let fraction = (volts - floor) / (ceiling - floor)
        return height - CGFloat(min(1, max(0, fraction))) * height
    }

    var body: some View {
        Canvas { context, size in
            guard trend.readings.count > 1,
                  let first = trend.readings.first?.date,
                  let last = trend.readings.last?.date,
                  last > first else { return }
            let span = last.timeIntervalSince(first)

            // The zones, worst at the bottom. Each band is filled between its OWN
            // bounds rather than from its ceiling down to the floor — stacked
            // fills would overlap into one undifferentiated block, which is
            // precisely the "something is vaguely wrong down there" impression
            // these bands exist to replace with a specific one.
            for (mode, lower, upper) in [(PowerMode.critical, floor, 2.39),
                                         (PowerMode.conserving, 2.39, 2.415),
                                         (PowerMode.saving, 2.415, 2.455)] {
                let top = y(upper, size.height)
                let bottom = y(lower, size.height)
                guard bottom > top else { continue }
                context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: bottom - top)),
                             with: .color(mode.tint.opacity(0.16)))
            }
            // The boundary out of normal: the line that matters, so it's the one
            // that's actually drawn.
            let normalLine = y(2.455, size.height)
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: normalLine))
                                  $0.addLine(to: CGPoint(x: size.width, y: normalLine)) },
                           with: .color(.secondary.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            var path = Path()
            for (index, reading) in trend.readings.enumerated() {
                let x = CGFloat(reading.date.timeIntervalSince(first) / span) * size.width
                let point = CGPoint(x: x, y: y(reading.volts, size.height))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(.accentColor),
                           style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))

            // The floor of the week, marked. It's the number the whole card is
            // about, and on a sawtooth the eye can't find it unaided.
            if let low = trend.readings.min(by: { $0.volts < $1.volts }) {
                let x = CGFloat(low.date.timeIntervalSince(first) / span) * size.width
                let point = CGPoint(x: x, y: y(low.volts, size.height))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3,
                                                    width: 6, height: 6)),
                             with: .color(PowerMode.forTempest(volts: low.volts).tint))
            }
        }
        .overlay(alignment: .topLeading) {
            Text("full charge").font(.caption2).foregroundStyle(.tertiary).padding(.leading, 2)
        }
        .overlay(alignment: .topTrailing) {
            Text("7 days").font(.caption2).foregroundStyle(.tertiary).padding(.trailing, 2)
        }
    }
}

// MARK: - Presentation

extension StationHealth.Standing {
    var symbol: String {
        switch self {
        case .good:    return "checkmark.seal.fill"
        case .watch:   return "exclamationmark.circle.fill"
        case .trouble: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .good:    return .green
        case .watch:   return .orange
        case .trouble: return .red
        }
    }

    /// The answer in three words, above the reason. A reader who opened this
    /// page to settle a doubt should be able to close it again without reading
    /// the paragraph.
    var headline: String {
        switch self {
        case .good:    return "Station is healthy"
        case .watch:   return "Worth keeping an eye on"
        case .trouble: return "Needs attention"
        }
    }
}

extension PowerMode {
    var tint: Color {
        switch self {
        case .normal:     return .green
        case .saving:     return .yellow
        case .conserving: return .orange
        case .critical:   return .red
        }
    }
}

extension DeviceKind {
    var symbol: String {
        switch self {
        case .tempest: return "sensor.tag.radiowaves.forward"
        case .air:     return "thermometer.medium"
        case .sky:     return "wind"
        case .hub:     return "wifi.router"
        case .unknown: return "questionmark.square.dashed"
        }
    }
}
