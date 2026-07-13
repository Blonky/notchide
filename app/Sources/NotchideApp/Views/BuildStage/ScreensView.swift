import SwiftUI

/// A `.screens(before:after:)` artifact (DESIGN §14): a before/after screenshot
/// pair with a **compare affordance** — a draggable reveal divider that wipes the
/// `before` image over the `after` one.
///
/// On the first capture there is no `before`, so it degrades to a single framed
/// `after` image with no divider.
public struct ScreensView: View {
    let before: URL?
    let after: URL

    /// 0 = all `before`, 1 = all `after`. Starts centered.
    @State private var reveal: CGFloat = 0.5

    public init(before: URL?, after: URL) {
        self.before = before
        self.after = after
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                SectionLabel(text: before == nil ? "AFTER" : "BEFORE / AFTER")
                Spacer(minLength: 0)
                if before != nil {
                    Text("drag to compare")
                        .font(Typo.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // AFTER fills the frame.
                    screenshot(after)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    cornerTag("after", .trailing, tint: Theme.done)

                    if let before {
                        // BEFORE clipped to the reveal fraction, drawn on top.
                        screenshot(before)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geo.size.width * reveal)
                            }
                        cornerTag("before", .leading, tint: Theme.needsYou)
                        divider(at: geo.size.width * reveal, height: geo.size.height)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard geo.size.width > 0 else { return }
                            reveal = min(max(value.location.x / geo.size.width, 0), 1)
                        }
                )
            }
            .frame(height: 280)
            .buildCard()
        }
    }

    /// A framed async image with a neutral loading/failure placeholder.
    @ViewBuilder
    private func screenshot(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                placeholder(system: "exclamationmark.triangle", label: "image unavailable")
            case .empty:
                placeholder(system: "photo", label: "loading…")
            @unknown default:
                placeholder(system: "photo", label: "loading…")
            }
        }
    }

    private func placeholder(system: String, label: String) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: system)
                .font(.system(size: 18))
                .foregroundStyle(Theme.textTertiary)
            Text(label)
                .font(Typo.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sunkenSurface)
    }

    /// The reveal handle: a thin bright line with a grabber knob.
    private func divider(at x: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 1.5, height: height)
            Circle()
                .fill(Theme.raisedSurface)
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                .overlay(
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                )
        }
        .position(x: x, y: height / 2)
        .allowsHitTesting(false)
    }

    private func cornerTag(_ text: String, _ edge: HorizontalAlignment, tint: Color) -> some View {
        VStack {
            HStack {
                if edge == .trailing { Spacer() }
                Text(text)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.85))
                    .clipShape(Capsule())
                if edge == .leading { Spacer() }
            }
            Spacer()
        }
        .padding(Theme.Spacing.sm)
        .allowsHitTesting(false)
    }
}
