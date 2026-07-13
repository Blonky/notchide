import Testing
import Foundation
@testable import NotchideKit

/// Blocks on a semaphore from a synchronous context. Wrapping the call lets an
/// async handler block a connection thread without tripping the "wait() is
/// unavailable from asynchronous contexts" diagnostic (the handler runs off the
/// cooperative pool via `runBlocking`, so a bounded block here is intentional).
private func semaphoreWait(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}

@Suite("IPC round-trip", .serialized)
struct IPCRoundTripTests {

    private let provider = ProviderID("sh.claude")

    private var handshake: AAPHandshake {
        AAPHandshake(providerID: provider, capabilities: [.observe, .gate])
    }

    private func tempSocketPath() -> String {
        NSTemporaryDirectory() + "nh-\(UUID().uuidString.prefix(8)).sock"
    }

    private func gateEnvelope(wantsDecision: Bool, command: String = "rm -rf build/") -> AgentEnvelope {
        let id = UUID()
        let event = AgentEvent(
            providerID: provider,
            sessionKey: SessionKey(provider: provider, agentSessionID: "sess", cwd: "/tmp"),
            kind: .needsDecision,
            command: command,
            decision: DecisionRequest(id: id, prompt: command)
        )
        return AgentEnvelope(id: id, event: event, wantsDecision: wantsDecision)
    }

    @Test("client receives the decision returned by the server handler")
    func endToEndDeny() throws {
        let path = tempSocketPath()
        let server = UnixSocketServer(socketPath: path) { envelope, _ in
            AgentDecision(id: envelope.id, verdict: .deny, reason: "blocked in test")
        }
        try server.start()
        defer { server.stop() }

        let envelope = gateEnvelope(wantsDecision: true)
        let decision = try UnixSocketClient.send(
            envelope, handshake: handshake, to: path, awaitDecision: true, timeout: 5.0
        )

        let received = try #require(decision)
        #expect(received.verdict == .deny)
        #expect(received.reason == "blocked in test")
        #expect(received.id == envelope.id)
    }

    @Test("client returns nil within the timeout when the server never responds")
    func clientTimeout() throws {
        let path = tempSocketPath()
        // Handler returns nil → server writes nothing → client must time out.
        let server = UnixSocketServer(socketPath: path) { _, _ in nil }
        try server.start()
        defer { server.stop() }

        let start = Date()
        let decision = try UnixSocketClient.send(
            gateEnvelope(wantsDecision: true), handshake: handshake,
            to: path, awaitDecision: true, timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(decision == nil)
        #expect(elapsed >= 0.4)   // waited roughly the timeout
        #expect(elapsed < 3.0)    // but returned promptly after it
    }

    @Test("fire-and-forget delivers the envelope without awaiting a decision")
    func fireAndForget() throws {
        let path = tempSocketPath()
        let box = UncheckedBox<AgentEnvelope?>(nil)
        let semaphore = DispatchSemaphore(value: 0)

        let server = UnixSocketServer(socketPath: path) { envelope, _ in
            box.value = envelope
            semaphore.signal()
            return nil
        }
        try server.start()
        defer { server.stop() }

        let event = AgentEvent(
            providerID: provider,
            sessionKey: SessionKey(provider: provider, agentSessionID: "s", cwd: "/tmp"),
            kind: .notified,
            title: "hi"
        )
        let envelope = AgentEnvelope(event: event, wantsDecision: false)
        let result = try UnixSocketClient.send(
            envelope, handshake: handshake, to: path, awaitDecision: false, timeout: 2.0
        )
        #expect(result == nil)

        // The server should still have received and handled the envelope.
        let delivered = semaphore.wait(timeout: .now() + 3.0)
        #expect(delivered == .success)
        #expect(box.value?.event.title == "hi")
    }

    // MARK: - ActuateFrame wire shape + framing

    private func actuateKey() -> SessionKey {
        SessionKey(provider: provider, agentSessionID: "sess", cwd: "/tmp")
    }

    @Test("ActuateFrame (prompt) round-trips and carries its text")
    func actuatePromptRoundTrip() throws {
        let frame = ActuateFrame(sessionKey: actuateKey(), kind: .prompt, text: "run the tests")
        let data = try NDJSON.encode(frame)
        let decoded = try JSONDecoder().decode(ActuateFrame.self, from: data)
        #expect(decoded == frame)
        #expect(decoded.text == "run the tests")

        // Wire shape: a top-level `actuate` wrapper with a nested sessionKey.
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try #require(object["actuate"] as? [String: Any])
        #expect(body["kind"] as? String == "prompt")
        #expect(body["text"] as? String == "run the tests")
        let key = try #require(body["sessionKey"] as? [String: Any])
        #expect(key["provider"] as? String == provider.raw)
        #expect(key["agentSessionID"] as? String == "sess")
        #expect(key["cwd"] as? String == "/tmp")
    }

    @Test("ActuateFrame (interrupt) round-trips and omits text on the wire")
    func actuateInterruptRoundTrip() throws {
        // Even if a caller passes text, interrupt normalizes it away.
        let frame = ActuateFrame(sessionKey: actuateKey(), kind: .interrupt, text: "ignored")
        #expect(frame.text == nil)
        let data = try NDJSON.encode(frame)
        let decoded = try JSONDecoder().decode(ActuateFrame.self, from: data)
        #expect(decoded == frame)
        #expect(decoded.text == nil)

        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try #require(object["actuate"] as? [String: Any])
        #expect(body["kind"] as? String == "interrupt")
        #expect(body["text"] == nil, "interrupt must not carry a text key")
    }

    @Test("ActuateFrame decodes from the documented literal wire JSON")
    func actuateDecodesLiteral() throws {
        let json = """
        {"actuate":{"sessionKey":{"provider":"sh.claude","agentSessionID":"s","cwd":"/tmp"},"kind":"prompt","text":"hi there world"}}
        """
        let frame = try JSONDecoder().decode(ActuateFrame.self, from: Data(json.utf8))
        #expect(frame.kind == .prompt)
        #expect(frame.text == "hi there world")
        #expect(frame.sessionKey == SessionKey(provider: ProviderID("sh.claude"), agentSessionID: "s", cwd: "/tmp"))
    }

    @Test("AAPFrame.classify distinguishes handshake / envelope / decision / actuate / unknown")
    func frameClassification() throws {
        let handshake = AAPHandshake(providerID: provider, capabilities: [.observe, .gate, .actuate])
        let envelope = gateEnvelope(wantsDecision: true)
        let decision = AgentDecision(id: envelope.id, verdict: .allow, reason: "ok")
        let actuate = ActuateFrame(sessionKey: actuateKey(), kind: .interrupt)

        if case .handshake(let value) = AAPFrame.classify(line: try NDJSON.encode(handshake)) {
            #expect(value == handshake)
        } else { Issue.record("expected .handshake") }

        if case .envelope(let value) = AAPFrame.classify(line: try NDJSON.encode(envelope)) {
            #expect(value == envelope)
        } else { Issue.record("expected .envelope") }

        if case .decision(let value) = AAPFrame.classify(line: try NDJSON.encode(decision)) {
            #expect(value == decision)
        } else { Issue.record("expected .decision") }

        if case .actuate(let value) = AAPFrame.classify(line: try NDJSON.encode(actuate)) {
            #expect(value == actuate)
        } else { Issue.record("expected .actuate") }

        #expect(AAPFrame.classify(line: Data("not json".utf8)) == .unknown)
        #expect(AAPFrame.classify(line: Data(#"{"weird":true}"#.utf8)) == .unknown)
    }

    @Test("connect to a missing socket throws (the adapter treats this as fail-open)")
    func connectFailure() {
        let path = tempSocketPath() // nothing listening
        #expect(throws: (any Error).self) {
            _ = try UnixSocketClient.send(
                gateEnvelope(wantsDecision: true), handshake: handshake,
                to: path, awaitDecision: true, timeout: 0.5
            )
        }
    }

