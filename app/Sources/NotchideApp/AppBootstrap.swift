import AppKit
import Darwin
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
    /// The active hotkey bindings. Push-to-talk defaults to the Control+Option
    /// hold (matching `PTTMonitor`); the HUD surfaces its chord as a hint.
    private let hotkeys = HotkeyConfig(pushToTalk: .controlOption)
    /// Records the HOST sidecar's process-group id; reclaimed on launch so a prior
    /// run's orphan is reaped before a fresh sidecar is spawned.
    private let sidecarPidFile = PidFile()
    private var controller: NotchController?
    private var socketProvider: SocketAAPProvider?
    private var hostLauncher: HostSessionLauncher?
    private var otlpProvider: OTLPProvider?
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

        // Reap any HOST sidecar orphaned by a previous run BEFORE we spawn a fresh
        // one, so a crash can never leave a duplicate sidecar tree behind.
        sidecarPidFile.reclaim()

        // Surface the push-to-talk chord in the voice HUD (⌃⌥ by default).
        model.pttHint = hotkeys.pushToTalk.displayName

        // The provider owns the AAP transport and decision correlation. Each
        // connection's handshake registers that provider's decision capability
        // with the store, so lanes are classified per the announced capabilities.
        // An abandoned gate (peer closed mid-decision) clears the wedged lane.
        let store = self.store
        let socketProvider = SocketAAPProvider(
            onProviderAnnounced: { providerID, capability in
                await store.register(providerID, decisionCapability: capability)
            },
            onGateAbandoned: { key in
                await store.abandonGate(for: key)
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
            },
            // Voice ACTUATE pushes travel the same provider's duplex actuate wire
            // (a safe no-op when the target has no live actuate connection).
            actuate: { [socketProvider] action in
                await socketProvider.actuate(action)
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
        hostLauncher?.stop()
        otlpProvider?.stop()
        controller?.teardown()
        socketProvider?.stop()
    }

    /// Starts the loopback OTLP receiver on the default port, falling back to an
    /// OS-assigned ephemeral port if `4318` is already in use (`EADDRINUSE`), and
    /// surfaces the actually-bound port. Returns `nil` if it could not bind at all
    /// — OTLP enrichment is a best-effort side-channel, so a bind failure never
    /// blocks launch.
    private func startOTLP(sink: @escaping OTLPProvider.Sink) -> OTLPProvider? {
        // Try the well-known port first, then port 0 (ephemeral, never clashes).
        for candidate in [OTLPProvider.defaultPort, 0] as [UInt16] {
            let provider = OTLPProvider(port: candidate, sink: sink)
            do {
                let bound = try provider.start()
                NSLog("notchide: OTLP receiver on 127.0.0.1:\(bound)")
                return provider
            } catch SocketError.bind(let err) where err == EADDRINUSE {
                NSLog("notchide: OTLP port \(candidate) in use (EADDRINUSE); trying an alternate")
                continue
            } catch {
                NSLog("notchide: OTLP receiver failed to start: \(error)")
                return nil
            }
        }
        NSLog("notchide: OTLP receiver could not bind any port; telemetry enrichment disabled")
        return nil
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
            let descriptors = await registry.descriptors()
            for descriptor in descriptors {
                await store.register(descriptor.id, decisionCapability: descriptor.decisionCapability)
            }
            // Providers that advertise `.actuate` can receive server-pushed
            // prompt/interrupt frames (HOST mode); the rest use the attach path.
            let actuatable = Set(descriptors.filter { $0.capabilities.contains(.actuate) }.map(\.id))
            controller.setActuatableProviders(actuatable)
        }

        do {
            try socketProvider.start()
            NSLog("notchide: listening on \(socketProvider.socketPath)")
        } catch {
            NSLog("notchide: failed to start socket provider: \(error)")
            return
        }

        // OTLP telemetry receiver (loopback only). Its mapped events ENRICH lanes
        // by session id — observe-only: `store.enrich` never opens a lane and never
        // drives a lane's lifecycle, so a lossy metrics/log side-channel can add
        // detail + refresh liveness but can never seize the user or clobber a gate.
        self.otlpProvider = startOTLP(sink: { events in
            Task { for event in events { await store.enrich(with: event) } }
        })

        // Spawn the HOST sidecar now the socket exists. A missing node/sidecar is
        // a clear logged failure state, never a crash — the app runs without it.
        // Its process-group id is recorded to `sidecarPidFile` for orphan reclaim.
        let hostLauncher = HostSessionLauncher(
            socketPath: socketProvider.socketPath,
            pidFile: sidecarPidFile
        )
        self.hostLauncher = hostLauncher
        hostLauncher.start()

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
