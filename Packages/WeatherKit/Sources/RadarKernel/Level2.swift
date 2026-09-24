//
//  Level2.swift  (WeatherKit)
//
//  A NEXRAD Level II decoder: the radar's own measurements, before anyone has
//  turned them into a picture.
//
//  WHY LEVEL II. The radar map used to draw the Iowa State mosaic: a finished
//  PNG, a national composite gridded to about a kilometre and coloured by
//  somebody else. Everything the app did with it was archaeology — reading
//  intensity back out of a colour, with no way to recover the absolute scale —
//  and it looked flat next to an app like RadarOmega, which starts from THIS: a
//  single radar's radials, 0.5° apart, a gate every 250 m, every value in real
//  dBZ.
//
//  THE FORMAT, AS FAR AS THIS FILE NEEDS IT (ICD 2620010, "Archive II"):
//
//    · a 24-byte volume header: "AR2V00xx.", a volume number, date, time, ICAO
//    · then LDM records, each a 4-byte big-endian length (negative on the last)
//      followed by one bzip2 stream
//    · a decompressed record is a run of messages, each behind a 12-byte
//      channel header. Most message types sit in fixed 2432-byte frames; type 31
//      — the one that carries radials — states its own length
//    · a type-31 message is one radial: azimuth, elevation, and pointers to data
//      blocks. "RVOL" says where the radar is; "DREF", "DVEL", "DRHO" and the
//      rest are one moment each, as scaled 8- or 16-bit gates
//
//  The realtime chunks in `unidata-nexrad-level2-chunks` are the same records
//  cut up as the radar sweeps, so the one decoder reads both.
//
//  WHAT IT KEEPS. Only the moments and elevations asked for, and it stops
//  decompressing once it is past the last elevation wanted. The lowest tilt is
//  the first thing in the volume, so reading "0.5° reflectivity" costs the first
//  megabyte or so of a seven-megabyte file — which is what makes a ranged
//  request (see `Level2Client`) worth doing.
//

import Foundation
import CBzip2

// MARK: - The decoded picture

/// One elevation sweep of one moment, resampled onto a uniform azimuth grid.
///
/// UNIFORM ON PURPOSE. The radar reports each radial at whatever azimuth the dish
/// was pointing, a little irregularly, starting wherever the sweep happened to
/// start. A renderer asking "what is at bearing 213.4°, 41 km" wants that to be
/// arithmetic, not a search — so on decode each radial is dropped into the row
/// its azimuth falls in, and the lookup becomes two multiplications.
public struct Level2Sweep: Sendable {
    /// Moment name as the file spells it: "REF", "VEL", "RHO", "ZDR", "PHI", "SW ".
    public let moment: String
    /// 1-based position in the volume coverage pattern. The 0.5° tilt is 1 (and,
    /// in split-cut patterns, 2 again for the Doppler half).
    public let elevationNumber: Int
    /// Mean elevation angle across the sweep, degrees.
    public let elevationAngle: Double
    /// Time of the first radial in the sweep.
    public let time: Date

    /// Range to the CENTRE of the first gate, metres.
    public let firstGate: Double
    /// Metres between gate centres.
    public let gateSpacing: Double
    public let gateCount: Int

    /// Rows in `values`, one per `azimuthStep` degrees starting at north.
    public let rowCount: Int
    public var azimuthStep: Double { 360 / Double(rowCount) }

    /// `rowCount × gateCount`, row-major. NaN is "no return" — below the noise
    /// threshold, or range-folded — and is kept distinct from any real value so a
    /// renderer never has to guess what a sentinel meant.
    public let values: [Float]

    /// Radials actually decoded. Short of `rowCount` means the sweep was cut off
    /// (a ranged read that stopped early, or a chunk still arriving).
    public let radialCount: Int
    /// True when the radar marked the sweep's last radial.
    public let isComplete: Bool

    /// Where the dish pointed and when, radial by radial, in the order the radar
    /// collected them. What a replay of the sweep follows — the real rotation,
    /// speed changes and all, rather than an assumed steady turn.
    public struct RadialStamp: Sendable, Equatable {
        /// Seconds after the sweep's first radial.
        public let seconds: Float
        /// Degrees from north.
        public let azimuth: Float
    }
    public var path: [RadialStamp] = []

