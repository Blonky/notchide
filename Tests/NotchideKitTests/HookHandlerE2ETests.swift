import Testing
import Foundation
@testable import NotchideKit

/// End-to-end tests that exercise the REAL product loop: they spawn the built
/// `notchide-hook` binary as a subprocess, pipe realistic Claude Code hook JSON
/// to its stdin, run an in-test `UnixSocketServer` it talks to over a unique
/// socket (via NOTCHIDE_SOCKET_PATH), and assert on the child's stdout + exit
/// code. This is the only place the actual CLI decision-mapping and fail-open
/// behavior are verified against the shipped binary.
@Suite("notchide-hook end-to-end (spawns the built binary)", .serialized)
struct HookHandlerE2ETests {

    // MARK: - Locating the built binary

    /// `.build/debug/notchide-hook`, derived from this test file's path:
    /// …/Tests/NotchideKitTests/HookHandlerE2ETests.swift → up 3 → package root.
    private func builtBinaryPath() -> String {
        let file = URL(fileURLWithPath: #filePath)
        let packageRoot = file
            .deletingLastPathComponent()  // NotchideKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        return packageRoot
            .appendingPathComponent(".build/debug/notchide-hook")
            .path
    }

    private func requireBinary() throws -> String {
        let path = builtBinaryPath()
        try #require(FileManager.default.fileExists(atPath: path),
                     "built notchide-hook not found at \(path); `swift test` builds products first, so it should exist")
        return path
    }

    // MARK: - Subprocess driver

    private struct ChildResult {
        let stdout: Data
        let status: Int32
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var trimmedStdout: String {
            stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Runs the built binary with `arguments`, feeding `stdin`, overlaying `env`
    /// onto the inherited environment. Reads stdout fully, then waits for exit.
    private func runChild(
        binary: String,
        arguments: [String],
        stdin: Data,
        env: [String: String]
    ) throws -> ChildResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env { environment[key] = value }
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe() // swallow child's stderr

        try process.run()
        stdinPipe.fileHandleForWriting.write(stdin)
        stdinPipe.fileHandleForWriting.closeFile()
        let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ChildResult(stdout: out, status: process.terminationStatus)
    }

    // MARK: - Fixtures

    private func uniqueSocketPath() -> String {
        NSTemporaryDirectory() + "nh-e2e-\(UUID().uuidString.prefix(8)).sock"
    }

    /// A realistic Claude Code PreToolUse payload (Bash rm), as sent on stdin.
    private func preToolUseJSON(command: String = "rm -rf build/") -> Data {
        Data("""
        {"session_id":"e2e-sess","cwd":"/tmp","hook_event_name":"PreToolUse",\
        "tool_name":"Bash","tool_input":{"command":"\(command)"}}
        """.utf8)
    }

    private func notificationJSON() -> Data {
        Data("""
        {"session_id":"e2e-sess","cwd":"/tmp","hook_event_name":"Notification",\
        "message":"waiting for input"}
        """.utf8)
    }

    /// Parses a child's stdout as the PreToolUse decision object, returning the
    /// nested `hookSpecificOutput` dictionary.
    private func decodeHookOutput(_ result: ChildResult) throws -> [String: Any] {
        let object = try #require(
            try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        #expect(object.keys.sorted() == ["hookSpecificOutput"])
        return try #require(object["hookSpecificOutput"] as? [String: Any])
    }

    // MARK: - (a) allow

    @Test("PreToolUse → server .allow yields the exact allow decision JSON and exit 0")
    func allowDecision() throws {
        let binary = try requireBinary()
        let socketPath = uniqueSocketPath()
        let server = UnixSocketServer(socketPath: socketPath) { envelope, _ in
            AgentDecision(id: envelope.id, verdict: .allow, reason: "trusted by test")
        }
        try server.start()
        defer { server.stop() }

        let result = try runChild(
            binary: binary,
            arguments: ["handle", "PreToolUse"],
            stdin: preToolUseJSON(),
            env: ["NOTCHIDE_SOCKET_PATH": socketPath])

        #expect(result.status == 0)
        #expect(!result.stdoutString.contains("\n\n")) // single JSON line
        let inner = try decodeHookOutput(result)
        #expect(inner["hookEventName"] as? String == "PreToolUse")
        #expect(inner["permissionDecision"] as? String == "allow")
        #expect(inner["permissionDecisionReason"] as? String == "trusted by test")
    }

