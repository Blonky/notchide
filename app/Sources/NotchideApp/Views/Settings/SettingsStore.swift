import Foundation
import SwiftUI
import NotchideKit

/// The single observable model behind the preferences window.
///
/// It owns the *real* NotchideKit stores (`WorkspaceStore`, `ToolRegistry`,
/// `ScreenContextBroker`, `ProviderRegistry`) and drives them with plain `await`
/// actor calls, mirroring their state into `@Published` snapshots SwiftUI can
/// render. Nothing here is a mock: every mutation lands in the same JSON on disk
/// the running app reads.
///
/// Two pieces of config have no dedicated NotchideKit store — `HotkeyConfig` (the
/// design says it lives "inside the app's settings blob") and the per-workspace
/// screen grants (the broker is in-memory only). This model persists both to
/// small owner-only JSON files under `NotchidePaths.supportDirectory`, and
/// re-hydrates the broker from disk on launch so a grant survives a restart.
@MainActor
final class SettingsStore: ObservableObject {

    // MARK: Real NotchideKit stores

    let workspaceStore: WorkspaceStore
    let toolRegistry: ToolRegistry
    let screenBroker: ScreenContextBroker

    // MARK: Published snapshots (rendered by the panes)

    @Published var workspaces: [Workspace] = []
    @Published var connectors: [ToolConnector] = []
    /// Per-workspace screen grants, mirrored from the broker (defaults `.none`).
    @Published var screenGrants: [UUID: ScreenAccess] = [:]
    /// Agent providers discovered from on-disk manifests.
    @Published var manifestProviders: [ProviderDescriptor] = []
    @Published var hotkeys: HotkeyConfig = SettingsStore.recommendedHotkeys
    /// True while `bootstrap()` has finished at least once (drives placeholders).
    @Published private(set) var didLoad = false

    /// The always-present built-in providers, shown read-only in the Providers
    /// pane. These are compiled in, not manifests, so the user can't remove them.
    let builtinProviders: [ProviderDescriptor] = [
        ClaudeCodeProvider.descriptor,
        ProviderDescriptor(
            id: OTLPProvider.providerID,
            displayName: "OTLP enrichment (:4318)",
            capabilities: OTLPProvider.capabilities,
            decisionCapability: .notifyOnly
        ),
    ]

    // MARK: Backing files for config with no NotchideKit store

    private let hotkeysURL: URL
    private let screenGrantsURL: URL
    private let providersDir: URL

    // MARK: Init

    init(
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        toolRegistry: ToolRegistry = ToolRegistry(),
        screenBroker: ScreenContextBroker = ScreenContextBroker(),
        supportDirectory: URL = NotchidePaths.supportDirectory
    ) {
        self.workspaceStore = workspaceStore
        self.toolRegistry = toolRegistry
        self.screenBroker = screenBroker
        self.hotkeysURL = supportDirectory.appendingPathComponent("hotkeys.json", isDirectory: false)
        self.screenGrantsURL = supportDirectory.appendingPathComponent("screen-access.json", isDirectory: false)
        self.providersDir = supportDirectory.appendingPathComponent("providers", isDirectory: true)
    }

    // MARK: Bootstrap + refreshers

    /// Loads everything from disk and hydrates the in-memory broker. Safe to call
    /// on `.task`; every step tolerates a missing/corrupt file.
    func bootstrap() async {
        try? await workspaceStore.load()
        try? await toolRegistry.load()
        loadHotkeys()
        await loadScreenGrants()
        await refreshWorkspaces()
        await refreshTools()
        await refreshProviders()
        didLoad = true
    }

    func refreshWorkspaces() async {
        workspaces = await workspaceStore.all()
        // Drop any grant snapshot whose workspace is gone.
        var grants: [UUID: ScreenAccess] = [:]
        for workspace in workspaces {
            grants[workspace.id] = await screenBroker.access(for: workspace.id)
        }
        screenGrants = grants
    }

    func refreshTools() async {
        connectors = await toolRegistry.all()
    }

    /// Rebuilds the manifest-provider list from a *fresh* registry so repeated
    /// scans never accumulate duplicate descriptors.
    func refreshProviders() async {
        let registry = ProviderRegistry()
        await registry.loadManifests(from: providersDir)
        manifestProviders = await registry.descriptors()
    }

    // MARK: Workspace mutators

    func addWorkspace(_ workspace: Workspace) async {
        await workspaceStore.add(workspace)
        await refreshWorkspaces()
    }

    func removeWorkspace(id: UUID) async {
        await workspaceStore.remove(id: id)
        await screenBroker.revoke(for: id)
        await refreshWorkspaces()
        persistScreenGrants()
    }

    // MARK: Screen-access mutators

    /// Sets a workspace's screen-access level. `.none` revokes; anything else is a
    /// grant. Persisted so it survives relaunch.
    func setScreenAccess(_ access: ScreenAccess, for id: UUID) async {
        if access == .none {
            await screenBroker.revoke(for: id)
        } else {
            await screenBroker.grant(access, for: id)
        }
        screenGrants[id] = access
        persistScreenGrants()
    }

    // MARK: Tool mutators

    func registerTool(_ connector: ToolConnector) async {
        try? await toolRegistry.register(connector)
        await refreshTools()
    }