    /// How long the sweep took, first radial to last.
    public var duration: Double { Double(path.last?.seconds ?? 0) }

    /// Furthest range the sweep reaches, metres.
    public var maxRange: Double { firstGate + gateSpacing * Double(gateCount - 1) }

    /// Raw lookup, nearest gate and row. Nil outside the sweep or where nothing
    /// came back.
    public func value(azimuth: Double, range: Double) -> Float? {
        let g = Int(((range - firstGate) / gateSpacing).rounded())
        guard g >= 0, g < gateCount else { return nil }
        var a = azimuth.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        let row = min(rowCount - 1, Int(a / azimuthStep))
        let v = values[row * gateCount + g]
        return v.isNaN ? nil : v
    }

    /// The same sweep with pinholes closed, FOR DRAWING.
    ///
    /// Inside a storm the radar leaves single empty gates — ground clutter it
    /// suppressed, a pulse that came back below threshold — and on a map each one
    /// is a black square in the middle of the rain, which reads as structure that
    /// is not there. A gate is filled only when at least six of its eight
    /// neighbours have values, so the fill cannot grow an echo's edge or bridge
    /// two cells: it only closes holes that rain already surrounds. `values` stays
    /// what the radar said; this is a separate copy for the renderer.
    public func pinholesFilled() -> Level2Sweep {
        // Raw buffers, and no allocation inside the loop: this runs over every
        // gate of every scan (~1.3 million), and a per-gate array literal made
        // it two seconds a scan in a Debug build.
        var out = values
        let rows = rowCount, gates = gateCount
        values.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<rows {
                    let up = ((row + rows - 1) % rows) * gates
                    let mid = row * gates
                    let down = ((row + 1) % rows) * gates
                    for g in 1..<(gates - 1) where src[mid + g].isNaN {
                        var sum: Float = 0, n = 0
                        @inline(__always) func take(_ i: Int) {
                            let v = src[i]
                            if !v.isNaN { sum += v; n += 1 }
                        }
                        take(up + g - 1); take(up + g); take(up + g + 1)
                        take(mid + g - 1);              take(mid + g + 1)
                        take(down + g - 1); take(down + g); take(down + g + 1)
                        if n >= 6 { dst[mid + g] = sum / Float(n) }
                    }
                }
            }
        }
        return Level2Sweep(moment: moment, elevationNumber: elevationNumber,
                           elevationAngle: elevationAngle, time: time,
                           firstGate: firstGate, gateSpacing: gateSpacing, gateCount: gateCount,
                           rowCount: rowCount, values: out,
                           radialCount: radialCount, isComplete: isComplete, path: path)
    }
}

/// Everything decoded from one file (or one run of chunks).
public struct Level2Volume: Sendable {
    public let icao: String
    /// Volume start time from the file header.
    public let time: Date
    public let latitude: Double
    public let longitude: Double
    /// Height of the site above sea level, metres.
    public let siteHeight: Double
    public let sweeps: [Level2Sweep]

    /// EVERY PASS OF THE LOWEST TILT, in the order the dish made them.
    ///
    /// Usually one. In SAILS mode the dish drops back to the lowest tilt partway
    /// through the volume — KAMX was doing it on 2026-09-24, back down at +113 s
    /// — and each of those is a fresh look at the weather nearest the ground.
    ///
    /// Each pass is a SPLIT CUT: a long-range reflectivity sweep and then a
    /// Doppler sweep at the same angle, which also carries reflectivity but to a
    /// shorter range. The pass's picture is the long-range one, so from each run
    /// of consecutive low-angle elevations the sweep with the most gates wins.
    public func lowestPasses(_ moment: String = "REF", maxAngle: Double = 0.8) -> [Level2Sweep] {
        let low = sweeps.filter { $0.moment == moment && $0.elevationAngle < maxAngle }
            .sorted { $0.elevationNumber < $1.elevationNumber }
        var passes: [[Level2Sweep]] = []
        for sweep in low {
            if let last = passes.last?.last, sweep.elevationNumber == last.elevationNumber + 1 {
                passes[passes.count - 1].append(sweep)
            } else {
                passes.append([sweep])
            }
        }
        return passes.compactMap { run in run.max { $0.gateCount < $1.gateCount } }
    }

    /// The lowest complete-enough sweep of a moment, which is what a map wants.
    public func lowest(_ moment: String) -> Level2Sweep? {
        sweeps.filter { $0.moment == moment }.min { $0.elevationNumber < $1.elevationNumber }
    }
}