    // MARK: - (b) deny

    @Test("PreToolUse → server .deny yields the exact deny decision JSON and exit 0")
    func denyDecision() throws {
        let binary = try requireBinary()
        let socketPath = uniqueSocketPath()
        let server = UnixSocketServer(socketPath: socketPath) { envelope, _ in
            AgentDecision(id: envelope.id, verdict: .deny, reason: "Destructive command blocked by hook")
        }
        try server.start()
        defer { server.stop() }

        let result = try runChild(
            binary: binary,
            arguments: ["handle", "PreToolUse"],
            stdin: preToolUseJSON(),
            env: ["NOTCHIDE_SOCKET_PATH": socketPath])

        #expect(result.status == 0)
        let inner = try decodeHookOutput(result)
        #expect(inner["hookEventName"] as? String == "PreToolUse")
        #expect(inner["permissionDecision"] as? String == "deny")
        #expect(inner["permissionDecisionReason"] as? String == "Destructive command blocked by hook")
    }

    // MARK: - item 12: .ask mapping

    @Test("PreToolUse → server .ask maps onto permissionDecision \"ask\"")
    func askDecision() throws {
        let binary = try requireBinary()
        let socketPath = uniqueSocketPath()
        let server = UnixSocketServer(socketPath: socketPath) { envelope, _ in
            AgentDecision(id: envelope.id, verdict: .ask, reason: "please confirm")
        }
        try server.start()
        defer { server.stop() }

        let result = try runChild(
            binary: binary,
            arguments: ["handle", "PreToolUse"],
            stdin: preToolUseJSON(),
            env: ["NOTCHIDE_SOCKET_PATH": socketPath])

        #expect(result.status == 0)
        let inner = try decodeHookOutput(result)
        #expect(inner["permissionDecision"] as? String == "ask")
        #expect(inner["permissionDecisionReason"] as? String == "please confirm")
    }

    // MARK: - item 12: redirect is never emitted into CLI stdout

    @Test("a server decision carrying `redirect` never leaks it into the CLI stdout")
    func redirectNeverEmitted() throws {
        let binary = try requireBinary()
        let socketPath = uniqueSocketPath()
        let server = UnixSocketServer(socketPath: socketPath) { envelope, _ in
            AgentDecision(id: envelope.id, verdict: .deny,
                          reason: "blocked", redirect: "https://internal/redirect-target")
        }
        try server.start()
        defer { server.stop() }

        let result = try runChild(
            binary: binary,
            arguments: ["handle", "PreToolUse"],
            stdin: preToolUseJSON(),
            env: ["NOTCHIDE_SOCKET_PATH": socketPath])

        #expect(result.status == 0)
        // The redirect string / key must not appear anywhere in stdout.
        #expect(!result.stdoutString.contains("redirect"))
        #expect(!result.stdoutString.contains("redirect-target"))
        let inner = try decodeHookOutput(result)
        #expect(inner.keys.sorted() == ["hookEventName", "permissionDecision", "permissionDecisionReason"])
    }

    // MARK: - (c) no server → fail-open

    @Test("no server listening → stdout empty, exit 0 (fail-open)")
    func failOpenNoServer() throws {
        let binary = try requireBinary()
        let socketPath = uniqueSocketPath() // nothing is listening here

        let result = try runChild(
            binary: binary,
            arguments: ["handle", "PreToolUse"],
            stdin: preToolUseJSON(),
            env: ["NOTCHIDE_SOCKET_PATH": socketPath])

        #expect(result.status == 0)
        #expect(result.trimmedStdout.isEmpty)
    }

    // MARK: - (d) server never responds + short timeout → fail-open

    @Test("server never responds + short timeout → stdout empty, exit 0 within the timeout")
    func failOpenOnTimeout() throws {
        let binary = try requireBinary()
        let socketPath = uniqueSocketPath()
        // Handler returns nil → server writes nothing → client must time out.
        let server = UnixSocketServer(socketPath: socketPath) { _, _ in nil }
        try server.start()
        defer { server.stop() }

        let start = Date()
        let result = try runChild(
            binary: binary,
            arguments: ["handle", "PreToolUse"],
            stdin: preToolUseJSON(),
            env: [
                "NOTCHIDE_SOCKET_PATH": socketPath,
                "NOTCHIDE_HOOK_TIMEOUT_MS": "300",
            ])
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.status == 0)
        #expect(result.trimmedStdout.isEmpty)
        #expect(elapsed < 5.0, "should fail open promptly after the ~300ms timeout, took \(elapsed)s")
    }

