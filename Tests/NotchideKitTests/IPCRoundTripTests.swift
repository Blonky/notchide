import Testing
import Foundation
@testable import NotchideKit

@Suite("IPC round-trip", .serialized)
struct IPCRoundTripTests {

    private func tempSocketPath() -> String {
        NSTemporaryDirectory() + "nh-\(UUID().uuidString.prefix(8)).sock"
    }

    private func preToolUseEnvelope(wantsDecision: Bool) -> HookEnvelope {
        let event = HookEvent(
            sessionId: "sess",
            cwd: "/tmp",
            hookEventName: .preToolUse,
            toolName: "Bash",
            toolInput: .object(["command": .string("rm -rf build/")])
        )
        return HookEnvelope(event: event, wantsDecision: wantsDecision)
    }

    @Test("client receives the decision returned by the server handler")
    func endToEndDeny() throws {
        let path = tempSocketPath()
        let server = UnixSocketServer(socketPath: path) { envelope in
            DecisionMessage(id: envelope.id, permission: .deny, reason: "blocked in test")
        }
        try server.start()
        defer { server.stop() }

        let envelope = preToolUseEnvelope(wantsDecision: true)
        let decision = try UnixSocketClient.send(
            envelope, to: path, awaitDecision: true, timeout: 5.0
        )

        let received = try #require(decision)
        #expect(received.permission == .deny)
        #expect(received.reason == "blocked in test")
        #expect(received.id == envelope.id)
    }

    @Test("client returns nil within the timeout when the server never responds")
    func clientTimeout() throws {
        let path = tempSocketPath()
        // Handler returns nil → server writes nothing → client must time out.
        let server = UnixSocketServer(socketPath: path) { _ in nil }
        try server.start()
        defer { server.stop() }

        let start = Date()
        let envelope = preToolUseEnvelope(wantsDecision: true)
        let decision = try UnixSocketClient.send(
            envelope, to: path, awaitDecision: true, timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(decision == nil)
        #expect(elapsed >= 0.4)   // waited roughly the timeout
        #expect(elapsed < 3.0)    // but returned promptly after it
    }

    @Test("fire-and-forget delivers the envelope without awaiting a decision")
    func fireAndForget() throws {
        let path = tempSocketPath()
        let box = UncheckedBox<HookEnvelope?>(nil)
        let semaphore = DispatchSemaphore(value: 0)

        let server = UnixSocketServer(socketPath: path) { envelope in
            box.value = envelope
            semaphore.signal()
            return nil
        }
        try server.start()
        defer { server.stop() }

        let event = HookEvent(sessionId: "s", cwd: "/tmp", hookEventName: .notification, message: "hi")
        let envelope = HookEnvelope(event: event, wantsDecision: false)
        let result = try UnixSocketClient.send(
            envelope, to: path, awaitDecision: false, timeout: 2.0
        )
        #expect(result == nil)

        // The server should still have received and handled the envelope.
        let delivered = semaphore.wait(timeout: .now() + 3.0)
        #expect(delivered == .success)
        #expect(box.value?.event.message == "hi")
    }

    @Test("connect to a missing socket throws (CLI treats this as fail-open)")
    func connectFailure() {
        let path = tempSocketPath() // nothing listening
        let envelope = preToolUseEnvelope(wantsDecision: true)
        #expect(throws: (any Error).self) {
            _ = try UnixSocketClient.send(envelope, to: path, awaitDecision: true, timeout: 0.5)
        }
    }
}
