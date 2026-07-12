import Foundation
import Darwin
import NotchideKit

// notchide-hook
// ─────────────
// A single binary with two jobs:
//
//   1. The HOOK HANDLER (`handle`, or a bare invocation): Claude Code runs this
//      as a hook command, piping the event JSON on stdin. For a PreToolUse
//      permission gate it asks the notchide app (over a Unix socket) for a
//      decision and prints the decision JSON on stdout; other events are
//      fire-and-forget status pings.
//
//   2. The INSTALLER (`install` / `uninstall` / `doctor`): merges notchide's
//      hook handlers into (or removes them from) `~/.claude/settings.json`, and
//      reports diagnostics. These are ordinary CLIs invoked by a human, NOT part
//      of an agent's execution path, so they may exit non-zero on real errors.
//
// FAIL-OPEN CONTRACT (the critical invariant, applies to the HANDLER only)
// ────────────────────────────────────────────────────────────────────────
// On ANY failure — socket missing, app not running, connect error, timeout,
// malformed decision, unparseable input — the handler prints NOTHING and exits
// 0. Emitting no decision makes Claude Code fall back to its normal permission
// prompt (equivalent to "defer"). We NEVER exit non-zero in a way that would
// block or error the agent, and we NEVER hang without a hard timeout. Being
// unable to reach notchide must be indistinguishable, to the agent, from
// notchide not being installed at all.

// MARK: - Entry point / dispatch

let rawArgs = Array(CommandLine.arguments.dropFirst())

// Backward-compatible fast path: in-process IPC round-trip for debugging.
if rawArgs.contains("--selftest") {
    selfTest()
    exit(0)
}

switch rawArgs.first {
case "install":
    runInstall(parseOptions(Array(rawArgs.dropFirst())))
case "uninstall":
    runUninstall(parseOptions(Array(rawArgs.dropFirst())))
case "doctor":
    runDoctor(parseOptions(Array(rawArgs.dropFirst())))
case "--help", "-h", "help":
    printUsage()
    exit(0)
case "handle":
    // Optional positional EventName after `handle` (falls back to stdin).
    let explicit = rawArgs.dropFirst().first(where: { !$0.hasPrefix("-") })
    runHandle(explicitEventName: explicit)
default:
    // Bare invocation (no subcommand), or the legacy `--event <Name>` form:
    // behave as the hook handler for backward compatibility.
    runHandle(explicitEventName: nil)
}

// MARK: - Hook handler

/// The hook handler. Reads the event JSON on stdin, forwards it over the socket,
/// and — for a blocking PreToolUse gate — prints the decision. Fail-open on any
/// error (see the contract above). Never returns.
func runHandle(explicitEventName: String?) -> Never {
    // ── Read the hook event JSON from stdin ──────────────────────────────────
    let stdinData = FileHandle.standardInput.readDataToEndOfFile()

    // Decode robustly. If we cannot parse the input at all, fail open.
    guard let event = try? JSONDecoder().decode(HookEvent.self, from: stdinData) else {
        failOpen()
    }

    // Determine the event name. Priority: the `handle <Name>` positional arg, then
    // a legacy `--event <Name>` override, then the JSON's own `hook_event_name`.
    let overridden = explicitEventName.flatMap(HookEventName.init(rawValue:))
        ?? eventNameOverride(from: CommandLine.arguments)
    let effectiveEventName = overridden ?? event.hookEventName

    let socketPath = NotchidePaths.socketPath

    // Only PreToolUse is a blocking permission gate; everything else is
    // best-effort fire-and-forget.
    let isBlocking = (effectiveEventName == .preToolUse)
    let envelope = HookEnvelope(event: event, wantsDecision: isBlocking)

    if isBlocking {
        // A permission prompt legitimately waits for a human. Default 10 minutes;
        // overridable via NOTCHIDE_HOOK_TIMEOUT_MS.
        let timeoutMs = ProcessInfo.processInfo.environment["NOTCHIDE_HOOK_TIMEOUT_MS"]
            .flatMap(Double.init) ?? 600_000
        let timeout = timeoutMs / 1000.0

        // Any throw here (connect/write failure) → fail open. A nil decision
        // (timeout / malformed / app declined to decide) → fail open.
        let decision = (try? UnixSocketClient.send(
            envelope,
            to: socketPath,
            awaitDecision: true,
            timeout: timeout
        )) ?? nil

        guard let decision else {
            failOpen()
        }

        // Map the app's decision onto the Claude Code PreToolUse decision output.
        // (`redirect` is reserved for app-side handling and is not part of the
        // Claude Code decision schema, so it is not emitted here.)
        let hookDecision = HookDecision(permission: decision.permission, reason: decision.reason)
        if let json = try? hookDecision.jsonString() {
            print(json)
        }
        exit(0)
    } else {
        // Fire-and-forget: send best-effort, never wait, never fail the agent.
        // A short connect timeout keeps us from lingering if the app is wedged.
        _ = try? UnixSocketClient.send(
            envelope,
            to: socketPath,
            awaitDecision: false,
            timeout: 2.0
        )
        exit(0)
    }
}

