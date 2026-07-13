import SwiftUI
import NotchideKit

/// The **Build stage** (DESIGN §14): the console surface that renders *what the
/// agent built* this turn — still read-only.
///
/// It switches over the already-classified `BuildArtifact` and renders the
/// richest sub-view the artifact carries, degrading down the ladder
/// (`livePreview → diff → tests → logs → document → screens → error`). The
/// classification itself lives in `BuildArtifact.classify` (NotchideKit); the
/// `previewURL:diff:tests:logs:hasErrors:` initializer below runs that ladder for
/// callers holding raw signals.
///
/// The header states the outcome at a glance — a state pip, a title, and (for a
/// diff) the `+adds / −dels / N files` summary — and advertises the `hold ⌃⌥ to
/// continue` gesture. Build stage is HOST-mode only, so this view is only ever
/// shown for turns whose output stream notchide could actually see.
public struct BuildStageView: View {
    let artifact: BuildArtifact

    public init(artifact: BuildArtifact) {
        self.artifact = artifact
    }

    /// Convenience: classify raw turn signals through the NotchideKit fallback
    /// ladder, then render the winner.
    public init(
        previewURL: URL?,
        diff: [DiffFileSummary] = [],
        tests: TestSummary? = nil,
        logs: String? = nil,
        hasErrors: Bool = false
    ) {
        self.artifact = BuildArtifact.classify(
            previewURL: previewURL,
            diff: diff,
            tests: tests,
            logs: logs,
            hasErrors: hasErrors
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            BuildStageHeader(artifact: artifact)
            content
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 520, alignment: .leading)
        .buildPanelChrome()
    }

    @ViewBuilder
    private var content: some View {
        switch artifact {
        case .livePreview(let url):
            LivePreviewView(url: url)
        case .diff(let files):
            DiffReelView(files: files)
        case .tests(let summary):
            TestGridView(summary: summary)
        case .logs(let text, let hasErrors):
            LogsView(text: text, hasErrors: hasErrors)
        case .document(let markdown):
            DocumentView(markdown: markdown)
        case .screens(let before, let after):
            ScreensView(before: before, after: after)
        case .error(let message, let failingStep):
            BuildErrorView(message: message, failingStep: failingStep)
        }
    }
}

// MARK: - Header

/// The one-line outcome summary above the artifact body.
private struct BuildStageHeader: View {
    let artifact: BuildArtifact

    var body: some View {
        // Derive the header model once per render rather than rebuilding it on
        // each field access below.
        let model = HeaderModel(artifact: artifact)
        return HStack(spacing: Theme.Spacing.sm) {
            StatePip(glyph: model.glyph)
            Image(systemName: model.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(model.title)
                .font(Typo.title)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.sm)

            ForEach(Array(model.stats.enumerated()), id: \.offset) { _, stat in
                StatChip(icon: stat.icon, text: stat.text, tint: stat.tint, emphasized: stat.emphasized)
            }

            // `.error` carries its own `hold ⌃⌥ to fix it` inside BuildErrorView,
            // so the header suppresses the generic "continue" affordance there.
            if !model.isError {
                HoldToContinueView(label: "to continue")
            }
        }
    }
}

/// A tiny header stat descriptor.
private struct HeaderStat {
    var icon: String? = nil
    let text: String
    var tint: Color = Theme.textSecondary
    var emphasized: Bool = false
}

/// Derives the header's pip color, glyph, title, and stat chips from the artifact.
private struct HeaderModel {
    let glyph: BuildGlyph
    let symbol: String
    let title: String
    let stats: [HeaderStat]
    let isError: Bool

    init(artifact: BuildArtifact) {
        switch artifact {
        case .livePreview:
            glyph = .flowing
            symbol = "globe"
            title = "Live preview"
            stats = [HeaderStat(icon: "lock.fill", text: "egress-locked", tint: Theme.flowing)]
            isError = false

        case .diff(let files):
            let adds = files.reduce(0) { $0 + $1.added }
            let dels = files.reduce(0) { $0 + $1.removed }
            glyph = .done
            symbol = "chevron.left.forwardslash.chevron.right"
            title = "Changes"
            stats = [
                HeaderStat(text: "+\(adds)", tint: Theme.diffAddText, emphasized: true),
                HeaderStat(text: "−\(dels)", tint: Theme.diffRemoveText, emphasized: true),
                HeaderStat(icon: "doc.on.doc", text: "\(files.count) \(files.count == 1 ? "file" : "files")", tint: Theme.textTertiary),
            ]
            isError = false

        case .tests(let summary):
            let clean = summary.failed == 0
            glyph = clean ? .done : .error
            symbol = "checklist"
            title = clean ? "Tests green" : "Tests"
            var chips = [HeaderStat(text: "\(summary.passed) passed", tint: Theme.done, emphasized: true)]
            if summary.failed > 0 {
                chips.append(HeaderStat(text: "\(summary.failed) failed", tint: Theme.error, emphasized: true))
            }
            stats = chips
            isError = false

        case .logs(_, let hasErrors):
            glyph = hasErrors ? .error : .flowing
            symbol = "text.alignleft"
            title = hasErrors ? "Logs · errors" : "Logs"
            stats = []
            isError = false

        case .document:
            glyph = .done
            symbol = "doc.text"
            title = "Document"
            stats = []
            isError = false

        case .screens(let before, _):
            glyph = .done
            symbol = "photo.on.rectangle"
            title = "Screens"
            stats = [HeaderStat(text: before == nil ? "first capture" : "before / after", tint: Theme.textTertiary)]
            isError = false

        case .error:
            glyph = .error
            symbol = "exclamationmark.triangle.fill"
            title = "Build failed"
            stats = []
            isError = true
        }
    }
}
