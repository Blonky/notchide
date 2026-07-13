import SwiftUI
import NotchideKit

/// The voice overlay that grows from the notch during a push-to-talk session.
///
/// It renders the three live states driven by `NotchViewModel.voiceState`:
///   • LISTENING — a breathing waveform orb, the dimmed live partial transcript,
///     a silence/auto-send meter, the target-session chip, and "Esc to cancel";
///   • REVIEW — the solidified, editable transcript plus the grace bar
///     ("Return to send now · Esc to edit");
///   • ERROR — a quiet, auto-dismissing message.
///
/// In a gate-verdict (`voiceGateMode`) session it reads as a compact "say approve
/// / deny" strip and surfaces the "voice approve disabled" hint when a spoken
/// approval was refused for a destructive command.
///
/// It never opens a window of its own — `NotchRootView` hosts it inside the notch
/// panel, above the cockpit or (as a strip) over the review console.
public struct VoiceHUDView: View {
    @ObservedObject var model: NotchViewModel

    public init(model: NotchViewModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            switch model.voiceState {
            case .inactive:
                Color.clear.frame(width: 1, height: 1)
            case .listening:
                if model.voiceGateMode {
                    gateVerdictStrip
                } else {
                    listening
                }
            case .review:
                review
            case .error(let message):
                errorBanner(message)
            }
        }
        .frame(width: 460)
        .padding(Theme.Spacing.xl)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .stroke(Theme.hairlineStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 30, x: 0, y: 18)
    }

    // MARK: LISTENING

    private var listening: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.md) {
                WaveformOrb(active: true, tint: Theme.flowing)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listening")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textSecondary)
                    if let target = model.voiceTargetLabel {
                        TargetChip(label: target)
                    }
                }
                Spacer(minLength: 0)
            }

            // The live partial transcript, dimmed — it may still change, so it is
            // deliberately quieter than a committed final.
            Text(model.voiceText.isEmpty ? "…" : model.voiceText)
                .font(Typo.mono)
                .foregroundStyle(model.voiceText.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            MeterBar(fraction: model.voiceMeter, tint: Theme.flowing)

            HintRow(text: "Esc to cancel")
        }
    }

    // MARK: REVIEW

    private var review: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.md) {
                WaveformOrb(active: false, tint: Theme.primaryGradientEnd)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.voiceEditing ? "Editing" : "Sending")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textSecondary)
                    if let target = model.voiceTargetLabel {
                        TargetChip(label: target)
                    }
                }
                Spacer(minLength: 0)
            }

            // The solidified, editable transcript. Editing (Esc) freezes the grace
            // timer so the user can correct before it auto-sends.
            TextField("", text: $model.voiceText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typo.mono)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...4)
                .padding(Theme.Spacing.md)
                .background(Theme.sunkenSurface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
                .onChange(of: model.voiceText) { newValue in
                    if model.voiceEditing { model.onVoiceEdit?(newValue) }
                }
                .onSubmit { model.onVoiceSendNow?() }

            if model.voiceEditing {
                HintRow(text: "Return to send")
            } else {
                // The grace bar: fills toward the auto-send.
                MeterBar(fraction: model.voiceMeter, tint: Theme.primaryGradientEnd)
                HintRow(text: "Return to send now · Esc to edit")
            }
        }
    }

    // MARK: ERROR

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.error)
            Text(message)
                .font(Typo.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: GATE VERDICT

    private var gateVerdictStrip: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.md) {
                WaveformOrb(active: true, tint: Theme.needsYou)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Say “approve” or “deny”")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(model.voiceText.isEmpty ? "listening for a verdict…" : model.voiceText)
                        .font(Typo.monoSmall)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if model.voiceApproveDisabled {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.error)
                    Text("voice approve disabled · click/hotkey required")
                        .font(Typo.caption)
                        .foregroundStyle(Theme.error)
                }
            } else {
                HintRow(text: "Esc to cancel")
            }
        }
    }

    private var panelBackground: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
            Theme.panelGradient
        }
    }
}

// MARK: - Pieces

/// A breathing "listening" orb with concentric rings, tinted per state.
private struct WaveformOrb: View {
    let active: Bool
    let tint: Color

    @State private var breathe = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .stroke(tint.opacity(0.35 - Double(ring) * 0.1), lineWidth: 1.5)
                    .frame(width: 18 + CGFloat(ring) * 10, height: 18 + CGFloat(ring) * 10)
                    .scaleEffect(active && breathe ? 1.15 : 0.9)
                    .opacity(active ? 1 : 0.4)
            }
            Circle()
                .fill(tint)
                .frame(width: 12, height: 12)
                .shadow(color: tint.opacity(0.8), radius: active && breathe ? 6 : 3)
                .scaleEffect(active && breathe ? 1.1 : 0.95)
        }
        .frame(width: 48, height: 48)
        .onAppear { breathe = true }
        .animation(
            active ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
            value: breathe
        )
    }
}

/// The target-session chip.
private struct TargetChip: View {
    let label: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "scope")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(label)
                .font(Typo.chip)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 2)
        .background(Theme.raisedSurface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
    }
}

/// The silence / auto-send meter.
private struct MeterBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.sunkenSurface)
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 4)
    }
}

/// A quiet hint line (keyboard affordances).
private struct HintRow: View {
    let text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(text)
                .font(Typo.caption)
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
    }
}
