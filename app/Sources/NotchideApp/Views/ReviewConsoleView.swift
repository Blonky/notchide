import SwiftUI
import NotchideKit

/// The expanded, READ-ONLY review console — the payoff surface.
///
/// Shows, for the single most-urgent session: a decision header (context chips),
/// the exact pending command (destructive tokens highlighted), the live git
/// diff, an output tail, the decision controls + a one-line redirect field, a
/// persistent jump-to-terminal affordance, and the "why did this tap?" line.
public struct ReviewConsoleView: View {
    @ObservedObject var model: NotchViewModel
    @State private var redirectText: String = ""

    public init(model: NotchViewModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let review = model.review {
                console(for: review)
            } else {
                Color.clear.frame(width: 520, height: 1)
            }
        }
    }

    private func console(for review: ReviewContext) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            DecisionHeaderView(
                review: review,
                isPinned: model.isPinned,
                onTogglePin: { model.onTogglePin?() },
                onJumpToTerminal: { model.onJumpToTerminal?(review.cwd) },
                onClose: { model.onCollapse?() }
            )

            CommandBlockView(review: review)

            DiffView(diff: review.diff)
                .frame(maxHeight: 240)

            if let tail = review.outputTail, !tail.isEmpty {
                OutputTailView(text: tail)
            }

            ActionBarView(
                enabled: review.wantsDecision,
                isDestructive: review.isDestructive,
                redirectText: $redirectText,
                onDeny: { model.onDecide?(.deny, "Denied from notchide", nil) },
                onApprove: { model.onDecide?(.allow, nil, nil) },
                onApproveRemember: { model.onDecide?(.allow, "approve-and-remember", nil) },
                onRedirect: {
                    let text = redirectText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    model.onDecide?(.deny, text, text)
                }
            )

            WhyTappedView(reason: review.reason)
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 520)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .stroke(Theme.hairlineStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 30, x: 0, y: 18)
        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 2)
    }

    private var panelBackground: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
            Theme.panelGradient
        }
    }
}

// MARK: - Decision header (context chips + affordances)

private struct DecisionHeaderView: View {
    let review: ReviewContext
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onJumpToTerminal: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ContextChip(icon: "cpu", text: review.shortSessionId)
            if let branch = review.branch {
                ContextChip(icon: "arrow.triangle.branch", text: branch)
            }
            if let tool = review.toolName {
                ContextChip(icon: "wrench.and.screwdriver", text: tool)
            }

            Spacer(minLength: Theme.Spacing.sm)

            IconButton(system: isPinned ? "pin.fill" : "pin", active: isPinned, action: onTogglePin)
            IconButton(system: "terminal", active: false, action: onJumpToTerminal)
            IconButton(system: "xmark", active: false, action: onClose)
        }
    }
}

private struct ContextChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(Typo.chip)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }
}

private struct IconButton: View {
    let system: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Theme.flowing : Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background(Theme.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pending command

private struct CommandBlockView: View {
    let review: ReviewContext

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Text("PENDING PERMISSION")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                if review.isDestructive {
                    Text("destructive")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.error)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(Theme.diffRemoveBackground)
                        .clipShape(Capsule())
                }
                Spacer()
            }

            Text(highlightedCommand)
                .font(Typo.mono)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.md)
                .background(Theme.sunkenSurface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .stroke(review.isDestructive ? Theme.error.opacity(0.5) : Theme.hairline, lineWidth: 1)
                )
        }
    }

    /// The command with any destructive tokens painted red.
    private var highlightedCommand: AttributedString {
        let command = review.command ?? "(no command payload)"
        return Self.attributed(command, destructive: review.destructiveTokens)
    }

    /// Builds an `AttributedString` painting `destructive` substrings red.
    static func attributed(_ command: String, destructive tokens: [String]) -> AttributedString {
        let ns = command as NSString
        guard ns.length > 0 else { return AttributedString(command) }
        var isRed = [Bool](repeating: false, count: ns.length)
        let lower = command.lowercased() as NSString
        for token in tokens {
            let needle = token.lowercased()
            guard !needle.isEmpty else { continue }
            var searchRange = NSRange(location: 0, length: lower.length)
            while true {
                let found = lower.range(of: needle, options: [], range: searchRange)
                if found.location == NSNotFound { break }
                let end = min(found.location + found.length, isRed.count)
                for i in found.location..<end { isRed[i] = true }
                let next = found.location + max(found.length, 1)
                if next >= lower.length { break }
                searchRange = NSRange(location: next, length: lower.length - next)
            }
        }

        var result = AttributedString()
        func append(_ start: Int, _ end: Int) {
            let piece = ns.substring(with: NSRange(location: start, length: end - start))
            var attr = AttributedString(piece)
            attr.foregroundColor = isRed[start] ? Theme.error : Theme.textPrimary
            result.append(attr)
        }
        var runStart = 0
        var index = 1
        while index < isRed.count {
            if isRed[index] != isRed[runStart] { append(runStart, index); runStart = index }
            index += 1
        }
        append(runStart, isRed.count)
        return result
    }
}

// MARK: - Output tail

private struct OutputTailView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("OUTPUT")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
            ScrollView(.vertical, showsIndicators: false) {
                Text(text)
                    .font(Typo.monoSmall)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 64)
            .padding(Theme.Spacing.sm)
            .background(Theme.sunkenSurface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
        }
    }
}

// MARK: - Action bar

private struct ActionBarView: View {
    let enabled: Bool
    let isDestructive: Bool
    @Binding var redirectText: String
    let onDeny: () -> Void
    let onApprove: () -> Void
    let onApproveRemember: () -> Void
    let onRedirect: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                DecisionButton(title: "Deny", kind: .neutral, action: onDeny)
                DecisionButton(title: "Approve", kind: .primary, action: onApprove)
                DecisionButton(title: "Approve & remember", kind: .ghost, action: onApproveRemember)
                Spacer(minLength: 0)
            }
            .opacity(enabled ? 1 : 0.4)
            .disabled(!enabled)

            // One-line redirect: a short natural-language steer round-tripped to the agent.
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Redirect the agent…", text: $redirectText)
                    .textFieldStyle(.plain)
                    .font(Typo.body)
                    .foregroundStyle(Theme.textPrimary)
                    .onSubmit(onRedirect)
                if !redirectText.isEmpty {
                    Button(action: onRedirect) {
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.flowing)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.sunkenSurface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
            .opacity(enabled ? 1 : 0.4)
            .disabled(!enabled)
        }
    }
}

private struct DecisionButton: View {
    enum Kind { case primary, neutral, ghost }
    let title: String
    let kind: Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .primary: Theme.primaryGradient
        case .neutral: Theme.raisedSurface
        case .ghost: Color.clear
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .neutral: return Theme.textPrimary
        case .ghost: return Theme.textSecondary
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: return .clear
        case .neutral: return Theme.hairlineStrong
        case .ghost: return Theme.hairline
        }
    }
}

// MARK: - Why did this tap?

private struct WhyTappedView: View {
    let reason: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "info.circle")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
            Text("why did this tap? · \(reason)")
                .font(Typo.caption)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
    }
}
