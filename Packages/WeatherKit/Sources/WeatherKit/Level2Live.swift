//
//  Level2Live.swift  (WeatherKit)
//
//  Following a radar's volume WHILE IT IS BEING SCANNED, from the realtime
//  chunks bucket — so the newest picture is a minute old instead of ten.
//
//  THE SOURCE. `unidata-nexrad-level2-chunks` gets each volume as it is made,
//  cut into chunks of 120 radials and posted every ten seconds or so:
//
//      KGRK/998/20260924-155008-001-S      metadata (the volume's plan)
//      KGRK/998/20260924-155008-002-I      radials 1–120 of the first tilt
//      …
//      KGRK/998/20260924-155008-055-E      the last chunk
//
//  The folder is a volume number, 1–999, wrapping every few days. The archive
//  file for a finished volume carries the same number in its header
//  (`AR2V0006.997` ↔ folder 997, checked on KGRK 2026-09-24), so the volume in
//  progress is the one after the newest archive file's.
//
//  ONLY THE LOWEST TILT IS DOWNLOADED. The metadata chunk's coverage pattern
//  says which chunks hold which tilt (see `Level2.CoveragePattern`), so a
//  volume costs its two-kilobyte metadata plus the six chunks of each lowest
//  pass — the same ~1.5 MB the archive path reads, minutes sooner. The listing
//  alone says which tilt the dish is on now, for free.
//

import Foundation

/// One chunk in the realtime bucket.
public struct LiveChunk: Equatable, Sendable {
    public let key: String
    public let number: Int
    /// "S" (start, metadata), "I" (intermediate) or "E" (end of volume).
    public let kind: Character
    /// When the volume began, from the key — the same instant an archive file's
    /// name records, which is how a live pass and an archive file are matched.
    public let volumeStart: Date
    public let posted: Date?

    /// Parses `KGRK/998/20260924-155008-045-I`.
    public init?(key: String, posted: Date?) {
        let parts = key.split(separator: "/")
        guard parts.count == 3 else { return nil }
        let fields = parts[2].split(separator: "-")
        guard fields.count == 4, let number = Int(fields[2]), let kind = fields[3].first,
              let start = LiveChunk.formatter.date(from: "\(fields[0])-\(fields[1])") else { return nil }
        self.key = key; self.number = number; self.kind = kind
        self.volumeStart = start; self.posted = posted
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

public struct Level2LiveClient: Sendable {
    public static let bucket = "https://unidata-nexrad-level2-chunks.s3.amazonaws.com"

    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    /// Chunks posted so far for one volume, in order.
    public func chunks(site: String, volume: Int) async throws -> [LiveChunk] {
        var components = URLComponents(string: Self.bucket)!
        components.queryItems = [.init(name: "list-type", value: "2"),
                                 .init(name: "prefix", value: "\(site)/\(volume)/")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Level2Client.Failure.badResponse(status: http.statusCode)
        }
        return Self.entries(inListing: data).compactMap { LiveChunk(key: $0.key, posted: $0.posted) }
            .sorted { $0.number < $1.number }
    }

    public func data(of chunk: LiveChunk) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(Self.bucket)/\(chunk.key)")!)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Level2Client.Failure.badResponse(status: http.statusCode)
        }
        return data
    }

    /// The volume number an archive file's header carries: `AR2V0006.997` → 997.
    public func volumeNumber(of scan: Level2Scan) async throws -> Int? {
        var request = URLRequest(url: URL(string: "\(Level2Client.archive)/\(scan.key)")!)
        request.setValue("bytes=0-23", forHTTPHeaderField: "Range")
        request.timeoutInterval = 15
        let (data, _) = try await session.data(for: request)
        return Self.volumeNumber(fromHeader: data)
    }

    static func volumeNumber(fromHeader data: Data) -> Int? {
        guard data.count >= 12, data.prefix(4) == Data("AR2V".utf8) else { return nil }
        return Int(String(decoding: data[9..<12], as: UTF8.self))
    }

