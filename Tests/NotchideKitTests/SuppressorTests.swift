import Testing
import Foundation
@testable import NotchideKit

@Suite("Suppressor truth table")
struct SuppressorTests {

    private let suppressor = Suppressor()

    private func event(_ name: HookEventName?, raw: String = "") -> HookEvent {
        HookEvent(sessionId: "s1", cwd: "/tmp", hookEventName: name, rawHookEventName: raw)
    }

    @Test("hard block + hidden + unmuted → tap")
    func hardBlockHiddenUnmuted() async {
        let context = StubFrontmostContext(visibleSessions: [])
        let result = await suppressor.shouldTap(
            event: event(.preToolUse), key: "s1", muted: false, context: context
        )
        #expect(result.tap == true)
        #expect(result.reason == "terminal not visible")
    }

    @Test("visible session → no tap")
    func visibleSuppresses() async {
        let context = StubFrontmostContext(visibleSessions: ["s1"])
        let result = await suppressor.shouldTap(
            event: event(.notification), key: "s1", muted: false, context: context
        )
        #expect(result.tap == false)
        #expect(result.reason == "already visible")
    }

    @Test("muted → no tap")
    func mutedSuppresses() async {
        let context = StubFrontmostContext(visibleSessions: [])
        let result = await suppressor.shouldTap(
            event: event(.stop), key: "s1", muted: true, context: context
        )
        #expect(result.tap == false)
        #expect(result.reason == "muted")
    }

    @Test("soft event → no tap")
    func softEventSuppresses() async {
        let context = StubFrontmostContext(visibleSessions: [])
        // PostToolUse is not a hard block.
        let result = await suppressor.shouldTap(
            event: event(.postToolUse), key: "s1", muted: false, context: context
        )
        #expect(result.tap == false)
        #expect(result.reason == "not a blocking event")
    }

    @Test("SubagentStop is not a hard block")
    func subagentStopIsSoft() async {
        let context = StubFrontmostContext(visibleSessions: [])
        let result = await suppressor.shouldTap(
            event: event(.subagentStop), key: "s1", muted: false, context: context
        )
        #expect(result.tap == false)
        #expect(result.reason == "not a blocking event")
    }

    @Test("all three hard-block events can tap when hidden + unmuted")
    func allHardBlocksTap() async {
        let context = StubFrontmostContext(visibleSessions: [])
        for name in [HookEventName.preToolUse, .notification, .stop] {
            let result = await suppressor.shouldTap(
                event: event(name), key: "s1", muted: false, context: context
            )
            #expect(result.tap == true, "\(name) should tap")
        }
    }
}
