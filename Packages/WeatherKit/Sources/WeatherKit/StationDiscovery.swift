//
//  StationDiscovery.swift  (WeatherKit)
//
//  Turning ONE pasted token into a configured app.
//
//  The rest of the client needs a station id before it can ask anything, which
//  in a settings form means the user goes and finds a number. But the same
//  `/stations` endpoint `stationCreated()` already calls answers without an id
//  too — with every station on the token, its name, and where it is. So the id
//  and the home coordinate are both DERIVABLE from the token, and asking for
//  them separately was only ever an artefact of the settings form.
//

import Foundation

/// One station on a token: enough to choose between them and to configure the
/// app from the choice.
public struct TempestStation: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    /// Where the station sits. Optional because a station registered but never
    /// placed has no coordinate, and inventing one would put home in the Gulf of
    /// Guinea — the same lie `AppSettings.homeCoordinate` refuses to tell.
    public let latitude: Double?
    public let longitude: Double?
    /// The station's own timezone string, shown as a sanity check: a user with
    /// two stations recognises "America/Los_Angeles" faster than a lat/lon pair.
    public let timeZone: String?

    public init(id: Int, name: String, latitude: Double?, longitude: Double?, timeZone: String?) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.timeZone = timeZone
    }

    public var hasLocation: Bool { latitude != nil && longitude != nil }
}

extension TempestClient {

    /// Every station the token can see.
    ///
    /// Static and token-only on purpose: this is the one call that runs BEFORE
    /// there is a station id, so it cannot hang off an instance that requires
    /// one. A token with no stations is a real, non-error answer — a valid
    /// personal-use token from an account that has not registered a unit yet —
    /// and it returns an empty array rather than throwing, so the caller can say
    /// so plainly instead of reporting a failure that didn't happen.
    public static func stations(token: String,
                                session: URLSession = .shared) async throws -> [TempestStation] {
        guard !token.isEmpty else { throw Failure.notConfigured }

        var components = URLComponents(string: "https://swd.weatherflow.com/swd/rest/stations")!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(status: http.statusCode)
        }
        do {
            let payload = try makeDecoder().decode(StationDirectory.self, from: data)
            return payload.stations.map(\.station)
        } catch {
            throw Failure.decoding(error)
        }
    }

    /// The `/stations` payload, read for identity rather than for the creation
    /// date `StationList` reads. A separate type rather than more fields on that
    /// one because the two calls want opposite tolerance: `stationCreated` takes
    /// the MINIMUM over whatever it finds and can shrug off a station it can't
    /// read, and this one has to drop any station it cannot name or address.
    struct StationDirectory: Decodable {
        var stations: [Entry]

        struct Entry: Decodable {
            var stationId: Int
            var name: String?
            var publicName: String?
            var latitude: Double?
            var longitude: Double?
            var timezone: String?

            enum CodingKeys: String, CodingKey {
                case stationId = "station_id"
                case name
                case publicName = "public_name"
                case latitude, longitude, timezone
            }

            /// `public_name` first: it's what the station is called in the
            /// Tempest app, which is the name the user will recognise. `name`
            /// is the account-side label and is often the same, or absent.
            var station: TempestStation {
                let label = [publicName, name]
                    .compactMap { $0 }
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                return TempestStation(id: stationId,
                                      name: label ?? "Station \(stationId)",
                                      latitude: latitude,
                                      longitude: longitude,
                                      timeZone: timezone)
            }
        }

        enum CodingKeys: String, CodingKey { case stations }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stations = try c.decodeIfPresent([Entry].self, forKey: .stations) ?? []
        }
    }
}
