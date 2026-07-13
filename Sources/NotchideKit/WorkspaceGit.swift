import Foundation
import Darwin

/// Errors thrown by `WorkspaceGit`.
public enum WorkspaceGitError: Error, Sendable, Equatable {
    /// The remote string failed validation (not an https/ssh URL, a `file://`
    /// URL, or an existing local path). Rejects transport-helper injection like
    /// `ext::sh -c whoami`, argument injection like `--upload-pack=…`, and shell
    /// metacharacter payloads like `; rm -rf /`.
    case invalidRemote(String)
    /// The `git` process could not be launched.
    case launchFailed(String)
    /// The `git` process exceeded its deadline and was killed.
    case timedOut(after: TimeInterval)
    /// `git` exited non-zero; `message` is its (trimmed) stderr.
    case gitFailed(status: Int32, message: String)
}

/// Hardened, dependency-free wrapper over `/usr/bin/git`.
///
/// SECURITY: every invocation runs git with an ARGUMENTS ARRAY (argv) — never a
/// shell string / `sh -c` — so no user-supplied value can be reinterpreted by a
/// shell. The environment is scrubbed exactly like `GitDiffProvider` (system /
/// global / repo config neutralized, no terminal prompt, no credential helper),
/// every network invocation additionally passes `-c protocol.ext.allow=never`
/// to disable the `ext::` transport helper, and `clone` validates its remote and
/// separates it from options with `--`. Each call is bounded by a hard timeout
/// and the child is killed if it overruns, so a hung git can never hang a caller.
public struct WorkspaceGit: Sendable {

    /// The git executable. A fixed absolute path so `PATH` cannot redirect it.
    private static let executable = "/usr/bin/git"

    /// Hard per-invocation deadline. A stuck clone (auth prompt, dead remote) is
    /// killed rather than hanging the caller forever.
    public static let timeout: TimeInterval = 60

    // MARK: - Public operations

    /// Clones `remote` into `destination`, optionally tracking `branch`.
    ///
    /// argv: `["clone","--depth","1"] + (branch → ["--branch",b]) + ["--", remote, destination.path]`,
    /// prefixed with `-c protocol.ext.allow=never`. `remote` is validated first
    /// (see `validate(remote:)`); the `--` guarantees it is treated as a URL, not
    /// an option, even if validation were ever bypassed.
    ///
    /// - Throws: `WorkspaceGitError.invalidRemote` for a rejected remote,
    ///   `.timedOut` if the clone overruns `timeout`, or `.gitFailed` on a
    ///   non-zero exit.
    public static func clone(remote: String, into destination: URL, branch: String?) throws {
        try validate(remote: remote)

        var argv = ["-c", "protocol.ext.allow=never", "clone", "--depth", "1"]
        if let branch, !branch.isEmpty {
            argv += ["--branch", branch]
        }
        argv += ["--", remote, destination.path]

        _ = try run(argv)
    }

    /// The porcelain working-tree status of the repo at `root`
    /// (`git -C <root> status --porcelain`).
    public static func status(root: URL) throws -> String {
        try run(["-c", "protocol.ext.allow=never", "-C", root.path, "status", "--porcelain"])
    }

    /// The current branch name of the repo at `root`
    /// (`git -C <root> rev-parse --abbrev-ref HEAD`), whitespace-trimmed.
    public static func currentBranch(root: URL) throws -> String {
        try run(["-c", "protocol.ext.allow=never", "-C", root.path, "rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Remote validation

    /// Validates a clone remote, throwing `invalidRemote` for anything unsafe.
    ///
    /// Accepts only: an `https://` URL, an ssh remote (`ssh://…` or scp-like
    /// `git@host:path`), a `file://` URL, or an existing local path. Everything
    /// else — an argument that looks like an option (`-…`), a transport-helper
    /// URL (`ext::…`), or a shell-metacharacter payload (`; rm -rf /`) — is
    /// rejected before git ever runs.
    static func validate(remote: String) throws {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceGitError.invalidRemote(remote) }
        // Never let a remote be mistaken for a git option.
        guard !trimmed.hasPrefix("-") else { throw WorkspaceGitError.invalidRemote(remote) }

        if trimmed.hasPrefix("https://") { return }
        if trimmed.hasPrefix("ssh://") { return }
        // scp-like ssh remote: user@host:path (require the ':' separator).
        if trimmed.hasPrefix("git@"), trimmed.contains(":") { return }
        if trimmed.hasPrefix("file://") { return }
        // An existing local path (absolute or relative) is a valid clone source.
        if FileManager.default.fileExists(atPath: trimmed) { return }

        throw WorkspaceGitError.invalidRemote(remote)
    }

    // MARK: - Process runner

    /// Runs `git` with the given argv under the hardened environment, bounded by
    /// `timeout`, and returns stdout.
    ///
    /// Both pipes are drained concurrently so a large stdout/stderr can never
    /// deadlock the child against a full pipe buffer, and a watchdog terminates
    /// (then hard-kills) the child if it overruns the deadline.
    private static func run(_ arguments: [String], timeout: TimeInterval = WorkspaceGit.timeout) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = hardenedEnvironment()
        // A hung git must never wait on our stdin.
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw WorkspaceGitError.launchFailed(String(describing: error))
        }

        // Drain both pipes on a background queue.
        let readGroup = DispatchGroup()
        let outData = DataBox()
        let errData = DataBox()
        let outHandle = UncheckedBox(outPipe.fileHandleForReading)
        let errHandle = UncheckedBox(errPipe.fileHandleForReading)
        let queue = DispatchQueue(label: "sh.notchide.WorkspaceGit", attributes: .concurrent)
        queue.async(group: readGroup) { outData.data = outHandle.value.readDataToEndOfFile() }
        queue.async(group: readGroup) { errData.data = errHandle.value.readDataToEndOfFile() }

        // Watchdog: SIGTERM at the deadline, SIGKILL after a short grace period.
        let timedOut = FlagBox()
        let processBox = UncheckedBox(process)
        let watchdog = DispatchWorkItem {
            guard processBox.value.isRunning else { return }
            timedOut.set()
            processBox.value.terminate() // SIGTERM
            Thread.sleep(forTimeInterval: 2)
            if processBox.value.isRunning {
                kill(processBox.value.processIdentifier, SIGKILL)
            }
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()  // no-op if it already fired
        readGroup.wait()   // both pipes fully drained now the child has exited

        if timedOut.value {
            throw WorkspaceGitError.timedOut(after: timeout)
        }

        let status = process.terminationStatus
        guard status == 0 else {
            let message = String(decoding: errData.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkspaceGitError.gitFailed(status: status, message: message)
        }
        return String(decoding: outData.data, as: UTF8.self)
    }

    /// The current environment with git config sources neutralized and all
    /// interactive/credential paths disabled.
    ///
    /// Mirrors `GitDiffProvider.hardenedGitEnvironment()` (system/global config →
    /// `/dev/null`, no optional locks, no terminal prompt) and adds the
    /// clone-specific hardening required for an untrusted remote: no credential
    /// helper (`GIT_ASKPASS=/usr/bin/true`) and no system config
    /// (`GIT_CONFIG_NOSYSTEM=1`).
    private static func hardenedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/true"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        return env
    }
}

// MARK: - Concurrency-safe boxes

/// Collects a pipe's bytes across the read queue. Access is serialized by the
/// enclosing `DispatchGroup`'s happens-before (`wait()` after both reads), so the
/// unchecked `Sendable` is sound.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// A lock-guarded boolean flag shared between the watchdog and the caller.
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
