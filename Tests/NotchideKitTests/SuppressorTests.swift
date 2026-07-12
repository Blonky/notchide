import Testing
import Foundation
@testable import NotchideKit

@Suite("Suppressor truth table")
struct SuppressorTests {

    private let suppressor = Suppressor()
    private let provider = ProviderID("sh.test")

    private func key(_ session: String = "s1") -> SessionKey {
        SessionKey(provider: provider, agentSessionID: session, cwd: "/tmp")
    }

    @Test("hard block + hidden + unmuted → tap")
    func hardBlockHiddenUnmuted() async {
        let context = StubFrontmostContext(visibleSessions: [])
        let result = await suppressor.shouldTap(
            kind: .needsDecision, decisionCapability: .blocking,
            key: key(), muted: false, context: context
        )
        #expect(result.tap == true)
        #expect(result.reason == "terminal not visible")
    }

    @Test("visible session → no tap")
    func visibleSuppresses() async {
        let context = StubFrontmostContext(visibleSessions: [key()])
        let result = await suppressor.shouldTap(
            kind: .notified, decisionCapability: .blocking,
            key: key(), muted: false, context: context
        )
        #expect(result.tap == false)
        #expect(result.reason == "already visible")
    }

    @Test("muted → no tap")
    func mutedSuppresses() async {
        let context = StubFrontmostContext(visibleSessions: [])
        let result = await suppressor.shouldTap(
            kind: .finished, decisionCapability: .blocking,
            key: key(), muted: true, context: context
        )
        #expect(result.tap == false)
        #expect(result.reason == "muted")
    }

    @Test("soft event → no tap")
    func softEventSuppresses() async {
        let context = StubFrontmostContext(visibleSessions: [])
        // progress (e.g. PostToolUse / SubagentStop) is not a hard block.
        let result = await suppressor.shouldTap(
            kind: .progress, decisionCapability: .blocking,
            key: key(), muted: false, context: context
        )
        #expect(result.tap == false)
        #expect(result.reason == "not a blocking event")
    }

    @Test("all three hard-block kinds can tap when hidden + unmuted (blocking provider)")
    func allHardBlocksTap() async {
        let context = StubFrontmostContext(visibleSessions: [])
        for kind in [AgentEventKind.needsDecision, .notified, .finished] {
            let result = await suppressor.shouldTap(
                kind: kind, decisionCapability: .blocking,
                key: key(), muted: false, context: context
            )
            #expect(result.tap == true, "\(kind) should tap")
        }
    }

    @Test("a notify-only provider can never tap the user")
    func notifyOnlyNeverTaps() async {
        let context = StubFrontmostContext(visibleSessions: [])
        for kind in [AgentEventKind.needsDecision, .notified, .finished] {
            let result = await suppressor.shouldTap(
                kind: kind, decisionCapability: .notifyOnly,
                key: key(), muted: false, context: context
            )
            #expect(result.tap == false, "\(kind) must not tap for a notify-only provider")
            #expect(result.reason == "not a blocking event")
        }
    }
}
