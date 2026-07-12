import SwiftUI

/// A read-only, syntax-highlighted unified-diff renderer.
///
/// Add/remove/context lines are colored (background tint + colored gutter sign),
/// each line carries its number, and the code text runs through the built-in
/// `SwiftSyntaxHighlighter`. notchide shows the diff — it never edits it.
public struct DiffView: View {
    let diff: GitDiff?

    public init(diff: GitDiff?) {
        self.diff = diff
    }

    public var body: some View {
        Group {
            if let diff, !diff.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        ForEach(diff.files) { file in
                            DiffFileView(file: file)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.sm)
                }
            } else if diff == nil {
                placeholder("Loading diff…")
            } else {
                placeholder("No uncommitted changes")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(Typo.monoSmall)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(Theme.Spacing.md)
    }
}

private struct DiffFileView: View {
    let file: DiffFile

    /// v0.1 highlighting is Swift-only; other files render as plain mono.
    private var language: SwiftSyntaxHighlighter.Language {
        SwiftSyntaxHighlighter.language(forPath: file.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File header with +/- counts.
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Text(file.displayName)
                    .font(Typo.monoSmall)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.sm)
                Text("+\(file.addedCount)")
                    .font(Typo.monoSmall)
                    .foregroundStyle(Theme.diffAddText)
                Text("−\(file.removedCount)")
                    .font(Typo.monoSmall)
                    .foregroundStyle(Theme.diffRemoveText)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.raisedSurface)

            ForEach(file.hunks) { hunk in
                Text(hunk.header)
                    .font(Typo.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, 3)
                    .background(Theme.diffGutter)

                ForEach(hunk.lines) { line in
                    DiffLineView(line: line, language: language)
                }
            }
        }
        .background(Theme.sunkenSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }
}

private struct DiffLineView: View {
    let line: DiffLine
    let language: SwiftSyntaxHighlighter.Language

    private var background: Color {
        switch line.kind {
        case .add: return Theme.diffAddBackground
        case .remove: return Theme.diffRemoveBackground
        case .context: return .clear
        }
    }

    private var sign: String {
        switch line.kind {
        case .add: return "+"
        case .remove: return "−"
        case .context: return " "
        }
    }

    private var signColor: Color {
        switch line.kind {
        case .add: return Theme.diffAddText
        case .remove: return Theme.diffRemoveText
        case .context: return Theme.textTertiary
        }
    }

    private var lineNumber: String {
        let number = line.kind == .remove ? line.oldLineNumber : line.newLineNumber
        return number.map(String.init) ?? ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Text(lineNumber)
                .font(Typo.monoSmall)
                .foregroundStyle(Theme.textTertiary.opacity(0.7))
                .frame(width: 34, alignment: .trailing)

            Text(sign)
                .font(Typo.monoSmall)
                .foregroundStyle(signColor)
                .frame(width: 8, alignment: .center)

            Text(SwiftSyntaxHighlighter.highlight(line.text, language: language))
                .font(Typo.monoSmall)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 1)
        .background(background)
    }
}
