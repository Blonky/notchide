import Foundation
import Darwin

/// A tiny POSIX helper that persists the HOST sidecar's process-GROUP id so a
/// relaunched hub can *reap an orphan* instead of spawning a duplicate.
///
/// The value stored is a process-group id (pgid), not a bare pid: the sidecar
/// spawns a `claude` child (which in turn spawns a shell/tool tree). Signalling
/// the whole *group* with `kill(-pgid, …)` tears that entire orphaned tree down
/// in one call. The file lives under `NotchidePaths`' `0700` support dir and is
/// itself clamped to owner-only `0600` — a stale pid record must never be
/// world-readable.
///
/// `reclaim()` uses direct `kill(2)` only — never a shell — so it is
/// dependency-free and safe to call at the very start of launch, before any
/// socket or SDK is wired up. A stored-but-dead or absent pgid is a safe no-op.
public struct PidFile: Sendable {
    /// The file backing this pid record.
    public let fileURL: URL

    /// Grace period between the polite `SIGTERM` and the forceful `SIGKILL`.
    /// Injectable so tests can drive `reclaim()` without a real wall-clock wait.
    private let graceSeconds: TimeInterval

    /// Creates a pid file at `fileURL` (default
    /// `~/Library/Application Support/notchide/sidecar.pid`).
    ///
    /// - Parameters:
    ///   - fileURL: The backing file. Injectable so tests can point at a temp dir.
    ///   - graceSeconds: Delay between `SIGTERM` and the follow-up `SIGKILL` in
    ///     `reclaim()`. Defaults to `0.5s`.
    public init(
        fileURL: URL = PidFile.defaultFileURL,
        graceSeconds: TimeInterval = 0.5
    ) {
        self.fileURL = fileURL
        self.graceSeconds = graceSeconds
    }

    /// The default backing file:
    /// `~/Library/Application Support/notchide/sidecar.pid`.
    public static var defaultFileURL: URL {
        NotchidePaths.supportDirectory.appendingPathComponent("sidecar.pid", isDirectory: false)
    }

    // MARK: - Persist

    /// Writes `pgid` to the file atomically, then restricts it to owner-only `0600`.
    ///
    /// The parent directory is created `0700` if absent. The pgid is stored as
    /// its decimal text with a trailing newline so the file is greppable.
    public func write(pgid: Int32) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let data = Data("\(pgid)\n".utf8)
        try data.write(to: fileURL, options: [.atomic])
        // The atomic write's temp file is created with the process umask, so
        // clamp the final file to owner-only after the rename.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    // MARK: - Read

    /// Reads the stored pgid, or `nil` if the file is absent, empty, or not a
    /// valid pgid. Never throws: a garbage or corrupt file is treated as "no
    /// record" so a bad pid file can never wedge launch.
    ///
    /// A stored value `<= 1` is rejected as garbage — `0`/negative/`1` are unsafe
    /// to feed to `kill(-pgid, …)` (they would target the caller's own group or
    /// `launchd`), so they must never round-trip out of `read()`.
    public func read() -> Int32? {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pgid = Int32(trimmed), pgid > 1 else { return nil }
        return pgid
    }

    // MARK: - Reclaim

    /// Terminates a previously-recorded, still-alive sidecar process group, then
    /// clears the file. A stored-but-dead or absent pgid is a safe no-op.
    ///
    /// If a pgid is stored AND alive (`kill(pgid, 0) == 0`), signals the whole
    /// group via `kill(-pgid, …)`: first `SIGTERM`, then after a short grace
    /// period `SIGKILL` if it is still alive. Uses direct `kill(2)` — no shell.
    public func reclaim() {
        guard let pgid = read() else { return }
        // Liveness probe: signal 0 tests existence/permission without delivering
        // a signal. A dead (or bogus) pgid → nothing to reclaim; just drop the
        // stale record so a later launch does not re-inspect it.
        guard PidFile.isAlive(pgid) else {
            clear()
            return
        }
        // Polite shutdown of the entire orphaned group.
        _ = kill(-pgid, SIGTERM)
        // Give it a moment to unwind, then force-kill any survivors.
        if graceSeconds > 0 {
            Thread.sleep(forTimeInterval: graceSeconds)
        }
        if PidFile.isAlive(pgid) {
            _ = kill(-pgid, SIGKILL)
        }
        clear()
    }

    /// Whether a process with pid `pgid` currently exists, via `kill(pgid, 0)`.
    /// Signal 0 delivers nothing; it only reports whether the target is present.
    private static func isAlive(_ pgid: Int32) -> Bool {
        kill(pgid, 0) == 0
    }

    // MARK: - Clear

    /// Removes the pid file if present. A missing file is not an error.
    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
