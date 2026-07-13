import SwiftUI

/// Raw log text (DESIGN §14), monospaced, with error-ish lines colored and the
/// body collapsible so a long tail does not dominate the panel.
///
/// Collapsed, it shows the last few lines (where the action usually is); expanded,
/// it scrolls the whole blob. Line coloring is a shallow lexical heuristic — the
/// same needles the NotchideKit classifier uses — never a parse.
public struct LogsView: View {
    let text: String
    let hasErrors: Bool

    @State private var expanded = false

    public init(text: String, hasErrors: Bool) {
        self.text = text
        self.hasErrors = hasErrors
    }

    /// Lines kept when collapsed.
    private let collapsedTail = 6

    private var lines: [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            header

            if expanded {
                ScrollView(.vertical, showsIndicators: true) {
                    logBody(lines)
                }
                .frame(maxHeight: 220)
                .padding(Theme.Spacing.md)
                .buildCard(stroke: hasErrors ? Theme.error.opacity(0.4) : Theme.hairline)
            } else {
                logBody(Array(lines.suffix(collapsedTail)))
                    .padding(Theme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .buildCard(stroke: hasErrors ? Theme.error.opacity(0.4) : Theme.hairline)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            SectionLabel(text: "LOGS")
            if hasErrors {
                Text("errors")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.error)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 2)
                    .background(Theme.diffRemoveBackground)
                    .clipShape(Capsule())
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(expanded ? "collapse" : "expand")
                        .font(Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func logBody(_ shown: [Substring]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : String(line))
                    .font(Typo.monoSmall)
                    .foregroundStyle(Self.isErrorish(line) ? Theme.error : Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    /// A line worth painting red — same needles as `BuildArtifact.lastErrorLine`,
    /// plus `warn` for the amber-adjacent case (still surfaced as error-ish).
    static func isErrorish(_ line: Substring) -> Bool {
        let lower = line.lowercased()
        return ["error", "fail", "fatal", "exception", "warn"].contains { lower.contains($0) }
    }
}
