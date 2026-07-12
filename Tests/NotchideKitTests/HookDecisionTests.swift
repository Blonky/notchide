import Testing
import Foundation
@testable import NotchideKit

@Suite("HookDecision encoding")
struct HookDecisionTests {

    /// Parses the encoded decision and returns the nested `hookSpecificOutput`.
    private func encodedInner(_ decision: HookDecision) throws -> [String: Any] {
        let data = try JSONEncoder().encode(decision)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // The only top-level key must be hookSpecificOutput.
        #expect(object.keys.sorted() == ["hookSpecificOutput"])
        return try #require(object["hookSpecificOutput"] as? [String: Any])
    }

    @Test("deny encodes to the confirmed PreToolUse schema")
    func encodeDeny() throws {
        let inner = try encodedInner(
            HookDecision(permissionDecision: .deny, reason: "Destructive command blocked by hook")
        )
        #expect(inner["hookEventName"] as? String == "PreToolUse")
        #expect(inner["permissionDecision"] as? String == "deny")
        #expect(inner["permissionDecisionReason"] as? String == "Destructive command blocked by hook")
        #expect(inner.keys.sorted() == ["hookEventName", "permissionDecision", "permissionDecisionReason"])
    }

    @Test("allow encodes correctly")
    func encodeAllow() throws {
        let inner = try encodedInner(HookDecision(permissionDecision: .allow, reason: "trusted"))
        #expect(inner["hookEventName"] as? String == "PreToolUse")
        #expect(inner["permissionDecision"] as? String == "allow")
        #expect(inner["permissionDecisionReason"] as? String == "trusted")
    }

    @Test("ask encodes correctly, reason omitted when nil")
    func encodeAskNoReason() throws {
        let inner = try encodedInner(HookDecision(permissionDecision: .ask))
        #expect(inner["hookEventName"] as? String == "PreToolUse")
        #expect(inner["permissionDecision"] as? String == "ask")
        #expect(inner["permissionDecisionReason"] == nil)
        #expect(inner.keys.sorted() == ["hookEventName", "permissionDecision"])
    }

    @Test("jsonString produces valid single-line JSON that decodes back")
    func jsonStringRoundTrip() throws {
        let decision = HookDecision(permissionDecision: .deny, reason: "nope")
        let string = try decision.jsonString()
        #expect(!string.contains("\n"))

        let decoded = try JSONDecoder().decode(HookDecision.self, from: Data(string.utf8))
        #expect(decoded.permissionDecision == .deny)
        #expect(decoded.reason == "nope")
    }
}
