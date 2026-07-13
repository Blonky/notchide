import Testing
import Foundation
import Darwin
@testable import NotchideKit

/// Waits on a semaphore from a synchronous helper so an `async` test can block
/// bounded on it (`DispatchSemaphore.wait` is unavailable directly from async).
private func waitFor(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
    semaphore.wait(timeout: .now() + seconds) == .success
}

/// A raw, persistent duplex AAP client for tests: connects, writes the
/// handshake, then STAYS OPEN so it can receive server-pushed `ActuateFrame`s
/// (unlike `UnixSocketClient`, which sends one envelope and closes).
private final class RawDuplexClient: @unchecked Sendable {
    let fd: Int32
    private let reader: FDLineReader

    init(path: String, handshake: AAPHandshake) throws {
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
        let frame = try NDJSON.encode(handshake)
        guard writeAllBytes(fd: fd, Array(frame)) else { Darwin.close(fd); throw SocketError.write }
        self.fd = fd
        self.reader = FDLineReader(fd: fd)
    }

    /// Reads one pushed line within `timeout`, decoded as an `ActuateFrame`.
    func readActuate(timeout: TimeInterval) -> ActuateFrame? {
        switch reader.nextLine(deadline: Date().addingTimeInterval(timeout)) {
        case .line(let bytes):
            return try? JSONDecoder().decode(ActuateFrame.self, from: Data(bytes))
        case .timedOut, .closed:
            return nil
        }
    }

    func close() { Darwin.close(fd) }
}

/// Exercises the AAP handshake negotiation over the real socket transport, and
/// the `SocketAAPProvider` events()/resolve() round-trip.
@Suite("AAP handshake + socket provider", .serialized)
struct AAPHandshakeTests {

    private let claude = ProviderID("sh.claude")

    private func tempSocketPath() -> String {
        NSTemporaryDirectory() + "nh-hs-\(UUID().uuidString.prefix(8)).sock"
    }

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

    // MARK: - Version / capability negotiation (server level)

    @Test("a gate handshake receives the decision")
    func gateHandshakeGetsDecision() throws {
        let path = tempSocketPath()
        let server = UnixSocketServer(socketPath: path) { envelope, _ in
            AgentDecision(id: envelope.id, verdict: .deny, reason: "ok")
        }
        try server.start()
        defer { server.stop() }

        let decision = try UnixSocketClient.send(
            gateEnvelope(),
            handshake: AAPHandshake(providerID: claude, capabilities: [.observe, .gate]),
            to: path, awaitDecision: true, timeout: 5.0)
        #expect(decision?.verdict == .deny)
    }

    @Test("a provider that did not advertise gate cannot escalate a decision")
    func nonGateHandshakeIgnoresDecisionEscalation() throws {
        let path = tempSocketPath()
        // Handler always returns a decision; the server must still refuse to write
        // it because the connection did not advertise `gate`.
        let server = UnixSocketServer(socketPath: path) { envelope, _ in
            AgentDecision(id: envelope.id, verdict: .deny, reason: "should be ignored")
        }
        try server.start()
        defer { server.stop() }

        let start = Date()
        let decision = try UnixSocketClient.send(
            gateEnvelope(),
            handshake: AAPHandshake(providerID: claude, capabilities: [.observe]),
            to: path, awaitDecision: true, timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)

        #expect(decision == nil, "non-gate provider must not receive a decision")
        #expect(elapsed >= 0.4) // it waited out the timeout rather than being answered
    }

    @Test("an unsupported handshake version is rejected")
    func unsupportedVersionRejected() throws {
        let path = tempSocketPath()
        let server = UnixSocketServer(socketPath: path) { envelope, _ in
            AgentDecision(id: envelope.id, verdict: .allow)
        }
        try server.start()
        defer { server.stop() }

        let decision = try? UnixSocketClient.send(
            gateEnvelope(),
            handshake: AAPHandshake(providerID: claude, capabilities: [.observe, .gate], aap: "99"),
            to: path, awaitDecision: true, timeout: 1.0)
        #expect(decision == nil, "a wrong-version handshake must be rejected")
    }

    @Test("the server surfaces the negotiated handshake to its observer")
    func observerReceivesHandshake() throws {
        let path = tempSocketPath()
        let box = UncheckedBox<AAPHandshake?>(nil)
        let got = DispatchSemaphore(value: 0)
        let server = UnixSocketServer(
            socketPath: path,
            onHandshake: { handshake in box.value = handshake; got.signal() },
            handler: { _, _ in nil })
        try server.start()
        defer { server.stop() }

        let event = AgentEvent(
            providerID: claude,
            sessionKey: SessionKey(provider: claude, agentSessionID: "s", cwd: "/tmp"),
            kind: .notified, title: "hi")
        _ = try UnixSocketClient.send(
            AgentEnvelope(event: event, wantsDecision: false),
            handshake: AAPHandshake(providerID: claude, capabilities: [.observe, .gate]),
            to: path, awaitDecision: false, timeout: 2.0)

        #expect(got.wait(timeout: .now() + 3.0) == .success)
        #expect(box.value?.providerID == claude)
        #expect(box.value?.capabilities == [.observe, .gate])
    }

