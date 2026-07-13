import Testing
import Foundation
import Darwin
@testable import NotchideKit

// MARK: - Local raw-socket test helpers (file-private; no collision with the
// identically-shaped helpers in HubRailsTests.swift, which are private there).

private let claude = ProviderID("sh.claude")

private func tempSocketPath(_ tag: String) -> String {
    NSTemporaryDirectory() + "nh-\(tag)-\(UUID().uuidString.prefix(8)).sock"
}

private func connectRaw(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError.create(errno) }
    disableSIGPIPE(fd)
    var addr = try makeUnixSockaddr(path: path)
    let rc = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else { Darwin.close(fd); throw SocketError.connect(errno) }
    return fd
}

@discardableResult
private func writeLine<T: Encodable>(_ value: T, to fd: Int32) throws -> Bool {
    writeAllBytes(fd: fd, Array(try NDJSON.encode(value)))
}

/// Runs a BLOCKING closure on a dedicated thread and returns its result to an
/// async caller — the same off-the-cooperative-pool pattern the socket suites
/// use so a blocking client send never starves the shared executor.
private func offload<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let box = UncheckedBox<CheckedContinuation<T, Never>?>(continuation)
        Thread.detachNewThread {
            let result = work()
            box.value?.resume(returning: result)
            box.value = nil
        }
    }
}

/// Awaits a semaphore signal off the cooperative pool.
private func awaitSignal(_ semaphore: DispatchSemaphore, seconds: Double) async -> Bool {
    await offload { semaphore.wait(timeout: .now() + seconds) == .success }
}

private func gateHandshake() -> AAPHandshake {
    AAPHandshake(providerID: claude, capabilities: [.observe, .gate])
}

/// A gate envelope whose envelope id and decision-request id are the SAME UUID,
/// so a matching `AgentDecision(id:)` resolves exactly this pending gate.
private func gateEnvelope(id: UUID) -> AgentEnvelope {
    let event = AgentEvent(
        providerID: claude,
        sessionKey: SessionKey(provider: claude, agentSessionID: "s", cwd: "/tmp"),
        kind: .needsDecision,
        command: "rm -rf build/",
        decision: DecisionRequest(id: id, prompt: "rm -rf build/")
    )
    return AgentEnvelope(id: id, event: event, wantsDecision: true)
}

/// Polls `provider.parkedDecisionCount` (a synchronous, internally-locked read)
/// until it equals `target` or the deadline elapses. Returns whether it matched.
private func waitForParked(
    _ provider: SocketAAPProvider, equals target: Int, seconds: Double
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if provider.parkedDecisionCount == target { return true }
        try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
    }
    return provider.parkedDecisionCount == target
}

// MARK: - Gate-abandon continuation resolution

/// The provider-level dual of HubRailsTests' server-level rail-1 test: it drives
/// a real `SocketAAPProvider` (which parks its decision on a `withChecked
/// Continuation`) and proves the parked continuation is resumed — with NO
/// decision — when the peer disconnects mid-decision, rather than leaking.
///
/// Serialized so at most one of these socket servers is live at a time and every
/// blocking wait is offloaded off the cooperative pool, for stable behavior under
/// heavy parallel load from the other socket suites.
@Suite("SocketAAPProvider gate-abandon", .serialized)
struct SocketAAPProviderAbandonTests {

    @Test("peer close during a parked decision resumes the continuation with no decision — no leak, no hang — and a later gate still resolves")
    func abandonResolvesParkedContinuation() async throws {
        let path = tempSocketPath("provider-abandon")
        let provider = SocketAAPProvider(socketPath: path)
        try provider.start()
        defer { provider.stop() }

        // ── Park a decision via the provider ──────────────────────────────────
        // Connect, gate-handshake, send a gate envelope; the provider's handler
        // yields the event and then parks on its continuation awaiting resolve().
        let firstID = UUID()
        let fd = try connectRaw(path: path)
        #expect(try writeLine(gateHandshake(), to: fd))
        #expect(try writeLine(gateEnvelope(id: firstID), to: fd))

        // The continuation is genuinely parked before we abandon it.
        #expect(await waitForParked(provider, equals: 1, seconds: 5.0))

        // ── Trigger abandonment: close the peer WHILE the decision is pending ──
        Darwin.close(fd)

        // (a) The parked continuation is resumed promptly and does not leak: the
        // parked count falls back to zero. Absent the fix this stays at 1 forever
        // (the continuation is stranded) and this assertion times out.
        #expect(await waitForParked(provider, equals: 0, seconds: 5.0))

        // (b) It was resumed by the ABANDON path (no decision), not by a verdict:
        // a late resolve() for the same id now finds nothing pending and is a
        // safe no-op — and critically does not crash on a double-resume.
        await provider.resolve(AgentDecision(id: firstID, verdict: .allow, reason: "late"))
        #expect(provider.parkedDecisionCount == 0)

        // ── A subsequent gate still works end-to-end ──────────────────────────
        // The abandonment tore down only that one connection; the provider still
        // serves. Send a fresh gate on a new connection and resolve it.
        let secondID = UUID()
        async let secondDecision: AgentDecision? = offload {
            try? UnixSocketClient.send(
                gateEnvelope(id: secondID), handshake: gateHandshake(),
                to: path, awaitDecision: true, timeout: 5.0)
        }

        #expect(await waitForParked(provider, equals: 1, seconds: 5.0))
        await provider.resolve(AgentDecision(id: secondID, verdict: .allow, reason: "ok"))

        let decision = await secondDecision
        #expect(decision?.id == secondID)
        #expect(decision?.verdict == .allow)
        #expect(provider.parkedDecisionCount == 0)
    }
}
