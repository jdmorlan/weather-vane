//
//  TVSettings.swift  (tvOS)
//
//  The two-and-a-bit things the TV app has to be told, and nowhere near the six
//  the Mac app keeps.
//
//  No facing: the egocentric phrasings ("on the back of the house") are for
//  someone standing in their own doorway, not for a room with other people in
//  it. No archive paths: nothing here is archived.
//
//  `UserDefaults` rather than a file, because tvOS may purge an app's container
//  and defaults is the one store the system carries for you. It is limited to
//  about 500KB, which is several thousand times what this needs.
//

import Foundation
import Combine
import CoreLocation
import WeatherKit

@MainActor
final class TVSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var homeLat: Double { didSet { defaults.set(homeLat, forKey: "homeLat"); syncHome() } }
    @Published var homeLon: Double { didSet { defaults.set(homeLon, forKey: "homeLon"); syncHome() } }
    @Published var tempestToken: String { didSet { defaults.set(tempestToken, forKey: "tempestToken"); syncStation() } }
    @Published var tempestStationID: Int { didSet { defaults.set(tempestStationID, forKey: "tempestStationID"); syncStation() } }
    @Published var stationName: String { didSet { defaults.set(stationName, forKey: "stationName"); syncStation() } }

    var hasHome: Bool { homeLat != 0 || homeLon != 0 }
    var homeCoordinate: CLLocationCoordinate2D? {
        hasHome ? CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon) : nil
    }
    var homePoint: GeoPoint? {
        hasHome ? GeoPoint(latitude: homeLat, longitude: homeLon) : nil
    }
    var hasStation: Bool { !tempestToken.isEmpty && tempestStationID != 0 }

    init() {
        homeLat = defaults.double(forKey: "homeLat")
        homeLon = defaults.double(forKey: "homeLon")
        tempestToken = defaults.string(forKey: "tempestToken") ?? ""
        tempestStationID = defaults.integer(forKey: "tempestStationID")
        stationName = defaults.string(forKey: "stationName") ?? ""
    }

    func apply(token: String, station: TempestStation) {
        // One publish once the three agree, not one per property. See
        // `AppSettings.apply` and `SettingsSync`.
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

    // MARK: Carrying settings from the person's other devices

    /// THIS IS THE TARGET THE WHOLE MECHANISM WAS BUILT FOR. `TVSetupView` opens
    /// by admitting that a token is the wrong thing to ask a television for and
    /// offers two coordinates instead — but finding a latitude and a longitude
    /// and entering them on a remote is not the smaller ask it looks like, and a
    /// wrong digit shows you a stranger's weather without failing. A Mac or iPad
    /// that is already set up can simply hand the TV all of it.
    ///
    /// It also earns its place a second way. This file already notes that tvOS
    /// may purge an app's container; a TV that loses its defaults now recovers
    /// them from the person's other devices instead of asking again.
    private var isApplyingRemote = false
    private var isBatching = false

    func startSync() {
        let sync = SettingsSync.shared
        sync.onRemoteChange = { [weak self] in self?.reconcile() }
        sync.start()
        reconcile()
    }

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
}
