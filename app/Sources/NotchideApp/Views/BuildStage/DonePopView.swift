import SwiftUI

/// The compact one-line **done pop** that precedes the Build-stage bloom (DESIGN
/// §14): a settled green glyph, the session name, and a terse outcome line
/// (`3 files · tests green`).
///
/// It is the ambient "it finished, cleanly" beat — small, glanceable, and quiet —
/// shown for a moment before (or instead of) the full artifact expanding open.
public struct DonePopView: View {
    let session: String
    let summary: String

    @State private var appeared = false

    public init(session: String, summary: String) {
        self.session = session
        self.summary = summary
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Settled done glyph — a green check in a soft halo.
            ZStack {
                Circle()
                    .fill(Theme.done.opacity(0.18))
                    .frame(width: 18, height: 18)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.done)
            }

            Text(session)
                .font(Typo.monoBold)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Text("·")
                .font(Typo.body)
                .foregroundStyle(Theme.textTertiary)

            Text(summary)
                .font(Typo.body)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            Capsule()
                .fill(Theme.raisedSurface)
                .overlay(Capsule().stroke(Theme.done.opacity(0.30), lineWidth: 1))
        )
        .fixedSize()
        .shadow(color: Theme.done.opacity(0.25), radius: 8)
        // A brief settle-in — the pop lands, it does not slide.
        .scaleEffect(appeared ? 1 : 0.86)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) { appeared = true }
        }
    }
}
