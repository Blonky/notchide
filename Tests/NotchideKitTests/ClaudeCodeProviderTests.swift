import Testing
import Foundation
@testable import NotchideKit

@Suite("ClaudeCodeProvider translation")
struct ClaudeCodeProviderTests {

    @Test("descriptor advertises observe + gate and is blocking")
    func descriptor() {
        let descriptor = ClaudeCodeProvider.descriptor
        #expect(descriptor.id == ProviderID("sh.claude"))
        #expect(descriptor.capabilities == [.observe, .gate])
        #expect(descriptor.decisionCapability == .blocking)
    }

    @Test("maps Claude hook event names to AAP kinds")
    func kindMapping() {
        #expect(ClaudeCodeProvider.kind(for: .preToolUse) == .needsDecision)
        #expect(ClaudeCodeProvider.kind(for: .notification) == .notified)
        #expect(ClaudeCodeProvider.kind(for: .stop) == .finished)
        // A subagent finishing is progress toward the parent turn, not a finish.
        #expect(ClaudeCodeProvider.kind(for: .subagentStop) == .progress)
        #expect(ClaudeCodeProvider.kind(for: .postToolUse) == .progress)
        #expect(ClaudeCodeProvider.kind(for: .userPromptSubmit) == .progress)
        #expect(ClaudeCodeProvider.kind(for: .sessionStart) == .started)
        #expect(ClaudeCodeProvider.kind(for: nil) == .errored)
    }

    @Test("a PreToolUse event becomes a needsDecision AgentEvent carrying a DecisionRequest")
    func preToolUseTranslation() {
        let hook = HookEvent(
            sessionId: "abc",
            cwd: "/work",
            hookEventName: .preToolUse,
            toolName: "Bash",
            toolInput: .object(["command": .string("rm -rf build/")]))
        let correlationID = UUID()
        let event = ClaudeCodeProvider.agentEvent(from: hook, correlationID: correlationID)

        #expect(event.providerID == ProviderID("sh.claude"))
        #expect(event.sessionKey == SessionKey(provider: ProviderID("sh.claude"), agentSessionID: "abc", cwd: "/work"))
        #expect(event.kind == .needsDecision)
        #expect(event.command == "rm -rf build/")
        #expect(event.decision?.id == correlationID)
        #expect(event.decision?.prompt == "rm -rf build/")
        // The original Claude payload is preserved losslessly in `payload`.
        #expect(event.payload["hook_event_name"]?.stringValue == "PreToolUse")
        #expect(event.payload["tool_input"]?["command"]?.stringValue == "rm -rf build/")
    }

    @Test("a non-decision event carries no DecisionRequest")
    func notificationTranslation() {
        let hook = HookEvent(
            sessionId: "abc",
            cwd: "/work",
            hookEventName: .notification,
            message: "waiting for input")
        let event = ClaudeCodeProvider.agentEvent(from: hook)
        #expect(event.kind == .notified)
        #expect(event.decision == nil)
        #expect(event.title == "waiting for input")
    }

    @Test("kindOverride forces the AAP kind (mirrors the CLI's positional override)")
    func kindOverride() {
        let hook = HookEvent(sessionId: "abc", cwd: "/work", hookEventName: .notification, message: "hi")
        let event = ClaudeCodeProvider.agentEvent(from: hook, kindOverride: .needsDecision)
        #expect(event.kind == .needsDecision)
        #expect(event.decision != nil)
    }

    @Test("an AgentEvent round-trips through the wire encoding")
    func wireRoundTrip() throws {
        let hook = HookEvent(
            sessionId: "abc",
            cwd: "/work",
            hookEventName: .preToolUse,
            toolName: "Bash",
            toolInput: .object(["command": .string("ls -la")]))
        let original = ClaudeCodeProvider.agentEvent(from: hook, correlationID: UUID())

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)

        #expect(decoded.providerID == original.providerID)
        #expect(decoded.sessionKey == original.sessionKey)
        #expect(decoded.kind == original.kind)
        #expect(decoded.command == original.command)
        #expect(decoded.decision == original.decision)
        #expect(decoded.payload["tool_input"]?["command"]?.stringValue == "ls -la")
    }

    @Test("AgentEvent decoding never throws on unknown/missing fields")
    func lenientDecode() throws {
        let json = """
        {"providerID":"sh.future","agentSessionID":"s","kind":"someFutureKind","weird":{"a":[1,2]}}
        """
        let event = try JSONDecoder().decode(AgentEvent.self, from: Data(json.utf8))
        #expect(event.providerID == ProviderID("sh.future"))
        #expect(event.kind == .errored) // unknown kind degrades to errored
        #expect(event.decision == nil)

        // Fully empty object degrades gracefully rather than throwing.
        let empty = try JSONDecoder().decode(AgentEvent.self, from: Data("{}".utf8))
        #expect(empty.kind == .errored)
        #expect(empty.sessionKey.agentSessionID == "")
    }
}
