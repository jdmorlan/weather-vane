//
//  Level2Client.swift  (WeatherKit)
//
//  Where single-site radar comes from, and the field that draws it.
//
//  THE SOURCE. NOAA's Big Data Program mirrors every WSR-88D volume to a public
//  S3 bucket, `unidata-nexrad-level2`, readable without an account or a key:
//
//      2026/09/24/KFWS/KFWS20260924_122217_V06
//
//  A volume lands there about seven minutes after it starts — the radar takes
//  four to six minutes to climb through its tilts, and the file is posted when
//  the last one is done. That is the lag this loop carries, and it is stated on
//  screen rather than hidden (`Level2Scan.time` is the scan's own start time).
//
//  RANGED READS. A volume is seven megabytes or so, and a map wants only the
//  0.5° tilt at the very front of it. S3 honours HTTP ranges, so the first
//  ~1.5 MB is fetched, decoded, and extended only if that sweep is not yet
//  whole. A ten-frame loop is ~15 MB instead of ~75.
//

import Foundation
import CoreGraphics

/// One volume scan in the archive.
public struct Level2Scan: Hashable, Sendable {
    /// File name, e.g. `KFWS20260924_122217_V06`. Also the loop stamp.
    public let name: String
    public let site: String
    /// Volume start time, from the name.
    public let time: Date

    /// The object's key in the bucket.
    public var key: String {
        let d = name.dropFirst(4)
        return "\(d.prefix(4))/\(d.dropFirst(4).prefix(2))/\(d.dropFirst(6).prefix(2))/\(site)/\(name)"
    }

    /// Parses `SSSSYYYYMMDD_HHMMSS_V06`. Anything else — the `_MDM` metadata
    /// files that share the folder, old gzipped volumes — is nil.
    public init?(name: String) {
        guard name.count >= 19, !name.hasSuffix("_MDM"), !name.hasSuffix(".gz") else { return nil }
        let site = String(name.prefix(4))
        let stamp = String(name.dropFirst(4).prefix(15))   // YYYYMMDD_HHMMSS
        guard let time = Level2Scan.formatter.date(from: stamp) else { return nil }
        self.name = name; self.site = site; self.time = time
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()
}

public struct Level2Client: Sendable {
    public static let archive = "https://unidata-nexrad-level2.s3.amazonaws.com"
    public static let credit = "NEXRAD Level II · NOAA via AWS Open Data"

    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public enum Failure: Error, LocalizedError {
        case badResponse(status: Int)
        case noScans(site: String)

        public var errorDescription: String? {
            switch self {
            case .badResponse(let status): return "The radar archive returned HTTP \(status)."
            case .noScans(let site): return "\(site) has posted no scans in the last ninety minutes — the site may be down for maintenance."
            }
        }
    }

    /// Volumes from `site` in the last `window`, oldest first.
    ///
    /// Asks for today's folder and, near midnight UTC, yesterday's too — a loop
    /// that straddles 00Z spans two folders. `start-after` keeps each listing to
    /// the recent tail instead of a day's three hundred keys.
    public func scans(site: String, window: TimeInterval = 90 * 60, now: Date = Date()) async throws -> [Level2Scan] {
        let from = now.addingTimeInterval(-window)
        var days = [from]
        if !Calendar.utc.isDate(from, inSameDayAs: now) { days.append(now) }

        var found: [Level2Scan] = []
        for day in days {
            let folder = Self.folder(site: site, day: day)
            let after = "\(folder)\(site)\(Level2Scan.formatter.string(from: from))"
            var components = URLComponents(string: Self.archive)!
            components.queryItems = [
                .init(name: "list-type", value: "2"),
                .init(name: "prefix", value: folder),
                .init(name: "start-after", value: after),
            ]
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw Failure.badResponse(status: http.statusCode)
            }
            found += Self.keys(inListing: data).compactMap { key in
                Level2Scan(name: String(key.split(separator: "/").last ?? ""))
            }
        }
        let scans = found.filter { $0.time >= from }.sorted { $0.time < $1.time }
        guard !scans.isEmpty else { throw Failure.noScans(site: site) }
        return scans
    }

