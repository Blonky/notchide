import Testing
import Foundation
import Darwin
@testable import NotchideKit

// MARK: - Shared raw-socket test helpers

/// Connects a raw AF_UNIX client to `path` and returns the fd (caller closes).
/// SIGPIPE is disabled so a write to a server-closed peer fails with EPIPE
/// rather than terminating the test process. Connecting/​writing to a local
/// listening socket is effectively immediate, so these stay synchronous.
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

private func tempSocketPath(_ tag: String) -> String {
    NSTemporaryDirectory() + "nh-\(tag)-\(UUID().uuidString.prefix(8)).sock"
}

/// Runs a BLOCKING closure on a dedicated thread and returns its result to an
/// async caller. Awaiting suspends the test's cooperative worker instead of
/// blocking it, so these socket tests never hog the shared executor while they
/// wait — which keeps them from deadlocking (and being deadlocked) under heavy
/// parallel load from other suites' blocking subprocess tests.
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

/// Drives a full gate round-trip (connect → handshake → envelope → await
/// decision) off the cooperative pool.
private func sendGate(to path: String, timeout: TimeInterval = 5.0) async -> AgentDecision? {
    await offload {
        try? UnixSocketClient.send(
            gateEnvelope(), handshake: gateHandshake(),
            to: path, awaitDecision: true, timeout: timeout)
    }
}

private let claude = ProviderID("sh.claude")

private func gateEnvelope() -> AgentEnvelope {
    let id = UUID()
    let event = AgentEvent(
        providerID: claude,
        sessionKey: SessionKey(provider: claude, agentSessionID: "s", cwd: "/tmp"),
        kind: .needsDecision,
        command: "rm -rf build/",
        decision: DecisionRequest(id: id, prompt: "rm -rf build/")
    )
    return AgentEnvelope(id: id, event: event, wantsDecision: true)
}

private func gateHandshake() -> AAPHandshake {
    AAPHandshake(providerID: claude, capabilities: [.observe, .gate])
}

/// A thread-safe call counter for handlers that must behave differently on the
/// first invocation (deterministic, no data races on a plain box).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}

/// An async gate a test handler parks on to model a decision awaiting a human.
///
/// It SUSPENDS the handler task on a continuation (never blocks a cooperative
/// thread — the same way the real `SocketAAPProvider` parks), so a parked test
/// handler cannot starve the shared executor. The continuation is resumed once,
/// at teardown, via `open()`.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func park() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

// MARK: - Hub socket rails (1, 2, 3)

/// Rails 1–3 over the real socket transport. One serialized suite so at most one
/// of these socket servers is live at a time, and every blocking wait is
/// offloaded off the cooperative pool for stable behavior under parallel load.
@Suite("Hub rails: gate-abandon, bounded conns, line cap", .serialized)
struct HubRailsTests {

    // MARK: Rail 1 — gate-continuation teardown on peer close

    @Test("peer close during a pending decision abandons it: no frame, app notified, server still serves")
    func abandonOnPeerClose() async throws {
        let path = tempSocketPath("abandon")

        let handlerEntered = DispatchSemaphore(value: 0) // first handler was invoked
        let gate = AsyncGate()                            // parks the "human decision"
        let abandoned = DispatchSemaphore(value: 0)       // onAbandon fired
        let abandonedEnvelope = UncheckedBox<AgentEnvelope?>(nil)
        let firstHandlerCompleted = UncheckedBox<Bool>(false)
        let calls = CallCounter()

        let server = UnixSocketServer(
            socketPath: path,
            onAbandon: { envelope in
                abandonedEnvelope.value = envelope
                abandoned.signal()
            },
            handler: { envelope, _ in
                if calls.next() == 1 {
                    // The gate the peer will abandon: suspend until torn down.
                    handlerEntered.signal()
                    await gate.park()
                    firstHandlerCompleted.value = true // only if it ever unparks
                    return AgentDecision(id: envelope.id, verdict: .allow, reason: "late")
                }
                // Any subsequent gate is answered normally.
                return AgentDecision(id: envelope.id, verdict: .deny, reason: "second serves fine")
            })
        try server.start()
        defer {
            gate.open() // let the parked first handler drain at teardown
            server.stop()
        }

        // Connect, handshake, send the gate envelope, then wait until the server
        // is actually parked in the decision handler before closing.
        let envelope = gateEnvelope()
        let fd = try connectRaw(path: path)
        #expect(try writeLine(gateHandshake(), to: fd))
        #expect(try writeLine(envelope, to: fd))
        #expect(await awaitSignal(handlerEntered, seconds: 5.0))

        // Close the peer WHILE the decision is still pending.
        Darwin.close(fd)

        // (a) the abandonment path fires deterministically…
        #expect(await awaitSignal(abandoned, seconds: 5.0))
        #expect(abandonedEnvelope.value?.id == envelope.id)
        // (b) …and NO decision frame was produced (the handler never unparked).
        #expect(firstHandlerCompleted.value == false)

        // (c) the server neither crashed nor hung: a fresh gate still resolves.
        #expect(await sendGate(to: path)?.verdict == .deny)
    }

