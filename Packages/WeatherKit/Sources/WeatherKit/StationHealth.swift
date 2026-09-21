//
//  StationHealth.swift  (WeatherKit)
//
//  THE HARDWARE, not the weather. Every other surface in this app treats the
//  station as an oracle — you ask it what the temperature is and it tells you.
//  This is the one that asks after the instrument itself: is it still talking,
//  is the battery holding, are all six sensors still reporting.
//
//  WHY IT'S A SEPARATE CONCERN. A station that has quietly stopped reporting
//  does not announce itself anywhere else in this app. The Now card keeps
//  showing the last reading it got, History keeps drawing the archive, and
//  nothing on screen distinguishes "27° right now" from "27°, eleven hours ago,
//  because the pole blew over". Freshness is in the window subtitle and that is
//  all — which is fine while the answer is ninety seconds and useless once it
//  isn't. The fix is not a warning bolted onto the forecast; it's a place where
//  the question is the subject.
//
//  THE THREE SIGNALS, AND WHY THESE THREE:
//
//    CONTACT   — when the station last spoke, against how often it claims to.
//                The only one that can be wrong in a way that invalidates every
//                other screen, so it leads.
//    BATTERY   — a Tempest is solar, and the number that matters is not today's
//                voltage but whether each night's low is recovering. See
//                `PowerMode`: the hardware degrades its own reporting in four
//                documented steps, so a falling battery shows up as SILENTLY
//                COARSER DATA long before it shows up as an outage. That is
//                exactly the kind of failure this archive must not absorb
//                unnoticed — `StationSample.bucketMinutes` exists because
//                resolution has to travel with the reading.
//    SENSORS   — which of the instruments produced a value in the latest
//                observation. A dead haptic rain sensor reports null, not zero,
//                and null is distinguishable; that distinction is the whole
//                test, and it's the same one `ObservationFieldMap` draws.
//
//  WHAT THIS DELIBERATELY DOESN'T CLAIM. There is no RSSI, no uptime and no
//  sensor fault bitfield here, because the REST API doesn't serve them — those
//  ride the local UDP broadcast, which is the "later layer" `TempestClient`
//  already describes. Showing a blank field for them would be inventing a
//  measurement; the surface says plainly which questions it cannot answer.
//

import Foundation

// MARK: - What's on the pole

/// The units WeatherFlow sells, by the two-letter code `/stations` reports.
///
/// `hub` is separated from the rest not as a taxonomy but because it changes
/// what can be asked: the hub is mains-powered and has no observations of its
/// own, so a vitals call for one is a 404 rather than an answer. See
/// `DeviceHealth.note`.
public enum DeviceKind: String, Sendable, Equatable {
    case tempest = "ST"
    case air = "AR"
    case sky = "SK"
    case hub = "HB"
    case unknown = "--"

    public init(code: String?) {
        self = DeviceKind(rawValue: (code ?? "").uppercased()) ?? .unknown
    }

    /// Whether this unit reports observations at all — i.e. whether there are
    /// vitals to fetch. False for the hub, which speaks only on behalf of others.
    public var senses: Bool {
        switch self {
        case .tempest, .air, .sky: return true
        case .hub, .unknown: return false
        }
    }

    public var label: String {
        switch self {
        case .tempest: return "Tempest"
        case .air:     return "Air"
        case .sky:     return "Sky"
        case .hub:     return "Hub"
        case .unknown: return "Device"
        }
    }
}

// MARK: - Power

