import Testing
import Foundation
@testable import NotchideKit

/// Waits on a semaphore from a synchronous helper so an `async` test can block
/// bounded on it (`DispatchSemaphore.wait` is unavailable directly from async).
private func waitFor(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
    semaphore.wait(timeout: .now() + seconds) == .success
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
}