    @Test("abandonment notification can be wired to SessionStore to clear the wedged lane")
    func abandonClearsLaneEndToEnd() async throws {
        let path = tempSocketPath("abandon-lane")
        let store = SessionStore()
        await store.register(claude, decisionCapability: .blocking)

        let handlerEntered = DispatchSemaphore(value: 0)
        let gate = AsyncGate()
        let abandoned = DispatchSemaphore(value: 0)

        let envelope = gateEnvelope()
        // Seed the lane into needsYou (as the app would on the streamed event).
        _ = await store.ingest(envelope.event)
        let key = envelope.event.sessionKey
        #expect(await store.mostUrgent()?.state == .needsYou)

        let server = UnixSocketServer(
            socketPath: path,
            onAbandon: { env in
                Task { await store.abandonGate(for: env.event.sessionKey); abandoned.signal() }
            },
            handler: { _, _ in
                handlerEntered.signal()
                await gate.park()
                return nil
            })
        try server.start()
        defer { gate.open(); server.stop() }

        let fd = try connectRaw(path: path)
        #expect(try writeLine(gateHandshake(), to: fd))
        #expect(try writeLine(envelope, to: fd))
        #expect(await awaitSignal(handlerEntered, seconds: 5.0))
        Darwin.close(fd)

        #expect(await awaitSignal(abandoned, seconds: 5.0))
        // The lane is flipped OUT of needsYou and its pending decision cleared.
        let lane = await store.currentLanes().first { $0.id == key }
        #expect(lane?.state == .flowing)
        #expect(lane?.pendingDecision == nil)
    }

    // MARK: Rail 2 — bounded connection concurrency

    @Test("beyond the cap, excess connections are closed promptly; a normal gate still works after capacity frees")
    func excessConnectionsClosed() async throws {
        let path = tempSocketPath("cap")
        let cap = 2

        let handshakes = DispatchSemaphore(value: 0)
        let server = UnixSocketServer(
            socketPath: path,
            maxConnections: cap,
            onHandshake: { _ in handshakes.signal() },
            handler: { envelope, _ in AgentDecision(id: envelope.id, verdict: .allow, reason: "ok") })
        try server.start()
        defer { server.stop() }

        // Occupy both slots with idle, handshaked connections. The slot is taken
        // before the connection thread spawns, so two handshake signals prove
        // both slots are held; the connections then park in their reader loop.
        var occupants: [Int32] = []
        for _ in 0..<cap {
            let fd = try connectRaw(path: path)
            #expect(try writeLine(gateHandshake(), to: fd))
            occupants.append(fd)
        }
        for _ in 0..<cap {
            #expect(await awaitSignal(handshakes, seconds: 5.0))
        }

        // cap + N excess connections: each is accepted then immediately closed.
        // Reading for EOF with a deadline — `.closed` (not `.timedOut`) proves
        // the server dropped it rather than serving/hanging it.
        for _ in 0..<3 {
            let excess = try connectRaw(path: path)
            let outcome = await offload {
                FDLineReader(fd: excess).nextLine(deadline: Date().addingTimeInterval(3.0))
            }
            #expect(outcome == .closed)
            Darwin.close(excess)
        }

        // Free the occupied slots; a subsequent normal gate must succeed once
        // capacity is available again (retry converges on the real condition).
        for fd in occupants { Darwin.close(fd) }
        let decision = await offload { () -> AgentDecision? in
            let deadline = Date().addingTimeInterval(5.0)
            while Date() < deadline {
                if let d = try? UnixSocketClient.send(
                    gateEnvelope(), handshake: gateHandshake(),
                    to: path, awaitDecision: true, timeout: 1.0) {
                    return d
                }
                usleep(20_000)
            }
            return nil
        }
        #expect(decision?.verdict == .allow)
    }

    // MARK: Rail 3 — NDJSON line cap

    @Test("a post-handshake line larger than the cap drops the connection; the server survives")
    func oversizedLineDropsConnection() async throws {
        let path = tempSocketPath("linecap")
        let cap = 1024

        let server = UnixSocketServer(
            socketPath: path,
            maxLineBytes: cap,
            handler: { envelope, _ in AgentDecision(id: envelope.id, verdict: .allow, reason: "ok") })
        try server.start()
        defer { server.stop() }

        let fd = try connectRaw(path: path)
        // Valid handshake (terminated), then a flood well over the cap with NO
        // newline — the server must drop the connection, never buffer it.
        #expect(try writeLine(gateHandshake(), to: fd))
        let flood = [UInt8](repeating: UInt8(ascii: "A"), count: cap + 8192)
        _ = writeAllBytes(fd: fd, flood) // may EPIPE once the server closes; fine

        let outcome = await offload {
            FDLineReader(fd: fd).nextLine(deadline: Date().addingTimeInterval(3.0))
        }
        #expect(outcome == .closed) // dropped, not hung
        Darwin.close(fd)

        // The server survived the overflow and still serves a normal gate.
        #expect(await sendGate(to: path)?.verdict == .allow)
    }

    @Test("an oversized handshake line (no newline) is dropped and does not crash the server")
    func oversizedHandshakeDropped() async throws {
        let path = tempSocketPath("linecap-hs")
        let cap = 512

        let server = UnixSocketServer(
            socketPath: path,
            maxLineBytes: cap,
            handler: { envelope, _ in AgentDecision(id: envelope.id, verdict: .allow) })
        try server.start()
        defer { server.stop() }

        let fd = try connectRaw(path: path)
        let flood = [UInt8](repeating: UInt8(ascii: "B"), count: cap + 4096)
        _ = writeAllBytes(fd: fd, flood) // never a newline → never a handshake

        let outcome = await offload {
            FDLineReader(fd: fd).nextLine(deadline: Date().addingTimeInterval(3.0))
        }
        #expect(outcome == .closed)
        Darwin.close(fd)

        #expect(await sendGate(to: path)?.verdict == .allow)
    }
}