    func setToolEnabled(_ enabled: Bool, id: String) async {
        try? await toolRegistry.setEnabled(enabled, id: id)
        await refreshTools()
    }

    func removeTool(id: String) async {
        try? await toolRegistry.remove(id: id)
        await refreshTools()
    }

    // MARK: Provider mutators

    /// Writes a `provider.json` manifest for a new agent provider, then rescans.
    /// This is the real discovery path `ProviderRegistry.loadManifests` reads.
    func addProviderManifest(id: String, displayName: String, capabilities: Set<Capability>) throws {
        let slug = Self.slug(id.isEmpty ? displayName : id)
        let dir = providersDir.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "id": id,
            "displayName": displayName,
            "capabilities": capabilities.map(\.rawValue).sorted(),
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("provider.json"), options: [.atomic])
    }

    /// Deletes a manifest provider's directory, then rescans. Built-ins have no
    /// directory and are silently skipped.
    func removeProviderManifest(id: ProviderID) {
        // Find the sibling dir whose provider.json declares this id.
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: providersDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let json = entry.appendingPathComponent("provider.json")
            guard
                let data = try? Data(contentsOf: json),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                (object["id"] as? String) == id.raw
            else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: Hotkeys

    /// Replaces the hotkey config and persists it. No-ops the persist if invalid,
    /// but still updates the in-memory value so the UI reflects the edit.
    func updateHotkeys(_ config: HotkeyConfig) {
        hotkeys = config
        guard config.isValid() else { return }
        persistHotkeys()
    }

    // MARK: Persistence (files with no NotchideKit store)

    /// The out-of-box hotkey binding for a *fresh* install. Overrides
    /// `HotkeyConfig.defaultConfig` (which is Fn-double-tap) with the recommended
    /// `⌃⌥` push-to-talk chord — Fn-double-tap collides with macOS Dictation
    /// (DESIGN §12.7), so it's never the default this surface offers.
    static let recommendedHotkeys = HotkeyConfig(pushToTalk: .controlOption)

    private func loadHotkeys() {
        guard
            let data = try? Data(contentsOf: hotkeysURL),
            let config = try? JSONDecoder().decode(HotkeyConfig.self, from: data)
        else {
            hotkeys = Self.recommendedHotkeys
            return
        }
        hotkeys = config
    }

    private func persistHotkeys() {
        guard let data = try? JSONEncoder().encode(hotkeys) else { return }
        Self.writeOwnerOnly(data, to: hotkeysURL)
    }

    private func loadScreenGrants() async {
        guard
            let data = try? Data(contentsOf: screenGrantsURL),
            let stored = try? JSONDecoder().decode([ScreenContextGrant].self, from: data)
        else { return }
        for grant in stored where grant.access != .none {
            await screenBroker.grant(grant.access, for: grant.workspaceID)
        }
    }

    private func persistScreenGrants() {
        let grants = screenGrants
            .filter { $0.value != .none }
            .map { ScreenContextGrant(workspaceID: $0.key, access: $0.value) }
        guard let data = try? JSONEncoder().encode(grants) else { return }
        Self.writeOwnerOnly(data, to: screenGrantsURL)
    }

    // MARK: Helpers

    /// Atomic write clamped to owner-only `0600`, mirroring the NotchideKit stores'
    /// posture — these files reference private local paths and bindings.
    private static func writeOwnerOnly(_ data: Data, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        guard (try? data.write(to: url, options: [.atomic])) != nil else { return }
        try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
    }

    /// A filesystem-safe slug for a provider directory name.
    private static func slug(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
        let lowered = raw.lowercased()
        let mapped = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped).replacingOccurrences(of: "--", with: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "provider-\(UUID().uuidString.prefix(8))" : trimmed
    }
}

// MARK: - Display helpers on the model types

extension Capability {
    /// A short human label for a capability chip.
    var displayLabel: String {
        switch self {
        case .observe: return "observe"
        case .gate: return "gate"
        case .actuate: return "actuate"
        case .observeScreen: return "see screen"
        case .controlScreen: return "control screen"
        }
    }
}

extension ScreenAccess {
    var displayLabel: String {
        switch self {
        case .none: return "No access"
        case .observe: return "Observe"
        case .control: return "Control"
        }
    }

    var detail: String {
        switch self {
        case .none: return "The agent gets no screenshots and cannot touch the screen."
        case .observe: return "The agent may be handed an on-request screenshot as context. Read-only."
        case .control: return "The agent may drive the pointer and keyboard — but only from a click, never by voice."
        }
    }
}

extension ToolKind {
    var displayLabel: String {
        switch self {
        case .github: return "GitHub"
        case .mcp: return "MCP server"
        case .browser: return "Browser"
        case .mail: return "Mail"
        case .slack: return "Slack"
        case .shell: return "Shell"
        case .custom: return "Custom"
        }
    }

    var systemImage: String {
        switch self {
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .mcp: return "puzzlepiece.extension"
        case .browser: return "globe"
        case .mail: return "envelope"
        case .slack: return "number"
        case .shell: return "terminal"
        case .custom: return "wrench.and.screwdriver"
        }
    }
}
