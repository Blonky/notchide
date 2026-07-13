import Testing
import Foundation
@testable import NotchideKit

@Suite("BuildArtifact taxonomy")
struct BuildArtifactTests {

    // MARK: - Codable round-trip of EVERY case

    @Test("every BuildArtifact case round-trips through Codable", arguments: [
        BuildArtifact.livePreview(url: URL(string: "http://localhost:3000")!),
        .diff(files: [
            DiffFileSummary(path: "Sources/A.swift", added: 12, removed: 3),
            DiffFileSummary(path: "Sources/B.swift", added: 0, removed: 7),
        ]),
        .tests(TestSummary(passed: 103, failed: 0, skipped: 2, coverageDelta: 0.041, firstFailure: nil)),
        .tests(TestSummary(passed: 9, failed: 1, skipped: 0, coverageDelta: nil, firstFailure: "testExplodes")),
        .logs(text: "line1\nline2\nline3", hasErrors: true),
        .logs(text: "clean run", hasErrors: false),
        .document(markdown: "# Title\n\nSome **body** text."),
        .screens(before: URL(string: "file:///before.png"), after: URL(string: "file:///after.png")!),
        .screens(before: nil, after: URL(string: "file:///after.png")!),
        .error(message: "boom", failingStep: "build"),
        .error(message: "No output produced", failingStep: nil),
    ])
    func codableRoundTrip(_ artifact: BuildArtifact) throws {
        let data = try JSONEncoder().encode(artifact)
        let decoded = try JSONDecoder().decode(BuildArtifact.self, from: data)
        #expect(decoded == artifact)
    }

    // MARK: - classify fallback ladder

    private let preview = URL(string: "http://localhost:3000")!
    private var someDiff: [DiffFileSummary] {
        [DiffFileSummary(path: "a.swift", added: 2, removed: 1)]
    }

    @Test("step 1: errors beat everything, message is the last error-ish log line")
    func classifyErrorsWin() {
        let art = BuildArtifact.classify(
            previewURL: preview,
            diff: someDiff,
            tests: TestSummary(passed: 5, failed: 0, skipped: 0),
            logs: "compiling module\nfatal error: boom\ndone",
            hasErrors: true
        )
        guard case .error(let message, let step) = art else {
            Issue.record("expected .error, got \(art)")
            return
        }
        #expect(message == "fatal error: boom")
        #expect(step == nil)
    }

    @Test("step 1 requires logs: hasErrors with nil logs falls through the ladder")
    func classifyErrorsNeedLogs() {
        let art = BuildArtifact.classify(
            previewURL: preview, diff: [], tests: nil, logs: nil, hasErrors: true
        )
        #expect(art == .livePreview(url: preview))
    }

    @Test("step 2: preview beats tests")
    func classifyPreviewBeatsTests() {
        let art = BuildArtifact.classify(
            previewURL: preview,
            diff: someDiff,
            tests: TestSummary(passed: 3, failed: 0, skipped: 0),
            logs: nil,
            hasErrors: false
        )
        #expect(art == .livePreview(url: preview))
    }

    @Test("step 3: tests beat diff")
    func classifyTestsBeatDiff() {
        let art = BuildArtifact.classify(
            previewURL: nil,
            diff: someDiff,
            tests: TestSummary(passed: 1, failed: 0, skipped: 0),
            logs: "some logs",
            hasErrors: false
        )
        guard case .tests = art else {
            Issue.record("expected .tests, got \(art)")
            return
        }
    }

    @Test("step 3 guard: tests with passed+failed == 0 do not win (skips only)")
    func classifyEmptyTestsFallThrough() {
        let art = BuildArtifact.classify(
            previewURL: nil,
            diff: someDiff,
            tests: TestSummary(passed: 0, failed: 0, skipped: 4),
            logs: nil,
            hasErrors: false
        )
        guard case .diff = art else {
            Issue.record("expected .diff, got \(art)")
            return
        }
    }

    @Test("step 4: non-empty diff beats logs")
    func classifyDiffBeatsLogs() {
        let art = BuildArtifact.classify(
            previewURL: nil,
            diff: someDiff,
            tests: nil,
            logs: "some non-error output",
            hasErrors: false
        )
        guard case .diff(let files) = art else {
            Issue.record("expected .diff, got \(art)")
            return
        }
        #expect(files.count == 1)
    }

    @Test("step 5: logs when only logs are present")
    func classifyLogsOnly() {
        let art = BuildArtifact.classify(
            previewURL: nil, diff: [], tests: nil,
            logs: "just some output", hasErrors: false
        )
        #expect(art == .logs(text: "just some output", hasErrors: false))
    }

    @Test("step 6: empty everything yields the no-output error")
    func classifyEmptyEverything() {
        let art = BuildArtifact.classify(
            previewURL: nil, diff: [], tests: nil, logs: nil, hasErrors: false
        )
        #expect(art == .error(message: "No output produced", failingStep: nil))
    }
}