// MARK: - Decoding

public enum Level2 {

    public enum Failure: Error, Equatable {
        case notLevel2
        case decompression(Int32)
        /// Decoded cleanly and held no radials — a metadata-only chunk, or a
        /// ranged read too short to reach the first sweep.
        case noRadials
    }

    /// Decode what `data` holds.
    ///
    /// - Parameters:
    ///   - moments: which data blocks to keep. Everything else is skipped at the
    ///     pointer, never copied.
    ///   - throughElevation: stop once radials for a later elevation appear. The
    ///     bzip2 streams after that point are never decompressed, which is most
    ///     of the cost of a volume.
    ///
    /// TRUNCATION IS NOT AN ERROR. A ranged read ends mid-record by design; the
    /// records that arrived whole are decoded and the sweep says, through
    /// `isComplete` and `radialCount`, how much of itself it has.
    public static func decode(_ data: Data,
                              moments: Set<String> = ["REF"],
                              throughElevation: Int? = nil) throws -> Level2Volume {
        try data.withUnsafeBytes { raw -> Level2Volume in
            var header = VolumeHeader()
            var offset = 0
            if raw.count >= 24, raw[0] == 0x41, raw[1] == 0x52, raw[2] == 0x32, raw[3] == 0x56 { // "AR2V"
                header = VolumeHeader(raw)
                offset = 24
            }

            var collector = Collector(moments: moments, throughElevation: throughElevation)

            // UNCOMPRESSED FILES. Older archives (the gzipped ones, before about
            // 2016) carry the messages straight after the header with no LDM
            // record lengths at all. Those still read through the same walk.
            let bz = offset + 7 <= raw.count
                && raw[offset + 4] == 0x42 && raw[offset + 5] == 0x5A && raw[offset + 6] == 0x68
            if !bz {
                collector.read(messages: UnsafeRawBufferPointer(rebasing: raw[offset...]))
                offset = raw.count
            }

            while offset + 4 <= raw.count, !collector.finished {
                let length = Int(abs(Int32(bitPattern: raw.u32(offset))))
                offset += 4
                guard length > 0 else { break }
                // A record that did not arrive whole is where a ranged read ends.
                guard offset + length <= raw.count else { break }
                let record = UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + length)])
                offset += length

