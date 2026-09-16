//
//  Gzip.swift  (WeatherKit)
//
//  A real gzip container over Apple's `Compression` framework, so the sample
//  archive can be compressed WITHOUT stopping being legible outside this app.
//
//  The numbers forced the issue. A day of 1-minute observations is ~579 KB of
//  NDJSON and ~24 KB gzipped — 24×, because the columns are enormously repetitive
//  (the same field names, and neighbouring minutes that barely differ). The full
//  1,419-day record is 840 MB plain against 35 MB compressed. Storing the plain
//  version is not defensible when the compressed one reads identically through
//  `zcat` and `zgrep`.
//
//  Which is the whole reason this writes a GZIP CONTAINER rather than calling
//  `Compression` and keeping the raw DEFLATE stream it hands back. Raw DEFLATE is
//  smaller by 18 bytes and can only be opened by this app — which would break
//  [[files-are-the-data]]: the vault has to be readable without Almanac. 18 bytes
//  buys `zcat 2026-06-15.ndjson.gz | jq`, and that is the difference between a
//  data file and an opaque blob.
//

import Foundation
import Compression

public enum Gzip {
    public enum Failure: Error {
        case notGzip
        case truncated
        case compressionFailed
    }

    // MARK: CRC-32
    //
    // Table built once, lazily. The gzip trailer carries a CRC of the ORIGINAL
    // bytes, and a decoder that checks it (gzip(1) does) rejects the file if it
    // disagrees — so this cannot be stubbed out.

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 == 1) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: Compress

    public static func compress(_ data: Data) throws -> Data {
        // Empty input still owes a terminating DEFLATE block. Emitting a bare
        // header and trailer produces an 18-byte file that gzip(1) — and our own
        // decoder — reject as truncated, which is how an empty day would come
        // back as a corrupt one rather than as no samples.
        let deflated = data.isEmpty
            ? Data([0x03, 0x00])
            : try transform(data, operation: COMPRESSION_STREAM_ENCODE,
                            algorithm: COMPRESSION_ZLIB,
                            // Deflate can expand incompressible input; the floor
                            // keeps a tiny payload from sizing its own
                            // destination too small.
                            hint: max(64, data.count))

        var out = Data([0x1F, 0x8B, 0x08, 0x00,        // magic, DEFLATE, no flags
                        0x00, 0x00, 0x00, 0x00,        // mtime 0 — a byte-identical
                                                       // rewrite must stay diffable
                        0x00, 0xFF])                   // no extra flags, unknown OS
        out.append(deflated)
        out.append(littleEndian: crc32(data))
        out.append(littleEndian: UInt32(truncatingIfNeeded: data.count))
        return out
    }

    // MARK: Decompress

    public static func decompress(_ data: Data) throws -> Data {
        guard data.count >= 18, data[data.startIndex] == 0x1F,
              data[data.startIndex + 1] == 0x8B else { throw Failure.notGzip }
        let flags = data[data.startIndex + 3]

        // Header is 10 bytes plus whatever the optional flag fields add. We never
        // write them, but a file re-written by gzip(1) — which is the entire point
        // of using the real container — routinely carries FNAME.
        var cursor = data.startIndex + 10
        func requireByte() throws -> UInt8 {
            guard cursor < data.endIndex else { throw Failure.truncated }
            defer { cursor += 1 }
            return data[cursor]
        }
        if flags & 0x04 != 0 {                                  // FEXTRA
            let lo = try requireByte(), hi = try requireByte()
            cursor += Int(lo) | (Int(hi) << 8)
        }
        if flags & 0x08 != 0 { while try requireByte() != 0 {} } // FNAME
        if flags & 0x10 != 0 { while try requireByte() != 0 {} } // FCOMMENT
        if flags & 0x02 != 0 { cursor += 2 }                     // FHCRC

        let trailerStart = data.endIndex - 8
        guard cursor <= trailerStart else { throw Failure.truncated }

        // ISIZE is the original length mod 2^32, which is exactly the destination
        // size the buffer API wants — no growing loop needed.
        let isize = data.integer(atOffsetFromEnd: 4)
        let deflated = data[cursor..<trailerStart]
        let inflated = try transform(Data(deflated), operation: COMPRESSION_STREAM_DECODE,
                                     algorithm: COMPRESSION_ZLIB,
                                     hint: max(64, Int(isize)))

        guard crc32(inflated) == data.integer(atOffsetFromEnd: 8) else {
            throw Failure.truncated
        }
        return inflated
    }

    // MARK: Stream driver
    //
    // The one-shot `compression_encode_buffer` needs a destination size guessed
    // up front and fails (returns 0) rather than growing, which is unusable for
    // compression. The stream API grows as needed.

    private static func transform(_ data: Data,
                                  operation: compression_stream_operation,
                                  algorithm: compression_algorithm,
                                  hint: Int) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, algorithm) == COMPRESSION_STATUS_OK else {
            throw Failure.compressionFailed
        }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data(capacity: hint)
        var thrown: Error?

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.src_ptr = base
            stream.src_size = data.count

            repeat {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    output.append(buffer, count: bufferSize - stream.dst_size)
                    if status == COMPRESSION_STATUS_END { return }
                default:
                    thrown = Failure.compressionFailed
                    return
                }
            } while true
        }

        if let thrown { throw thrown }
        return output
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }

    /// Read a little-endian `UInt32` sitting `offset` bytes back from the end —
    /// how both gzip trailer fields are addressed.
    func integer(atOffsetFromEnd offset: Int) -> UInt32 {
        let start = endIndex - offset
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(self[start + i]) << (8 * UInt32(i)) }
        return value
    }
}
