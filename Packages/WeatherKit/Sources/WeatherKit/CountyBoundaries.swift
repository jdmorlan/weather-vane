//
//  CountyBoundaries.swift  (WeatherKit)
//
//  Every US county's outline, from the Census Bureau's 1:5,000,000 cartographic
//  boundary file, bundled rather than fetched. Counties change about once a
//  decade (Connecticut's planning regions in 2022 were the last), so a network
//  request per launch would be buying nothing but a way to fail.
//
//  WHY THE MAP WANTS THEM. Watches, outlooks and most of what the NWS says out
//  loud are issued in counties: "a Slight risk for Travis and Hays counties" is
//  only a sentence you can place if the lines are on the map. The base map draws
//  states and nothing finer.
//
//  `Scripts/build-county-boundaries.sh` rebuilds the file and says why it is
//  shaped the way it is.
//

import Foundation

public struct County: Sendable, Identifiable {
    /// The five-digit FIPS code: state then county, "48453".
    public let geoid: String
    /// "Travis" — without "County", which Louisiana, Alaska and Virginia's
    /// independent cities would each spell differently.
    public let name: String
    /// "TX".
    public let state: String
    /// Every ring, outer boundary and hole alike. Only ever DRAWN — no county
    /// question here needs to know which ring is which.
    public let rings: [[GeoPoint]]

    public var id: String { geoid }
}

public enum CountyBoundaries {
    public enum Failure: Error {
        case missingResource
    }

    public static let resourceName = "census-counties-5m"

    /// Decode the bundled file. About 220,000 points, so call it off the main
    /// thread; the app loads it once and keeps it.
    public static func load() throws -> [County] {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "json.gz") else {
            throw Failure.missingResource
        }
        return try decode(Gzip.decompress(Data(contentsOf: url)))
    }

    /// The file's shape: rings stored flat, `[lon, lat, lon, lat, …]`, which
    /// decodes several times faster than GeoJSON's nested pairs and is the same
    /// numbers in the same order.
    static func decode(_ data: Data) throws -> [County] {
        struct File: Decodable {
            struct Entry: Decodable {
                var geoid: String
                var name: String
                var state: String
                var rings: [[Double]]
            }
            var counties: [Entry]
        }
        return try JSONDecoder().decode(File.self, from: data).counties.map { entry in
            County(geoid: entry.geoid, name: entry.name, state: entry.state,
                   rings: entry.rings.map { flat in
                       stride(from: 0, to: flat.count - 1, by: 2).map {
                           GeoPoint(latitude: flat[$0 + 1], longitude: flat[$0])
                       }
                   })
        }
    }

    /// The county a point is in, or nil offshore and outside the US.
    ///
    /// Even-odd over every ring, which is correct for holes without having to
    /// know which ring is one — the same test `GeoShape` runs per ring.
    public static func county(containing point: GeoPoint, in counties: [County]) -> County? {
        counties.first { county in
            county.rings.reduce(false) { inside, ring in
                GeoShape.ringContains(ring, point) ? !inside : inside
            }
        }
    }
}
