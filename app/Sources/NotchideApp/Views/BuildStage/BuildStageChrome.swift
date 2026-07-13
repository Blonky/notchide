import SwiftUI

// Shared primitives for the Build stage (DESIGN §14). Kept small and glanceable:
// every element here is legible in peripheral vision and reuses the design-system
// tokens (the flowing / needs-you / done / error color language, the spacing and
// radius scales, the mono/UI type ramp).

/// The four-state color language, reused from the cockpit glyphs, expressed as a
/// value so Build-stage surfaces can tint themselves consistently.
enum BuildGlyph {
    case flowing, needsYou, done, error

    var color: Color {
        switch self {
        case .flowing: return Theme.flowing
        case .needsYou: return Theme.needsYou
        case .done: return Theme.done
        case .error: return Theme.error
        }
    }
}

/// A settled state pip — the same idea as `LaneDotView` but static (the Build
/// stage is a payoff surface, not an ambient one, so it does not breathe).
struct StatePip: View {
    let glyph: BuildGlyph
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(glyph.color)
            .frame(width: size, height: size)
            .shadow(color: glyph.color.opacity(0.7), radius: 2)
    }
}

/// A single keycap, e.g. `⌃` or `⌥`.
struct KeycapView: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 16, height: 16)
            .background(Theme.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Theme.hairlineStrong, lineWidth: 1)
            )
    }
}

/// The `hold ⌃⌥ …` affordance shared by the header and the error card. Purely a
/// visual affordance here — the hotkey monitor is wired centrally later; this view
/// only advertises the gesture.
struct HoldToContinueView: View {
    /// The trailing phrase, e.g. `"to continue"` or `"to fix it"`.
    var label: String = "to continue"
    var tint: Color = Theme.flowing

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("hold")
                .font(Typo.caption)
                .foregroundStyle(Theme.textTertiary)
            KeycapView(symbol: "⌃")
            KeycapView(symbol: "⌥")
            Text(label)
                .font(Typo.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(tint.opacity(0.10))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
        .help("Hold Control-Option \(label)")
    }
}

/// An uppercase, tracked section label (matches `OUTPUT` / `PENDING PERMISSION`
/// in the review console).
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// A compact metric chip — an optional SF Symbol plus a value, tinted to carry
/// meaning (green adds, red dels, grey counts).
struct StatChip: View {
    var icon: String? = nil
    let text: String
    var tint: Color = Theme.textSecondary
    var emphasized: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(Typo.chip)
                .foregroundStyle(emphasized ? tint : Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(emphasized ? tint.opacity(0.12) : Theme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .stroke(emphasized ? tint.opacity(0.35) : Theme.hairline, lineWidth: 1)
        )
    }
}

/// The dark "screenshot" panel surface shared by every full Build-stage view —
/// the same layered vibrancy + gradient the review console uses.
struct BuildPanelBackground: View {
    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
            Theme.panelGradient
        }
    }
}

extension View {
    /// Wraps a Build-stage root in the standard panel chrome (rounded, hairline,
    /// layered shadow) so each artifact view is presentable stand-alone.
    func buildPanelChrome() -> some View {
        self
            .background(BuildPanelBackground())
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                    .stroke(Theme.hairlineStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 30, x: 0, y: 18)
            .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 2)
    }

    /// The recessed inner-card treatment (sunken fill + hairline) used by the diff
    /// reel, test grid, logs, and screens.
    func buildCard(stroke: Color = Theme.hairline) -> some View {
        self
            .background(Theme.sunkenSurface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
    }
}
