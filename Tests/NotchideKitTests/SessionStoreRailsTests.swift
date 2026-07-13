import Testing
import Foundation
@testable import NotchideKit

/// Rail 4: SessionStore snapshot persistence, liveness TTL, and gate abandon.
@Suite("SessionStore rail 4: persistence, TTL, abandon", .serialized)
struct SessionStoreRailsTests {

    private let provider = ProviderID("sh.test")

    private func key(_ session: String, cwd: String = "/tmp") -> SessionKey {
        SessionKey(provider: provider, agentSessionID: session, cwd: cwd)
    }

    private func event(
        _ kind: AgentEventKind,
        session: String = "s1",
        cwd: String = "/tmp",
        command: String? = nil,
        decision: DecisionRequest? = nil
    ) -> AgentEvent {
        AgentEvent(
            providerID: provider,
            sessionKey: key(session, cwd: cwd),
            kind: kind,
            command: command,
            decision: decision
        )
    }

    private func tempFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nh-lanes-\(UUID().uuidString.prefix(8)).json")
    }

    // MARK: - (b) Persistence

    @Test("persist then restore into a fresh store yields identical lanes")
    func persistRoundTrip() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        // Integer-second clock so timestamps round-trip through JSON exactly.
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let store = SessionStore(now: clock.now, persistenceURL: url)
        await store.register(provider, decisionCapability: .blocking)

        _ = await store.ingest(event(
            .needsDecision, session: "a", command: "make",
            decision: DecisionRequest(id: UUID(), prompt: "make")))
        clock.advance(1)
        _ = await store.ingest(event(.progress, session: "b"))

        let before = await store.currentLanes()
        #expect(before.count == 2)
        try await store.persist()

        let reloaded = SessionStore(now: clock.now, persistenceURL: url)
        await reloaded.restore()
        let after = await reloaded.currentLanes()
        #expect(after == before)
    }

    @Test("persisted snapshot is written owner-only (0600)")
    func persistIsOwnerOnly() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SessionStore(persistenceURL: url)
        _ = await store.ingest(event(.progress))
        try await store.persist()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value
        #expect(perms == Int16(0o600))
    }

    @Test("restore from a missing snapshot is a safe no-op (store stays empty)")
    func restoreMissingIsNoOp() async {
        let store = SessionStore(persistenceURL: tempFile())
        await store.restore()
        #expect(await store.currentLanes().isEmpty)
    }

    @Test("restore from a corrupt snapshot is a safe no-op")
    func restoreCorruptIsNoOp() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ not valid json".utf8).write(to: url)

        let store = SessionStore(persistenceURL: url)
        await store.restore()
        #expect(await store.currentLanes().isEmpty)
    }

    // MARK: - (a) Gate abandon

    @Test("abandonGate flips a needsYou lane to flowing and clears its pending decision")
    func abandonFlipsNeedsYouOut() async {
        let store = SessionStore()
        await store.register(provider, decisionCapability: .blocking)
        _ = await store.ingest(event(
            .needsDecision, session: "g", command: "rm -rf build/",
            decision: DecisionRequest(prompt: "rm -rf build/")))

        let k = key("g")
        var lane = await store.currentLanes().first { $0.id == k }
        #expect(lane?.state == .needsYou)
        #expect(lane?.pendingDecision != nil)

        let result = await store.abandonGate(for: k)
        #expect(result == .flowing)

        lane = await store.currentLanes().first { $0.id == k }
        #expect(lane?.state == .flowing)
        #expect(lane?.pendingDecision == nil)
        #expect(lane?.showsDecisionButtons == false)

        // Abandoning an untracked lane is a nil no-op.
        #expect(await store.abandonGate(for: key("nope")) == nil)
    }

    // MARK: - Observe-only enrichment (OTLP side-channel)

    @Test("enrich drops an event for an untracked session — it never opens a lane")
    func enrichNeverOpensLane() async {
        let store = SessionStore()
        // No prior ingest for this session: nothing to enrich.
        #expect(await store.enrich(with: event(.progress, session: "ghost")) == nil)
        #expect(await store.currentLanes().isEmpty)
    }

    @Test("enrich merges detail into an existing lane without changing its lifecycle state")
    func enrichMergesDetailPreservingState() async {
        let store = SessionStore()
        await store.register(provider, decisionCapability: .notifyOnly)
        _ = await store.ingest(event(.started, session: "s", command: "build"))
        let k = key("s")
        #expect(await store.currentLanes().first { $0.id == k }?.state == .flowing)

        // An OTLP progress enrichment carrying a newer command.
        let result = await store.enrich(with: event(.progress, session: "s", command: "compile Foo.swift"))
        #expect(result == .flowing) // state unchanged

        let lane = await store.currentLanes().first { $0.id == k }
        #expect(lane?.state == .flowing)
        #expect(lane?.lastCommand == "compile Foo.swift")
        #expect(lane?.lastEvent == AgentEventKind.progress.rawValue)
    }

    @Test("enrich never clobbers a live gate: a needsYou lane keeps its state and pending decision")
    func enrichPreservesLiveGate() async {
        let store = SessionStore()
        await store.register(provider, decisionCapability: .blocking)
        _ = await store.ingest(event(
            .needsDecision, session: "g", command: "rm -rf build/",
            decision: DecisionRequest(prompt: "rm -rf build/")))
        let k = key("g")
        #expect(await store.currentLanes().first { $0.id == k }?.state == .needsYou)

        // A concurrent OTLP progress event must NOT flip the gate back to flowing
        // or drop the pending decision.
        _ = await store.enrich(with: event(.progress, session: "g"))
        let lane = await store.currentLanes().first { $0.id == k }
        #expect(lane?.state == .needsYou)
        #expect(lane?.pendingDecision != nil)
        #expect(lane?.showsDecisionButtons == true)
    }

    @Test("enrich refreshes liveness on an existing lane")
    func enrichRefreshesLiveness() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 50_000))
        let store = SessionStore(now: clock.now, livenessTTL: 30)
        _ = await store.ingest(event(.progress, session: "s"))
        let k = key("s")

        clock.advance(31) // lane is now stale by event time
        #expect(await store.liveness(for: k) == .stale)

        // An OTLP enrichment IS a real liveness signal, so it refreshes the TTL.
        _ = await store.enrich(with: event(.progress, session: "s"))
        #expect(await store.liveness(for: k) == .live)
    }

    // MARK: - (c) Liveness TTL

    @Test("a lane with no event within the TTL reports stale; a fresh lane reports live")
    func ttlStaleness() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 10_000))
        let store = SessionStore(now: clock.now, livenessTTL: 30)

        _ = await store.ingest(event(.progress, session: "live"))
        let k = key("live")
        #expect(await store.liveness(for: k) == .live)
        #expect(await store.isStale(for: k) == false)

        clock.advance(31) // past the 30s TTL, with no new event
        #expect(await store.liveness(for: k) == .stale)
        #expect(await store.isStale(for: k) == true)

        // A fresh event refreshes liveness back to live.
        _ = await store.ingest(event(.progress, session: "live"))
        #expect(await store.liveness(for: k) == .live)

        // An untracked lane is unknown (neither live nor stale).
        #expect(await store.liveness(for: key("ghost")) == .unknown)
        #expect(await store.isStale(for: key("ghost")) == false)
    }

    @Test("an abandoned gate does not refresh liveness (lastEventAt is untouched)")
    func abandonDoesNotRefreshLiveness() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 20_000))
        let store = SessionStore(now: clock.now, livenessTTL: 30)
        await store.register(provider, decisionCapability: .blocking)
        _ = await store.ingest(event(
            .needsDecision, session: "g",
            decision: DecisionRequest(prompt: "gate")))

        clock.advance(40) // lane is already stale by event time
        _ = await store.abandonGate(for: key("g"))
        // Abandon bumped updatedAt but NOT lastEventAt, so the lane stays stale.
        #expect(await store.liveness(for: key("g")) == .stale)
    }
}