/// Exit cleanly (fail-open): print nothing and exit 0.
func failOpen() -> Never {
    exit(0)
}

/// Parses an optional `--event <Name>` override from argv (legacy handler form).
func eventNameOverride(from arguments: [String]) -> HookEventName? {
    guard let index = arguments.firstIndex(of: "--event"),
          index + 1 < arguments.count else {
        return nil
    }
    return HookEventName(rawValue: arguments[index + 1])
}

extension HookDecision {
    init(permission: PermissionDecision, reason: String?) {
        self.init(permissionDecision: permission, reason: reason)
    }
}

// MARK: - CLI option parsing

/// Flags shared by `install` / `uninstall` (and, harmlessly, `doctor`).
struct CLIOptions {
    var yes = false
    var dryRun = false
    var settingsPath: String?
}

func parseOptions(_ args: [String]) -> CLIOptions {
    var opts = CLIOptions()
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--yes", "-y":
            opts.yes = true
        case "--dry-run":
            opts.dryRun = true
        case "--settings":
            if i + 1 < args.count {
                opts.settingsPath = args[i + 1]
                i += 1
            }
        default:
            if arg.hasPrefix("--settings=") {
                opts.settingsPath = String(arg.dropFirst("--settings=".count))
            }
        }
        i += 1
    }
    return opts
}

// MARK: - install

