import SwiftUI
import NotchideKit

/// The Screen access pane — per-workspace observe/control grants.
///
/// Maps one-to-one onto `ScreenContextBroker` / `ScreenAccess`. The two
/// invariants are stated plainly and repeated at the point of the grant:
///   1. **Control is never voice-driven.** Even a full `.control` grant only
///      authorizes an action initiated by a *click*; a voice origin is always
///      refused (`ScreenContextBroker.authorizeControl`).
///   2. **Capture is never silent.** Any screenshot lights the macOS recording
///      indicator — notchide cannot hide it, and does not try to.
struct ScreenAccessPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        PaneScaffold(
            title: "Screen access",
            subtitle: "What each workspace's agent may do with your screen. The ladder is None → Observe → Control, granted per workspace and off by default."
        ) {
            SettingsCallout(
                .danger,
                "Control is never voice-driven. Even with a full Control grant, the agent may drive the pointer or keyboard only from a click you make — a spoken command can never move the mouse. This refusal is the invariant the whole feature rests on."
            )
            SettingsCallout(
                .caution,
                "Screen capture is never silent. Any screenshot handed to an agent lights the macOS recording indicator in the menu bar. notchide can't hide it and doesn't try."
            )

            if store.workspaces.isEmpty {
                EmptyStateView(
                    systemImage: "rectangle.on.rectangle.slash",
                    title: "No workspaces",
                    message: "Add a workspace first — screen access is granted per workspace."
                )
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(store.workspaces) { workspace in
                        ScreenAccessRow(
                            workspace: workspace,
                            access: store.screenGrants[workspace.id] ?? .none,
                            onChange: { newAccess in
                                Task { await store.setScreenAccess(newAccess, for: workspace.id) }
                            }
                        )
                    }
                }
            }
        }
    }
}

private struct ScreenAccessRow: View {
    let workspace: Workspace
    let access: ScreenAccess
    let onChange: @Sendable (ScreenAccess) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: "folder")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                        .font(Typo.title)
                    Text(workspace.root.path)
                        .font(Typo.monoSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: Theme.Spacing.md)

                Picker("", selection: Binding(get: { access }, set: onChange)) {
                    Text("None").tag(ScreenAccess.none)
                    Text("Observe").tag(ScreenAccess.observe)
                    Text("Control").tag(ScreenAccess.control)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: iconForAccess)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tintForAccess)
                Text(access.detail)
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 22 + Theme.Spacing.md)
        }
        .settingsCard(stroke: access == .control ? Theme.error.opacity(0.35) : Color.primary.opacity(0.08))
    }

    private var iconForAccess: String {
        switch access {
        case .none: return "eye.slash"
        case .observe: return "eye"
        case .control: return "cursorarrow.rays"
        }
    }

    private var tintForAccess: Color {
        switch access {
        case .none: return .secondary
        case .observe: return Theme.needsYou
        case .control: return Theme.error
        }
    }
}
