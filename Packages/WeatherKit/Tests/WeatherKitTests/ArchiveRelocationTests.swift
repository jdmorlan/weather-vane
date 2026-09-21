import Foundation
import Testing
@testable import WeatherKit

/// The case that cost a real archive: a destination that EXISTS but is empty.
@Suite("Archive relocation")
struct ArchiveRelocationTests {
    /// A scratch pair of roots, plus helpers to build and inspect them.
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relocation-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ root: URL, _ path: String, _ contents: String = "x") {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exists(_ root: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    @Test("An empty directory is not an archive")
    func emptyDirectoryIsNotEvidence() {
        let root = scratch()
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("daily"), withIntermediateDirectories: true)
        #expect(ArchiveRelocation.holdsArchive(root) == false)

        write(root, "daily/2024.json")
        #expect(ArchiveRelocation.holdsArchive(root) == true)
    }

    @Test("A destination the stores already created still receives the archive")
    func latchedEmptyDestinationRecovers() {
        let source = scratch(), destination = scratch()
        write(source, "daily/2024.json", "a year")
        write(source, "samples/2024/2024-01-01.ndjson.gz", "minutes")
        write(source, "wind-climate.json", "{}")

        // Exactly the state the old guard latched on: the archive stores ran
        // once against an empty container and left their directories behind.
        try? FileManager.default.createDirectory(
            at: destination.appendingPathComponent("daily"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: destination.appendingPathComponent("samples"), withIntermediateDirectories: true)

        ArchiveRelocation.migrate(from: source, to: destination)

        #expect(exists(destination, "daily/2024.json"))
        #expect(exists(destination, "samples/2024/2024-01-01.ndjson.gz"))
        #expect(exists(destination, "wind-climate.json"))
        #expect(ArchiveRelocation.holdsArchive(destination))
    }

    @Test("Real data at the destination is never overwritten")
    func destinationWins() {
        let source = scratch(), destination = scratch()
        write(source, "daily/2024.json", "old")
        write(destination, "daily/2024.json", "live")

        ArchiveRelocation.migrate(from: source, to: destination)

        let kept = try? String(contentsOf: destination.appendingPathComponent("daily/2024.json"),
                               encoding: .utf8)
        #expect(kept == "live")
    }

    @Test("The source is never touched")
    func nonDestructive() {
        let source = scratch(), destination = scratch()
        write(source, "daily/2024.json")
        write(source, "samples/2024/day.ndjson.gz")

        ArchiveRelocation.migrate(from: source, to: destination)

        #expect(exists(source, "daily/2024.json"))
        #expect(exists(source, "samples/2024/day.ndjson.gz"))
    }

    @Test("Running it again copies nothing and breaks nothing")
    func idempotent() {
        let source = scratch(), destination = scratch()
        write(source, "daily/2024.json")

        let first = ArchiveRelocation.migrate(from: source, to: destination)
        let second = ArchiveRelocation.migrate(from: source, to: destination)

        #expect(first == ["daily"])
        #expect(second.isEmpty)
        #expect(exists(destination, "daily/2024.json"))
    }

    @Test("A source with no archive is left alone")
    func emptySourcePublishesNothing() {
        let source = scratch(), destination = scratch()
        write(source, "forecasts/2024-01-01.ndjson.gz")   // a cache, not evidence

        #expect(ArchiveRelocation.migrate(from: source, to: destination).isEmpty)
        #expect(exists(destination, "forecasts/2024-01-01.ndjson.gz") == false)
    }

    @Test("A previous run's staging is never mistaken for data")
    func stagingIsIgnored() {
        let source = scratch(), destination = scratch()
        write(source, "daily/2024.json")
        write(source, "daily.incoming/junk.json")

        ArchiveRelocation.migrate(from: source, to: destination)

        #expect(exists(destination, "daily/2024.json"))
        #expect(exists(destination, "daily.incoming") == false)
    }
}
