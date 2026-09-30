//
//  Settings.swift  (Weather)
//
//  What Almanac's `Core.AppSettings` was, reduced to the six fields the weather
//  views actually read. The extraction survey found no other coupling: not one
//  view touches a block, a vault, or a document — weather only ever needed to
//  know WHERE you are, WHICH WAY you face, and HOW to reach your station.
//
//  Kept as an `ObservableObject` rather than modernised to `@Observable` so the
//  copied views' `@EnvironmentObject` declarations compile unchanged. Worth
//  revisiting once the app builds; not worth mixing into the move.
//

import Foundation
import CoreLocation
import Combine
import WeatherKit

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    // MARK: Home

    /// The point every local answer is relative to. Zero means "not set" rather
    /// than the Gulf of Guinea — `hasHome` is the guard every caller uses.
    @Published var homeLat: Double { didSet { defaults.set(homeLat, forKey: "homeLat"); syncHome() } }
    @Published var homeLon: Double { didSet { defaults.set(homeLon, forKey: "homeLon"); syncHome() } }

    var hasHome: Bool { homeLat != 0 || homeLon != 0 }
    /// Optional on purpose: "no home set" is a real state, and a zeroed
    /// coordinate would put you in the Gulf of Guinea rather than admit it.
    var homeCoordinate: CLLocationCoordinate2D? {
        hasHome ? CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon) : nil
    }

    /// Which way the house looks, in degrees true. Weather is issued north-up but
    /// READ by a person facing some way; storing the facing once is what lets
    /// "the wind is on the back of the house" be sayable at all. `-1` is unset,
    /// which `facing` turns into the honest `nil`.
    @Published var homeFacing: Double { didSet { defaults.set(homeFacing, forKey: "homeFacing") } }
    var facing: Double? { homeFacing >= 0 ? homeFacing : nil }

    // MARK: Station

    /// A personal-use token from tempestwx.com → Settings → Data Authorizations,
    /// and the numeric station id.
    @Published var tempestToken: String { didSet { defaults.set(tempestToken, forKey: "tempestToken"); syncStation() } }
    @Published var tempestStationID: Int { didSet { defaults.set(tempestStationID, forKey: "tempestStationID"); syncStation() } }

    /// What the station is CALLED. Carries no behaviour — nothing fetches by it —
    /// but a sidebar that says "Backyard" instead of "Station 12345" is the
    /// difference between an app that knows where it lives and one that was
    /// handed a number, and setup already learns the name on the way past.
    @Published var stationName: String { didSet { defaults.set(stationName, forKey: "stationName"); syncStation() } }

    var hasWeatherStation: Bool { !tempestToken.isEmpty && tempestStationID != 0 }

    /// The label for the configured station: its name when setup learned one,
    /// and the bare id when the token was typed into Settings by hand.
    var stationLabel: String {
        if !stationName.isEmpty { return stationName }
        return tempestStationID != 0 ? "Station \(tempestStationID)" : "No station"
    }

    // MARK: Setup

    /// Whether the first-run flow has been seen through — NOT whether the app is
    /// configured. The two come apart on purpose: Radar and Pattern work with no
    /// station at all, so "skip for now" is a legitimate ending, and a user who
    /// took it must not be handed the same sheet on every launch. `needsSetup`
    /// is what the nudge in the sidebar reads instead.
    @Published var hasSeenSetup: Bool { didSet { defaults.set(hasSeenSetup, forKey: "hasSeenSetup") } }

    /// Something the app still needs and cannot work out for itself. Home alone
    /// counts: it is what radar centres on and what the hazard poll asks about.
    var needsSetup: Bool { !hasWeatherStation || !hasHome }

    /// Everything setup learns from one chosen station, applied together.
    ///
    /// The coordinate is only taken when the station HAS one and home is still
    /// unset: a user who has already placed their home — the porch, not the pole
    /// at the bottom of the garden — has said something more precise than the
    /// station registry knows, and a later re-run of setup must not overwrite it.
    func apply(token: String, station: TempestStation) {
        // BATCHED, AND THAT IS NOT A PERFORMANCE POINT. Each of these three
        // assignments fires its own `didSet`, so publishing per-property would
        // broadcast the moment when the new token sits beside the OLD station
        // id — a pair that names a station this token cannot read, sent to every
        // other device as though it were a fact. One publish, once the three
        // agree. See `SettingsSync` on why they travel as a unit.
        isBatching = true
        tempestToken = token
        tempestStationID = station.id
        stationName = station.name
        if !hasHome, let lat = station.latitude, let lon = station.longitude {
            homeLat = lat
            homeLon = lon
        }
        isBatching = false
        syncStation()
        syncHome()
    }

    // MARK: Carrying settings between this person's devices

    /// True while remote values are being written into local properties, so the
    /// `didSet`s they trip don't publish straight back out. A mirror that echoes
    /// what it was just handed is a loop.
    private var isApplyingRemote = false
    /// True while several related properties are being set together.
    private var isBatching = false

    /// Start listening, and reconcile once with whatever is already up there.
    ///
    /// Called from the app's root rather than from `init`, because it can fire
    /// `onRemoteChange` immediately and a half-constructed settings object is
    /// not a thing to hand a callback.
    func startSync() {
        let sync = SettingsSync.shared
        sync.onRemoteChange = { [weak self] in self?.reconcile() }
        sync.start()
        reconcile()
    }

    /// Adopt anything remote that is newer, then publish anything local that is.
    ///
    /// Adoption runs first so that a device which has just been handed a better
    /// record doesn't immediately overwrite it with the one it woke up holding.
    private func reconcile() {
        isApplyingRemote = true
        adoptStation()
        adoptHome()
        isApplyingRemote = false
        syncStation()
        syncHome()
    }

    private func adoptStation() {
        guard let remote = SettingsSync.shared.station() else { return }
        let local = StationIdentity(token: tempestToken, stationID: tempestStationID, name: stationName)
        guard remote.value != local,
              shouldAdopt(remote.updatedAt, localKey: "stationUpdatedAt", localIsUsable: local.isUsable)
        else { return }
        tempestToken = remote.value.token
        tempestStationID = remote.value.stationID
        stationName = remote.value.name
        defaults.set(remote.updatedAt, forKey: "stationUpdatedAt")
    }

    private func adoptHome() {
        guard let remote = SettingsSync.shared.home() else { return }
        let local = HomeLocation(latitude: homeLat, longitude: homeLon)
        guard remote.value != local,
              shouldAdopt(remote.updatedAt, localKey: "homeUpdatedAt", localIsUsable: local.isUsable)
        else { return }
        homeLat = remote.value.latitude
        homeLon = remote.value.longitude
        defaults.set(remote.updatedAt, forKey: "homeUpdatedAt")
    }

    /// AN UNCONFIGURED DEVICE ALWAYS YIELDS, whatever the clocks say. Comparing
    /// timestamps is right between two devices that both have an answer; against
    /// one that has none it is a way for a stale clock to keep a blank install
    /// blank. Only once there is something to lose does recency decide.
    private func shouldAdopt(_ remoteAt: Date, localKey: String, localIsUsable: Bool) -> Bool {
        guard localIsUsable else { return true }
        let localAt = defaults.object(forKey: localKey) as? Date ?? .distantPast
        return remoteAt > localAt
    }

    private func syncStation() {
        guard !isApplyingRemote, !isBatching else { return }
        let identity = StationIdentity(token: tempestToken, stationID: tempestStationID, name: stationName)
        if SettingsSync.shared.publish(station: identity) {
            defaults.set(Date(), forKey: "stationUpdatedAt")
        }
    }

    private func syncHome() {
        guard !isApplyingRemote, !isBatching else { return }
        if SettingsSync.shared.publish(home: HomeLocation(latitude: homeLat, longitude: homeLon)) {
            defaults.set(Date(), forKey: "homeUpdatedAt")
        }
    }

    init() {
        homeLat = defaults.double(forKey: "homeLat")
        homeLon = defaults.double(forKey: "homeLon")
        homeFacing = defaults.object(forKey: "homeFacing") as? Double ?? -1
        tempestToken = defaults.string(forKey: "tempestToken") ?? ""
        tempestStationID = defaults.integer(forKey: "tempestStationID")
        stationName = defaults.string(forKey: "stationName") ?? ""
        hasSeenSetup = defaults.bool(forKey: "hasSeenSetup")
    }
}