/// What the station does to itself as the battery falls.
///
/// A Tempest doesn't simply run until it stops. It steps down through four
/// documented modes, and every step DEGRADES THE DATA rather than interrupting
/// it — wind sampling slows from three seconds to six, then to a minute, then
/// to five, and in the last mode the haptic rain sensor stops listening
/// altogether. From the outside, mode 3 looks like a working station reporting
/// a calm, dry day.
///
/// That is the reason this type exists at all instead of a "battery low"
/// boolean. The interesting question isn't whether the station is alive; it's
/// whether the readings it's producing still mean what the rest of the app
/// assumes they mean.
///
/// THE THRESHOLDS ARE HYSTERETIC on the hardware — it drops to mode 1 at
/// 2.415 V but won't climb back out until 2.455 V, and so on down. The falling
/// edges are used here because a voltage alone can't say which direction it was
/// travelling, and reading the worse of the two is the conservative answer.
public enum PowerMode: Int, Sendable, Equatable, CaseIterable, Comparable {
    /// ≥ 2.455 V. Everything on, wind sampled every three seconds.
    case normal = 0
    /// ≥ 2.415 V. Wind sampling drops to six seconds.
    case saving = 1
    /// ≥ 2.39 V. Wind sampling drops to one minute.
    case conserving = 2
    /// Below 2.355 V. Everything drops to five minutes and the haptic rain
    /// sensor stops listening.
    case critical = 3

    public static func < (a: PowerMode, b: PowerMode) -> Bool { a.rawValue < b.rawValue }

    /// The mode a voltage puts a Tempest in, reading the falling edges.
    ///
    /// Between 2.355 and 2.39 the hardware could legitimately be in either mode
    /// 2 or mode 3 depending on where it came from; this returns the worse one,
    /// on the principle that a surface whose job is to warn you should not round
    /// in the flattering direction.
    public static func forTempest(volts: Double) -> PowerMode {
        switch volts {
        case 2.455...: return .normal
        case 2.415..<2.455: return .saving
        case 2.39..<2.415: return .conserving
        default: return .critical
        }
    }

    public var title: String {
        switch self {
        case .normal:     return "Normal"
        case .saving:     return "Saving power"
        case .conserving: return "Conserving"
        case .critical:   return "Critical"
        }
    }

    /// What is actually different about the data in this mode. Phrased as a
    /// consequence rather than a mode number, because "mode 2" tells a reader
    /// nothing and "wind is only sampled once a minute" tells them everything.
    public var effect: String {
        switch self {
        case .normal:
            return "All sensors at full rate. Wind sampled every three seconds."
        case .saving:
            return "Wind sampling has slowed to every six seconds. Gusts between samples are missed."
        case .conserving:
            return "Wind is only sampled once a minute. Gust peaks are no longer reliable."
        case .critical:
            return "Everything has dropped to five-minute sampling and the rain sensor has stopped listening. Readings are still arriving, but they no longer describe the day accurately."
        }
    }
}

/// One battery reading in the trend series.
public struct BatteryReading: Sendable, Equatable {
    public var date: Date
    public var volts: Double

    public init(date: Date, volts: Double) {
        self.date = date
        self.volts = volts
    }
}

/// A week of battery, reduced to the question a solar station actually poses.
///
/// The instantaneous voltage is close to meaningless on its own: a healthy
/// Tempest swings most of a third of a volt every single day, charging in sun
/// and discharging overnight, so "2.45 V" at dusk and at noon are two completely
/// different states of health. What matters is whether each night's LOW is
/// holding. A station that recovers to full every afternoon is fine no matter
/// how low it dipped; one whose nightly floor is walking downwards is on its way
/// to mode 3 whatever this second's reading says.
public struct BatteryTrend: Sendable, Equatable {
    public var readings: [BatteryReading]

    public init(readings: [BatteryReading]) {
        self.readings = readings.sorted { $0.date < $1.date }
    }

    public var isEmpty: Bool { readings.isEmpty }
    public var low: Double? { readings.map(\.volts).min() }
    public var high: Double? { readings.map(\.volts).max() }

    /// The worst mode the station passed through over the window. A dip into
    /// `.saving` at 4am is invisible in the current reading and is the earliest
    /// honest warning there is.
    public var worstMode: PowerMode? { low.map(PowerMode.forTempest(volts:)) }

