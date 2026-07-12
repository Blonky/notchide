import Testing
import Foundation
@testable import NotchideKit

@Suite("SessionStore")
struct SessionStoreTests {

    private func event(_ name: HookEventName, session: String = "s1", cwd: String = "/tmp") -> HookEvent {
        HookEvent(sessionId: session, cwd: cwd, hookEventName: name)
    }

    @Test("ingest maps each event type to the correct lane state")
    func stateTransitions() async {
        let store = SessionStore()

        #expect(await store.ingest(event(.preToolUse)) == .needsYou)
        #expect(await store.ingest(event(.notification)) == .needsYou)
        #expect(await store.ingest(event(.postToolUse)) == .flowing)
        #expect(await store.ingest(event(.userPromptSubmit)) == .flowing)
        #expect(await store.ingest(event(.sessionStart)) == .flowing)
        #expect(await store.ingest(event(.stop)) == .done)
        #expect(await store.ingest(event(.subagentStop)) == .done)
    }

    @Test("unclassifiable events yield the error state")
    func unknownEventIsError() async {
        let store = SessionStore()
        let unknown = HookEvent(sessionId: "s1", cwd: "/tmp", hookEventName: nil, rawHookEventName: "Mystery")
        #expect(await store.ingest(unknown) == .error)
    }

    @Test("ingest records the last command for tool events")
    func recordsLastCommand() async {
        let store = SessionStore()
        let e = HookEvent(
            sessionId: "s1",
            cwd: "/tmp",
            hookEventName: .preToolUse,
            toolName: "Bash",
            toolInput: .object(["command": .string("make test")])
        )
        _ = await store.ingest(e)
        let lane = await store.mostUrgent()
        #expect(lane?.lastCommand == "make test")
        #expect(lane?.lastEvent == "PreToolUse")
    }

    @Test("mostUrgent prefers needsYou over flowing across sessions")
    func mostUrgentPrioritizes() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let store = SessionStore(now: clock.now)

        _ = await store.ingest(event(.preToolUse, session: "needs"))      // needsYou
        clock.advance(1)
        _ = await store.ingest(event(.postToolUse, session: "flowing"))   // flowing, but newer

        let urgent = await store.mostUrgent()
        #expect(urgent?.id == "needs")
        #expect(urgent?.state == .needsYou)
    }

    @Test("mostUrgent returns nil when empty")
    func mostUrgentEmpty() async {
        let store = SessionStore()
        #expect(await store.mostUrgent() == nil)
    }

    @Test("snapshots stream yields updates on ingest")
    func snapshotStream() async {
        let store = SessionStore()
        var iterator = await store.snapshots().makeAsyncIterator()

        // First value is the initial (empty) snapshot.
        let initial = await iterator.next()
        #expect(initial?.isEmpty == true)

        _ = await store.ingest(event(.preToolUse, session: "s1"))
        let next = await iterator.next()
        #expect(next?.count == 1)
        #expect(next?.first?.state == .needsYou)
    }
}

/// A thread-safe mutable clock for deterministic timestamps in tests.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { self.current = start }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock(); defer { lock.unlock() }
            return current
        }
    }
}
