import SwiftUI

/// A `.error(message:failingStep:)` artifact (DESIGN §14): the failure message,
/// an optional pointer at the step that failed, and a `hold ⌃⌥ to fix it`
/// affordance — the one-gesture handoff back to the agent to attempt a fix.
///
/// Errors sit at the bottom of the fallback ladder but at the top of the router's
/// attention order, so this reads sharp and red without shouting.
public struct BuildErrorView: View {
    let message: String
    let failingStep: String?

    public init(message: String, failingStep: String?) {
        self.message = message
        self.failingStep = failingStep
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if let failingStep, !failingStep.isEmpty {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text("failing step")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.textTertiary)
                    Text(failingStep)
                        .font(Typo.monoSmall)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // The error message itself.
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.error)
                Text(message)
                    .font(Typo.mono)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.diffRemoveBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.error.opacity(0.5), lineWidth: 1)
            )

            HStack {
                Spacer(minLength: 0)
                HoldToContinueView(label: "to fix it", tint: Theme.error)
            }
        }
    }
}