    /// Whether the battery recovers. Compares the mean of the newer half of the
    /// window against the older half; a station that is keeping up sits flat,
    /// and one that is losing ground drifts down.
    ///
    /// Nil until there are enough readings for the halves to mean anything —
    /// two points and a straight line through them is not a trend.
    public var driftVolts: Double? {
        guard readings.count >= 8 else { return nil }
        let split = readings.count / 2
        let older = readings[..<split].map(\.volts)
        let newer = readings[split...].map(\.volts)
        guard !older.isEmpty, !newer.isEmpty else { return nil }
        return (newer.reduce(0, +) / Double(newer.count)) - (older.reduce(0, +) / Double(older.count))
    }

    /// A drift small enough to be the weather rather than the battery. A cloudy
    /// week genuinely does lower the average without meaning anything is wrong,
    /// so the band has to be wide enough to swallow one.
    public static let driftNoise = 0.03

    public var isFalling: Bool { (driftVolts ?? 0) < -Self.driftNoise }
}

// MARK: - Contact

/// Whether the station is still talking, and how late it is if not.
///
/// Judged against the station's OWN `report_interval` rather than a fixed
/// number, because that interval is itself a function of the power mode — a
/// station in mode 3 reporting every five minutes is not late at four, and
/// hard-coding one minute would cry wolf at exactly the moment the surface most
/// needs to be believed.
public enum Contact: Sendable, Equatable {
    case reporting(age: TimeInterval)
    case late(age: TimeInterval)
    case silent(age: TimeInterval)

    /// How much slack to give before calling a station late: three reports
    /// missed, and never less than five minutes. A single dropped report over
    /// wifi is ordinary and must not read as a fault.
    public static func judge(lastObserved: Date, reportInterval: Int?, now: Date = Date()) -> Contact {
        let age = now.timeIntervalSince(lastObserved)
        let expected = TimeInterval(max(1, reportInterval ?? 1) * 60)
        let grace = max(expected * 3, 300)
        if age <= grace { return .reporting(age: age) }
        if age <= 3600 { return .late(age: age) }
        return .silent(age: age)
    }

    public var age: TimeInterval {
        switch self {
        case .reporting(let a), .late(let a), .silent(let a): return a
        }
    }

    public var isHealthy: Bool {
        if case .reporting = self { return true }
        return false
    }
}

// MARK: - Sensors

/// The instruments on a Tempest, as the app cares about them.
///
/// Grouped by what they MEASURE rather than by wire column, because that's the
/// unit a reader thinks in and the unit that fails: the haptic rain sensor is
/// one part, and it backs one row here, even though it lands in the payload as
/// both an accumulation and a precipitation type.
public enum SensorKind: String, Sendable, Equatable, CaseIterable {
    case wind = "Wind"
    case temperature = "Temperature & humidity"
    case pressure = "Pressure"
    case light = "Light & UV"
    case rain = "Rain"
    case lightning = "Lightning"
}

/// Whether one instrument produced a value in the most recent observation.
///
/// NULL, NOT ZERO, is the test — and it's the same distinction
/// `ObservationFieldMap.value` draws. A working lightning sensor on a quiet day
/// reports a strike count of 0; a failed one reports nothing at all. Treating a
/// zero as a fault would mark every clear day as broken hardware, and treating a
/// null as a zero would archive a dead sensor as a calm, dry, unlit world.
public struct SensorReport: Identifiable, Sendable, Equatable {
    public var kind: SensorKind
    public var isReporting: Bool

    public var id: String { kind.rawValue }

    public init(kind: SensorKind, isReporting: Bool) {
        self.kind = kind
        self.isReporting = isReporting
    }
}

// MARK: - Vitals