    // MARK: - Notification is fire-and-forget

    @Test("Notification event returns promptly (exit 0) with no decision output")
    func notificationFireAndForget() throws {
        let binary = try requireBinary()
        let socketPath = uniqueSocketPath()
        let received = UncheckedBox<Bool>(false)
        let gotIt = DispatchSemaphore(value: 0)
        let server = UnixSocketServer(socketPath: socketPath) { envelope, _ in
            if envelope.event.kind == .notified {
                received.value = true
                gotIt.signal()
            }
            return nil
        }
        try server.start()
        defer { server.stop() }

        let start = Date()
        let result = try runChild(
            binary: binary,
            arguments: ["handle", "Notification"],
            stdin: notificationJSON(),
            env: ["NOTCHIDE_SOCKET_PATH": socketPath])
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.status == 0)
        #expect(result.trimmedStdout.isEmpty)
        #expect(elapsed < 3.0)
        #expect(gotIt.wait(timeout: .now() + 2.0) == .success)
        #expect(received.value)
    }

    // MARK: - item 12: event-name precedence

    @Test("positional `handle <Name>` overrides the payload's hook_event_name (Notification payload treated as blocking PreToolUse)")
    func positionalEventNameOverridesPayload() throws {
        let binary = try requireBinary()
        let socketPath = uniqueSocketPath()
        let server = UnixSocketServer(socketPath: socketPath) { envelope, _ in
            AgentDecision(id: envelope.id, verdict: .deny, reason: "overridden to blocking")
        }
        try server.start()
        defer { server.stop() }

        // Payload SAYS Notification, but we invoke `handle PreToolUse`.
        let payload = Data("""
        {"session_id":"e2e","cwd":"/tmp","hook_event_name":"Notification","message":"hi"}
        """.utf8)

        let result = try runChild(
            binary: binary,
            arguments: ["handle", "PreToolUse"],
            stdin: payload,
            env: ["NOTCHIDE_SOCKET_PATH": socketPath])

        // Because the positional name wins, the CLI blocked for a decision and emitted it.
        #expect(result.status == 0)
        let inner = try decodeHookOutput(result)
        #expect(inner["permissionDecision"] as? String == "deny")
    }

    @Test("positional `handle Notification` overrides a PreToolUse payload → fire-and-forget, no decision emitted")
    func positionalEventNameDowngradesToFireAndForget() throws {
        let binary = try requireBinary()
        let socketPath = uniqueSocketPath()
        let server = UnixSocketServer(socketPath: socketPath) { envelope, _ in
            // Even if we would decide, a fire-and-forget client won't read it.
            AgentDecision(id: envelope.id, verdict: .deny, reason: "should not be emitted")
        }
        try server.start()
        defer { server.stop() }

        // Payload SAYS PreToolUse, but we invoke `handle Notification`.
        let result = try runChild(
            binary: binary,
            arguments: ["handle", "Notification"],
            stdin: preToolUseJSON(),
            env: ["NOTCHIDE_SOCKET_PATH": socketPath])

        #expect(result.status == 0)
        #expect(result.trimmedStdout.isEmpty)
    }

    @Test("legacy `--event <Name>` (no positional) overrides the payload's hook_event_name")
    func legacyEventFlagOverridesPayload() throws {
        let binary = try requireBinary()
        let socketPath = uniqueSocketPath()
        let server = UnixSocketServer(socketPath: socketPath) { envelope, _ in
            AgentDecision(id: envelope.id, verdict: .allow, reason: "via --event")
        }
        try server.start()
        defer { server.stop() }

        // Bare invocation (no `handle`) + legacy --event flag; payload says Notification.
        let payload = Data("""
        {"session_id":"e2e","cwd":"/tmp","hook_event_name":"Notification","message":"hi"}
        """.utf8)

        let result = try runChild(
            binary: binary,
            arguments: ["--event", "PreToolUse"],
            stdin: payload,
            env: ["NOTCHIDE_SOCKET_PATH": socketPath])

        #expect(result.status == 0)
        let inner = try decodeHookOutput(result)
        #expect(inner["permissionDecision"] as? String == "allow")
    }
}
