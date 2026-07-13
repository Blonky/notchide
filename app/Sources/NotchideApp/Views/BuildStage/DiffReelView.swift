import SwiftUI
import NotchideKit

/// A **scrubbable reel** of the turn's changed files (DESIGN §14). Each card is a
/// per-file `DiffFileSummary` — path, `+added / −removed`, and a proportion bar —
/// laid out horizontally so the eye can scrub across a large change set without a
/// wall of text. This is the summary form; the full unified diff is the review
/// console's `DiffView`.
public struct DiffReelView: View {
    let files: [DiffFileSummary]

    public init(files: [DiffFileSummary]) {
        self.files = files
    }

    public var body: some View {
        if files.isEmpty {
            Text("No file changes")
                .font(Typo.monoSmall)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.md)
                .buildCard()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                        DiffFileCard(file: file, maxChurn: maxChurn)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 96)
        }
    }

    /// The busiest single file, so every card's bar is scaled to a shared max.
    private var maxChurn: Int {
        max(1, files.map { $0.added + $0.removed }.max() ?? 1)
    }
}

/// One file in the reel.
private struct DiffFileCard: View {
    let file: DiffFileSummary
    let maxChurn: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // File name (basename bold, parent dir muted underneath).
            VStack(alignment: .leading, spacing: 1) {
                Text(basename)
                    .font(Typo.monoBold)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !parent.isEmpty {
                    Text(parent)
                        .font(Typo.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 0)

            // Churn bar: green added over red removed, widths proportional.
            ChurnBar(added: file.added, removed: file.removed, maxChurn: maxChurn)

            HStack(spacing: Theme.Spacing.sm) {
                Text("+\(file.added)")
                    .font(Typo.monoSmall)
                    .foregroundStyle(Theme.diffAddText)
                Text("−\(file.removed)")
                    .font(Typo.monoSmall)
                    .foregroundStyle(Theme.diffRemoveText)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(width: 168, height: 88, alignment: .leading)
        .buildCard()
        .help(file.path)
    }

    private var basename: String {
        (file.path as NSString).lastPathComponent
    }

    private var parent: String {
        (file.path as NSString).deletingLastPathComponent
    }
}

/// A single-line churn bar — added (green) beside removed (red), scaled to the
/// reel's busiest file so relative size reads across cards.
private struct ChurnBar: View {
    let added: Int
    let removed: Int
    let maxChurn: Int

    var body: some View {
        GeometryReader { geo in
            let total = CGFloat(max(1, maxChurn))
            let addW = geo.size.width * CGFloat(added) / total
            let remW = geo.size.width * CGFloat(removed) / total
            HStack(spacing: 1) {
                Capsule().fill(Theme.diffAddText).frame(width: addW)
                Capsule().fill(Theme.diffRemoveText).frame(width: remW)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 4)
        .background(Theme.diffGutter)
        .clipShape(Capsule())
    }
}