/// Where the archive lives.
///
/// THE GROUP CONTAINER ON THE MAC, so Vane and Vane Dev (the Debug build, a
/// separate app) read one archive — and `ArchiveFileLock` keeps them from
/// writing the same file at once. The group is reachable from inside the App
/// Sandbox, which is what let the Mac app be sandboxed at all.
///
/// APPLICATION SUPPORT EVERYWHERE ELSE. The iOS app claims no group (see
/// project.yml), so `containerURL(for:)` is nil there and the archive lives in
/// the app's own sandbox — the right home until a widget needs to share it.
///
/// THE FALLBACK FOLDER IS STILL CALLED `Almanac`, and that is a pointer, not a
/// name. It is where the iPhone and iPad archives already are; renaming it would
/// strand them. Nothing here reads Almanac's own files any more: the Mac archive
/// moved into the group container in September 2026 and the one-time move was
/// removed when the Mac app was sandboxed, since a sandboxed app cannot see the
/// old folder anyway.
enum AppGroup {
    /// macOS requires the team id as a prefix; iOS and tvOS do not. Same suffix
    /// on all three so a phone or TV target later addresses the same group.
    static let identifier: String = {
        #if os(macOS)
        return "CG68B3UD28.group.jdm-solutions.vane"
        #else
        return "group.jdm-solutions.vane"
        #endif
    }()

    /// Where the archive lives when there is no group container. See above for
    /// why the folder keeps its old name.
    static var fallbackDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Almanac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolved once per launch. Every caller wants a stable URL synchronously,
    /// and re-deciding per call would risk two answers in one session.
    static var dataDirectory: URL { resolved }

    private static let resolved: URL = resolve()

    private static func resolve() -> URL {
        let fm = FileManager.default
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            return fallbackDirectory
        }
        try? fm.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }
}
