import SwiftUI
import NotchideKit

/// The root view hosted in the notch's EXPANDED slot.
///
/// On notched Macs the ambient cockpit lives in the compact (trailing) slot and
/// this expanded slot is used only for the review console. On floating screens
/// (external monitors / non-notch Macs) there is no compact slot, so this root
/// doubles as the persistent floating cockpit: it renders the console when a
/// review is on screen and the compact cockpit otherwise. See
/// `NotchController.showCockpit`.
public struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel

    public init(model: NotchViewModel) {
        self.model = model
    }

    public var body: some View {
        if model.voiceState.isActive && !model.voiceGateMode {
            // A fresh voice ACTUATE prompt (no gate on screen): the HUD is the panel.
            VoiceHUDView(model: model)
        } else if model.review != nil {
            // A gate is on screen; a gate-verdict voice session overlays a compact
            // "say approve / deny" strip at the bottom of the console. A live gate
            // always wins over a Build stage (which is why this branch precedes it).
            ZStack(alignment: .bottom) {
                ReviewConsoleView(model: model)
                if model.voiceState.isActive && model.voiceGateMode {
                    VoiceHUDView(model: model)
                        .padding(.bottom, Theme.Spacing.md)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        } else if model.donePop != nil || model.buildStage != nil {
            // A finished turn carrying an artifact (DESIGN §14): the compact "done
            // pop" lands first, then it blooms into the full Build stage once
            // `NotchController` clears `donePop`.
            buildStageBloom
        } else {
            CockpitView(model: model)
        }
    }

    /// The Build-stage presentation: the transient done pop first, then the full
    /// artifact blooming open once `NotchController` clears `model.donePop`.
    @ViewBuilder
    private var buildStageBloom: some View {
        ZStack {
            if let pop = model.donePop {
                DonePopView(session: pop.session, summary: pop.summary)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if let artifact = model.buildStage {
                BuildStageView(artifact: artifact)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: model.donePop)
    }
}

/// The collapsed cockpit: a row of pre-attentive dots, one per active lane.
///
/// No text — state is read entirely through color + motion, so it registers in
/// peripheral vision. Sits in DynamicNotchKit's compact (trailing) slot beside
/// the notch.
public struct CockpitView: View {
    @ObservedObject var model: NotchViewModel
    @State private var pulseGlow: Double = 0

    public init(model: NotchViewModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(model.lanes.prefix(8)) { lane in
                LaneDotView(state: lane.state)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(height: 28)
        .fixedSize()
        // Passive pulse: a non-decision tap briefly haloes the pill instead of
        // auto-expanding it (silence-by-default). Driven by `model.pillPulse`.
        .background(
            Capsule()
                .fill(Theme.needsYou.opacity(0.22 * pulseGlow))
                .blur(radius: 6)
        )
        .onChange(of: model.pillPulse) { _ in
            pulseGlow = 1
            withAnimation(.easeOut(duration: 0.9)) { pulseGlow = 0 }
        }
    }
}

/// A single lane glyph. Four states encoded as color + motion:
/// flowing (calm teal, slow breathing), needs-you (amber, pulsing ring),
/// done (green, settled), error (red, sharp attention).
struct LaneDotView: View {
    let state: LaneState

    @State private var breathe = false
    @State private var pulse = false

    private var color: Color {
        switch state {
        case .flowing: return Theme.flowing
        case .needsYou: return Theme.needsYou
        case .done: return Theme.done
        case .error: return Theme.error
        }
    }

    var body: some View {
        ZStack {
            // needs-you: an expanding, fading ring that keeps drawing the eye.
            if state == .needsYou {
                Circle()
                    .stroke(color, lineWidth: 1.5)
                    .frame(width: 9, height: 9)
                    .scaleEffect(pulse ? 2.1 : 1.0)
                    .opacity(pulse ? 0.0 : 0.7)
            }

            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .shadow(color: color.opacity(0.7), radius: state == .flowing && breathe ? 4 : 2)
                .scaleEffect(scale)
        }
        .frame(width: 12, height: 12)
        .onAppear { startMotion() }
        .animation(motionAnimation, value: breathe)
        .animation(pulseAnimation, value: pulse)
    }

    private var scale: CGFloat {
        switch state {
        case .flowing: return breathe ? 1.12 : 0.92   // slow ambient breathing
        case .needsYou: return 1.0
        case .done: return 1.0
        case .error: return breathe ? 1.15 : 0.9      // sharp attention motion
        }
    }

    private var motionAnimation: Animation? {
        switch state {
        case .flowing: return .easeInOut(duration: 1.8).repeatForever(autoreverses: true)
        case .error: return .easeInOut(duration: 0.4).repeatForever(autoreverses: true)
        case .needsYou, .done: return nil
        }
    }

    private var pulseAnimation: Animation? {
        state == .needsYou ? .easeOut(duration: 1.1).repeatForever(autoreverses: false) : nil
    }

    private func startMotion() {
        breathe = true
        pulse = true
    }
}
