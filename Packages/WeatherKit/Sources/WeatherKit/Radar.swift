//
//  Radar.swift  (WeatherKit)
//
//  The radar loop's INDEX — which scans exist, when each one is for, and how to
//  build a tile URL for it. Rendering is MapKit's job and lives in the app.
//
//  Source is NEXRAD: the NWS WSR-88D network's Level III base reflectivity (N0Q,
//  0.25 dBZ resolution), mosaicked into a CONUS composite every five minutes and
//  served by the Iowa Environmental Mesonet at Iowa State. Two endpoints:
//
//    · `Radar.indexURL(...)`  IEM's radar JSON — the scan times that EXIST
//    · `Radar.tileURL(...)`   a time-stamped OGC WMS GetMap, one tile's worth
//
//  WHY NEXRAD AND NOT A DERIVED PRODUCT. Every frame here is an observation with
//  a real valid time that the service states out loud, so the loop no longer has
//  to carry a boundary between "what the radar saw" and "what a model
//  extrapolated" — there is no nowcast in this feed, and nothing on the card is a
//  claim about the future. That is the same rule the archive enforces about
//  coverage and the alert half enforces about reachability, met by choosing a
//  source that cannot break it rather than by labelling around it.
//
//  The second reason is that a frame is addressed by its TIMESTAMP. The old
//  source handed back opaque paths for a rolling two-hour window and nothing
//  else; this one will render any five-minute slot back to 2011, which is the
//  same shape as the sample archive and the door to reading radar for a day you
//  are looking back at.
//

import Foundation

/// One scan of the loop — a five-minute CONUS composite, valid at `time`.
public struct RadarFrame: Codable, Equatable, Sendable, Identifiable {
    /// Valid time of the scan. Always on a five-minute boundary.
    public var time: Date

    /// The valid time as the service spells it, e.g. `2026-09-03T20:55:00Z`. This
    /// is both the WMS `TIME` argument and the frame's identity — see `id`.
    public var stamp: String { Radar.stampFormatter.string(from: time) }

    /// IDENTITY IS THE VALID TIME, which is what makes both the overlay diff and
    /// the tile cache correct. A composite for a given five-minute slot is
    /// finished once and does not change afterwards, so a tile fetched for
    /// 20:55Z stays the right picture of 20:55Z forever — the loop can re-add its
    /// overlays every reload without re-paying for a single tile it already has.
    public var id: String { stamp }

    public init(time: Date) { self.time = time }
}

public enum Radar {
    public static let host = "https://mesonet.agron.iastate.edu"
    public static let credit = "NEXRAD · NWS / Iowa State Mesonet"

    /// The time-enabled WMS layer: NWS base reflectivity, CONUS composite.
    public static let layer = "nexrad-n0q-wmst"

    /// A frame older than this means the loop is not showing you now. Composites
    /// land every five minutes, so this is several missed ones — generous on
    /// purpose, because the index only ever lists scans that actually exist and a
    /// short gap is the mosaic waiting on one site, not a broken feed.
    public static let staleAfter: TimeInterval = 25 * 60

    /// The composite cadence. The index is enumerated on this grid and the loop's
    /// length is counted in it.
    public static let scanInterval: TimeInterval = 5 * 60

    /// Tile edge in pixels. 512 RATHER THAN 256, AND THIS IS THE WHOLE BUDGET.
    ///
    /// A 512px tile covers the ground of four 256px tiles at one zoom lower, so
    /// the picture is identical and the request count falls by about four.
    /// Measured on the real card at 1810x340pt retina, per frame:
    ///
    ///     close    112 -> 12      nearby  32 -> 8      regional  40 -> 10
    ///
    /// That mattered when the old source enforced a hard burst limit and answered
    /// 429 to everything past it. It still matters for a different reason: IEM is
    /// a free academic service rendering each of these from the mosaic, and a
    /// ten-frame loop asking for eleven hundred tiles at once is rude whether or
    /// not anyone stops it.
    public static let tileSize = 512

    /// `2026-09-03T20:55:00Z` — what the WMS `TIME` argument wants.
    static let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Web-Mercator half-circumference in metres — the edge of the EPSG:3857 world.
    static let mercatorExtent = 20_037_508.342789244

    /// The EPSG:3857 bounding box of a slippy tile, as WMS wants it:
    /// `minX,minY,maxX,maxY`.
    ///
    /// THIS IS THE ONE PIECE OF ARITHMETIC THE CARD CANNOT GET SLIGHTLY WRONG. A
    /// tile service is handed z/x/y and works the projection out itself; a WMS is
    /// handed metres and draws exactly what you asked for, so an error here does
    /// not fail — it shifts the returns off the town they are actually over,
    /// which is the one thing this card exists to answer.
    public static func tileBBox(z: Int, x: Int, y: Int) -> String {
        let span = 2 * mercatorExtent / pow(2, Double(z))
        let minX = -mercatorExtent + Double(x) * span
        let maxY = mercatorExtent - Double(y) * span
        return "\(minX),\(maxY - span),\(minX + span),\(maxY)"
    }