                if record.count >= 3, record[0] == 0x42, record[1] == 0x5A, record[2] == 0x68 { // "BZh"
                    let messages = try bunzip(record)
                    messages.withUnsafeBytes { collector.read(messages: $0) }
                } else {
                    // Uncompressed files predate 2008 and are not worth a code
                    // path; a record that is neither is not Level II.
                    throw Failure.notLevel2
                }
            }

            guard collector.sawRadial else { throw Failure.noRadials }
            return Level2Volume(
                icao: collector.icao ?? header.icao,
                time: header.time ?? collector.firstTime ?? Date(timeIntervalSince1970: 0),
                latitude: collector.latitude ?? .nan,
                longitude: collector.longitude ?? .nan,
                siteHeight: collector.siteHeight ?? 0,
                sweeps: collector.sweeps())
        }
    }

    // MARK: The volume's plan

    /// The VOLUME COVERAGE PATTERN: the list of tilts the dish will make this
    /// volume, in order. Message 5, carried in the metadata record at the front
    /// of every volume — the first two kilobytes of an archive file, and the
    /// whole of a realtime volume's "S" chunk.
    ///
    /// WHY THE LIVE FEED NEEDS IT. Realtime chunks hold exactly 120 radials each
    /// (checked against KGRK volume 998, all 55 chunks), so a tilt of 720
    /// radials is six chunks and one of 360 is three. With the plan, a chunk's
    /// number says which tilt it holds — so the app can fetch only the lowest
    /// tilt's chunks, and say which tilt the dish is on from a file listing alone.
    public struct CoveragePattern: Equatable, Sendable {
        public struct Cut: Equatable, Sendable {
            /// Elevation angle, degrees.
            public let angle: Double
            /// A surveillance cut: long-range reflectivity. The other kind is
            /// the Doppler cut of a split pair, which the map does not draw.
            public let isSurveillance: Bool
            /// 720 at half-degree azimuth resolution, else 360.
            public let radials: Int
        }
        /// The pattern number the NWS publishes: 35 is clear air, 212 and 215
        /// are precipitation.
        public let number: Int
        public let cuts: [Cut]

        public static let radialsPerChunk = 120

        /// Chunk numbers each cut occupies. Chunk 1 is the metadata; the first
        /// cut starts at 2.
        public var chunkRanges: [ClosedRange<Int>] {
            var next = 2
            return cuts.map { cut in
                let count = max(1, cut.radials / Self.radialsPerChunk)
                defer { next += count }
                return next...(next + count - 1)
            }
        }

        /// Which cut a chunk belongs to, 0-based. Nil for the metadata chunk or
        /// one past the plan.
        public func cut(forChunk chunk: Int) -> Int? {
            chunkRanges.firstIndex { $0.contains(chunk) }
        }

        /// The cuts a map draws: the surveillance pass of each visit to the
        /// lowest tilt. One per volume usually; more in SAILS mode.
        public func lowestPasses(maxAngle: Double = 0.8) -> [Int] {
            cuts.indices.filter { cuts[$0].isSurveillance && cuts[$0].angle < maxAngle }
        }
    }

    /// The coverage pattern, from bytes that begin with a volume's metadata
    /// record — an "S" chunk, or the start of an archive file.
    public static func coveragePattern(_ data: Data) -> CoveragePattern? {
        data.withUnsafeBytes { raw -> CoveragePattern? in
            var offset = 0
            if raw.count >= 24, raw[0] == 0x41, raw[1] == 0x52, raw[2] == 0x32, raw[3] == 0x56 { offset = 24 }
            guard offset + 7 <= raw.count else { return nil }
            let length = Int(abs(Int32(bitPattern: raw.u32(offset))))
            let start = offset + 4
            guard length > 0, start + length <= raw.count,
                  let messages = try? bunzip(UnsafeRawBufferPointer(rebasing: raw[start..<(start + length)]))
            else { return nil }
            return messages.withUnsafeBytes { m -> CoveragePattern? in
                var o = 0
                while o + 28 <= m.count {
                    if m[o + 15] == 5 {
                        let b = o + 28
                        guard b + 22 <= m.count else { return nil }
                        let number = Int(m.u16(b + 4))
                        let count = Int(m.u16(b + 6))
                        var cuts: [CoveragePattern.Cut] = []
                        for c in 0..<count {
                            let e = b + 22 + c * 46
                            guard e + 6 <= m.count else { return nil }
                            // Angle in binary angular measure: 180/32768 of a
                            // degree per count. Waveform 1 is contiguous
                            // surveillance. Super-resolution bit 0x01 is the
                            // half-degree azimuth that doubles the radial count.
                            let angle = Double(m.u16(e)) * 180 / 32768
                            let waveform = m[e + 3]
                            let superRes = m[e + 4]
                            cuts.append(.init(angle: angle, isSurveillance: waveform == 1,
                                              radials: superRes & 0x01 != 0 ? 720 : 360))
                        }
                        return CoveragePattern(number: number, cuts: cuts)
                    }
                    o += 2432
                }
                return nil
            }
        }
    }

    // MARK: Volume header

    struct VolumeHeader {
        var icao = ""
        var time: Date?

        init() {}
        init(_ raw: UnsafeRawBufferPointer) {
            let date = raw.u32(12), ms = raw.u32(16)
            time = Level2.date(modifiedJulian: Int(date), milliseconds: Int(ms))
            icao = String(decoding: UnsafeRawBufferPointer(rebasing: raw[20..<24]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        }
    }

    /// NEXRAD dates count days with 1 January 1970 as day ONE.
    static func date(modifiedJulian days: Int, milliseconds: Int) -> Date? {
        guard days > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(days - 1) * 86_400 + Double(milliseconds) / 1000)
    }

    // MARK: bzip2

    static func bunzip(_ input: UnsafeRawBufferPointer) throws -> [UInt8] {
        var stream = bz_stream()
        var rc = BZ2_bzDecompressInit(&stream, 0, 0)
        guard rc == BZ_OK else { throw Failure.decompression(rc) }
        defer { BZ2_bzDecompressEnd(&stream) }

        let chunk = 1 << 20
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 6)
        var buffer = [UInt8](repeating: 0, count: chunk)

        stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress!.assumingMemoryBound(to: CChar.self))
        stream.avail_in = UInt32(input.count)

        repeat {
            let produced: Int = buffer.withUnsafeMutableBytes { buf in
                stream.next_out = buf.baseAddress!.assumingMemoryBound(to: CChar.self)
                stream.avail_out = UInt32(chunk)
                rc = BZ2_bzDecompress(&stream)
                return chunk - Int(stream.avail_out)
            }
            out.append(contentsOf: buffer[0..<produced])
            if rc == BZ_STREAM_END { break }
            guard rc == BZ_OK else { throw Failure.decompression(rc) }
            // No input left and nothing produced: a stream that stops short.
            if stream.avail_in == 0 && produced == 0 { throw Failure.decompression(BZ_UNEXPECTED_EOF) }
        } while true
        return out
    }

    // MARK: Messages

    /// Accumulates radials across records, grouped by (elevation, moment).
    struct Collector {
        let moments: Set<String>
        let throughElevation: Int?

        var icao: String?
        var latitude: Double?
        var longitude: Double?
        var siteHeight: Double?
        var firstTime: Date?
        var sawRadial = false
        var finished = false

        struct Key: Hashable { let elevation: Int; let moment: String }
        struct Radial { let azimuth: Float; let time: Date?; let values: [Float] }
        struct Partial {
            var firstGate = 0.0, gateSpacing = 0.0, gateCount = 0
            var halfDegree = true
            var angleSum = 0.0
            var time: Date?
            var radials: [Radial] = []
            var complete = false
        }
        var partials: [Key: Partial] = [:]

        init(moments: Set<String>, throughElevation: Int?) {
            self.moments = moments
            self.throughElevation = throughElevation
        }

        mutating func read(messages raw: UnsafeRawBufferPointer) {
            var o = 0
            while o + 28 <= raw.count {
                let size = Int(raw.u16(o + 12)) * 2   // halfwords, excluding the 12-byte channel header
                let type = raw[o + 15]
                if type == 31 {
                    guard size >= 16, o + 12 + size <= raw.count else { return }
                    radial(UnsafeRawBufferPointer(rebasing: raw[(o + 28)..<(o + 12 + size)]))
                    if finished { return }
                    o += 12 + size
                } else {
                    o += 2432
                }
            }
        }

        mutating func radial(_ m: UnsafeRawBufferPointer) {
            guard m.count >= 32 else { return }
            let elevation = Int(m[22])
            if let last = throughElevation, elevation > last { finished = true; return }

            sawRadial = true
            if icao == nil {
                icao = String(decoding: UnsafeRawBufferPointer(rebasing: m[0..<4]), as: UTF8.self)
            }
            let time = Level2.date(modifiedJulian: Int(m.u16(8)), milliseconds: Int(m.u32(4)))
            if firstTime == nil { firstTime = time }

            let azimuth = m.f32(12)
            let halfDegree = m[20] == 1
            let status = m[21]
            let angle = Double(m.f32(24))
            let blocks = min(Int(m.u16(30)), 10)

            for b in 0..<blocks {
                let p = Int(m.u32(32 + b * 4))
                guard p > 0, p + 28 <= m.count else { continue }
                let kind = m[p]
                let name = String(decoding: UnsafeRawBufferPointer(rebasing: m[(p + 1)..<(p + 4)]), as: UTF8.self)

                if kind == 0x52, name == "VOL", latitude == nil {           // "R" + "VOL"
                    latitude = Double(m.f32(p + 8))
                    longitude = Double(m.f32(p + 12))
                    siteHeight = Double(Int16(bitPattern: m.u16(p + 16)))
                    continue
                }
                guard kind == 0x44, moments.contains(name) else { continue } // "D"

                let gates = Int(m.u16(p + 8))
                let first = Double(Int16(bitPattern: m.u16(p + 10)))
                let spacing = Double(Int16(bitPattern: m.u16(p + 12)))
                let word = Int(m[p + 19])
                let scale = m.f32(p + 20), offset = m.f32(p + 24)
                let bytes = word == 16 ? 2 : 1
                guard gates > 0, scale != 0, p + 28 + gates * bytes <= m.count else { continue }

                // Raw 0 is "below threshold" and 1 is "range folded". Neither is
                // a measurement, and both become NaN rather than a number that
                // would draw as weak rain.
                var values = [Float](repeating: .nan, count: gates)
                let base = p + 28
                if bytes == 1 {
                    for g in 0..<gates {
                        let r = m[base + g]
                        if r > 1 { values[g] = (Float(r) - offset) / scale }
                    }
                } else {
                    for g in 0..<gates {
                        let r = m.u16(base + g * 2)
                        if r > 1 { values[g] = (Float(r) - offset) / scale }
                    }
                }

                // MODIFIED IN PLACE through the dictionary's subscript. Copying the
                // partial out, appending, and writing it back duplicated the whole
                // growing radial list on every radial — quadratic in the sweep.
                let key = Key(elevation: elevation, moment: name)
                if partials[key] == nil {
                    partials[key] = Partial(firstGate: first, gateSpacing: spacing, gateCount: gates,
                                            halfDegree: halfDegree, time: time)
                }
                let expected = partials[key]!.gateCount
                // A radial with a different gate count than the sweep's first is
                // padded or cut to fit; it happens at the sweep edge on some VCPs.
                if gates != expected {
                    values = Array(values.prefix(expected))
                    if values.count < expected {
                        values += [Float](repeating: .nan, count: expected - values.count)
                    }
                }
                partials[key]!.radials.append(Radial(azimuth: azimuth, time: time, values: values))
                partials[key]!.angleSum += angle
                // 2 = end of elevation, 4 = end of volume.
                if status == 2 || status == 4 { partials[key]!.complete = true }
            }
        }

        func sweeps() -> [Level2Sweep] {
            partials.compactMap { key, p -> Level2Sweep? in
                guard !p.radials.isEmpty, p.gateCount > 0 else { return nil }
                let rows = p.halfDegree ? 720 : 360
                let step = 360.0 / Double(rows)
                var grid = [Float](repeating: .nan, count: rows * p.gateCount)
                var filled = [Bool](repeating: false, count: rows)
                for radial in p.radials {
                    var a = Double(radial.azimuth).truncatingRemainder(dividingBy: 360)
                    if a < 0 { a += 360 }
                    let row = min(rows - 1, Int(a / step))
                    grid.replaceSubrange((row * p.gateCount)..<((row + 1) * p.gateCount), with: radial.values)
                    filled[row] = true
                }
                // A row no radial landed in borrows its neighbour's — ONLY a
                // one-row gap, which is jitter in where the dish reported. A wider
                // gap is data that is not there, and stays empty.
                for row in 0..<rows where !filled[row] {
                    let prev = (row + rows - 1) % rows, next = (row + 1) % rows
                    let source = filled[prev] ? prev : (filled[next] ? next : nil)
                    if let source {
                        let slice = Array(grid[(source * p.gateCount)..<((source + 1) * p.gateCount)])
                        grid.replaceSubrange((row * p.gateCount)..<((row + 1) * p.gateCount), with: slice)
                    }
                }
                return Level2Sweep(
                    moment: key.moment,
                    elevationNumber: key.elevation,
                    elevationAngle: p.angleSum / Double(p.radials.count),
                    time: p.time ?? Date(timeIntervalSince1970: 0),
                    firstGate: p.firstGate,
                    gateSpacing: p.gateSpacing,
                    gateCount: p.gateCount,
                    rowCount: rows,
                    values: grid,
                    radialCount: p.radials.count,
                    isComplete: p.complete,
                    path: p.radials.map { radial in
                        let start = p.time ?? radial.time ?? Date(timeIntervalSince1970: 0)
                        let seconds = radial.time.map { Float($0.timeIntervalSince(start)) } ?? 0
                        return Level2Sweep.RadialStamp(seconds: seconds, azimuth: radial.azimuth)
                    })
            }
            .sorted { ($0.elevationNumber, $0.moment) < ($1.elevationNumber, $1.moment) }
        }
    }
}

// MARK: - Big-endian reads

extension UnsafeRawBufferPointer {
    @inline(__always) func u16(_ o: Int) -> UInt16 {
        UInt16(self[o]) << 8 | UInt16(self[o + 1])
    }
    @inline(__always) func u32(_ o: Int) -> UInt32 {
        UInt32(self[o]) << 24 | UInt32(self[o + 1]) << 16 | UInt32(self[o + 2]) << 8 | UInt32(self[o + 3])
    }
    @inline(__always) func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
}
