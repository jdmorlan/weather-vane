//
//  ArchiveRelocation.swift  (WeatherKit)
//
//  Moving the archive from one root to another, without ever risking it.
//
//  WHY THIS IS IN THE KIT AND NOT NEXT TO ITS CALLER. It lived in `AppGroup` as
//  a private function taking one URL, which made it unreachable from a test —
//  and it was wrong for months without anyone finding out. The failure was
//  silent by construction: the app did not error, it decided it had no history
//  and began a full backfill, and the only visible symptom was an empty-looking
//  archive and a burst of throttled requests. Filesystem logic that can lose
//  four years of readings is exactly the kind of thing this package exists to
//  hold — "verifiable on its own", per `Package.swift`.
//

import Foundation

public enum ArchiveRelocation {
    /// The subdirectories whose contents mean "there is an archive here".
    ///
    /// `forecasts` and `upper-air` are deliberately not on this list: both are
    /// caches that refill themselves, so either one alone is not evidence that
    /// the irreplaceable part came across.
    static let evidence = ["daily", "samples"]

    /// Does this directory HOLD the archive, as opposed to merely existing?
    ///
    /// The distinction is the entire bug. A `Weather/` directory existing proves
    /// nothing: the archive stores are handed roots inside it and create their
    /// own directories on first write, so the folder appears whether or not a
    /// single day was ever written into it.
    public static func holdsArchive(_ root: URL) -> Bool {
        let fm = FileManager.default
        return evidence.contains { name in
            let sub = root.appendingPathComponent(name, isDirectory: true)
            let items = (try? fm.contentsOfDirectory(atPath: sub.path)) ?? []
            return !items.isEmpty
        }
    }

    /// Copy anything `destination` is missing out of `source`.
    ///
    /// THE BUG THIS REPLACES, because it is worth being able to find again. The
    /// old version guarded on `!fileExists(destination)` and its `catch`
    /// reasoned: "leave the container without a `Weather/` so the next launch
    /// tries again." That is not what happened. The archive stores are built on
    /// the same launch with roots inside `Weather/`, so a migration that failed
    /// once left an EMPTY `Weather/daily` behind — and the existence guard then
    /// returned early on every launch forever. One bad copy and the app was
    /// permanently pointed at an empty archive while 42MB sat untouched in the
    /// old location.
    ///
    /// So the question asked is "is the archive THERE", not "does the folder
    /// exist", and the copy is per item so a destination holding part of the
    /// subtree can still receive the rest.
    ///
    /// NON-DESTRUCTIVE AND STAGED. Each item is copied to `<name>.incoming` and
    /// then RENAMED into place, which within a volume is atomic — an interrupted
    /// copy can never leave a partial `daily/` that the next launch mistakes for
    /// the real thing. The source is never removed: deleting the old copy is a
    /// decision for a person who can see that the new one works.
    ///
    /// Idempotent, so it is safe on every launch. Once the destination holds the
    /// archive every item is skipped and this costs one directory listing.
    @discardableResult
    public static func migrate(from source: URL, to destination: URL) -> [String] {
        let fm = FileManager.default
        guard holdsArchive(source) else { return [] }
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var copied: [String] = []
        for item in (try? fm.contentsOfDirectory(atPath: source.path)) ?? [] {
            // Never carry a previous run's staging across as though it were data.
            guard !item.hasSuffix(".incoming") else { continue }

            let from = source.appendingPathComponent(item)
            let to = destination.appendingPathComponent(item)

            // An EMPTY directory here is the stores' handiwork, not data, and it
            // must not stand in for the thing it is named after. A file, or a
            // directory with anything in it, is left alone: the destination is
            // the live archive and always wins.
            if let existing = try? fm.contentsOfDirectory(atPath: to.path), existing.isEmpty {
                try? fm.removeItem(at: to)
            }
            guard !fm.fileExists(atPath: to.path) else { continue }

            let staging = destination.appendingPathComponent("\(item).incoming")
            try? fm.removeItem(at: staging)
            do {
                try fm.copyItem(at: from, to: staging)
                try fm.moveItem(at: staging, to: to)
                copied.append(item)
            } catch {
                try? fm.removeItem(at: staging)
            }
        }
        return copied
    }
}
