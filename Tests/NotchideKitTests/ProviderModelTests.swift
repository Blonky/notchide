import Testing
import Foundation
@testable import NotchideKit

/// An in-test provider that replays a fixed set of events, for exercising the
/// registry fan-in.
private struct FakeProvider: AgentProvider {
    static let providerID = ProviderID("sh.fake")
    let descriptor: ProviderDescriptor
    let stored: [AgentEvent]

    func events() -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            for event in stored { continuation.yield(event) }
            continuation.finish()
        }
    }
    func resolve(_ decision: AgentDecision) async {}
}

@Suite("Provider model: namespacing, capabilities, registry")
struct ProviderModelTests {

    private func lane(_ store: SessionStore, provider: ProviderID) async -> Lane? {
        await store.currentLanes().first { $0.providerID == provider }
    }

    /// Polls the store until a lane appears (fan-in is asynchronous).
    private func waitForLane(_ store: SessionStore) async -> Lane? {
        for _ in 0..<200 {
            if let lane = await store.mostUrgent() { return lane }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        return nil
    }

    // MARK: - SessionKey namespacing

    @Test("two providers with the same agentSessionID never cross-wire")
    func sessionKeyNamespacing() async {
        let store = SessionStore()
        let a = ProviderID("sh.a")
        let b = ProviderID("sh.b")

        _ = await store.ingest(AgentEvent(
            providerID: a,
            sessionKey: SessionKey(provider: a, agentSessionID: "shared", cwd: "/tmp"),
            kind: .progress))
        _ = await store.ingest(AgentEvent(
            providerID: b,
            sessionKey: SessionKey(provider: b, agentSessionID: "shared", cwd: "/tmp"),
            kind: .needsDecision))

        let lanes = await store.currentLanes()
        #expect(lanes.count == 2)
        #expect(await lane(store, provider: a)?.state == .flowing)
        #expect(await lane(store, provider: b)?.state == .needsYou)
    }

    // MARK: - notify-only cannot escalate (SessionStore level)

    @Test("a notify-only provider cannot escalate to needsYou or show decision buttons")
    func notifyOnlyCannotEscalate() async {
        let store = SessionStore()
        let notifier = ProviderID("sh.notify")
        await store.register(notifier, decisionCapability: .notifyOnly)

        let state = await store.ingest(AgentEvent(
            providerID: notifier,
            sessionKey: SessionKey(provider: notifier, agentSessionID: "s", cwd: "/tmp"),
            kind: .needsDecision,
            decision: DecisionRequest(prompt: "please?")))

        #expect(state != .needsYou)
        #expect(state == .flowing)
        let lane = await lane(store, provider: notifier)
        #expect(lane?.showsDecisionButtons == false)
        #expect(lane?.pendingDecision == nil)
    }

    @Test("a blocking provider does reach needsYou with decision buttons (contrast)")
    func blockingProviderEscalates() async {
        let store = SessionStore()
        let gate = ProviderID("sh.gate")
        await store.register(gate, decisionCapability: .blocking)

        let state = await store.ingest(AgentEvent(
            providerID: gate,
            sessionKey: SessionKey(provider: gate, agentSessionID: "s", cwd: "/tmp"),
            kind: .needsDecision,
            decision: DecisionRequest(prompt: "please?")))

        #expect(state == .needsYou)
        let lane = await lane(store, provider: gate)
        #expect(lane?.showsDecisionButtons == true)
    }

    // MARK: - ProviderRegistry.register + fanIn

    @Test("registry register + fanIn delivers a provider's events into the store")
    func registryFanInDelivers() async {
        let store = SessionStore()
        let registry = ProviderRegistry()
        let id = ProviderID("sh.fake")
        let event = AgentEvent(
            providerID: id,
            sessionKey: SessionKey(provider: id, agentSessionID: "s", cwd: "/tmp"),
            kind: .needsDecision)
        let provider = FakeProvider(
            descriptor: ProviderDescriptor(
                id: id, displayName: "Fake",
                capabilities: [.observe, .gate], decisionCapability: .blocking),
            stored: [event])

        await registry.register(provider)
        await registry.fanIn(into: store)

        let lane = await waitForLane(store)
        #expect(lane?.providerID == id)
        #expect(lane?.state == .needsYou)
    }

    @Test("fanIn registers each provider's decision capability (notify-only stays flowing)")
    func fanInRegistersCapability() async {
        let store = SessionStore()
        let registry = ProviderRegistry()
        let id = ProviderID("sh.fake")
        let event = AgentEvent(
            providerID: id,
            sessionKey: SessionKey(provider: id, agentSessionID: "s", cwd: "/tmp"),
            kind: .needsDecision,
            decision: DecisionRequest(prompt: "x"))
        let provider = FakeProvider(
            descriptor: ProviderDescriptor(
                id: id, displayName: "Fake",
                capabilities: [.observe], decisionCapability: .notifyOnly),
            stored: [event])

        await registry.register(provider)
        await registry.fanIn(into: store)

        let lane = await waitForLane(store)
        // Because fanIn registered notifyOnly, the needsDecision is clamped.
        #expect(lane?.state == .flowing)
        #expect(lane?.showsDecisionButtons == false)
    }

    // MARK: - Manifest loading (minimal TOML / JSON)

    @Test("loadManifests parses a TOML provider manifest into a descriptor")
    func loadsTOMLManifest() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("providers-\(UUID().uuidString.prefix(8))")
        let sub = root.appendingPathComponent("example")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let toml = """
        # example provider manifest
        id = "sh.example"
        displayName = "Example Agent"
        capabilities = ["observe"]
        decisionCapability = "notifyOnly"
        """
        try Data(toml.utf8).write(to: sub.appendingPathComponent("provider.toml"))

        let registry = ProviderRegistry()
        await registry.loadManifests(from: root)
        let descriptors = await registry.descriptors()

        let example = descriptors.first { $0.id == ProviderID("sh.example") }
        #expect(example != nil)
        #expect(example?.displayName == "Example Agent")
        #expect(example?.capabilities == [.observe])
        #expect(example?.decisionCapability == .notifyOnly)
    }

    @Test("loadManifests accepts a JSON provider manifest and derives capability from gate")
    func loadsJSONManifest() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("providers-\(UUID().uuidString.prefix(8))")
        let sub = root.appendingPathComponent("gated")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let json = """
        {"id": "sh.gated", "displayName": "Gated", "capabilities": ["observe", "gate"]}
        """
        try Data(json.utf8).write(to: sub.appendingPathComponent("provider.json"))

        let registry = ProviderRegistry()
        await registry.loadManifests(from: root)
        let descriptors = await registry.descriptors()

        let gated = descriptors.first { $0.id == ProviderID("sh.gated") }
        #expect(gated?.capabilities == [.observe, .gate])
        // Derived from the presence of `gate` since no explicit decisionCapability.
        #expect(gated?.decisionCapability == .blocking)
    }

    @Test("loadManifests on a missing directory is a no-op")
    func loadManifestsMissingDirectory() async {
        let registry = ProviderRegistry()
        await registry.loadManifests(from: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(await registry.descriptors().isEmpty)
    }
}
