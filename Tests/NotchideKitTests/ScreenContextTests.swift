import Testing
import Foundation
@testable import NotchideKit

@Suite("Screen-context capabilities and broker")
struct ScreenContextTests {

    // MARK: - Capability

    @Test("the two new capabilities decode from their raw strings")
    func capabilityDecodesNewCases() throws {
        let observe = try JSONDecoder().decode(Capability.self, from: Data("\"observeScreen\"".utf8))
        let control = try JSONDecoder().decode(Capability.self, from: Data("\"controlScreen\"".utf8))
        #expect(observe == .observeScreen)
        #expect(control == .controlScreen)
    }

    @Test("CaseIterable count reflects the added capabilities")
    func capabilityCaseCount() {
        #expect(Capability.allCases.count == 5)
        #expect(Capability.allCases.contains(.observeScreen))
        #expect(Capability.allCases.contains(.controlScreen))
    }

    @Test("DecisionCapability stays derived from .gate only")
    func decisionCapabilityIgnoresScreenCaps() {
        // Advertising screen capabilities does NOT make a provider blocking.
        #expect(DecisionCapability(capabilities: [.observeScreen, .controlScreen]) == .notifyOnly)
        #expect(DecisionCapability(capabilities: [.gate, .controlScreen]) == .blocking)
    }

    // MARK: - ScreenContextBroker

    @Test("grant, access, and revoke")
    func grantAccessRevoke() async {
        let broker = ScreenContextBroker()
        let id = UUID()

        // Default is .none for an unseen workspace.
        #expect(await broker.access(for: id) == .none)
        let canObserveDefault = await broker.canObserve(id)
        #expect(!canObserveDefault)

        await broker.grant(.observe, for: id)
        #expect(await broker.access(for: id) == .observe)
        #expect(await broker.canObserve(id))

        await broker.grant(.control, for: id)
        #expect(await broker.access(for: id) == .control)

        await broker.revoke(for: id)
        #expect(await broker.access(for: id) == .none)
        let canObserveAfterRevoke = await broker.canObserve(id)
        #expect(!canObserveAfterRevoke)
    }

    @Test("authorizeControl is true ONLY for (.control, .click)")
    func authorizeControlHappyPath() async {
        let broker = ScreenContextBroker()
        let id = UUID()
        await broker.grant(.control, for: id)
        #expect(await broker.authorizeControl(id, origin: .click))
    }

    @Test("voice is ALWAYS refused control, even with a full .control grant")
    func voiceRefusalInvariant() async {
        let broker = ScreenContextBroker()
        let id = UUID()
        await broker.grant(.control, for: id)
        // The load-bearing safety invariant: voice may never drive the pointer.
        let voiceAuthorized = await broker.authorizeControl(id, origin: .voice)
        #expect(!voiceAuthorized)
    }

    @Test("an .observe grant cannot authorize control, even by click")
    func observeCannotControl() async {
        let broker = ScreenContextBroker()
        let id = UUID()
        await broker.grant(.observe, for: id)
        let byClick = await broker.authorizeControl(id, origin: .click)
        let byVoice = await broker.authorizeControl(id, origin: .voice)
        #expect(!byClick)
        #expect(!byVoice)
    }

    @Test("no grant refuses control by any origin")
    func noGrantRefusesControl() async {
        let broker = ScreenContextBroker()
        let id = UUID()
        let byClick = await broker.authorizeControl(id, origin: .click)
        let byVoice = await broker.authorizeControl(id, origin: .voice)
        #expect(!byClick)
        #expect(!byVoice)
    }

    @Test("ScreenContextGrant round-trips through Codable")
    func grantCodableRoundTrip() throws {
        let grant = ScreenContextGrant(workspaceID: UUID(), access: .control)
        let data = try JSONEncoder().encode(grant)
        let decoded = try JSONDecoder().decode(ScreenContextGrant.self, from: data)
        #expect(decoded == grant)
    }
}