/// Everything the latest observation says about the unit rather than the sky.
public struct DeviceVitals: Sendable, Equatable {
    public var observedAt: Date
    /// Volts. Absent for a device type whose payload we can't place the column
    /// in — never guessed from a position, for the reason `StationSample`
    /// spells out at length.
    public var battery: Double?
    /// Minutes between reports, as the station itself claims. Read from the
    /// LATEST single observation and never from a windowed fetch, where this
    /// column carries the server's bucket size instead.
    public var reportInterval: Int?
    public var sensors: [SensorReport]
    public var trend: BatteryTrend

    public init(observedAt: Date, battery: Double? = nil, reportInterval: Int? = nil,
                sensors: [SensorReport] = [], trend: BatteryTrend = BatteryTrend(readings: [])) {
        self.observedAt = observedAt
        self.battery = battery
        self.reportInterval = reportInterval
        self.sensors = sensors
        self.trend = trend
    }

    public func contact(now: Date = Date()) -> Contact {
        Contact.judge(lastObserved: observedAt, reportInterval: reportInterval, now: now)
    }

    public var powerMode: PowerMode? { battery.map(PowerMode.forTempest(volts:)) }

    public var silentSensors: [SensorKind] {
        sensors.filter { !$0.isReporting }.map(\.kind)
    }
}

/// One unit on the station: what it is, and how it's doing.
public struct DeviceHealth: Identifiable, Sendable, Equatable {
    public var id: Int
    public var kind: DeviceKind
    public var serial: String
    public var name: String
    public var firmware: String?
    public var hardware: String?
    /// Metres above ground, as registered. Shown because it's the one piece of
    /// configuration that silently invalidates a reading — a Tempest at 0.3 m
    /// measures a different wind than the same unit at 2 m, and nothing else in
    /// the app would ever surface it.
    public var heightAboveGround: Double?
    public var environment: String?
    public var vitals: DeviceVitals?
    /// Why there are no vitals, when there are none. A hub has none by nature;
    /// anything else here is a fetch that failed, and saying which is the
    /// difference between "this is normal" and "look into this".
    public var note: String?

    public init(id: Int, kind: DeviceKind, serial: String, name: String,
                firmware: String? = nil, hardware: String? = nil,
                heightAboveGround: Double? = nil, environment: String? = nil,
                vitals: DeviceVitals? = nil, note: String? = nil) {
        self.id = id
        self.kind = kind
        self.serial = serial
        self.name = name
        self.firmware = firmware
        self.hardware = hardware
        self.heightAboveGround = heightAboveGround
        self.environment = environment
        self.vitals = vitals
        self.note = note
    }
}

// MARK: - The station

/// The whole check, as of one moment.
public struct StationHealth: Sendable, Equatable {
    public var stationID: Int
    public var name: String
    public var timeZone: TimeZone?
    /// Metres. From the station registry, not the device.
    public var elevation: Double?
    public var devices: [DeviceHealth]
    public var checkedAt: Date

    public init(stationID: Int, name: String, timeZone: TimeZone? = nil,
                elevation: Double? = nil, devices: [DeviceHealth] = [],
                checkedAt: Date = Date()) {
        self.stationID = stationID
        self.name = name
        self.timeZone = timeZone
        self.elevation = elevation
        self.devices = devices
        self.checkedAt = checkedAt
    }

    /// The units that actually measure something, which is what "is the station
    /// OK" is really asking about.
    public var sensingDevices: [DeviceHealth] { devices.filter { $0.kind.senses } }

    /// How worried to be, in three steps.
    ///
    /// Three and not five, because this drives one badge and a headline, and a
    /// scale finer than the action it informs is decoration. You either do
    /// nothing, keep an eye on it, or go outside.
    public enum Standing: Sendable, Equatable, Comparable {
        case good, watch, trouble

        public static func < (a: Standing, b: Standing) -> Bool {
            let order: [Standing] = [.good, .watch, .trouble]
            return order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }
    }