    /// The volume after `v`. Numbers run 1–999 per the Archive II spec; the
    /// tracker also tries 0 after 999 in case a site counts from zero.
    static func after(_ v: Int) -> Int { v >= 999 ? 1 : v + 1 }

    /// `<Key>` and `<LastModified>` pairs out of an S3 listing.
    static func entries(inListing data: Data) -> [(key: String, posted: Date?)] {
        let text = String(decoding: data, as: UTF8.self)
        var out: [(String, Date?)] = []
        var rest = text[...]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        while let open = rest.range(of: "<Key>"),
              let close = rest.range(of: "</Key>", range: open.upperBound..<rest.endIndex) {
            let key = String(rest[open.upperBound..<close.lowerBound])
            rest = rest[close.upperBound...]
            var posted: Date?
            if let m1 = rest.range(of: "<LastModified>"), let m2 = rest.range(of: "</LastModified>"),
               m1.lowerBound < (rest.range(of: "<Key>")?.lowerBound ?? rest.endIndex) {
                posted = iso.date(from: String(rest[m1.upperBound..<m2.lowerBound]))
            }
            out.append((key, posted))
        }
        return out
    }
}

// MARK: - Following one site

/// Tracks one site's volume in progress and hands back each lowest-tilt pass as
/// soon as its chunks are all posted.
public actor Level2Live {
    /// A finished lowest-tilt pass, decoded and already in `Level2Frames`.
    public struct Pass: Equatable, Sendable {
        /// `KGRK20260924_155008_V06#p1` — the archive file's name for the same
        /// volume, plus which pass. The prefix is how the loop knows this pass
        /// supersedes that archive file.
        public let stamp: String
        /// The pass's first radial.
        public let time: Date
    }

    /// What the dish is doing, as far as the posted chunks say.
    public struct Dish: Equatable, Sendable {
        public let volumeStart: Date
        public let pattern: Int?
        /// Tilt of the newest posted chunk, degrees.
        public let angle: Double?
        /// 0-based position in the volume's plan, and how many tilts it has.
        public let cut: Int?
        public let cuts: Int
        /// When the newest chunk was posted.
        public let posted: Date?
        /// True while the newest chunk is part of a lowest pass.
        public let onLowestTilt: Bool
        /// A rough wait until the dish is next back on the lowest tilt, from how
        /// fast this volume's chunks have been arriving.
        public let untilNextLowest: TimeInterval?
    }

    public let site: String
    private let client = Level2LiveClient()

    private var volume: Int?
    private var plan: Level2.CoveragePattern?
    private var metadata: Data?
    private var fetched: [Int: Data] = [:]
    private var emitted: Set<Int> = []
    private var emptyPolls = 0

    public init(site: String) { self.site = site }

    /// One look at the bucket. Returns passes finished since the last poll, and
    /// the dish's state. Cheap when nothing has changed: one listing request.
    public func poll() async -> (passes: [Pass], dish: Dish?) {
        do {
            if volume == nil { try await seed() }
            guard let current = volume else { return ([], nil) }

            let chunks = try await client.chunks(site: site, volume: current)
            guard let first = chunks.first else {
                // Not started yet — or this number was skipped. After a while,
                // look one further on.
                emptyPolls += 1
                if emptyPolls >= 6 { advance(to: Level2LiveClient.after(current)) }
                return ([], nil)
            }
            emptyPolls = 0

            if plan == nil, let s = chunks.first(where: { $0.kind == "S" }) {
                let data = try await client.data(of: s)
                metadata = data
                plan = Level2.coveragePattern(data)
                radarLog.info("live \(self.site, privacy: .public) volume \(current): pattern \(self.plan?.number ?? -1), \(self.plan?.cuts.count ?? 0) tilts, lowest passes at \(self.plan.map { $0.lowestPasses().map { $0 + 1 } } ?? [], privacy: .public)")
            }

            let passes = try await collectPasses(chunks: chunks, volumeStart: first.volumeStart)
            let dish = describe(chunks: chunks, volumeStart: first.volumeStart)

            if chunks.contains(where: { $0.kind == "E" }) {
                advance(to: Level2LiveClient.after(current))
            }
            return (passes, dish)
        } catch {
            radarLog.error("live \(self.site, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ([], nil)
        }
    }

    /// Start from the volume after the newest archive file's.
    private func seed() async throws {
        guard let newest = try await Level2Client().scans(site: site).last,
              let number = try await client.volumeNumber(of: newest) else { return }
        volume = Level2LiveClient.after(number)
        radarLog.info("live \(self.site, privacy: .public): newest archive volume \(number), following \(self.volume ?? -1)")
    }

    private func advance(to next: Int) {
        volume = next
        plan = nil; metadata = nil
        fetched = [:]; emitted = []; emptyPolls = 0
    }

    /// Fetch the chunks of each lowest pass as they appear; decode a pass once
    /// all of its chunks are in.
    private func collectPasses(chunks: [LiveChunk], volumeStart: Date) async throws -> [Pass] {
        guard let plan, let metadata else { return [] }
        let byNumber = Dictionary(chunks.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        var found: [Pass] = []

        for cut in plan.lowestPasses() where !emitted.contains(cut) {
            let range = plan.chunkRanges[cut]
            for n in range where fetched[n] == nil {
                guard let chunk = byNumber[n] else { break }
                fetched[n] = try await client.data(of: chunk)
            }
            guard range.allSatisfy({ fetched[$0] != nil }) else { continue }

            var bytes = metadata
            for n in range { bytes.append(fetched[n]!) }
            let volume = try Level2.decode(bytes, moments: ["REF", "RHO"])
            guard let ref = volume.sweeps.filter({ $0.moment == "REF" && $0.elevationNumber == cut + 1 }).first
                    ?? volume.lowestPasses().last,
                  volume.latitude.isFinite else { continue }
            let rho = volume.sweeps.first { $0.moment == "RHO" && $0.elevationNumber == ref.elevationNumber }
            let sweep = Level2TileRenderer.display(reflectivity: ref, rho: rho)

            let stamp = "\(site)\(Level2Scan.formatter.string(from: volumeStart))_V06#p\(cut + 1)"
            await Level2Frames.shared.insert(.init(sweep: sweep, latitude: volume.latitude,
                                                   longitude: volume.longitude), for: stamp)
            emitted.insert(cut)
            for n in range { fetched[n] = nil }   // decoded; the bytes are no longer needed
            found.append(Pass(stamp: stamp, time: ref.time))
            radarLog.info("live \(self.site, privacy: .public): pass \(stamp, privacy: .public) ready, \(Int(Date().timeIntervalSince(ref.time)))s after its first radial")
        }
        return found
    }

    private func describe(chunks: [LiveChunk], volumeStart: Date) -> Dish {
        let newest = chunks.last
        let cut = newest.flatMap { plan?.cut(forChunk: $0.number) }
        let lows = plan?.lowestPasses() ?? []

        // Chunks arrive at a steady-ish pace within a volume; use it to say
        // roughly when the dish is next on the lowest tilt.
        var until: TimeInterval?
        let times = chunks.compactMap(\.posted)
        if let plan, let newest, let cut, times.count >= 3,
           let firstTime = times.first, let lastTime = times.last {
            let perChunk = lastTime.timeIntervalSince(firstTime) / Double(times.count - 1)
            let ranges = plan.chunkRanges
            let nextLow = lows.first { $0 > cut }.map { ranges[$0].lowerBound }
                // Otherwise the next volume's first pass: the rest of this one,
                // its metadata chunk, then straight in.
                ?? ((ranges.last?.upperBound ?? newest.number) + 2)
            until = max(0, Double(nextLow - newest.number) * perChunk)
        }

        return Dish(volumeStart: volumeStart, pattern: plan?.number,
                    angle: cut.flatMap { plan?.cuts[$0].angle },
                    cut: cut, cuts: plan?.cuts.count ?? 0,
                    posted: newest?.posted,
                    onLowestTilt: cut.map { lows.contains($0) } ?? false,
                    untilNextLowest: until)
    }
}
