import SwiftUI
import NotchideKit

/// The Tools pane — the external `ToolConnector`s notchide can offer to agents.
///
/// Drives `ToolRegistry` directly: list, add (with a `ToolKind` picker), toggle
/// `enabled`, and remove. A disabled connector stays configured but is not offered
/// to agents.
struct ToolsPane: View {
    @ObservedObject var store: SettingsStore
    @State private var showAdd = false

    var body: some View {
        PaneScaffold(
            title: "Tools",
            subtitle: "Connectors agents can reach — GitHub, MCP servers, a browser, mail, Slack, a shell. Disable one to keep it configured but hidden from agents."
        ) {
            if store.connectors.isEmpty {
                EmptyStateView(
                    systemImage: "wrench.and.screwdriver",
                    title: "No tools yet",
                    message: "Add a connector to make it available to your agents."
                )
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(store.connectors) { connector in
                        ToolRow(
                            connector: connector,
                            onToggle: { enabled in
                                Task { await store.setToolEnabled(enabled, id: connector.id) }
                            },
                            onRemove: {
                                Task { await store.removeTool(id: connector.id) }
                            }
                        )
                    }
                }
            }

            Button {
                showAdd = true
            } label: {
                Label("Add tool…", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showAdd) {
            AddSheet(store: store, kind: .tool)
        }
    }
}

private struct ToolRow: View {
    let connector: ToolConnector
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: connector.kind.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(connector.enabled ? Theme.flowing : Color.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(connector.name)
                    .font(Typo.title)
                    .foregroundStyle(connector.enabled ? Color.primary : Color.secondary)
                HStack(spacing: Theme.Spacing.xs) {
                    Text(connector.kind.displayLabel)
                        .font(Typo.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(connector.id)
                        .font(Typo.monoSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: Theme.Spacing.sm)

            Toggle("", isOn: Binding(
                get: { connector.enabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .help(connector.enabled ? "Offered to agents" : "Hidden from agents")

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove connector")
        }
        .settingsCard()
    }
}