    @Test("a handler blocked on one connection does not stall a second connection")
    func blockedHandlerDoesNotStallOtherConnections() throws {
        let path = tempSocketPath()
        let release = DispatchSemaphore(value: 0)      // gates the slow handler
        let slowInFlight = DispatchSemaphore(value: 0)  // slow handler has begun

        let server = UnixSocketServer(socketPath: path) { envelope, _ in
            if envelope.event.command == "SlowTool" {
                slowInFlight.signal()
                semaphoreWait(release) // block this connection until the test releases it
                return AgentDecision(id: envelope.id, verdict: .deny, reason: "slow")
            }
            return AgentDecision(id: envelope.id, verdict: .allow, reason: "fast")
        }
        try server.start()
        defer { server.stop() }

        // Fire the slow request on a background thread; it will block in-handler.
        let slowResult = UncheckedBox<AgentDecision?>(nil)
        let slowDone = DispatchSemaphore(value: 0)
        let handshakeValue = handshake
        Thread.detachNewThread {
            slowResult.value = try? UnixSocketClient.send(
                self.gateEnvelope(wantsDecision: true, command: "SlowTool"),
                handshake: handshakeValue, to: path, awaitDecision: true, timeout: 5.0)
            slowDone.signal()
        }

        // Wait until the slow handler is actually running (and blocked).
        #expect(slowInFlight.wait(timeout: .now() + 3.0) == .success)

        // A second connection must be served promptly despite the first being stuck.
        let start = Date()
        let fast = try UnixSocketClient.send(
            gateEnvelope(wantsDecision: true, command: "FastTool"),
            handshake: handshakeValue, to: path, awaitDecision: true, timeout: 3.0)
        let elapsed = Date().timeIntervalSince(start)

        #expect(fast?.verdict == .allow)
        #expect(elapsed < 2.0, "second connection stalled behind the blocked one")

        // Release the slow handler; it should now complete with its own decision.
        release.signal()
        #expect(slowDone.wait(timeout: .now() + 3.0) == .success)
        #expect(slowResult.value?.verdict == .deny)
    }
}
