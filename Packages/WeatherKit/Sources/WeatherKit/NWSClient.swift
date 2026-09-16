//
//  NWSClient.swift  (WeatherKit)
//
//  api.weather.gov, for ONE fixed point. No key, no account — but it does require
//  a User-Agent that identifies the app and a way to reach its author, which is
//  the API's stated condition of use rather than a nicety.
//
//  `alerts/active?point=` resolves BOTH kinds of product server-side: it returns
//  polygon warnings whose polygon covers you and zone products issued for your
//  county. We re-run the polygon test ourselves anyway — see `HazardParser.hazard`.
//

import Foundation

public struct NWSClient: Sendable {
    public let point: GeoPoint
    public let contact: String

    private let session: URLSession

    public init(point: GeoPoint, contact: String, session: URLSession = .shared) {
        self.point = point
        self.contact = contact
        self.session = session
    }

    public enum Failure: Error, LocalizedError {
        case noLocation
        case badResponse(status: Int)
        case decoding(Error)

        public var errorDescription: String? {
            switch self {
            case .noLocation:
                return "Set your home location in Settings so alerts can be looked up for it."
            case .badResponse(let status):
                return "The National Weather Service returned HTTP \(status)."
            case .decoding(let error):
                return "Couldn't read the alert feed: \(error.localizedDescription)"
            }
        }
    }

    /// NWS rounds point coordinates to four decimals and 301-redirects anything
    /// longer. Truncating up front keeps it a single request.
    var alertsURL: URL {
        var components = URLComponents(string: "https://api.weather.gov/alerts/active")!
        let lat = (point.latitude * 10_000).rounded() / 10_000
        let lon = (point.longitude * 10_000).rounded() / 10_000
        components.queryItems = [URLQueryItem(name: "point", value: "\(lat),\(lon)")]
        return components.url!
    }

    /// Every hazard live over the point, ranked. An empty array here means NWS
    /// answered and had nothing — which is why the caller must record that it
    /// answered, not just what it said.
    public func activeHazards() async throws -> [Hazard] {
        guard point.latitude != 0 || point.longitude != 0 else { throw Failure.noLocation }

        var request = URLRequest(url: alertsURL)
        request.timeoutInterval = 20
        request.setValue("(Almanac, \(contact))", forHTTPHeaderField: "User-Agent")
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        // Alerts change on a scale of minutes and the feed sets its own cache
        // headers generously; a warning we serve from cache is a warning we didn't
        // serve.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(status: http.statusCode)
        }
        do {
            let feed = try JSONDecoder().decode(NWSAlertFeed.self, from: data)
            return HazardParser.hazards(from: feed, at: point)
        } catch {
            throw Failure.decoding(error)
        }
    }
}
