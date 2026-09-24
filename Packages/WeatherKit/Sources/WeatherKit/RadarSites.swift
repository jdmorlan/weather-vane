//
//  RadarSites.swift  (WeatherKit)
//
//  Every WSR-88D in the NEXRAD network, and which one is closest to a point.
//
//  BUNDLED, NOT FETCHED. The list comes from api.weather.gov/radar/stations
//  (stationType=WSR-88D, 159 sites, pulled 2026-09-24) and changes on the
//  scale of decades. Asking the network for it at launch would make "which
//  radar am I near" depend on the NWS API being up, for an answer that has not
//  changed since the last build.
//

import Foundation

public struct RadarSite: Hashable, Sendable, Identifiable {
    /// Four-letter ICAO, e.g. "KFWS". Also the key in the Level II buckets.
    public let id: String
    public let name: String
    public let latitude: Double
    public let longitude: Double

    init(_ id: String, _ name: String, _ latitude: Double, _ longitude: Double) {
        self.id = id; self.name = name
        self.latitude = latitude; self.longitude = longitude
    }

    /// Great-circle distance to a point, metres.
    public func distance(toLatitude lat: Double, longitude lon: Double) -> Double {
        RadarGeometry.groundPath(fromLatitude: latitude, longitude: longitude,
                                 toLatitude: lat, longitude: lon).distance
    }
}

public enum RadarSites {

    public static func site(_ id: String) -> RadarSite? { all.first { $0.id == id } }

    /// The sites nearest a point, closest first.
    public static func nearest(latitude: Double, longitude: Double, count: Int = 1) -> [RadarSite] {
        all.map { ($0, $0.distance(toLatitude: latitude, longitude: longitude)) }
            .sorted { $0.1 < $1.1 }
            .prefix(count)
            .map(\.0)
    }

