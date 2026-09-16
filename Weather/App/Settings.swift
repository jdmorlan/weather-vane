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

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    // MARK: Home

    /// The point every local answer is relative to. Zero means "not set" rather
    /// than the Gulf of Guinea — `hasHome` is the guard every caller uses.
    @Published var homeLat: Double { didSet { defaults.set(homeLat, forKey: "homeLat") } }
    @Published var homeLon: Double { didSet { defaults.set(homeLon, forKey: "homeLon") } }

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
    @Published var tempestToken: String { didSet { defaults.set(tempestToken, forKey: "tempestToken") } }
    @Published var tempestStationID: Int { didSet { defaults.set(tempestStationID, forKey: "tempestStationID") } }

    var hasWeatherStation: Bool { !tempestToken.isEmpty && tempestStationID != 0 }

    init() {
        homeLat = defaults.double(forKey: "homeLat")
        homeLon = defaults.double(forKey: "homeLon")
        homeFacing = defaults.object(forKey: "homeFacing") as? Double ?? -1
        tempestToken = defaults.string(forKey: "tempestToken") ?? ""
        tempestStationID = defaults.integer(forKey: "tempestStationID")
    }
}

/// Where the archive lives.
///
/// Deliberately still Almanac's directory. The station has years of one-minute
/// samples on disk (`samples/`, `daily/`, `forecasts/`, `upper-air/`) and the
/// whole point of that archive is that it is CONTINUOUS — standing this app up
/// against an empty folder would make every "compared to the record" answer
/// silent on day one, and forking the archive would give two apps two different
/// pasts. One truth, read and written from here until the split is decided.
enum AppGroup {
    static var dataDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Almanac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
