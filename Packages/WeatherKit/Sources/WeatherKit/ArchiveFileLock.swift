//
//  ArchiveFileLock.swift  (WeatherKit)
//
//  One writer at a time ACROSS PROCESSES, for an archive two apps share.
//
//  WHY THERE ARE TWO PROCESSES. On a Mac the installed Vane and Vane Dev (the
//  Debug build, a separate app — see project.yml) both reach the archive through
//  the same app group, so both fetch from the station and both merge into the
//  same day files. Every archive already had an `NSLock`, but that only orders
//  threads inside one app.
//
//  WHAT IT PREVENTS. Not corruption: every write is `.atomic`, a whole new file
//  renamed into place, so a reader never sees half a file. What can happen is a
//  LOST MERGE. Both apps read 2026-09-30, each adds the readings it just
//  fetched, each writes its version — and the second rename throws away
//  whatever only the first one had. A read-merge-write has to be one step, and
//  `flock` on a file beside the data is what makes it one between processes.
//
//  WRITERS ONLY. Readers still just read: the atomic rename already guarantees
//  them a whole file, and making every chart wait on the other app's backfill
//  would buy nothing.
//
//  Advisory, and released by the kernel when the descriptor closes — including
//  when the app crashes or is stopped in the debugger mid-write, so a killed
//  Vane Dev cannot leave the real Vane locked out.
//

import Foundation

struct ArchiveFileLock {
    let url: URL

    /// The lock for the archive rooted at `root`. Lives inside it — every
    /// archive's directory listing already ignores names it does not recognise.
    init(root: URL) {
        url = root.appendingPathComponent(".write.lock")
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        // A lock that cannot be taken is not a reason to lose the readings in
        // hand. Write unguarded — the risk is the rare lost merge above, which the
        // next fetch repairs — rather than throw and keep nothing at all.
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { return try body() }
        }
        return try body()
    }
}
