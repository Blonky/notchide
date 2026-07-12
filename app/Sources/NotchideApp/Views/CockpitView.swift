import SwiftUI
import NotchideKit

/// The collapsed cockpit: a row of pre-attentive dots, one per active lane.
///
/// No text — state is read entirely through color + motion, so it registers in
/// peripheral vision. Sits in DynamicNotchKit's compact (trailing) slot beside
/// the notch.
public struct CockpitView: View {
    @ObservedObject var model: NotchViewModel

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
