//
//  SettingsSync.swift  (WeatherKit)
//
//  The station and the home point, carried between this person's own devices.
//
//  THE PROBLEM IT EXISTS FOR. Set the Mac up, then the iPad, then the Apple TV,
//  and you configure the same station three times. The TV is the worst of the
//  three by a distance: a personal-use token is a UUID, and the fallback the TV
//  setup offers instead — type a latitude and a longitude — is not the smaller
//  ask it looks like. You have to go and FIND two signed decimals, enter them on
//  a remote, and a wrong digit in a longitude does not fail, it silently shows
//  you a stranger's weather.
//
//  WHY KEY-VALUE STORAGE AND NOT THE KEYCHAIN. A token is a credential and the
//  synced Keychain is where credentials belong — except tvOS has no iCloud
//  Keychain at all, so the one device that most needs this would be the one
//  device it could not reach. `NSUbiquitousKeyValueStore` runs on all three.
//  The token is a read-only data token rather than a password (see
//  `AppSettings`), which is what makes that trade acceptable rather than merely
//  convenient. It is also already sitting in plain `UserDefaults` on every
//  device, so this moves nothing across a line it had not already crossed.
//
//  TWO RECORDS, NOT SIX KEYS, AND THIS IS THE LOAD-BEARING DECISION. KVS
//  resolves conflicts per key, last writer wins, with no timestamps of its own.
//  Six independent keys therefore permit a state no device ever wrote: a token
//  from the Mac next to a station id from the TV. Token, id and name are ONE
//  fact — which station you are reading — and latitude and longitude are
//  another. Each travels as a unit, with its own timestamp, and a device adopts
//  a record whole or not at all.
//
//  WHAT DELIBERATELY DOES NOT SYNC. `homeFacing` — which way the house looks —
//  because it is for a person standing in their own doorway and means nothing to
//  a room with other people in it; `TVSetupView` already refuses to ask for it.
//  And `hasSeenSetup`, which is a fact about THIS INSTALL's first run, not about
//  the person.
//

import Foundation

/// Which station this person reads. Travels as one value because a token that
/// does not match its station id is not a partial answer, it is a broken one.
public struct StationIdentity: Codable, Equatable, Sendable {
    public var token: String
    public var stationID: Int
    public var name: String

    public init(token: String, stationID: Int, name: String) {
        self.token = token
        self.stationID = stationID
        self.name = name
    }

    /// A record worth carrying. An empty token or a zero id is the "not set up
    /// yet" state, and publishing it would be how a fresh install erases a
    /// configured one.
    public var isUsable: Bool { !token.isEmpty && stationID != 0 }
}

/// Where "here" is. Radar centres on it and NWS warnings are matched against it.
public struct HomeLocation: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Zero is the app's "unset" everywhere else rather than the Gulf of Guinea,
    /// and the same reasoning applies to what gets published.
    public var isUsable: Bool { latitude != 0 || longitude != 0 }
}

/// A value and when it was last set, which is the part KVS does not provide.
private struct Stamped<Value: Codable & Equatable>: Codable {
    var value: Value
    var updatedAt: Date
}

@MainActor
public final class SettingsSync {
    public static let shared = SettingsSync()

    /// Raised when another device changed something. The owner re-reads rather
    /// than being handed a diff: there are two records, and re-reading both is
    /// cheaper than describing which one moved.
    public var onRemoteChange: (@MainActor () -> Void)?

    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?

    private enum Key {
        static let station = "sync.station"
        static let home = "sync.home"
    }

    private init() {}

    /// Begin listening. Safe to call when the iCloud entitlement is absent or the
    /// user is signed out — KVS then behaves as a local dictionary that never
    /// syncs, every read returns what this device wrote, and nothing fails.
    /// That is the whole degradation story: the app works, the carrying just
    /// hasn't happened.
    public func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onRemoteChange?() }
        }
        store.synchronize()
    }

    // MARK: Reading

    public func station() -> (value: StationIdentity, updatedAt: Date)? {
        read(Key.station)
    }

    public func home() -> (value: HomeLocation, updatedAt: Date)? {
        read(Key.home)
    }

    private func read<Value: Codable & Equatable>(_ key: String) -> (value: Value, updatedAt: Date)? {
        guard let data = store.data(forKey: key),
              let stamped = try? JSONDecoder().decode(Stamped<Value>.self, from: data)
        else { return nil }
        return (stamped.value, stamped.updatedAt)
    }

    // MARK: Writing

    /// Publish a station, unless it would overwrite something better.
    ///
    /// TWO GUARDS, AND BOTH HAVE BITTEN REAL SYNC CODE. An unusable value is
    /// never published, so a fresh install's empty defaults cannot erase a
    /// configured device. And an unchanged value is never republished, because
    /// every write is a notification to every other device and a mirror that
    /// echoes what it just received is a loop.
    @discardableResult
    public func publish(station: StationIdentity) -> Bool {
        guard station.isUsable else { return false }
        return write(Key.station, station)
    }

    @discardableResult
    public func publish(home: HomeLocation) -> Bool {
        guard home.isUsable else { return false }
        return write(Key.home, home)
    }

    private func write<Value: Codable & Equatable>(_ key: String, _ value: Value) -> Bool {
        if let existing: (value: Value, updatedAt: Date) = read(key), existing.value == value {
            return false
        }
        guard let data = try? JSONEncoder().encode(Stamped(value: value, updatedAt: Date()))
        else { return false }
        store.set(data, forKey: key)
        store.synchronize()
        return true
    }
}
