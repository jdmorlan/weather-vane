//
//  RainLogStore.swift  (Weather)
//
//  The rain gauge log, kept on this device and carried to the others.
//
//  On disk beside the archive, so the Mac's totals can read it, and mirrored
//  into iCloud key-value storage — the same store `SettingsSync` uses, which
//  every one of these devices can reach — so a reading typed on the phone in
//  the yard is in the Mac's October total a moment later. The log is a handful
//  of small records; KVS's per-key limit is a megabyte.
//
//  Merged, not overwritten: two devices each keep every reading either has
//  seen, the newer edit of each winning, deletions travelling as tombstones
//  (see `RainLog.merged`).
//

import Foundation
import Combine
import WeatherKit

@MainActor
final class RainLogStore: ObservableObject {
    @Published private(set) var log = RainLog()

    private let url: URL
    private let kvs = NSUbiquitousKeyValueStore.default
    private static let key = "rainLog.v1"
    private var observer: NSObjectProtocol?

    init(root: URL? = nil) {
        let weather = root ?? AppGroup.dataDirectory.appendingPathComponent("Weather", isDirectory: true)
        url = weather.appendingPathComponent("rain-log.json")
        if let data = try? Data(contentsOf: url), let local = try? JSONDecoder.log.decode(RainLog.self, from: data) {
            log = local
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.adoptRemote() }
            }
        kvs.synchronize()
        adoptRemote()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Day → inches from the gauge, for laying over the station's record.
    var dailyAmounts: [String: Double] { log.dailyAmounts }

    /// A stable key for "the gauge changed", for `.task(id:)`.
    var revision: String {
        log.dailyAmounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    func save(_ reading: GaugeReading) {
        log.upsert(reading)
        persist()
    }

    func delete(_ id: UUID) {
        log.delete(id)
        persist()
    }

    private func adoptRemote() {
        guard let data = kvs.data(forKey: Self.key),
              let remote = try? JSONDecoder.log.decode(RainLog.self, from: data) else { return }
        let merged = log.merged(with: remote)
        guard merged != log else { return }
        log = merged
        writeFile()
        // Hand back anything this device had that the cloud didn't.
        if merged != remote { writeCloud() }
    }

    private func persist() {
        writeFile()
        writeCloud()
    }

    private func writeFile() {
        guard let data = try? JSONEncoder.log.encode(log) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func writeCloud() {
        guard let data = try? JSONEncoder.log.encode(log) else { return }
        kvs.set(data, forKey: Self.key)
        kvs.synchronize()
    }
}

private extension JSONEncoder {
    static var log: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

private extension JSONDecoder {
    static var log: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
