//
//  Blog.swift  (WeatherKit)
//
//  A forecast blog, read from its RSS feed. One so far: Space City Weather,
//  Eric Berger and Matt Lanza's Houston forecast, posted most mornings.
//
//  THE FEED CARRIES THE WHOLE POST. WordPress puts the full HTML in
//  `content:encoded` — text, headings, the forecast graphics — so a post can
//  be read inside the app, in the app's own type, with no page to load and
//  nothing around it. Each post opens with an "In brief" paragraph, which is
//  what the list shows under the headline.
//

import Foundation

public struct Blog: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let feedURL: URL
    /// Where the posts' relative links and images resolve.
    public let home: URL

    public static let spaceCityWeather = Blog(
        id: "space-city-weather",
        name: "Space City Weather",
        feedURL: URL(string: "https://spacecityweather.com/feed/")!,
        home: URL(string: "https://spacecityweather.com/")!)
}

public struct BlogPost: Identifiable, Hashable, Sendable {
    /// The feed's guid — WordPress's `?p=` id — which survives a retitled post.
    public let id: String
    public let title: String
    public let link: URL?
    public let author: String?
    public let published: Date
    /// The "In brief" paragraph as plain text, or the start of the post.
    public let summary: String
    /// The post's body as the blog wrote it.
    public let html: String

    public init(id: String, title: String, link: URL?, author: String?, published: Date,
                summary: String, html: String) {
        self.id = id; self.title = title; self.link = link; self.author = author
        self.published = published; self.summary = summary; self.html = html
    }
}

public enum BlogFeed {
    /// The posts in an RSS 2.0 feed, newest first.
    public static func parse(_ data: Data) throws -> [BlogPost] {
        let reader = RSSReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else {
            throw BlogClient.Failure.unreadable(parser.parserError?.localizedDescription ?? "not XML")
        }
        return reader.posts.sorted { $0.published > $1.published }
    }

    /// "In brief: After today, which will be windy…" → "After today, which will
    /// be windy…". The first paragraph of the body when it is the brief, else
    /// the feed's own excerpt, which ends in a "See full post" link to drop.
    static func summary(html: String, excerpt: String) -> String {
        if let open = html.range(of: "<p"), let close = html.range(of: "</p>", range: open.upperBound..<html.endIndex) {
            let first = plainText(String(html[open.lowerBound..<close.upperBound]))
            if first.lowercased().hasPrefix("in brief") {
                return first.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
            }
        }
        let cut = excerpt.range(of: "<p")?.lowerBound ?? excerpt.endIndex
        return plainText(String(excerpt[..<cut]))
    }

    /// Tags dropped, the handful of entities WordPress actually emits decoded,
    /// and runs of space collapsed.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in [("&#8217;", "’"), ("&#8216;", "‘"), ("&#8220;", "“"), ("&#8221;", "”"),
                               ("&#8211;", "–"), ("&#8212;", "—"), ("&#8230;", "…"), ("&nbsp;", " "),
                               ("&#038;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"),
                               ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class RSSReader: NSObject, XMLParserDelegate {
        var posts: [BlogPost] = []
        private var item: [String: String]?
        private var text = ""
        private let dates: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return f
        }()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "item" { item = [:] }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            text += String(decoding: block, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            guard item != nil else { return }
            switch name {
            case "title", "link", "guid", "pubDate", "dc:creator", "description", "content:encoded":
                if item?[name] == nil { item?[name] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            case "item":
                if let i = item, let title = i["title"],
                   let published = i["pubDate"].flatMap(dates.date(from:)) {
                    let html = i["content:encoded"] ?? i["description"] ?? ""
                    posts.append(BlogPost(
                        id: i["guid"] ?? i["link"] ?? title,
                        title: BlogFeed.plainText(title),
                        link: i["link"].flatMap(URL.init(string:)),
                        author: i["dc:creator"],
                        published: published,
                        summary: BlogFeed.summary(html: html, excerpt: i["description"] ?? ""),
                        html: html))
                }
                item = nil
            default: break
            }
            text = ""
        }
    }
}

public struct BlogClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public enum Failure: Error, LocalizedError {
        case badResponse(status: Int)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .badResponse(let status): return "The blog returned HTTP \(status)."
            case .unreadable(let why): return "Couldn't read the blog's feed: \(why)"
            }
        }
    }

    public func posts(from blog: Blog) async throws -> [BlogPost] {
        var request = URLRequest(url: blog.feedURL)
        // A new post has to show up the hour it is published, not whenever a
        // cached copy of the feed expires.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(status: http.statusCode)
        }
        return try BlogFeed.parse(data)
    }
}
