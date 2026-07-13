import SwiftUI
import NotchideKit

/// Shared look-and-feel helpers for the preferences panes.
///
/// The notch panel is a fixed dark surface, but the preferences window is a
/// normal, appearance-following macOS settings window. So these helpers lean on
/// the *semantic* DesignSystem accent tokens (teal/amber/red/green) and `Typo`
/// faces, while leaving structural chrome to native `Form`/`GroupBox` controls
/// that adapt to light and dark on their own.

/// The emphasis of a callout, mapped onto a DesignSystem accent color.
enum CalloutTone {
    case info
    case caution
    case danger
    case success

    var color: Color {
        switch self {
        case .info: return Theme.flowing
        case .caution: return Theme.needsYou
        case .danger: return Theme.error
        case .success: return Theme.done
        }
    }

    var defaultIcon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .danger: return "exclamationmark.octagon.fill"
        case .success: return "checkmark.seal.fill"
        }
    }
}

/// A tinted, bordered inline note — the standard way these panes surface a safety
/// invariant ("control is never voice-driven", "loopback-only", etc).
struct SettingsCallout: View {
    let tone: CalloutTone
    let text: String
    var icon: String?

    init(_ tone: CalloutTone, _ text: String, icon: String? = nil) {
        self.tone = tone
        self.text = text
        self.icon = icon
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Image(systemName: icon ?? tone.defaultIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone.color)
            Text(text)
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(tone.color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .stroke(tone.color.opacity(0.30), lineWidth: 1)
        )
    }
}

extension View {
    /// The standard settings-pane card: padded content on a faint fill, rounded to
    /// the card radius with a hairline border. The border tint is overridable so a
    /// row can flag a dangerous state (e.g. a Control screen grant).
    func settingsCard(stroke: Color = Color.primary.opacity(0.08)) -> some View {
        self
            .padding(Theme.Spacing.md)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
    }
}

/// A small pill for a capability / kind tag.
struct TagChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = Theme.flowing

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .medium))
            }
            Text(text)
                .font(Typo.chip)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.30), lineWidth: 1))
    }
}

/// An empty-state placeholder used by list panes before anything is configured.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(Typo.title)
                .foregroundStyle(.secondary)
            Text(message)
                .font(Typo.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
    }
}

/// A titled section header used inside the scrollable panes.
struct PaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(subtitle)
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A copyable monospaced code block (env-var setup, paths). Read-only.
struct CodeBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Text(text)
                .font(Typo.monoSmall)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(Theme.Spacing.md)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