    /// The worst thing true of any sensing unit, with the reason.
    ///
    /// ORDERED BY WHAT IT COSTS YOU, not by severity in the abstract. Silence
    /// comes first because it invalidates every other screen in the app; a dead
    /// sensor next because the archive is quietly recording a lie; then the
    /// power modes, which degrade data without breaking it; and a falling
    /// nightly floor last, which is a warning about next month rather than a
    /// statement about now.
    public func standing(now: Date = Date()) -> (Standing, String) {
        let sensing = sensingDevices
        guard !sensing.isEmpty else {
            return (.watch, "No sensing device is registered to this station.")
        }
        guard sensing.contains(where: { $0.vitals != nil }) else {
            return (.trouble, "Couldn't reach the station to check on it.")
        }

        for device in sensing {
            guard let vitals = device.vitals else { continue }
            switch vitals.contact(now: now) {
            case .silent(let age):
                return (.trouble, "Nothing heard from \(device.name) in \(Self.spell(age)). Readings on every other screen are at least that old.")
            case .late(let age):
                return (.watch, "\(device.name) is \(Self.spell(age)) late reporting.")
            case .reporting:
                break
            }
        }

        for device in sensing {
            let silent = device.vitals?.silentSensors ?? []
            if !silent.isEmpty {
                let names = silent.map(\.rawValue.localizedLowercase)
                return (.trouble, "\(names.joined(separator: " and ").localizedCapitalized) stopped reporting on \(device.name).")
            }
        }

        let worst = sensing.compactMap { $0.vitals?.powerMode }.max()
        if let worst, worst >= .conserving {
            return (.trouble, worst.effect)
        }
        if let worst, worst == .saving {
            return (.watch, worst.effect)
        }

        for device in sensing {
            guard let trend = device.vitals?.trend, trend.isFalling,
                  let drift = trend.driftVolts else { continue }
            let drop = String(format: "%.2f", -drift)
            return (.watch, "The battery on \(device.name) is down \(drop) V across the week. It isn't keeping up with what it's spending.")
        }

        // A NIGHTLY DIP IS NOT A FAULT, and this is the line where that has to be
        // said. Most Tempests spend their whole lives in mode 0 but a great many
        // touch mode 1 at four in the morning after a cloudy day, recover by
        // noon, and are in perfect health. Flagging that orange would put a
        // warning on this page most weeks, and a page that cries wolf is one
        // nobody reads on the week it matters. So the dip is REPORTED and not
        // WARNED about until it reaches mode 2, which is where gust peaks stop
        // being trustworthy.
        let dip = sensing.compactMap { $0.vitals?.trend.worstMode }.max()
        if let dip, dip >= .conserving {
            return (.watch, "Fully charged now, but it fell to \(dip.title.localizedLowercase) overnight this week — wind from those hours is coarser than the rest of the record.")
        }
        if dip == .saving {
            return (.good, "Reporting on time, every sensor answering. It dips into power saving some nights and recovers by day, which is ordinary for a solar station.")
        }

        return (.good, "Reporting on time, every sensor answering, battery holding.")
    }

    /// "11 hours", "4 minutes" — a duration at the coarsest grain that's still
    /// true, because this is read as prose in a sentence, not compared.
    static func spell(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return "\(max(1, minutes)) minute\(minutes == 1 ? "" : "s")"
        }
        let hours = minutes / 60
        if hours < 48 {
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        return "\(hours / 24) days"
    }
}

// MARK: - Reading the wire

/// The column layout of one device-observation payload.
///
/// NAMED PER `type`, NEVER ASSUMED. The device endpoint returns bare arrays with
/// no `ob_fields` to go with them — the one place in this API where positions
/// are unavoidable — so the response's own `type` discriminator picks the
/// layout, and an unrecognised type yields nothing rather than reading a
/// Tempest's battery column out of a Sky's row. That would put a plausible
/// voltage on screen and could only ever be wrong.
struct DeviceObservationLayout {
    var battery: Int
    var reportInterval: Int
    /// The columns behind each instrument. An instrument counts as reporting if
    /// ANY of its columns carried a value, so a Tempest that reports a wind
    /// direction but no gust still reads as a live anemometer.
    var sensors: [(SensorKind, [Int])]

