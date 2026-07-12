import Testing
import Foundation
@testable import NotchideKit

@Suite("SessionStore")
struct SessionStoreTests {

    private let provider = ProviderID("sh.test")

    private func key(_ session: String, cwd: String = "/tmp") -> SessionKey {
        SessionKey(provider: provider, agentSessionID: session, cwd: cwd)
    }

    private func event(
        _ kind: AgentEventKind,
        session: String = "s1",
        cwd: String = "/tmp",
        command: String? = nil
    ) -> AgentEvent {
        AgentEvent(
            providerID: provider,
            sessionKey: key(session, cwd: cwd),
            kind: kind,
            command: command
        )
    }

    @Test("ingest maps each event kind to the correct lane state")
    func stateTransitions() async {
        let store = SessionStore()

        #expect(await store.ingest(event(.needsDecision)) == .needsYou)
        #expect(await store.ingest(event(.notified)) == .needsYou)
        #expect(await store.ingest(event(.progress)) == .flowing)
        #expect(await store.ingest(event(.started)) == .flowing)
        #expect(await store.ingest(event(.finished)) == .done)
    }

    @Test("errored events yield the error state")
    func erroredEventIsError() async {
        let store = SessionStore()
        #expect(await store.ingest(event(.errored)) == .error)
    }

    @Test("ingest records the last command and kind for tool events")
    func recordsLastCommand() async {
        let store = SessionStore()
        _ = await store.ingest(event(.needsDecision, command: "make test"))
        let lane = await store.mostUrgent()
        #expect(lane?.lastCommand == "make test")
        #expect(lane?.lastEvent == "needsDecision")
    }

    @Test("mostUrgent prefers needsYou over flowing across sessions")
    func mostUrgentPrioritizes() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let store = SessionStore(now: clock.now)

        _ = await store.ingest(event(.needsDecision, session: "needs"))   // needsYou
        clock.advance(1)
        _ = await store.ingest(event(.progress, session: "flowing"))      // flowing, newer

        let urgent = await store.mostUrgent()
        #expect(urgent?.id.agentSessionID == "needs")
        #expect(urgent?.state == .needsYou)
    }

    @Test("mostUrgent returns nil when empty")
    func mostUrgentEmpty() async {
        let store = SessionStore()
        #expect(await store.mostUrgent() == nil)
    }

    @Test("a blocking provider's needsDecision lane exposes decision buttons")
    func pendingDecisionSurfacesButtons() async {
        let store = SessionStore()
        await store.register(provider, decisionCapability: .blocking)
        let e = AgentEvent(
            providerID: provider,
            sessionKey: key("s1"),
            kind: .needsDecision,
            command: "rm -rf build/",
            decision: DecisionRequest(prompt: "rm -rf build/")
        )
        _ = await store.ingest(e)
        let lane = await store.mostUrgent()
        #expect(lane?.state == .needsYou)
        #expect(lane?.showsDecisionButtons == true)
        #expect(lane?.pendingDecision?.prompt == "rm -rf build/")
    }

    @Test("snapshots stream yields updates on ingest")
    func snapshotStream() async {
        let store = SessionStore()
        var iterator = await store.snapshots().makeAsyncIterator()

        // First value is the initial (empty) snapshot.
        let initial = await iterator.next()
        #expect(initial?.isEmpty == true)

        _ = await store.ingest(event(.needsDecision, session: "s1"))
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
