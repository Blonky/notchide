import SwiftUI
import NotchideKit

/// The notchide preferences window — a native, tabbed settings surface.
///
/// The notch itself stays a *glance* surface: an ambient cockpit and a read-only
/// review console. Everything that is configuration rather than glance lives
/// here, out of the notch. Six panes, one per subsystem:
///
///   Workspaces · Providers · Tools · Hotkeys · Screen access · Telemetry
///
/// Each pane drives the real NotchideKit stores through `SettingsStore`.
public struct PreferencesView: View {
    @StateObject private var store: SettingsStore

    /// Builds a preferences window backed by the real NotchideKit stores.
    public init() {
        _store = StateObject(wrappedValue: SettingsStore())
    }

    /// Injectable initializer for tests / previews that need a store backed by
    /// temp files. Internal because `SettingsStore` is an app-internal type.
    init(store: SettingsStore) {
        _store = StateObject(wrappedValue: store)
    }

    public var body: some View {
        TabView {
            WorkspacesPane(store: store)
                .tabItem { Label("Workspaces", systemImage: "folder") }

            ProvidersPane(store: store)
                .tabItem { Label("Providers", systemImage: "cpu") }

            ToolsPane(store: store)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }

            HotkeysPane(store: store)
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }

            ScreenAccessPane(store: store)
                .tabItem { Label("Screen access", systemImage: "rectangle.inset.filled.and.person.filled") }

            TelemetryPane(store: store)
                .tabItem { Label("Telemetry", systemImage: "chart.bar.xaxis") }
        }
        .frame(minWidth: 620, idealWidth: 660, minHeight: 520, idealHeight: 600)
        .task {
            // Hydrate every store once when the window first appears.
            if !store.didLoad { await store.bootstrap() }
        }
    }
}

/// A common scaffold every pane uses: a fixed header over scrollable content.
/// Keeps the six panes visually consistent without repeating the layout.
struct PaneScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: title, subtitle: subtitle)
                .padding(Theme.Spacing.xl)
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    content()
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