    static func forType(_ type: String?) -> DeviceObservationLayout? {
        switch type {
        case "obs_st":
            return DeviceObservationLayout(battery: 16, reportInterval: 17, sensors: [
                (.wind, [1, 2, 3, 4]),
                (.temperature, [7, 8]),
                (.pressure, [6]),
                (.light, [9, 10, 11]),
                (.rain, [12]),
                (.lightning, [14, 15]),
            ])
        case "obs_air":
            return DeviceObservationLayout(battery: 6, reportInterval: 7, sensors: [
                (.temperature, [2, 3]),
                (.pressure, [1]),
                (.lightning, [4, 5]),
            ])
        case "obs_sky":
            return DeviceObservationLayout(battery: 8, reportInterval: 9, sensors: [
                (.wind, [4, 5, 6, 7]),
                (.light, [1, 2, 10]),
                (.rain, [3]),
            ])
        default:
            return nil
        }
    }

    func value(_ index: Int, in row: [Double?]) -> Double? {
        guard index < row.count else { return nil }
        return row[index]
    }

    func reports(_ columns: [Int], in row: [Double?]) -> Bool {
        columns.contains { value($0, in: row) != nil }
    }
}

/// `observations/device/{id}` — bare arrays, discriminated by `type`.
struct DeviceObservations: Decodable {
    var deviceID: Int?
    var type: String?
    var obs: [[Double?]]

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case type
        case obs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decodeIfPresent(Int.self, forKey: .deviceID)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        obs = try c.decodeIfPresent([[Double?]].self, forKey: .obs) ?? []
    }

    var latest: [Double?]? { obs.last }

    /// Vitals from the newest row, with the trend supplied separately.
    ///
    /// `reportInterval` is read HERE and only here, from an unwindowed fetch.
    /// The same column in a ranged response carries the server's bucket size —
    /// a week-long fetch reports "30" for a station that speaks every minute —
    /// and reading it from there would make a perfectly healthy station look
    /// like it had throttled itself.
    func vitals(trend: BatteryTrend = BatteryTrend(readings: [])) -> DeviceVitals? {
        guard let layout = DeviceObservationLayout.forType(type),
              let row = latest,
              let stamp = layout.value(0, in: row) else { return nil }
        return DeviceVitals(
            observedAt: Date(timeIntervalSince1970: stamp),
            battery: layout.value(layout.battery, in: row),
            reportInterval: layout.value(layout.reportInterval, in: row).map { Int($0) },
            sensors: layout.sensors.map { SensorReport(kind: $0.0, isReporting: layout.reports($0.1, in: row)) },
            trend: trend)
    }

    /// Battery over the window. Rows are the server's buckets, not raw reports,
    /// which is exactly what's wanted: the question is the shape of the nightly
    /// floor across a week, and a week of one-minute rows would be ten thousand
    /// points drawing the same curve.
    func batteryTrend() -> BatteryTrend {
        guard let layout = DeviceObservationLayout.forType(type) else {
            return BatteryTrend(readings: [])
        }
        return BatteryTrend(readings: obs.compactMap { row in
            guard let stamp = layout.value(0, in: row),
                  let volts = layout.value(layout.battery, in: row) else { return nil }
            return BatteryReading(date: Date(timeIntervalSince1970: stamp), volts: volts)
        })
    }
}

// MARK: - Fetching

extension TempestClient {

    /// How much battery history to draw. A week covers seven nightly lows, which
    /// is the shortest window in which "the floor is dropping" can be told apart
    /// from "it was cloudy yesterday".
    public static let batteryTrendDays = 7

