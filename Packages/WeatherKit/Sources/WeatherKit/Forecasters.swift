//
//  Forecasters.swift  (WeatherKit)
//
//  Two people whose forecasts are worth hearing, and whether either of them is
//  on the air with a storm right now. Read from YouTube without a key or an
//  account: each channel publishes an Atom feed of its fifteen newest uploads.
//
//  THE FEED CANNOT SAY WHAT IS LIVE, so a video's own watch page is asked. The
//  page carries a `liveBroadcastDetails` object — `isLiveNow`, when it started,
//  when it ended — beside `isLiveContent`, which is what separates a broadcast
//  from an upload. `liveBroadcastDetails` alone does not: an ordinary upload
//  released as a premiere carries one too (measured 2026-09-30 on 8eM634tizx8,
//  a Texas Weather Roundup with a start and an end, `isLiveContent` false).
//  This is page data rather than a published API, so a page that no longer says
//  any of it reads as `.unknown` and is simply not badged — never as live.
//
//  A STORM STREAM IS NOT "THE CHANNEL IS LIVE". Texas Weather Center runs a
//  24/7 stream of radar and warnings under music, live continuously since
//  2026-07-30. Vane draws everything on it, so it is never offered, and a
//  channel-is-live check would say yes every hour of every day. What is wanted
//  is the coverage he opens when storms fire — "LIVE BREAKING WEATHER: Texas
//  Tornado Warnings", three of them on the evening of 2026-09-29. Those appear
//  in the feed as they start; the 24/7 stream is too old to be in it. Should it
//  restart and land in the feed, two rules still keep it out: its title says
//  24/7, and a broadcast running longer than `stormStreamLimit` is not coverage
//  of a storm. See `LiveBroadcast.isStormStream`.
//

import Foundation

/// A YouTube channel Vane follows. The ids are YouTube's own, which survive a
/// rename or a new handle — Texas Weather Center's feed is titled "David Reimer |
/// Texas Weather Roundup" and its handle is @TSCWX, neither of them the name
/// people know it by.
public struct ForecasterChannel: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// What the channel is FOR, in a line. The two are not alike, and the list
    /// should say so before you open either.
    public let summary: String

    public static let texasWeatherCenter = ForecasterChannel(
        id: "UCoIfgmxArIATc2EpHD3W9EA",
        name: "Texas Weather Center",
        summary: "Daily Texas roundups, and live coverage when storms fire")
    public static let convectiveChronicles = ForecasterChannel(
        id: "UCRYYy0UrfyGmMKQDU1N1R3g",
        name: "Convective Chronicles",
        summary: "Forecast discussions and severe-weather case studies")

    public static let all: [ForecasterChannel] = [.texasWeatherCenter, .convectiveChronicles]

    public var feedURL: URL {
        URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)")!
    }
}

/// One upload or broadcast, as the channel's feed lists it.
public struct ForecasterVideo: Identifiable, Hashable, Sendable {
    public let id: String
    public let channelID: String
    public let title: String
    public let published: Date

    public init(id: String, channelID: String, title: String, published: Date) {
        self.id = id
        self.channelID = channelID
        self.title = title
        self.published = published
    }

    /// `hqdefault` rather than the feed's own thumbnail URL: the feed names it
    /// on a numbered host (i1.ytimg.com) that is not guaranteed to stay, and
    /// this one is the address YouTube's own embeds use.
    public var thumbnailURL: URL {
        URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!
    }
    public var watchURL: URL {
        URL(string: "https://www.youtube.com/watch?v=\(id)")!
    }
}

// MARK: - The feed

public enum ForecasterFeed {
    /// The videos in a channel's Atom feed, newest first.
    public static func parse(_ data: Data) throws -> [ForecasterVideo] {
        let reader = AtomReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else {
            throw ForecasterClient.Failure.unreadable(parser.parserError?.localizedDescription ?? "not XML")
        }
        return reader.videos.sorted { $0.published > $1.published }
    }

