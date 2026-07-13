import SwiftUI
import NotchideKit

/// The Workspaces pane — the projects the notch tracks.
///
/// Lists `WorkspaceStore`, adds a folder (NSOpenPanel → `.folder`) or a cloned
/// GitHub repo (`WorkspaceGit.clone` → `.git`), and exposes per-workspace screen
/// access inline (with the standing rule that Control never responds to voice).
struct WorkspacesPane: View {
    @ObservedObject var store: SettingsStore
    @State private var sheetKind: AddKind?

    var body: some View {
        PaneScaffold(
            title: "Workspaces",
            subtitle: "The projects the notch follows. Open a folder already on disk, or clone a GitHub repo into one you choose."
        ) {
            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    sheetKind = .folder
                } label: {
                    Label("Add folder", systemImage: "folder.badge.plus")
                }
                Button {
                    sheetKind = .githubRepo
                } label: {
                    Label("Add GitHub repo", systemImage: "arrow.down.circle")
                }
                Spacer()
            }

            if store.workspaces.isEmpty {
                EmptyStateView(
                    systemImage: "folder",
                    title: "No workspaces yet",
                    message: "Add a folder or clone a repo to start tracking a project."
                )
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(store.workspaces) { workspace in
                        WorkspaceRow(
                            workspace: workspace,
                            access: store.screenGrants[workspace.id] ?? .none,
                            onAccessChange: { newAccess in
                                Task { await store.setScreenAccess(newAccess, for: workspace.id) }
                            },
                            onRemove: {
                                Task { await store.removeWorkspace(id: workspace.id) }
                            }
                        )
                    }
                }
            }
        }
        .sheet(item: $sheetKind) { kind in
            AddSheet(store: store, kind: kind)
        }
    }
}

// Allow `AddKind` to drive `.sheet(item:)`.
extension AddKind: Identifiable {
    var id: Self { self }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    let access: ScreenAccess
    let onAccessChange: @Sendable (ScreenAccess) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.flowing)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(workspace.name)
                            .font(Typo.title)
                        sourceTag
                    }
                    Text(workspace.root.path)
                        .font(Typo.monoSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if case let .git(remote, branch) = workspace.source {
                        Text(branch.map { "\(remote) · \($0)" } ?? remote)
                            .font(Typo.monoSmall)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: Theme.Spacing.sm)

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove workspace")
            }

            Divider()

            // Inline per-workspace screen access.
            HStack(spacing: Theme.Spacing.md) {
                Text("Screen access")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { access }, set: onAccessChange)) {
                    Text("None").tag(ScreenAccess.none)
                    Text("Observe").tag(ScreenAccess.observe)
                    Text("Control").tag(ScreenAccess.control)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
                Spacer()
            }

            if access == .control {
                SettingsCallout(
                    .danger,
                    "Control never responds to voice. The agent may drive the pointer/keyboard only from a click — a spoken command can't. Capture also lights the macOS recording indicator."
                )
            }
        }
        .settingsCard(stroke: access == .control ? Theme.error.opacity(0.35) : Color.primary.opacity(0.08))
    }

    private var sourceIcon: String {
        switch workspace.source {
        case .folder: return "folder"
        case .git: return "arrow.triangle.branch"
        }
    }

    @ViewBuilder
    private var sourceTag: some View {
        switch workspace.source {
        case .folder:
            TagChip(text: "folder", systemImage: "folder", tint: Theme.textSecondary)
        case .git:
            TagChip(text: "git", systemImage: "arrow.triangle.branch", tint: Theme.flowing)
        }
    }
}