    public static let all: [RadarSite] = [
        .init("KABR", "Aberdeen", 45.45583, -98.41305),
        .init("KABX", "Albuquerque", 35.14972, -106.82388),
        .init("KAKQ", "Norfolk", 36.98388, -77.00750),
        .init("KAMA", "Amarillo", 35.23333, -101.70927),
        .init("KAMX", "Miami", 25.61055, -80.41305),
        .init("KAPX", "NCL Michigan", 44.90634, -84.71953),
        .init("KARX", "La Crosse", 43.82277, -91.19110),
        .init("KATX", "Seattle", 48.19461, -122.49568),
        .init("KBBX", "Beale AFB", 39.49611, -121.63165),
        .init("KBGM", "Binghamton", 42.19969, -75.98472),
        .init("KBHX", "Eureka (Bunker Hill)", 40.49833, -124.29215),
        .init("KBIS", "Bismarck", 46.77083, -100.76027),
        .init("KBLX", "Billings", 45.85377, -108.60679),
        .init("KBMX", "Birmingham", 33.17194, -86.76972),
        .init("KBOX", "Boston", 41.95577, -71.13686),
        .init("KBRO", "Brownsville", 25.91555, -97.41860),
        .init("KBUF", "Buffalo", 42.94860, -78.73694),
        .init("KBYX", "Key West", 24.59694, -81.70333),
        .init("KCAE", "Columbia", 33.94860, -81.11861),
        .init("KCBW", "Caribou", 46.03916, -67.80642),
        .init("KCBX", "Boise", 43.49021, -116.23602),
        .init("KCCX", "State College", 40.92305, -78.00389),
        .init("KCLE", "Cleveland", 41.41305, -81.86000),
        .init("KCLX", "Charleston,SC", 32.65552, -81.04219),
        .init("KCRP", "Corpus Christi", 27.78388, -97.51083),
        .init("KCXX", "Burlington", 44.51110, -73.16639),
        .init("KCYS", "Cheyenne", 41.15194, -104.80610),
        .init("KDAX", "Sacramento", 38.50111, -121.67782),
        .init("KDDC", "Dodge City", 37.76083, -99.96888),
        .init("KDFX", "Laughlin AFB", 29.27250, -100.28027),
        .init("KDGX", "Jackson/Brandon,MS", 32.27999, -89.98444),
        .init("KDIX", "Philadelphia", 39.94694, -74.41072),
        .init("KDLH", "Duluth", 46.83694, -92.20971),
        .init("KDMX", "Des Moines", 41.73110, -93.72285),
        .init("KDOX", "Dover AFB", 38.82555, -75.44000),
        .init("KDTX", "Detroit", 42.69999, -83.47166),
        .init("KDVN", "Quad Cities", 41.61166, -90.58083),
        .init("KDYX", "Dyess AFB", 32.53833, -99.25416),
        .init("KEAX", "Pleasant Hill", 38.81024, -94.26446),
        .init("KEMX", "Tucson", 31.89361, -110.63027),
        .init("KENX", "Albany", 42.58655, -74.06408),
        .init("KEOX", "Ft Rucker", 31.46055, -85.45938),
        .init("KEPZ", "El Paso", 31.87305, -106.69799),
        .init("KESX", "Las Vegas", 35.70111, -114.89138),
        .init("KEVX", "Eglin Afb", 30.56503, -85.92166),
        .init("KEWX", "Austin/San Antonio", 29.70405, -98.02860),
        .init("KEYX", "Edwards AFB", 35.09777, -117.56074),
        .init("KFCX", "Roanoke", 37.02416, -80.27416),
        .init("KFDR", "Altus AFB", 34.36219, -98.97666),
        .init("KFDX", "Cannon AFB", 34.63416, -103.61888),
        .init("KFFC", "Atlanta", 33.36333, -84.56583),
        .init("KFSD", "Sioux Falls", 43.58777, -96.72888),
        .init("KFSX", "Flagstaff", 34.57433, -111.19843),
        .init("KFTG", "Denver", 39.78663, -104.54580),
        .init("KFWS", "Dallas/Ft Worth", 32.57277, -97.30313),
        .init("KGGW", "Glasgow", 48.20635, -106.62468),
        .init("KGJX", "Grand Junction", 39.06222, -108.21375),
        .init("KGLD", "Goodland", 39.36694, -101.70027),
        .init("KGRB", "Green Bay", 44.49862, -88.11110),
        .init("KGRK", "Ft Hood", 30.72166, -97.38277),
        .init("KGRR", "Grand Rapids", 42.89388, -85.54488),
        .init("KGSP", "Greer", 34.88330, -82.21983),
        .init("KGWX", "Columbus AFB", 33.89691, -88.32919),
        .init("KGYX", "Portland,ME", 43.89130, -70.25636),
        .init("KHDC", "Hammond", 30.51960, -90.40740),
        .init("KHDX", "Holloman AFB", 33.07699, -106.12002),
        .init("KHGX", "Houston", 29.47194, -95.07888),
        .init("KHNX", "San Joaquin Valley", 36.31416, -119.63213),
        .init("KHPX", "Ft Campbell", 36.73666, -87.28499),
        .init("KHTX", "Northeast Alabama", 34.93055, -86.08361),
        .init("KICT", "Wichita", 37.65444, -97.44305),
        .init("KICX", "Cedar City", 37.59104, -112.86221),
        .init("KILN", "Cincinnati", 39.42027, -83.82166),
        .init("KILX", "Lincoln", 40.15049, -89.33679),
        .init("KIND", "Indianapolis", 39.70749, -86.28027),
        .init("KINX", "Tulsa", 36.17499, -95.56413),
        .init("KIWA", "Phoenix", 33.28916, -111.66999),
        .init("KIWX", "Northern Indiana", 41.35860, -85.70000),
        .init("KJAX", "Jacksonville", 30.48463, -81.70190),
        .init("KJGX", "Robins AFB", 32.67499, -83.35111),
        .init("KJKL", "Jackson,KY", 37.59083, -83.31305),
        .init("KLBB", "Lubbock", 33.65413, -101.81416),
        .init("KLCH", "Lake Charles", 30.12530, -93.21588),
        .init("KLGX", "Langley Hill", 47.11689, -124.10663),
        .init("KLNX", "North Platte", 41.95794, -100.57621),
        .init("KLOT", "Chicago", 41.60444, -88.08444),
        .init("KLRX", "Elko", 40.73972, -116.80277),
        .init("KLSX", "St Louis", 38.69888, -90.68277),
        .init("KLTX", "Wilmington", 33.98916, -78.42916),
        .init("KLVX", "Louisville", 37.97527, -85.94388),
        .init("KLWX", "Sterling", 38.97610, -77.48750),
        .init("KLZK", "Little Rock", 34.83638, -92.26194),
        .init("KMAF", "Midland/Odessa", 31.94346, -102.18924),
        .init("KMAX", "Medford", 42.08111, -122.71735),
        .init("KMBX", "Minot AFB", 48.39249, -100.86443),
        .init("KMHX", "Morehead City", 34.77583, -76.87639),
        .init("KMKX", "Milwaukee", 42.96777, -88.55055),
        .init("KMLB", "Melbourne", 28.11305, -80.65444),
        .init("KMOB", "Mobile", 30.67944, -88.23972),
        .init("KMPX", "Minneapolis", 44.84888, -93.56552),
        .init("KMQT", "Marquette", 46.53110, -87.54833),
        .init("KMRX", "Knoxville", 36.16833, -83.40194),
        .init("KMSX", "Missoula", 47.04110, -113.98610),
        .init("KMTX", "Salt Lake City", 41.26277, -112.44777),
        .init("KMUX", "San Francisco", 37.15522, -121.89843),
        .init("KMVX", "Fargo/Grand Forks", 47.52805, -97.32499),
        .init("KMXX", "Maxwell AFB", 32.53664, -85.78975),
        .init("KNKX", "San Diego", 32.91888, -117.04193),
        .init("KNQA", "Memphis", 35.34472, -89.87333),
        .init("KOAX", "Omaha", 41.32027, -96.36680),
        .init("KOHX", "Nashville", 36.24722, -86.56250),
        .init("KOKX", "Brookhaven", 40.86552, -72.86392),
        .init("KOTX", "Spokane", 47.68055, -117.62582),
        .init("KPAH", "Paducah", 37.06833, -88.77194),
        .init("KPBZ", "Pittsburgh", 40.53166, -80.21794),
        .init("KPDT", "Pendleton", 45.69055, -118.85290),
        .init("KPOE", "Ft Polk", 31.15527, -92.97583),
        .init("KPUX", "Pueblo", 38.45944, -104.18138),
        .init("KRAX", "Raleigh/Durham", 35.66527, -78.49000),
        .init("KRGX", "Reno", 39.75405, -119.46202),
        .init("KRIW", "Riverton/Lander", 43.06610, -108.47729),
        .init("KRLX", "Charleston,WV", 38.31110, -81.72277),
        .init("KRTX", "Portland,OR", 45.71499, -122.96499),
        .init("KSFX", "Pocatello", 43.10559, -112.68612),
        .init("KSGF", "Springfield", 37.23527, -93.40027),
        .init("KSHV", "Shreveport", 32.45083, -93.84124),
        .init("KSJT", "San Angelo", 31.37111, -100.49221),
        .init("KSOX", "Santa Ana Mts", 33.81773, -117.63599),
        .init("KSRX", "Western Arkansas", 35.29041, -94.36188),
        .init("KTBW", "Tampa", 27.70527, -82.40194),
        .init("KTFX", "Great Falls", 47.45972, -111.38527),
        .init("KTLH", "Tallahassee", 30.39749, -84.32889),
        .init("KTLX", "Norman", 35.33305, -97.27775),
        .init("KTWX", "Topeka", 38.99694, -96.23249),
        .init("KTYX", "Ft Drum", 43.75582, -75.68000),
        .init("KUDX", "Rapid City", 44.12471, -102.82999),
        .init("KUEX", "Grand Island", 40.32083, -98.44194),
        .init("KVAX", "Moody AFB", 30.89027, -83.00180),
        .init("KVBX", "Vandenberg AFB", 34.83855, -120.39790),
        .init("KVNX", "Vance AFB", 36.74083, -98.12749),
        .init("KVTX", "Los Angeles", 34.41166, -119.17860),
        .init("KVWX", "Evansville,IN", 38.26024, -87.72452),
        .init("KYUX", "Yuma", 32.49527, -114.65668),
        .init("PABC", "Bethel", 60.79194, -161.87637),
        .init("PACG", "Sitka", 56.85277, -135.52915),
        .init("PAEC", "Nome", 64.51139, -165.29498),
        .init("PAHG", "Kenai", 60.72591, -151.35144),
        .init("PAIH", "Middleton Island", 59.46194, -146.30109),
        .init("PAKC", "King Salmon", 58.67944, -156.62942),
        .init("PAPD", "Fairbanks Faa", 65.03511, -147.50140),
        .init("PGUA", "Andersen AFB", 13.45583, 144.81112),
        .init("PHKI", "South Kauai", 21.89389, -159.55249),
        .init("PHKM", "Kamuela/Kohala Apt", 20.12527, -155.77776),
        .init("PHMO", "Molokai", 21.13277, -157.18026),
        .init("PHWA", "South Shore", 19.09500, -155.56887),
        .init("RKJK", "Kunsan AB", 35.92417, 126.62222),
        .init("RKSG", "Camp Humphreys", 37.20757, 127.28556),
        .init("RODN", "Kadena AB", 26.30194, 127.90972),
        .init("TJUA", "San Juan", 18.11566, -66.07817),
    ]
}
