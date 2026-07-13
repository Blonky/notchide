import Testing
import Foundation
@testable import NotchideKit

@Suite("AgentEvent artifact back-compat")
struct AgentEventArtifactTests {

    private let provider = ProviderID("sh.test")
    private func key() -> SessionKey {
        SessionKey(provider: provider, agentSessionID: "sess", cwd: "/tmp")
    }

    @Test("legacy AgentEvent JSON without an artifact key decodes with artifact == nil")
    func backCompatNoArtifactKey() throws {
        // A frame encoded before `artifact` existed: no "artifact" key at all.
        let legacy = """
        {"providerID":"sh.test","agentSessionID":"sess","cwd":"/tmp",\
        "kind":"progress","payload":{},"at":123.0}
        """
        let event = try JSONDecoder().decode(AgentEvent.self, from: Data(legacy.utf8))
        #expect(event.artifact == nil)
        #expect(event.kind == .progress)
        #expect(event.providerID == provider)
    }

    @Test("a nil artifact is omitted on encode (no stray artifact key)")
    func nilArtifactOmittedOnEncode() throws {
        let event = AgentEvent(providerID: provider, sessionKey: key(), kind: .finished)
        let data = try JSONEncoder().encode(event)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["artifact"] == nil)
        #expect(object.keys.contains("artifact") == false)
    }

    @Test("an AgentEvent carrying an artifact round-trips through Codable")
    func artifactRoundTrip() throws {
        let artifact = BuildArtifact.tests(
            TestSummary(passed: 4, failed: 1, skipped: 0, coverageDelta: -0.01, firstFailure: "testBar")
        )
        let event = AgentEvent(
            providerID: provider,
            sessionKey: key(),
            kind: .finished,
            // Exactly representable so full-struct equality survives the JSON
            // Double round-trip of `at`.
            at: Date(timeIntervalSince1970: 1000),
            artifact: artifact
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)
        #expect(decoded.artifact == artifact)
        #expect(decoded == event)
    }

    @Test("each BuildArtifact case survives an AgentEvent round-trip", arguments: [
        BuildArtifact.livePreview(url: URL(string: "http://localhost:5173")!),
        .diff(files: [DiffFileSummary(path: "x.swift", added: 1, removed: 1)]),
        .logs(text: "log body", hasErrors: false),
        .document(markdown: "# Doc"),
        .screens(before: nil, after: URL(string: "file:///a.png")!),
        .error(message: "boom", failingStep: "compile"),
    ])
    func artifactCasesSurviveEnvelope(_ artifact: BuildArtifact) throws {
        let event = AgentEvent(
            providerID: provider, sessionKey: key(), kind: .finished,
            at: Date(timeIntervalSince1970: 42), artifact: artifact
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)
        #expect(decoded.artifact == artifact)
    }
}