func runInstall(_ opts: CLIOptions) -> Never {
    let binaryPath = resolveBinaryPath()
    let settingsPath = opts.settingsPath ?? defaultSettingsPath()

    let existing: [String: Any]
    switch readSettings(at: settingsPath) {
    case .ok(let dict):
        existing = dict
    case .missing:
        existing = [:]
    case .invalid(let why):
        errPrintln("error: \(settingsPath) is not valid JSON (\(why)); aborting without changes.")
        exit(1)
    }

    let merged = HookInstaller.install(into: existing, binaryPath: binaryPath)

    print("notchide-hook install")
    print("  binary:   \(binaryPath)")
    print("  settings: \(settingsPath)")
    print("  wiring \(HookInstaller.managedEvents.count) events:")
    for event in HookInstaller.managedEvents {
        print("    \(event) -> \(HookInstaller.command(for: event, binaryPath: binaryPath))")
    }

    if opts.dryRun {
        print("")
        print("--dry-run: resulting settings.json (not written):")
        print("")
        print(prettyJSON(merged))
        exit(0)
    }

    if !opts.yes {
        guard confirm("\nWrite these changes to \(settingsPath)? [y/N] ") else {
            print("aborted; no changes written.")
            exit(0)
        }
    }

    do {
        try ensureParentDirectory(of: settingsPath)
        let backup = try backUpIfPresent(settingsPath)
        try writeJSON(merged, to: settingsPath)
        if let backup {
            print("backed up previous settings to \(backup)")
        }
        print("installed notchide hooks into \(settingsPath)")
    } catch {
        errPrintln("error: failed to write \(settingsPath): \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

// MARK: - uninstall

func runUninstall(_ opts: CLIOptions) -> Never {
    let settingsPath = opts.settingsPath ?? defaultSettingsPath()

    let existing: [String: Any]
    switch readSettings(at: settingsPath) {
    case .ok(let dict):
        existing = dict
    case .missing:
        print("no settings file at \(settingsPath); nothing to remove.")
        exit(0)
    case .invalid(let why):
        errPrintln("error: \(settingsPath) is not valid JSON (\(why)); aborting without changes.")
        exit(1)
    }

    let wiredBefore = HookInstaller.wiredEvents(in: existing)
    if wiredBefore.isEmpty {
        print("notchide hooks are not present in \(settingsPath); nothing to remove.")
        exit(0)
    }

    let cleaned = HookInstaller.uninstall(from: existing)
    let removedEvents = HookInstaller.managedEvents.filter { wiredBefore.contains($0) }

    print("notchide-hook uninstall")
    print("  settings: \(settingsPath)")
    print("  removing notchide from: \(removedEvents.joined(separator: ", "))")

    if opts.dryRun {
        print("")
        print("--dry-run: resulting settings.json (not written):")
        print("")
        print(prettyJSON(cleaned))
        exit(0)
    }

    if !opts.yes {
        guard confirm("\nWrite these changes to \(settingsPath)? [y/N] ") else {
            print("aborted; no changes written.")
            exit(0)
        }
    }

    do {
        let backup = try backUpIfPresent(settingsPath)
        try writeJSON(cleaned, to: settingsPath)
        if let backup {
            print("backed up previous settings to \(backup)")
        }
        print("removed notchide hooks from \(settingsPath)")
    } catch {
        errPrintln("error: failed to write \(settingsPath): \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

// MARK: - doctor

func runDoctor(_ opts: CLIOptions) -> Never {
    let binaryPath = resolveBinaryPath()
    let socketPath = NotchidePaths.socketPath
    let socketExists = FileManager.default.fileExists(atPath: socketPath)
    let settingsPath = opts.settingsPath ?? defaultSettingsPath()

    print("notchide-hook doctor")
    print("  binary:   \(binaryPath)")
    print("  socket:   \(socketPath)")
    print("            \(socketExists ? "present" : "absent")")
    if !socketExists {
        print("            hint: the notchide app owns this socket and does not appear to be")
        print("            running. Hooks will fail open — you get Claude Code's normal prompt.")
    }
    print("  settings: \(settingsPath)")

    switch readSettings(at: settingsPath) {
    case .ok(let dict):
        let wired = HookInstaller.wiredEvents(in: dict)
        for event in HookInstaller.managedEvents {
            print("    \(event): \(wired.contains(event) ? "wired" : "not wired")")
        }
        if wired.isEmpty {
            print("  hint: no notchide hooks found; run `notchide-hook install`.")
        }
    case .missing:
        print("    (no settings file; run `notchide-hook install`)")
    case .invalid(let why):
        print("    (settings.json is not valid JSON: \(why))")
    }
    exit(0)
}

// MARK: - Settings file I/O (install/uninstall/doctor only)

enum SettingsReadResult {
    case ok([String: Any])
    case missing
    case invalid(String)
}

func readSettings(at path: String) -> SettingsReadResult {
    guard FileManager.default.fileExists(atPath: path) else { return .missing }
    guard let data = FileManager.default.contents(atPath: path) else {
        return .invalid("could not read file")
    }
    if data.isEmpty { return .ok([:]) }
    do {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            return .invalid("top-level JSON is not an object")
        }
        return .ok(dict)
    } catch {
        return .invalid(error.localizedDescription)
    }
}

/// Serializes a settings dictionary as pretty-printed, key-sorted JSON.
func prettyJSON(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    ), let string = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return string
}

/// Writes a settings dictionary atomically as pretty-printed, key-sorted JSON.
func writeJSON(_ object: [String: Any], to path: String) throws {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
}

func ensureParentDirectory(of path: String) throws {
    let dir = (path as NSString).deletingLastPathComponent
    guard !dir.isEmpty else { return }
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
}

/// Copies an existing settings file to `settings.json.bak.<unix-timestamp>`.
/// Returns the backup path, or `nil` if there was no file to back up.
func backUpIfPresent(_ path: String) throws -> String? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let backup = "\(path).bak.\(Int(Date().timeIntervalSince1970))"
    if FileManager.default.fileExists(atPath: backup) {
        try? FileManager.default.removeItem(atPath: backup)
    }
    try FileManager.default.copyItem(atPath: path, toPath: backup)
    return backup
}

// MARK: - Path resolution

/// The absolute path of the currently running `notchide-hook` binary, with
/// symlinks resolved. Prefers the loader-provided executable path; falls back to
/// resolving argv0.
func resolveBinaryPath() -> String {
    if let path = Bundle.main.executablePath {
        return canonicalizePath(path)
    }
    let argv0 = CommandLine.arguments.first ?? "notchide-hook"
    return canonicalizePath(argv0)
}

/// Resolves a path to an absolute, symlink-free form via `realpath`, falling
/// back to making it absolute against the current directory.
func canonicalizePath(_ path: String) -> String {
    if let resolved = realpath(path, nil) {
        defer { free(resolved) }
        return String(cString: resolved)
    }
    if path.hasPrefix("/") { return path }
    let cwd = FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: cwd).appendingPathComponent(path).standardizedFileURL.path
}

/// `~/.claude/settings.json`
func defaultSettingsPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("settings.json")
        .path
}

// MARK: - Console helpers

func errPrintln(_ string: String) {
    FileHandle.standardError.write(Data((string + "\n").utf8))
}

/// Prompts on stderr and reads a yes/no answer from stdin. Any non-affirmative
/// answer (including EOF) is treated as "no".
func confirm(_ prompt: String) -> Bool {
    FileHandle.standardError.write(Data(prompt.utf8))
    guard let line = readLine(strippingNewline: true) else { return false }
    let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
    return answer == "y" || answer == "yes"
}

// MARK: - Usage

func printUsage() {
    print("""
    notchide-hook — Claude Code hook sidecar for notchide

    USAGE:
      notchide-hook <command> [options]

    COMMANDS:
      handle [EventName]   Hook handler (what settings.json invokes). Reads the
                           event JSON on stdin; on PreToolUse it asks the notchide
                           app for a decision (fail-open), other events are
                           fire-and-forget. EventName is optional and falls back
                           to the payload's hook_event_name. A bare invocation
                           (no command) behaves the same way.
      install              Merge notchide's hooks into ~/.claude/settings.json.
      uninstall            Remove only notchide's hooks from settings.json.
      doctor               Print diagnostics (binary path, socket, wired events).
      help, --help, -h     Show this help.

    OPTIONS (install / uninstall):
      --yes, -y            Skip the interactive confirmation.
      --dry-run            Print the resulting settings.json; write nothing.
      --settings <path>    Operate on <path> instead of ~/.claude/settings.json.

    NOTES:
      install backs the existing file up to settings.json.bak.<unix-timestamp>
      before writing (atomically), and creates ~/.claude/settings.json if absent.
      The hook handler never blocks or errors an agent: any failure to reach
      notchide prints nothing and exits 0 (fail-open).
    """)
}

// MARK: - Self test

/// Spawns a server on a temp socket, sends a PreToolUse event through the real
/// client, and prints OK/FAIL. Useful for verifying the IPC path end to end.
func selfTest() {
    let tempSocket = NSTemporaryDirectory() + "notchide-selftest-\(UUID().uuidString.prefix(8)).sock"

    let server = UnixSocketServer(socketPath: tempSocket) { envelope in
        DecisionMessage(id: envelope.id, permission: .deny, reason: "selftest")
    }

    do {
        try server.start()
    } catch {
        FileHandle.standardError.write(Data("SELFTEST FAIL: server start: \(error)\n".utf8))
        return
    }
    defer { server.stop() }

    let event = HookEvent(
        sessionId: "selftest-session",
        cwd: FileManager.default.currentDirectoryPath,
        hookEventName: .preToolUse,
        toolName: "Bash",
        toolInput: .object(["command": .string("rm -rf build/")])
    )
    let envelope = HookEnvelope(event: event, wantsDecision: true)

    let decision = (try? UnixSocketClient.send(
        envelope,
        to: tempSocket,
        awaitDecision: true,
        timeout: 3.0
    )) ?? nil

    if let decision, decision.permission == .deny {
        print("SELFTEST OK (received .deny over \(tempSocket))")
    } else {
        FileHandle.standardError.write(Data("SELFTEST FAIL: no valid decision received\n".utf8))
    }
}
