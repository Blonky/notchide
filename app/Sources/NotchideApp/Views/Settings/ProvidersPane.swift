import SwiftUI
import NotchideKit

/// The Providers pane — the agent adapters notchide can light lanes for.
///
/// Two tiers, mirroring `ProviderRegistry.descriptors()`:
///   • **Built-in** — compiled adapters (`ClaudeCodeProvider`, the OTLP
///     enrichment plane). Read-only: capabilities are fixed and they can't be
///     removed.
///   • **From manifests** — providers discovered from
///     `~/Library/Application Support/notchide/providers/<name>/provider.{toml,json}`.
///     Adding one writes a `provider.json` the registry then scans.
struct ProvidersPane: View {
    @ObservedObject var store: SettingsStore
    @State private var showAdd = false

    var body: some View {
        PaneScaffold(
            title: "Providers",
            subtitle: "The agent adapters that feed lanes. Every provider maps its own events into the fixed four-state glyph model — it doesn't invent colors or gates."
        ) {
            section(title: "Built-in") {
                ForEach(store.builtinProviders, id: \.id) { descriptor in
                    ProviderRow(descriptor: descriptor, removable: false, onRemove: nil)
                }
            }

            section(title: "From manifests") {
                if store.manifestProviders.isEmpty {
                    EmptyStateView(
                        systemImage: "doc.badge.plus",
                        title: "No manifest providers",
                        message: "Drop a provider.toml under the notchide providers folder, or add one below."
                    )
                } else {
                    ForEach(store.manifestProviders, id: \.id) { descriptor in
                        ProviderRow(
                            descriptor: descriptor,
                            removable: true,
                            onRemove: {
                                store.removeProviderManifest(id: descriptor.id)
                                Task { await store.refreshProviders() }
                            }
                        )
                    }
                }
            }

            HStack {
                Button {
                    showAdd = true
                } label: {
                    Label("Add provider…", systemImage: "plus")
                }
                Spacer()
                Button {
                    Task { await store.refreshProviders() }
                } label: {
                    Label("Rescan manifests", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            SettingsCallout(
                .info,
                "A manifest only contributes a descriptor — Swift can't load code at runtime, so a live provider still connects over the AAP socket. The manifest just lets notchide classify its lanes before the first event arrives."
            )
        }
        .sheet(isPresented: $showAdd) {
            AddSheet(store: store, kind: .provider)
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            VStack(spacing: Theme.Spacing.sm) {
                content()
            }
        }
    }
}

private struct ProviderRow: View {
    let descriptor: ProviderDescriptor
    let removable: Bool
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "cpu")
                .font(.system(size: 16))
                .foregroundStyle(Theme.flowing)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(descriptor.displayName)
                        .font(Typo.title)
                    Text(descriptor.id.raw)
                        .font(Typo.monoSmall)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: Theme.Spacing.xs) {
                    // Decision capability first — it's the load-bearing one.
                    if descriptor.decisionCapability == .blocking {
                        TagChip(text: "can gate", systemImage: "hand.raised", tint: Theme.needsYou)
                    } else {
                        TagChip(text: "notify-only", systemImage: "dot.radiowaves.left.and.right", tint: Theme.flowing)
                    }
                    ForEach(Capability.allCases.filter { descriptor.capabilities.contains($0) }, id: \.self) { capability in
                        TagChip(text: capability.displayLabel, tint: capabilityTint(capability))
                    }
                }
            }

            Spacer(minLength: Theme.Spacing.sm)

            if removable, let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this manifest provider")
            }
        }
        .settingsCard()
    }

    private func capabilityTint(_ capability: Capability) -> Color {
        switch capability {
        case .controlScreen: return Theme.error
        case .observeScreen: return Theme.needsYou
        default: return Theme.textSecondary
        }
    }
}
