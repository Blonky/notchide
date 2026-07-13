import Foundation
import Darwin
import NotchideKit

/// Spawns and supervises the Node HOST sidecar (`sidecar/notchide-claude`,
/// `node src/index.js`), which bridges the Claude Agent SDK to notchide's Unix
/// socket in HOST mode (advertising `.actuate` so voice `.prompt`/`.interrupt`
/// can reach a live Claude session).
///
/// It points the child at the app's socket via `NOTCHIDE_SOCKET_PATH`, tracks its
/// lifecycle, and stops it on teardown. A missing `node` or a missing sidecar is
/// surfaced as a clear `.failed` state — never a crash — so the app runs fine
/// without HOST mode (only voice ACTUATE into a host session is unavailable).
@MainActor
public final class HostSessionLauncher {
    public enum State: Equatable {
        case idle
        case running
        /// Could not start; the reason is human-readable.
        case failed(String)
        case stopped
    }

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    /// Observe lifecycle changes (e.g. to surface a banner). Optional.
    public var onStateChange: ((State) -> Void)?

    private let socketPath: String
    /// Records the spawned sidecar's process-GROUP id so a relaunched hub can
    /// reclaim an orphaned subtree. Shared with the app's launch-time `reclaim()`.
    private let pidFile: PidFile
    private var process: Process?

    /// - Parameters:
    ///   - socketPath: The socket the sidecar should connect to. Defaults to the
    ///     canonical `agent.sock`.
    ///   - pidFile: Where the sidecar's pgid is recorded (same file the app's
    ///     launch-time `reclaim()` inspects). Defaults to `PidFile()`.
    public init(
        socketPath: String = NotchidePaths.socketPath,
        pidFile: PidFile = PidFile()
    ) {
        self.socketPath = socketPath
        self.pidFile = pidFile
    }

    /// Resolves `node` + the sidecar directory and launches the process. Idempotent
    /// while already running.
    public func start() {
        guard process == nil else { return }

        guard let sidecarDir = Self.resolveSidecarDirectory() else {
            state = .failed("sidecar not found (set NOTCHIDE_SIDECAR_DIR to sidecar/notchide-claude)")
            NSLog("notchide: \(stateDescription)")
            return
        }
        let entry = sidecarDir.appendingPathComponent("src/index.js")
        guard FileManager.default.fileExists(atPath: entry.path) else {
            state = .failed("sidecar entry missing at \(entry.path)")
            NSLog("notchide: \(stateDescription)")
            return
        }
        guard let node = Self.resolveNodeExecutable() else {
            state = .failed("`node` not found on PATH (install Node ≥18 to enable HOST mode)")
            NSLog("notchide: \(stateDescription)")
            return
        }

        let process = Process()
        process.executableURL = node
        process.arguments = ["src/index.js"]
        process.currentDirectoryURL = sidecarDir

        var environment = ProcessInfo.processInfo.environment
        environment["NOTCHIDE_SOCKET_PATH"] = socketPath
        // GUI apps launch with a minimal PATH; make sure the child can find its
        // own toolchain (npm, node-gyp, …).
        environment["PATH"] = Self.augmentedPATH(nodeDirectory: node.deletingLastPathComponent().path)
        process.environment = environment

        // Surface the sidecar's own logs into the unified log without blocking.
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        Self.forward(stdout, tag: "sidecar")
        Self.forward(stderr, tag: "sidecar!")

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self, self.process === proc else { return }
                self.process = nil
                if case .stopped = self.state { return }
                self.state = .failed("sidecar exited (status \(proc.terminationStatus))")
                NSLog("notchide: \(self.stateDescription)")
            }
        }

        do {
            try process.run()
            self.process = process
            state = .running
            recordProcessGroup(of: process)
            NSLog("notchide: HOST sidecar started (\(node.path) src/index.js → \(socketPath))")
        } catch {
            state = .failed("failed to launch sidecar: \(error.localizedDescription)")
            NSLog("notchide: \(stateDescription)")
        }
    }

    /// Persists the sidecar's process-GROUP id so a relaunched hub can reclaim the
    /// whole orphaned subtree via `kill(-pgid, …)` (see `PidFile`).
    ///
    /// Foundation spawns the child as its OWN process-group leader (its pgid
    /// equals its pid and is distinct from the app's group), so signalling the
    /// group tears down only the sidecar tree, never the app. Guarded so we never
    /// persist the app's own group id (which `kill(-pgid, …)` would turn on the
    /// app itself): if the child is somehow in our group, we skip the record.
    private func recordProcessGroup(of process: Process) {
        let pid = process.processIdentifier
        let pgid = getpgid(pid)
        guard pgid > 1, pgid != getpgid(0) else {
            NSLog("notchide: sidecar pgid unavailable (pid=\(pid), pgid=\(pgid)); skipping pid file")
            return
        }
        do {
            try pidFile.write(pgid: pgid)
        } catch {
            NSLog("notchide: failed to persist sidecar pgid \(pgid): \(error.localizedDescription)")
        }
    }

    /// Terminates the sidecar if running. Idempotent.
    public func stop() {
        // A graceful stop clears the pid record: the process we started is being
        // torn down here, so there is no orphan for a later launch to reclaim. A
        // CRASH (no `stop()`) deliberately leaves the record behind so the next
        // launch's `reclaim()` reaps the survivor.
        pidFile.clear()
        guard let process else {
            if state == .running { state = .stopped }
            return
        }
        self.process = nil
        state = .stopped
        if process.isRunning {
            process.terminate()
        }
    }

    private var stateDescription: String {
        switch state {
        case .idle: return "HOST sidecar idle"
        case .running: return "HOST sidecar running"
        case .failed(let reason): return "HOST sidecar failed — \(reason)"
        case .stopped: return "HOST sidecar stopped"
        }
    }

    // MARK: - Resolution

    /// Candidate directories for the sidecar, most specific first.
    private static func resolveSidecarDirectory() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["NOTCHIDE_SIDECAR_DIR"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        // Walk up from the executable to find a co-located `sidecar/notchide-claude`
        // (works for `swift run` and a repo-relative bundle layout).
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("sidecar/notchide-claude"))
            dir = dir.deletingLastPathComponent()
        }
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("notchide/sidecar/notchide-claude"))

        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("package.json").path) }
    }

    /// Locates a usable `node` binary. GUI apps do not inherit the login shell's
    /// PATH, so common install locations are probed directly.
    private static func resolveNodeExecutable() -> URL? {
        let fm = FileManager.default
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            candidates += envPath.split(separator: ":").map { "\($0)/node" }
        }
        return candidates.map { URL(fileURLWithPath: $0) }.first { fm.isExecutableFile(atPath: $0.path) }
    }

    private static func augmentedPATH(nodeDirectory: String) -> String {
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        var parts = [nodeDirectory, "/opt/homebrew/bin", "/usr/local/bin"]
        parts += base.split(separator: ":").map(String.init)
        // De-dup while preserving order.
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Streams a pipe's lines into the unified log without ever blocking the app.
    private static func forward(_ pipe: Pipe, tag: String) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where !line.isEmpty {
                NSLog("notchide[\(tag)]: \(line)")
            }
        }
    }
}
