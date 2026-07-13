import Foundation

/// A per-file line-count summary of a diff. The unit the `.diff` artifact renders.
public struct DiffFileSummary: Sendable, Codable, Equatable, Hashable {
    public let path: String
    public let added: Int
    public let removed: Int

    public init(path: String, added: Int, removed: Int) {
        self.path = path
        self.added = added
        self.removed = removed
    }
}

/// The outcome of a test run. `coverageDelta` and `firstFailure` are optional
/// enrichments a provider may or may not supply.
public struct TestSummary: Sendable, Codable, Equatable {
    public let passed: Int
    public let failed: Int
    public let skipped: Int
    /// Change in coverage vs. the baseline, if measured (e.g. `+0.03` = +3pt).
    public var coverageDelta: Double?
    /// A short description of the first failing test, if any.
    public var firstFailure: String?

    public init(
        passed: Int,
        failed: Int,
        skipped: Int,
        coverageDelta: Double? = nil,
        firstFailure: String? = nil
    ) {
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.coverageDelta = coverageDelta
        self.firstFailure = firstFailure
    }
}

/// The single rendered output of an agent turn — what the app shows in the notch.
///
/// One turn produces exactly one artifact, chosen from raw signals by
/// `classify(previewURL:diff:tests:logs:hasErrors:)`.
public enum BuildArtifact: Sendable, Codable, Equatable {
    /// A running preview the user can open (dev server, deployed URL).
    case livePreview(url: URL)
    /// A code diff, summarised per file.
    case diff(files: [DiffFileSummary])
    /// A test run's outcome.
    case tests(TestSummary)
    /// Raw log text, flagged when it contains errors.
    case logs(text: String, hasErrors: Bool)
    /// A Markdown document (a written answer, plan, or report).
    case document(markdown: String)
    /// A before/after screenshot pair (`before` may be absent on first capture).
    case screens(before: URL?, after: URL)
    /// A failure, with an optional pointer at the step that failed.
    case error(message: String, failingStep: String?)

    /// Collapses the raw signals of a turn into the single most useful artifact.
    ///
    /// FALLBACK LADDER (first match wins):
    /// 1. `hasErrors` && `logs` present → `.error` (message = the last error-ish
    ///    line of the logs, `failingStep: nil`). Errors beat everything.
    /// 2. else `previewURL` present → `.livePreview`.
    /// 3. else `tests` with `passed + failed > 0` → `.tests`.
    /// 4. else non-empty `diff` → `.diff`.
    /// 5. else `logs` present → `.logs(text, hasErrors)`.
    /// 6. else → `.error(message: "No output produced", failingStep: nil)`.
    public static func classify(
        previewURL: URL?,
        diff: [DiffFileSummary],
        tests: TestSummary?,
        logs: String?,
        hasErrors: Bool
    ) -> BuildArtifact {
        if hasErrors, let logs {
            return .error(message: lastErrorLine(in: logs), failingStep: nil)
        }
        if let previewURL {
            return .livePreview(url: previewURL)
        }
        if let tests, tests.passed + tests.failed > 0 {
            return .tests(tests)
        }
        if !diff.isEmpty {
            return .diff(files: diff)
        }
        if let logs {
            return .logs(text: logs, hasErrors: hasErrors)
        }
        return .error(message: "No output produced", failingStep: nil)
    }

    /// The last "error-ish" line of a log blob, used as the `.error` message.
    ///
    /// Prefers the last non-empty line mentioning "error"/"fail"/"fatal"/
    /// "exception"; falls back to the last non-empty line, then to the trimmed
    /// blob itself.
    private static func lastErrorLine(in logs: String) -> String {
        let nonEmpty = logs
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let needles = ["error", "fail", "fatal", "exception"]
        if let match = nonEmpty.last(where: { line in
            let lower = line.lowercased()
            return needles.contains { lower.contains($0) }
        }) {
            return match
        }
        return nonEmpty.last ?? logs.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