    /// The whole check: the registry entry, then each sensing unit's latest
    /// observation and its week of battery.
    ///
    /// ONE FAILING DEVICE MUST NOT FAIL THE CHECK. A station with a Tempest and
    /// an old Air where the Air has been offline for a year should say exactly
    /// that, not throw — so per-device errors are caught and recorded as a
    /// `note` on the device they belong to. Only the registry call can throw,
    /// because without it there is nothing to report at all.
    public func health(now: Date = Date()) async throws -> StationHealth {
        guard !token.isEmpty, stationID != 0 else { throw Failure.notConfigured }

        let entry = try await stationEntry()
        var health = StationHealth(stationID: stationID,
                                   name: entry.displayName,
                                   timeZone: entry.timezone.flatMap(TimeZone.init(identifier:)),
                                   elevation: entry.stationMeta?.elevation,
                                   checkedAt: now)

        let devices = entry.devices.map(\.health)
        health.devices = await withTaskGroup(of: (Int, DeviceHealth).self) { group in
            for (offset, device) in devices.enumerated() {
                group.addTask {
                    guard device.kind.senses else {
                        var resolved = device
                        resolved.note = "The hub relays the other units. It has no readings of its own, and no battery — if it's unplugged, nothing above will be current."
                        return (offset, resolved)
                    }
                    var resolved = device
                    do {
                        let trend = try await self.batteryTrend(deviceID: device.id, now: now)
                        let latest = try await self.deviceObservations(deviceID: device.id)
                        resolved.vitals = latest.vitals(trend: trend)
                        if resolved.vitals == nil {
                            resolved.note = "Reached the station, but it returned no readings to check."
                        }
                    } catch {
                        resolved.note = (error as? Failure)?.errorDescription ?? error.localizedDescription
                    }
                    return (offset, resolved)
                }
            }
            var collected: [(Int, DeviceHealth)] = []
            for await result in group { collected.append(result) }
            // Restored to registry order: a task group finishes in whatever
            // order the network allows, and a list of hardware that reshuffles
            // itself on every refresh is unreadable.
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return health
    }

    /// The newest single observation for one device.
    func deviceObservations(deviceID: Int) async throws -> DeviceObservations {
        var components = URLComponents(string: "https://swd.weatherflow.com/swd/rest/observations/device/\(deviceID)")!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return try await fetchDeviceObservations(components)
    }

    /// A window of battery readings for one device.
    func batteryTrend(deviceID: Int, days: Int = TempestClient.batteryTrendDays,
                      now: Date = Date()) async throws -> BatteryTrend {
        var components = URLComponents(string: "https://swd.weatherflow.com/swd/rest/observations/device/\(deviceID)")!
        let start = now.addingTimeInterval(-Double(days) * 86_400)
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "time_start", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "time_end", value: String(Int(now.timeIntervalSince1970))),
        ]
        return try await fetchDeviceObservations(components).batteryTrend()
    }

    private func fetchDeviceObservations(_ components: URLComponents) async throws -> DeviceObservations {
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        // A hub answers this endpoint with a genuine 404 ("must be a Tempest,
        // Air or Sky device"), which is why `health()` never asks one.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(status: http.statusCode)
        }
        do {
            return try Self.makeDecoder().decode(DeviceObservations.self, from: data)
        } catch {
            throw Failure.decoding(error)
        }
    }

    /// This station's registry entry, devices and all.
    ///
    /// A fourth reading of `/stations` — `stationCreated` takes the creation
    /// date, `stations(token:)` takes identity and location, and this one takes
    /// the hardware inventory. Separate types rather than one union for the
    /// reason `StationDiscovery` already gives: each call wants different
    /// tolerance for a field it can't read, and merging them would force the
    /// strictest one on all three.
    func stationEntry() async throws -> StationRegistryEntry {
        var components = URLComponents(string: "https://swd.weatherflow.com/swd/rest/stations/\(stationID)")!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(status: http.statusCode)
        }
        let payload: StationRegistry
        do {
            payload = try Self.makeDecoder().decode(StationRegistry.self, from: data)
        } catch {
            throw Failure.decoding(error)
        }
        // Matched by id rather than taking the first: the endpoint is addressed
        // by station, but a token that can see several has no guarantee about
        // ordering, and reporting another station's hardware is worse than
        // reporting none.
        guard let entry = payload.stations.first(where: { $0.stationId == stationID })
                ?? payload.stations.first else {
            throw Failure.badResponse(status: 404)
        }
        return entry
    }

    struct StationRegistry: Decodable {
        var stations: [StationRegistryEntry]
        enum CodingKeys: String, CodingKey { case stations }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stations = try c.decodeIfPresent([StationRegistryEntry].self, forKey: .stations) ?? []
        }
    }

    struct StationRegistryEntry: Decodable {
        var stationId: Int = 0
        var name: String?
        var publicName: String?
        var timezone: String?
        var stationMeta: StationMeta?
        var devices: [DeviceEntry] = []

        enum CodingKeys: String, CodingKey {
            case stationId = "station_id"
            case name
            case publicName = "public_name"
            case timezone
            case stationMeta = "station_meta"
            case devices
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stationId = try c.decodeIfPresent(Int.self, forKey: .stationId) ?? 0
            name = try c.decodeIfPresent(String.self, forKey: .name)
            publicName = try c.decodeIfPresent(String.self, forKey: .publicName)
            timezone = try c.decodeIfPresent(String.self, forKey: .timezone)
            stationMeta = try c.decodeIfPresent(StationMeta.self, forKey: .stationMeta)
            devices = try c.decodeIfPresent([DeviceEntry].self, forKey: .devices) ?? []
        }

        /// Same preference as `StationDiscovery`: `public_name` is what the
        /// station is called in the Tempest app, which is the name the user
        /// recognises.
        var displayName: String {
            let label = [publicName, name]
                .compactMap { $0 }
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return label ?? "Station \(stationId)"
        }

        struct StationMeta: Decodable {
            var elevation: Double?
        }

        struct DeviceEntry: Decodable {
            var deviceId: Int = 0
            var deviceType: String?
            var serialNumber: String?
            var firmwareRevision: String?
            var hardwareRevision: String?
            var deviceMeta: DeviceMeta?

            enum CodingKeys: String, CodingKey {
                case deviceId = "device_id"
                case deviceType = "device_type"
                case serialNumber = "serial_number"
                case firmwareRevision = "firmware_revision"
                case hardwareRevision = "hardware_revision"
                case deviceMeta = "device_meta"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                deviceId = try c.decodeIfPresent(Int.self, forKey: .deviceId) ?? 0
                deviceType = try c.decodeIfPresent(String.self, forKey: .deviceType)
                serialNumber = try c.decodeIfPresent(String.self, forKey: .serialNumber)
                firmwareRevision = try c.decodeIfPresent(String.self, forKey: .firmwareRevision)
                hardwareRevision = try c.decodeIfPresent(String.self, forKey: .hardwareRevision)
                deviceMeta = try c.decodeIfPresent(DeviceMeta.self, forKey: .deviceMeta)
            }

            struct DeviceMeta: Decodable {
                var agl: Double?
                var environment: String?
                var name: String?
            }

            var health: DeviceHealth {
                let kind = DeviceKind(code: deviceType)
                let serial = serialNumber ?? "\(deviceId)"
                let meta = deviceMeta?.name?.trimmingCharacters(in: .whitespaces)
                return DeviceHealth(
                    id: deviceId,
                    kind: kind,
                    serial: serial,
                    // The registry names a unit after its serial by default,
                    // which is no better than the serial we already show. A
                    // renamed unit keeps its name; an unrenamed one falls back
                    // to what it IS.
                    name: (meta?.isEmpty == false && meta != serial) ? meta! : kind.label,
                    firmware: firmwareRevision,
                    hardware: hardwareRevision,
                    heightAboveGround: deviceMeta?.agl,
                    environment: deviceMeta?.environment)
            }
        }
    }
}