    /// Reads `<entry>` elements only. The feed's own `<title>` and
    /// `<published>` describe the channel and sit outside every entry.
    private final class AtomReader: NSObject, XMLParserDelegate {
        var videos: [ForecasterVideo] = []
        private var entry: [String: String]?
        private var text = ""
        private let dates = ISO8601DateFormatter()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "entry" { entry = [:] }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            guard entry != nil else { return }
            switch name {
            // First one wins: `media:title` inside `media:group` repeats the title.
            case "yt:videoId", "yt:channelId", "title", "published":
                if entry?[name] == nil { entry?[name] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            case "entry":
                if let e = entry, let id = e["yt:videoId"], let title = e["title"],
                   let published = e["published"].flatMap(dates.date(from:)) {
                    videos.append(ForecasterVideo(id: id, channelID: e["yt:channelId"] ?? "",
                                                  title: title, published: published))
                }
                entry = nil
            default: break
            }
            text = ""
        }
    }
}

// MARK: - Live

/// What a video's watch page says about it as a broadcast.
public enum LiveBroadcast: Equatable, Sendable {
    /// An upload, including one released as a premiere. Never live; settled.
    case upload
    /// A broadcast that has not started.
    case upcoming
    /// On the air now, since `started`.
    case live(started: Date)
    /// A broadcast that has finished. Settled.
    case ended
    /// The page said none of it. Asked again next time, and never badged.
    case unknown

    /// Nothing about this video can change any more, so it need not be asked
    /// about again.
    public var isSettled: Bool {
        switch self {
        case .upload, .ended: return true
        case .upcoming, .live, .unknown: return false
        }
    }

    /// The longest a broadcast can have run and still be storm coverage. His
    /// longest storm stream in the feed on 2026-09-30 ran about five hours;
    /// eighteen allows for an all-night outbreak and is still two orders of
    /// magnitude short of the 24/7 stream.
    public static let stormStreamLimit: TimeInterval = 18 * 3600

    /// Whether this is live storm coverage — on the air, recently begun, and not
    /// the round-the-clock radar stream. See the file's header.
    public func isStormStream(title: String, now: Date = Date()) -> Bool {
        guard case .live(let started) = self else { return false }
        if title.contains("24/7") { return false }
        return now.timeIntervalSince(started) < Self.stormStreamLimit
    }

    /// Reads a watch page's HTML. Two fields matter, and both are looked for as
    /// literal JSON inside the page's inline script rather than by decoding that
    /// script whole — it is a megabyte of which these are forty characters.
    public static func parse(watchPage html: String) -> LiveBroadcast {
        if html.contains(#""isLiveContent":false"#) { return .upload }
        guard html.contains(#""isLiveContent":true"#) else { return .unknown }
        if html.contains(#""isUpcoming":true"#) { return .upcoming }

        guard let details = object(named: "liveBroadcastDetails", in: html),
              let data = details.data(using: .utf8),
              let fields = try? JSONDecoder().decode(Details.self, from: data) else { return .unknown }
        if fields.isLiveNow == true {
            guard let started = fields.startTimestamp.flatMap(ISO8601DateFormatter().date(from:)) else {
                return .unknown
            }
            return .live(started: started)
        }
        return fields.endTimestamp != nil ? .ended : .upcoming
    }

    private struct Details: Decodable {
        let isLiveNow: Bool?
        let startTimestamp: String?
        let endTimestamp: String?
    }

    /// `{…}` following `"name":`, which here is always flat — three scalar
    /// fields — so the first closing brace ends it.
    private static func object(named name: String, in html: String) -> String? {
        guard let key = html.range(of: "\"\(name)\":{") else { return nil }
        let open = html.index(before: key.upperBound)
        guard let close = html[open...].firstIndex(of: "}") else { return nil }
        return String(html[open...close])
    }
}

// MARK: - Client

public struct ForecasterClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public enum Failure: Error, LocalizedError {
        case badResponse(status: Int)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .badResponse(let status): return "YouTube returned HTTP \(status)."
            case .unreadable(let why): return "Couldn't read the channel's feed: \(why)"
            }
        }
    }

    public func videos(from channel: ForecasterChannel) async throws -> [ForecasterVideo] {
        try ForecasterFeed.parse(try await get(channel.feedURL))
    }

    public func broadcast(of video: ForecasterVideo) async throws -> LiveBroadcast {
        LiveBroadcast.parse(watchPage: String(decoding: try await get(video.watchURL), as: UTF8.self))
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(status: http.statusCode)
        }
        return data
    }
}
