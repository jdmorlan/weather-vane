//
//  DroughtMonitor.swift  (WeatherKit)
//
//  The US Drought Monitor's weekly rating for the county home is in.
//
//  WHY IT BELONGS BESIDE THE STATION'S OWN RAIN. The two answer different
//  questions and the gap between them is the lesson. The station adds up inches
//  since January; the Drought Monitor is an analysts' judgement over weeks to
//  months, across a whole region, folding in soil moisture, streamflow and the
//  heat that took the water back out. So a year can be 1.5" ahead and still in
//  drought — October 2026 here was exactly that, after a 38-day dry summer — and
//  the rating easing the week after a 2.5" storm is the station's own rain
//  showing up in someone else's map.
//
//  BY COUNTY, AND THE COUNTY COMES FROM WHERE HOME IS. Nobody types one in. The
//  county statistics are the cheap way to get a season of weeks (one small JSON
//  file); the polygons themselves are 18–25 MB a week nationally, which is a map
//  layer's cost, not a headline's.
//
//  THE NUMBERS ARE CUMULATIVE. `d1: 100` means all of the county is in D1 OR
//  WORSE, so `d2: 40` is a subset of it. Nothing here un-accumulates them except
//  `share(atLeast:)`'s callers, which never need to.
//
//  A WEEK IS DATED BY ITS MAP. The map is released on Thursday and describes
//  conditions as of the Tuesday before; `mapDate` is that Tuesday, and that is
//  the date the page shows — "as of Oct 13", never "this week".
//

import Foundation

/// D0–D4, in the Drought Monitor's own words.
public enum DroughtLevel: Int, CaseIterable, Comparable, Sendable, Identifiable {
    case d0, d1, d2, d3, d4

    public var id: Int { rawValue }
    public var code: String { "D\(rawValue)" }

    /// "Moderate drought". D0 is not a drought, and isn't called one.
    public var name: String {
        switch self {
        case .d0: return "Abnormally dry"
        case .d1: return "Moderate drought"
        case .d2: return "Severe drought"
        case .d3: return "Extreme drought"
        case .d4: return "Exceptional drought"
        }
    }

    public static func < (a: DroughtLevel, b: DroughtLevel) -> Bool { a.rawValue < b.rawValue }
}

/// One weekly map, for one county.
public struct DroughtWeek: Equatable, Sendable, Identifiable {
    /// The Tuesday the map describes, as a day key.
    public var mapDate: String
    /// Percent of the county at each level OR WORSE, D0 first. Five values, 0–100.
    public var atLeast: [Double]

    public var id: String { mapDate }

    public init(mapDate: String, atLeast: [Double]) {
        self.mapDate = mapDate
        self.atLeast = atLeast
    }

    public func share(atLeast level: DroughtLevel) -> Double {
        atLeast.indices.contains(level.rawValue) ? atLeast[level.rawValue] : 0
    }

    /// The level most of the county is in: the worst one covering half of it or
    /// more. Nil when most of the county is in none — not dry at all.
    public var prevailing: DroughtLevel? {
        DroughtLevel.allCases.last { share(atLeast: $0) >= 50 }
    }

    /// The worst level anywhere in the county, however small a corner.
    public var worst: DroughtLevel? {
        DroughtLevel.allCases.last { share(atLeast: $0) > 0 }
    }
}

public struct DroughtReport: Equatable, Sendable {
    public var countyName: String
    public var state: String
    public var fips: String
    /// Oldest first.
    public var weeks: [DroughtWeek]
    public var fetched: Date

    public var latest: DroughtWeek? { weeks.last }

    /// The most recent week the prevailing level changed, and what it was before.
    /// "Eased from severe on the Oct 6 map" is the sentence this exists for.
    public var lastChange: (week: DroughtWeek, from: DroughtLevel?)? {
        guard let latest else { return nil }
        for i in weeks.indices.reversed().dropFirst() where weeks[i].prevailing != latest.prevailing {
            return (weeks[i + 1], weeks[i].prevailing)
        }
        return nil
    }
}

public struct DroughtMonitorClient: Sendable {
    public static let credit = "US Drought Monitor"

    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public enum Failure: Error, LocalizedError {
        case badResponse(status: Int)
        case decoding(Error)
        case empty

        public var errorDescription: String? {
            switch self {
            case .badResponse(let status): return "The Drought Monitor returned HTTP \(status)."
            case .decoding(let error): return "Couldn't read the drought map: \(error.localizedDescription)"
            case .empty: return "The Drought Monitor had no weeks for this county."
            }
        }
    }

    /// The last `weeks` weekly maps for a county, oldest first.
    public func report(for county: County, weeks: Int = 26, now: Date = Date()) async throws -> DroughtReport {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "M/d/yyyy"
        let start = now.addingTimeInterval(-Double(weeks) * 7 * 86_400)

        var components = URLComponents(string: "https://usdmdataservices.unl.edu/api/CountyStatistics/GetDroughtSeverityStatisticsByAreaPercent")!
        components.queryItems = [
            .init(name: "aoi", value: county.geoid),
            .init(name: "startdate", value: f.string(from: start)),
            .init(name: "enddate", value: f.string(from: now)),
            // 1 is cumulative: each level's percent includes every level worse.
            .init(name: "statisticsType", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        // Without it the service answers in CSV.
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.badResponse(status: status) }
        let decoded: [DroughtWeek]
        do { decoded = try Self.decode(data) } catch { throw Failure.decoding(error) }
        guard !decoded.isEmpty else { throw Failure.empty }
        return DroughtReport(countyName: county.name, state: county.state, fips: county.geoid,
                             weeks: decoded, fetched: now)
    }

    static func decode(_ data: Data) throws -> [DroughtWeek] {
        struct Row: Decodable {
            var mapDate: String
            var d0: Double, d1: Double, d2: Double, d3: Double, d4: Double
        }
        return try JSONDecoder().decode([Row].self, from: data)
            // "2026-10-13T00:00:00" — the day key is its first ten characters.
            .map { DroughtWeek(mapDate: String($0.mapDate.prefix(10)), atLeast: [$0.d0, $0.d1, $0.d2, $0.d3, $0.d4]) }
            .sorted { $0.mapDate < $1.mapDate }
    }
}