    /// One tile of one scan, as a WMS GetMap.
    ///
    /// NO ZOOM CLAMP, DELIBERATELY. An earlier guess of 3…10 was wrong in the way
    /// guesses about someone else's service usually are: MapKit renders "Zoom
    /// level not supported" for any zoom outside an overlay's declared range, so
    /// the constraint didn't clamp the view, it blanked it — and the message
    /// blamed zoom for a problem that had nothing to do with zoom. A WMS has no
    /// zoom levels at all; it has a bounding box, and it will render any box you
    /// name at any size you ask for.
    public static func tileURL(frame: RadarFrame, z: Int, x: Int, y: Int,
                               size: Int = tileSize) -> URL? {
        var components = URLComponents(string: "\(host)/cgi-bin/wms/nexrad/n0q-t.cgi")
        components?.queryItems = [
            .init(name: "SERVICE", value: "WMS"),
            .init(name: "VERSION", value: "1.1.1"),
            .init(name: "REQUEST", value: "GetMap"),
            .init(name: "LAYERS", value: layer),
            .init(name: "SRS", value: "EPSG:3857"),
            .init(name: "BBOX", value: tileBBox(z: z, x: x, y: y)),
            .init(name: "WIDTH", value: "\(size)"),
            .init(name: "HEIGHT", value: "\(size)"),
            .init(name: "FORMAT", value: "image/png"),
            // Without this the composite arrives on an opaque background and the
            // basemap underneath it — the roads that say WHERE the returns are —
            // disappears everywhere the radar has coverage, which is everywhere.
            .init(name: "TRANSPARENT", value: "TRUE"),
            .init(name: "TIME", value: frame.stamp),
        ]
        return components?.url
    }

    /// The scans available in a window. `start`/`end` are inclusive-ish; the
    /// service answers with the five-minute slots it actually holds.
    public static func indexURL(from start: Date, to end: Date) -> URL {
        var components = URLComponents(string: "\(host)/json/radar")!
        components.queryItems = [
            .init(name: "operation", value: "list"),
            .init(name: "radar", value: "USCOMP"),
            .init(name: "product", value: "N0Q"),
            .init(name: "start", value: stampFormatter.string(from: start)),
            .init(name: "end", value: stampFormatter.string(from: end)),
        ]
        return components.url!
    }
}

/// IEM's `json/radar?operation=list` — `{"scans":[{"ts":"2026-09-03T20:55Z"}]}`.
public struct RadarIndex: Decodable, Sendable {
    public var scans: [Scan]

    public struct Scan: Decodable, Sendable {
        public var ts: String
    }

    /// The frames as one timeline, oldest first.
    ///
    /// `maxPast` exists because MapKit holds a renderer per frame and the useful
    /// question is "what has the last hour done", not "what happened since
    /// lunch". Ten five-minute scans is fifty minutes of weather.
    public func frames(maxPast: Int = 10) -> [RadarFrame] {
        scans.compactMap { RadarIndex.time(from: $0.ts).map(RadarFrame.init(time:)) }
            .sorted { $0.time < $1.time }
            .suffix(maxPast)
            .map { $0 }
    }

    /// THE INDEX AND THE TILE REQUEST DO NOT AGREE ON A FORMAT. The list writes
    /// `2026-09-03T20:55Z` — no seconds — and WMS `TIME` wants
    /// `2026-09-03T20:55:00Z`, so parsing has to accept both and `RadarFrame` has
    /// to emit the second from a `Date` rather than pass the first through.
    static func time(from stamp: String) -> Date? {
        Radar.stampFormatter.date(from: stamp)
            ?? Radar.stampFormatter.date(from: stamp.replacingOccurrences(of: "Z", with: ":00Z"))
    }
}

public struct NEXRADClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public enum Failure: Error, LocalizedError {
        case badResponse(status: Int)
        case noFrames

        public var errorDescription: String? {
            switch self {
            case .badResponse(let status): return "The radar index returned HTTP \(status)."
            case .noFrames:                return "The radar service listed no recent scans."
            }
        }
    }

    /// How far back to ask for. Wider than the loop on purpose: the index is the
    /// only thing that knows a scan is MISSING, and a window sized exactly to the
    /// loop would silently return a short loop instead of a full one whenever the
    /// mosaic skipped a slot.
    private static let window: TimeInterval = 90 * 60

    public func frames() async throws -> [RadarFrame] {
        let now = Date()
        var request = URLRequest(url: Radar.indexURL(from: now.addingTimeInterval(-Self.window),
                                                     to: now))
        request.timeoutInterval = 20
        // The index names the newest scan; a cached index names an older one,
        // which is the entire failure mode worth avoiding here.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(status: http.statusCode)
        }
        let frames = try JSONDecoder().decode(RadarIndex.self, from: data).frames()
        guard !frames.isEmpty else { throw Failure.noFrames }
        return frames
    }
}

// MARK: - How far out to look

/// The viewport is FIXED on your acre, so the only spatial control left is how far
/// out it reaches. Three steps rather than a free zoom, because a cell over the
/// next field and a line 60 miles west are different questions — and a continuous
/// zoom makes you re-answer "where am I looking" every single time.
public enum RadarRange: String, CaseIterable, Identifiable, Sendable {
    case close, nearby, regional

    public var id: String { rawValue }

    /// Radius in metres.
    public var radius: Double {
        switch self {
        case .close:    return 30_000     // ~19 mi — is it over the house
        case .nearby:   return 90_000     // ~56 mi — what is about to be
        case .regional: return 240_000    // ~150 mi — what the day is made of
        }
    }

    public var label: String {
        switch self {
        case .close:    return "Close"
        case .nearby:   return "Nearby"
        case .regional: return "Regional"
        }
    }
}