    // MARK: - SocketAAPProvider events() / resolve()

    @Test("SocketAAPProvider streams the event, announces the provider, and resolve() answers the client")
    func providerResolvesDecision() async throws {
        let path = tempSocketPath()
        let announced = UncheckedBox<(ProviderID, DecisionCapability)?>(nil)
        let provider = SocketAAPProvider(
            socketPath: path,
            onProviderAnnounced: { id, capability in announced.value = (id, capability) })
        try provider.start()
        defer { provider.stop() }

        let envelope = gateEnvelope()
        let resultBox = UncheckedBox<AgentDecision?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            resultBox.value = try? UnixSocketClient.send(
                envelope,
                handshake: AAPHandshake(providerID: self.claude, capabilities: [.observe, .gate]),
                to: path, awaitDecision: true, timeout: 5.0)
            done.signal()
        }

        // Consume the streamed event and resolve its decision.
        var iterator = provider.events().makeAsyncIterator()
        let received = await iterator.next()
        let request = try #require(received?.decision)
        #expect(received?.providerID == claude)
        await provider.resolve(AgentDecision(id: request.id, verdict: .deny, reason: "resolved"))

        #expect(waitFor(done, seconds: 5.0))
        #expect(resultBox.value?.verdict == .deny)
        #expect(resultBox.value?.reason == "resolved")
        #expect(announced.value?.0 == claude)
        #expect(announced.value?.1 == .blocking)
    }

    @Test("a notify-only handshake is announced as notifyOnly")
    func notifyOnlyAnnounced() async throws {
        let path = tempSocketPath()
        let announced = UncheckedBox<DecisionCapability?>(nil)
        let got = DispatchSemaphore(value: 0)
        let provider = SocketAAPProvider(
            socketPath: path,
            onProviderAnnounced: { _, capability in announced.value = capability; got.signal() })
        try provider.start()
        defer { provider.stop() }

        let notifier = ProviderID("sh.notifier")
        let event = AgentEvent(
            providerID: notifier,
            sessionKey: SessionKey(provider: notifier, agentSessionID: "s", cwd: "/tmp"),
            kind: .notified, title: "hi")
        Thread.detachNewThread {
            _ = try? UnixSocketClient.send(
                AgentEnvelope(event: event, wantsDecision: false),
                handshake: AAPHandshake(providerID: notifier, capabilities: [.observe]),
                to: path, awaitDecision: false, timeout: 2.0)
        }

        #expect(waitFor(got, seconds: 3.0))
        #expect(announced.value == .notifyOnly)
    }

    // MARK: - Duplex actuate push

    private func key(for provider: ProviderID) -> SessionKey {
        SessionKey(provider: provider, agentSessionID: "s", cwd: "/tmp")
    }

    @Test("an actuate-capable connection receives pushed prompt + interrupt frames, correlated to the right connection")
    func actuablePushCorrelatesToRightConnection() throws {
        let path = tempSocketPath()
        let handshakes = DispatchSemaphore(value: 0)
        let server = UnixSocketServer(
            socketPath: path,
            onHandshake: { _ in handshakes.signal() },
            handler: { _, _ in nil })
        try server.start()
        defer { server.stop() }

        let other = ProviderID("sh.other")
        let clientA = try RawDuplexClient(
            path: path,
            handshake: AAPHandshake(providerID: claude, capabilities: [.observe, .gate, .actuate]))
        defer { clientA.close() }
        let clientB = try RawDuplexClient(
            path: path,
            handshake: AAPHandshake(providerID: other, capabilities: [.observe, .actuate]))
        defer { clientB.close() }

        // Both connections are registered (registration precedes the handshake
        // observer, so two signals means both writers are live).
        #expect(waitFor(handshakes, seconds: 3.0))
        #expect(waitFor(handshakes, seconds: 3.0))

        // Push a prompt to A only.
        #expect(server.sendActuate(
            ActuateFrame(sessionKey: key(for: claude), kind: .prompt, text: "run the tests"),
            to: claude))
        let prompt = clientA.readActuate(timeout: 3.0)
        #expect(prompt?.kind == .prompt)
        #expect(prompt?.text == "run the tests")
        #expect(prompt?.sessionKey.provider == claude)

        // B must not have received A's push.
        #expect(clientB.readActuate(timeout: 0.3) == nil, "push must be correlated to A's connection")

        // Push an interrupt to A.
        #expect(server.sendActuate(ActuateFrame(sessionKey: key(for: claude), kind: .interrupt), to: claude))
        let interrupt = clientA.readActuate(timeout: 3.0)
        #expect(interrupt?.kind == .interrupt)
        #expect(interrupt?.text == nil)
    }

    @Test("a connection without the actuate capability is never a push target")
    func nonActuateConnectionNeverReceivesPush() throws {
        let path = tempSocketPath()
        let handshakes = DispatchSemaphore(value: 0)
        let server = UnixSocketServer(
            socketPath: path,
            onHandshake: { _ in handshakes.signal() },
            handler: { _, _ in nil })
        try server.start()
        defer { server.stop() }

        let client = try RawDuplexClient(
            path: path,
            handshake: AAPHandshake(providerID: claude, capabilities: [.observe, .gate]))
        defer { client.close() }
        #expect(waitFor(handshakes, seconds: 3.0))

        // No live actuate connection for this provider → drop (logged no-op).
        #expect(server.sendActuate(
            ActuateFrame(sessionKey: key(for: claude), kind: .prompt, text: "should not arrive"),
            to: claude) == false)
        #expect(client.readActuate(timeout: 0.3) == nil)
    }

    @Test("deregistration on disconnect: a push to a provider whose connection closed is a safe no-op")
    func pushToClosedConnectionIsNoOp() throws {
        let path = tempSocketPath()
        let handshakes = DispatchSemaphore(value: 0)
        let server = UnixSocketServer(
            socketPath: path,
            onHandshake: { _ in handshakes.signal() },
            handler: { _, _ in nil })
        try server.start()
        defer { server.stop() }

        do {
            let client = try RawDuplexClient(
                path: path,
                handshake: AAPHandshake(providerID: claude, capabilities: [.observe, .actuate]))
            #expect(waitFor(handshakes, seconds: 3.0))
            client.close() // disconnect; the server reader loop will deregister
        }
        // Give the server's reader thread a moment to observe EOF and deregister.
        Thread.sleep(forTimeInterval: 0.3)
        // Never crashes; returns false once deregistered (and is safe even in the
        // race window before deregistration, since the dead-peer write fails).
        #expect(server.sendActuate(
            ActuateFrame(sessionKey: key(for: claude), kind: .interrupt), to: claude) == false)
    }

    // MARK: - SocketAAPProvider.actuate

    @Test("SocketAAPProvider.actuate pushes prompt + interrupt to the owning live connection")
    func providerActuateDelivers() async throws {
        let path = tempSocketPath()
        let announced = DispatchSemaphore(value: 0)
        let provider = SocketAAPProvider(
            socketPath: path,
            onProviderAnnounced: { _, _ in announced.signal() })
        try provider.start()
        defer { provider.stop() }

        let client = try RawDuplexClient(
            path: path,
            handshake: AAPHandshake(providerID: claude, capabilities: [.observe, .gate, .actuate]))
        defer { client.close() }
        #expect(waitFor(announced, seconds: 3.0))

        await provider.actuate(.prompt(key(for: claude), "run the tests now"))
        let prompt = client.readActuate(timeout: 3.0)
        #expect(prompt?.kind == .prompt)
        #expect(prompt?.text == "run the tests now")

        await provider.actuate(.interrupt(key(for: claude)))
        let interrupt = client.readActuate(timeout: 3.0)
        #expect(interrupt?.kind == .interrupt)
    }

    @Test("SocketAAPProvider.actuate to an unknown session is a safe no-op")
    func providerActuateUnknownSessionNoOp() async throws {
        let path = tempSocketPath()
        let provider = SocketAAPProvider(socketPath: path)
        try provider.start()
        defer { provider.stop() }

        let unknown = SessionKey(provider: ProviderID("sh.nobody"), agentSessionID: "x", cwd: "/nope")
        // No live connection anywhere → must not crash.
        await provider.actuate(.prompt(unknown, "into the void"))
        await provider.actuate(.interrupt(unknown))
        // resume/answer are not carried on the actuate wire; also safe no-ops.
        await provider.actuate(.resume(unknown))
        await provider.actuate(.answer(unknown, "hi"))
    }

    @Test("actuateFrame mapping: only prompt/interrupt map to a frame")
    func actuateFrameMapping() {
        let k = key(for: claude)
        #expect(SocketAAPProvider.actuateFrame(for: .prompt(k, "go now please")) == ActuateFrame(sessionKey: k, kind: .prompt, text: "go now please"))
        #expect(SocketAAPProvider.actuateFrame(for: .interrupt(k)) == ActuateFrame(sessionKey: k, kind: .interrupt))
        #expect(SocketAAPProvider.actuateFrame(for: .resume(k)) == nil)
        #expect(SocketAAPProvider.actuateFrame(for: .answer(k, "x")) == nil)
    }
}