    static func folder(site: String, day: Date) -> String {
        let c = Calendar.utc.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d/%02d/%02d/%@/", c.year!, c.month!, c.day!, site)
    }

    /// `<Key>…</Key>` out of an S3 listing. A regex rather than `XMLParser`: the
    /// listing's shape is fixed and this is the only element read.
    static func keys(inListing data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var out: [String] = []
        var rest = text[...]
        while let open = rest.range(of: "<Key>"), let close = rest.range(of: "</Key>", range: open.upperBound..<rest.endIndex) {
            out.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return out
    }

    /// The lowest tilt of one volume: reflectivity and correlation coefficient,
    /// read with as few bytes as will complete the sweep.
    public func lowestSweep(of scan: Level2Scan) async throws -> Level2Volume {
        let url = URL(string: "\(Self.archive)/\(scan.key)")!
        var buffer = Data()
        var step = 1_600_000
        // Five megabytes is well past any 0.5° sweep seen; beyond it something
        // is wrong with the file and a partial sweep is the honest result.
        while buffer.count < 5_000_000 {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("bytes=\(buffer.count)-\(buffer.count + step - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 416 is a range starting past the end: the file is shorter than
            // what we already hold, so we hold it all.
            if status == 416 { break }
            guard (200..<300).contains(status) else { throw Failure.badResponse(status: status) }
            buffer.append(data)

            let volume = try? Level2.decode(buffer, moments: ["REF", "RHO"], throughElevation: 1)
            if let volume, volume.lowest("REF")?.isComplete == true { return volume }
            // A 200 is the whole file; a short 206 is the end of it.
            if status == 200 || data.count < step { break }
            step = 1_000_000
        }
        return try Level2.decode(buffer, moments: ["REF", "RHO"], throughElevation: 1)
    }
}

extension Calendar {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

// MARK: - Decoded frames

/// Scans decoded and ready to draw, shared by every tile of every zoom.
///
/// ONE DOWNLOAD PER SCAN, HOWEVER MANY TILES ASK. A prefetch fires a few dozen
/// tile renders for the same stamp at once; without this each would fetch and
/// decode the same megabyte and a half. The first caller starts the work and
/// everyone else awaits the same task.
public actor Level2Frames {
    public static let shared = Level2Frames()

    /// What a tile needs: the drawable sweep and where the radar is.
    public struct Frame: Sendable {
        public let sweep: Level2Sweep
        public let latitude: Double
        public let longitude: Double
    }

    private var frames: [String: Frame] = [:]
    private var order: [String] = []
    private var pending: [String: Task<Frame?, Never>] = [:]

    /// A loop's worth and a reload's overlap. Each frame is one 720 × ~1800
    /// float grid, about 5 MB.
    private let capacity = 24

    /// Scans fetched and decoded at once. Three keeps the newest frame's
    /// download from queueing behind the whole loop's, without ten decodes
    /// landing on the CPU together.
    static let decodes = AsyncGate(limit: 3)

    /// Tiles drawn at once: every core but two, so MapKit and the interface
    /// always have somewhere to run.
    public static let renders = AsyncGate(limit: max(1, ProcessInfo.processInfo.activeProcessorCount - 2))

    /// For diagnostics: what is held, what is on its way, and the two gates.
    public func snapshot() async -> String {
        let decodes = await Self.decodes.state, renders = await Self.renders.state
        return "held \(frames.count), pending \(pending.keys.sorted()), "
            + "decodes \(decodes.running) running/\(decodes.waiting) waiting, "
            + "renders \(renders.running) running/\(renders.waiting) waiting"
    }

    /// A frame decoded elsewhere — a live pass from `Level2Live`, which has no
    /// archive file to fetch it from yet.
    public func insert(_ frame: Frame, for stamp: String) {
        if frames[stamp] == nil { order.append(stamp) }
        frames[stamp] = frame
        while order.count > capacity { frames[order.removeFirst()] = nil }
    }

    public func frame(for stamp: String) async -> Frame? {
        if let held = frames[stamp] { return held }
        if let task = pending[stamp] { return await task.value }
        // A live pass not held is one this session never saw, or one evicted;
        // either way there is no file to fetch it from.
        if stamp.contains("#") { return nil }
        guard let scan = Level2Scan(name: stamp) else { return nil }

        let task = Task<Frame?, Never>.detached(priority: .utility) {
            await Self.decodes.run {
                let started = Date()
                radarLog.info("scan \(stamp, privacy: .public): fetching")
                let volume: Level2Volume
                do { volume = try await Level2Client().lowestSweep(of: scan) } catch {
                    radarLog.error("scan \(stamp, privacy: .public): failed — \(error.localizedDescription, privacy: .public)")
                    return nil
                }
                guard let ref = volume.lowest("REF"), volume.latitude.isFinite else {
                    radarLog.error("scan \(stamp, privacy: .public): no reflectivity in the bytes read")
                    return nil
                }
                let sweep = Level2TileRenderer.display(reflectivity: ref, rho: volume.lowest("RHO"))
                radarLog.info("scan \(stamp, privacy: .public): ready in \(Int(Date().timeIntervalSince(started) * 1000))ms, \(ref.radialCount) radials")
                return Frame(sweep: sweep, latitude: volume.latitude, longitude: volume.longitude)
            }
        }
        pending[stamp] = task
        let frame = await task.value
        pending[stamp] = nil
        if let frame {
            frames[stamp] = frame
            order.append(stamp)
            while order.count > capacity { frames[order.removeFirst()] = nil }
        }
        return frame
    }
}

// MARK: - The field

/// One radar site's lowest tilt, drawn tile by tile on this device.
public struct Level2FieldSource: RenderedFieldTileSource {
    public let site: String
    public var palette: ReflectivityPalette = .standard

    public init(site: String) { self.site = site }

    /// Site in the id: two sites' tiles for the same instant are different
    /// pictures. The version is bumped whenever the drawing changes.
    public var id: String { "level2-\(site)-v1" }

    /// TO z11, NOT z12. At z10 a 512-px tile pixel is ~65 m here against a
    /// 250 m gate, so z10 already resolves every gate four times over; z11 buys
    /// smoother edges when zoomed right in. z12 bought nothing visible and
    /// quadrupled the tiles — ~600 renders for one loop on a large window.
    public var zoomRange: ClosedRange<Int> { 3...11 }

    /// ONE TILE PIXEL PER SCREEN POINT, NOT TWO. Measured: a ten-frame loop at
    /// retina density over a large window is ~480 tiles of 1 MB each — more than
    /// the tile cache holds, so tiles were evicted and re-rendered forever and
    /// the map never finished. At one per point it is a quarter of that, and a
    /// point is still finer than a 250 m gate at any zoom a loop is watched at.
    public var maxPixelScale: Double? { 1 }
    /// Drawn nearest-neighbour like every field (see `FieldRenderer.drawImage`
    /// for the seam grid smoothing caused): at one pixel per point each block is
    /// a single screen point, which on a retina display nothing resolves.

    public func render(stamp: String, z: Int, x: Int, y: Int) async -> CGImage? {
        guard let frame = await Level2Frames.shared.frame(for: stamp) else { return nil }
        let size = tileSize, palette = palette
        return await Level2Frames.renders.run {
            Level2TileRenderer.render(sweep: frame.sweep,
                                      siteLatitude: frame.latitude, siteLongitude: frame.longitude,
                                      z: z, x: x, y: y, size: size, palette: palette)
        }
    }
}
