import AppKit
import Foundation
import NotchideKit

/// The application delegate — the one place everything is wired together.
///
/// On launch it becomes an accessory (agent) app, boots the notch UI, starts the
/// Unix-domain socket server, and connects the async decision round-trip:
///
///   notchide-hook ──envelope──▶ UnixSocketServer.handler
///                                   │  await SessionStore.ingest        (lanes/glyphs)
///                                   │  await Suppressor.shouldTap        (frontmost check)
///                                   │  await NotchController.present     (surface it)
///                                   │  await DecisionBroker.awaitDecision (if wantsDecision)
///                                   ▼
///   notchide-hook ◀──decision── (UI Approve/Deny/redirect → broker.resolve)
///
/// Non-decision events only update lanes/glyphs; a `wantsDecision` gate suspends
/// in the broker until the user acts (or the timeout fails open).
@MainActor
public final class NotchideAppDelegate: NSObject, NSApplicationDelegate {
    // Core (from NotchideKit) — all offline, dependency-free.
    private let store = SessionStore()
    private let broker = DecisionBroker()
    private let suppressor = Suppressor()
    private let frontmost = AppKitFrontmostContext()

    // App-side state + UI.
    private let model = NotchViewModel()
    private let remembered = RememberedStore()
    private var controller: NotchController?
    private var server: UnixSocketServer?
    private var lanesTask: Task<Void, Never>?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app — no Dock icon, no menu bar presence.
        NSApp.setActivationPolicy(.accessory)

        let controller = NotchController(
            model: model,
            broker: broker,
            diffProvider: GitDiffProvider(),
            terminalJumper: TerminalJumper(),
            remembered: remembered
        )
        self.controller = controller
        controller.start()

        observeLanes(into: controller)
        startSocketServer(driving: controller)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        lanesTask?.cancel()
        lanesTask = nil
        controller?.teardown()
        server?.stop()
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

    /// Binds `hook.sock` and installs the handler that runs the full round-trip.
    private func startSocketServer(driving controller: NotchController) {
        let store = self.store
        let broker = self.broker
        let suppressor = self.suppressor
        let frontmost = self.frontmost
        let remembered = self.remembered

        let handler: UnixSocketServer.Handler = { envelope in
            let event = envelope.event
            let key = event.sessionId

            // 1. Update lanes/glyphs (this drives the cockpit via the store stream).
            await store.ingest(event)

            // 2. Approve-and-remember fast path: a decision gate whose exact,
            //    normalized command was previously remembered resolves .allow
            //    immediately and silently — the console is never shown.
            if envelope.wantsDecision,
               let command = event.commandDescription,
               await remembered.contains(command) {
                return DecisionMessage(id: envelope.id, permission: .allow, reason: "remembered by notchide")
            }

            // 3. Attention routing: should this actually tap the user? (Global
            //    mute is threaded through here — a muted user is never tapped.)
            let (tap, reason) = await suppressor.shouldTap(
                event: event, key: key, muted: MuteSettings.isMuted, context: frontmost
            )

            // 4. Surface. A `wantsDecision` PreToolUse gate is the ONE deliberate
            //    auto-expand (it blocks a real agent). A non-decision "tap" is
            //    passive: it only pulses the pill — never drops the full console
            //    (silence-by-default, DESIGN §4.1/§8).
            if envelope.wantsDecision {
                await controller.present(envelope: envelope, reason: reason)
            } else if tap {
                await controller.pulsePill()
            }

            // 5. For a blocking gate, suspend until the human decides (or timeout).
            //    The app-side timeout matches the sidecar's default so a
            //    late-but-valid click is never dropped by the app expiring first.
            if envelope.wantsDecision {
                let timeout = Double(HookTimeout.defaultMilliseconds) / 1000.0
                return await broker.awaitDecision(id: envelope.id, timeout: timeout)
            }
            return nil
        }

        do {
            try NotchidePaths.ensureSupportDirectory()
            let server = UnixSocketServer(handler: handler)
            try server.start()
            self.server = server
            NSLog("notchide: listening on \(server.socketPath)")
        } catch {
            NSLog("notchide: failed to start socket server: \(error)")
        }
    }
}
