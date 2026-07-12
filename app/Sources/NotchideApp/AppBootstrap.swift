import AppKit
import Foundation
import NotchideKit

/// The application delegate — the one place everything is wired together.
///
/// On launch it becomes an accessory (agent) app, boots the notch UI, and stands
/// up the AAP provider model:
///
///   adapter ──AAP frames──▶ SocketAAPProvider (owns socket + decision correlation)
///                               │  events()  ──▶ SessionStore.ingest   (lanes/glyphs)
///                               │            ──▶ NotchController.consider (Suppressor → surface)
///                               ▼
///   adapter ◀── decision ── SocketAAPProvider.resolve(AgentDecision)   (UI Approve/Deny/redirect)
///
/// The provider now owns wire correlation (replacing the app's old
/// DecisionBroker + UnixSocketServer handler wiring). We consume the provider's
/// `events()` stream directly rather than `ProviderRegistry.fanIn(into:)` so each
/// event can both update the store AND drive the capability-aware console — an
/// `AsyncStream` has a single consumer, so the two cannot both drain it. The
/// registry is still used for descriptors + on-disk manifests so lanes are
/// classified by capability.
@MainActor
public final class NotchideAppDelegate: NSObject, NSApplicationDelegate {
    // Core (from NotchideKit) — all offline, dependency-free.
    private let store = SessionStore()
    private let suppressor = Suppressor()
    private let frontmost = AppKitFrontmostContext()
    private let registry = ProviderRegistry()

    // App-side state + UI.
    private let model = NotchViewModel()
    private let remembered = RememberedStore()
    private var controller: NotchController?
    private var socketProvider: SocketAAPProvider?
    private var lanesTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app — no Dock icon, no menu bar presence.
        NSApp.setActivationPolicy(.accessory)

        do {
            try NotchidePaths.ensureSupportDirectory()
        } catch {
            NSLog("notchide: failed to prepare support directory: \(error)")
        }

        // The provider owns the AAP transport and decision correlation. Each
        // connection's handshake registers that provider's decision capability
        // with the store, so lanes are classified per the announced capabilities.
        let store = self.store
        let socketProvider = SocketAAPProvider(
            onProviderAnnounced: { providerID, capability in
                await store.register(providerID, decisionCapability: capability)
            }
        )
        self.socketProvider = socketProvider

        let controller = NotchController(
            model: model,
            suppressor: suppressor,
            frontmost: frontmost,
            diffProvider: GitDiffProvider(),
            terminalJumper: TerminalJumper(),
            remembered: remembered,
            // The one place the app hands a decision back to the agent: the
            // provider writes it onto the correlated open connection.
            resolveDecision: { [socketProvider] decision in
                await socketProvider.resolve(decision)
            }
        )
        self.controller = controller
        controller.start()

        observeLanes(into: controller)
        bootProviders(socketProvider: socketProvider, driving: controller)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        lanesTask?.cancel(); lanesTask = nil
        eventsTask?.cancel(); eventsTask = nil
        controller?.teardown()
        socketProvider?.stop()
    }

    /// Bridges `SessionStore`'s lane stream onto the `@MainActor` view model and
    /// keeps the ambient cockpit in sync. Event-driven — no polling.
    private func observeLanes(into controller: NotchController) {
        let store = self.store
        let model = self.model
        lanesTask = Task {
            for await lanes in await store.snapshots() {
                model.lanes = lanes
                await controller.lanesDidUpdate()
            }
        }
    }

    /// Registers descriptors (built-in + on-disk manifests), starts the socket
    /// transport, and fans the provider's events into the store + attention router.
    private func bootProviders(socketProvider: SocketAAPProvider, driving controller: NotchController) {
        let store = self.store
        let registry = self.registry
        let providersDir = NotchidePaths.supportDirectory
            .appendingPathComponent("providers", isDirectory: true)

        // Descriptors let the store classify a provider's lanes by capability even
        // before any of its events arrive. `loadManifests` contributes on-disk
        // provider descriptors (Swift can't dynamically load code, so a manifest
        // only contributes its capability metadata, not a live provider).
        Task {
            await registry.register(socketProvider)
            await registry.loadManifests(from: providersDir)
            for descriptor in await registry.descriptors() {
                await store.register(descriptor.id, decisionCapability: descriptor.decisionCapability)
            }
        }

        do {
            try socketProvider.start()
            NSLog("notchide: listening on \(socketProvider.socketPath)")
        } catch {
            NSLog("notchide: failed to start socket provider: \(error)")
            return
        }

        // The single consumer of the provider's event stream: update lanes/glyphs
        // (the store broadcast drives the cockpit via `observeLanes`) and route
        // attention through the controller (Suppressor → auto-surface / pulse).
        eventsTask = Task {
            for await event in socketProvider.events() {
                await store.ingest(event)
                let capability = await store.decisionCapability(for: event.providerID)
                await controller.consider(event: event, capability: capability)
            }
        }
    }
}
