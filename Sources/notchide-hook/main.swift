import Foundation
import NotchideKit

// notchide-hook
// ─────────────
// The sidecar that Claude Code invokes as a hook command. Claude Code pipes the
// hook event JSON on stdin; for a PreToolUse permission gate this process asks
// the notchide app (over a Unix socket) for a decision and prints the decision
// JSON on stdout.
//
// FAIL-OPEN CONTRACT (the critical invariant)
// ───────────────────────────────────────────
// On ANY failure — socket missing, app not running, connect error, timeout,
// malformed decision, unparseable input — this process prints NOTHING and exits
// 0. Emitting no decision makes Claude Code fall back to its normal permission
// prompt (equivalent to "defer"). We NEVER exit non-zero in a way that would
// block or error the agent, and we NEVER hang without a hard timeout. Being
// unable to reach notchide must be indistinguishable, to the agent, from
// notchide not being installed at all.

/// Exit cleanly (fail-open): print nothing and exit 0.
func failOpen() -> Never {
    exit(0)
}

// ── --selftest: in-process round-trip to aid debugging ──────────────────────
if CommandLine.arguments.contains("--selftest") {
    selfTest()
    exit(0)
}

// ── Read the hook event JSON from stdin ─────────────────────────────────────
let stdinData = FileHandle.standardInput.readDataToEndOfFile()

// Decode robustly. If we cannot parse the input at all, fail open.
guard let event = try? JSONDecoder().decode(HookEvent.self, from: stdinData) else {
    failOpen()
}

// Determine the event name from the JSON (do not rely on argv), but accept an
// optional argv override of the form `--event <Name>` for testing/debugging.
let overriddenEventName = eventNameOverride(from: CommandLine.arguments)
let effectiveEventName = overriddenEventName ?? event.hookEventName

let socketPath = NotchidePaths.socketPath

// Only PreToolUse is a blocking permission gate; everything else is best-effort
// fire-and-forget.
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

// MARK: - Helpers

/// Parses an optional `--event <Name>` override from argv.
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
