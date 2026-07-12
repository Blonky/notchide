import SwiftUI
import AppKit
import Combine
import DynamicNotchKit
import NotchideKit

/// Owns the on-screen object: the DynamicNotchKit panel hosting our collapsed
/// cockpit and expanded review console, plus every interaction timer
/// (hover-intent, ESC, click-to-pin, auto-collapse) and the global summon hotkey.
///
/// `@MainActor` throughout — all DynamicNotchKit control (`expand`/`compact`/
/// `hide`, which are `@MainActor` in the library) and all SwiftUI/AppKit state
/// mutation happen here.
@MainActor
public final class NotchController {
    private let model: NotchViewModel
    private let broker: DecisionBroker
    private let diffProvider: GitDiffProvider
    private let terminalJumper: TerminalJumper
    private let remembered: RememberedStore

    /// The DynamicNotchKit panel. `.auto` style resolves to a real notch on
    /// notched Macs and to the first-class floating pill everywhere else.
    ///
    /// The expanded slot hosts `NotchRootView`, which renders the review console
    /// when a review is on screen and the compact cockpit otherwise — this is
    /// what lets the floating fallback (no compact slot, see `showCockpit`) still
    /// present an ambient cockpit.
    private var notch: DynamicNotch<NotchRootView, EmptyView, CockpitView>?
    private var hotkey: HotkeyMonitor?

    private enum Presentation { case hidden, cockpit, expanded }
    private var presentation: Presentation = .hidden
    private var isHovering = false

    private var hoverIntentTask: Task<Void, Never>?
    private var autoCollapseTask: Task<Void, Never>?
    private var hoverObserverTask: Task<Void, Never>?

    /// Outstanding decision gates queued behind the one currently on screen, in
    /// arrival order. A newer gate (or a non-decision tap) must never replace a
    /// still-pending decision the broker is awaiting (see `present`).
    private var pendingGates: [ReviewContext] = []
    private let maxQueuedGates = 32

    /// Per-gate app-side expiry timers (see F): when a shown gate expires, its
    /// console controls are disabled and it is furled so a stale click can't
    /// "decide" something already dropped.
    private var gateExpiryTasks: [UUID: Task<Void, Never>] = [:]

    /// How long the console stays down before auto-furling (unless pinned/hovered).
    public var autoCollapseSeconds: Double = 12
    /// Hover-intent delay before a peek expands the console.
    public var hoverIntentSeconds: Double = 0.2
    /// App-side gate lifetime. Kept `>=` the sidecar's effective timeout
    /// (`HookTimeout.defaultMilliseconds`) so a late-but-valid click is never
    /// dropped by the app expiring the gate before the sidecar does.
    public var gateTimeoutSeconds: Double = Double(HookTimeout.defaultMilliseconds) / 1000.0

    public init(
        model: NotchViewModel,
        broker: DecisionBroker,
        diffProvider: GitDiffProvider,
        terminalJumper: TerminalJumper,
        remembered: RememberedStore
    ) {
        self.model = model
        self.broker = broker
        self.diffProvider = diffProvider
        self.terminalJumper = terminalJumper
        self.remembered = remembered
    }

    // MARK: Lifecycle

    public func start() {
        let model = self.model
        let notch = DynamicNotch(
            hoverBehavior: .all,
            style: .auto,
            expanded: { NotchRootView(model: model) },
            compactTrailing: { CockpitView(model: model) }
        )
        self.notch = notch

        wireModelCallbacks()
        observeHover()

        let hotkey = HotkeyMonitor()
        hotkey.onSummon = { [weak self] in self?.summon() }
        hotkey.onEscape = { [weak self] in Task { await self?.collapse() } }
        hotkey.start()
        self.hotkey = hotkey
    }

    /// Cancels every long-lived task and monitor. Called on app termination so
    /// the observer/hover/expiry tasks and hotkey monitors don't outlive us.
    public func teardown() {
        hoverObserverTask?.cancel(); hoverObserverTask = nil
        hoverIntentTask?.cancel(); hoverIntentTask = nil
        autoCollapseTask?.cancel(); autoCollapseTask = nil
        for task in gateExpiryTasks.values { task.cancel() }
        gateExpiryTasks.removeAll()
        hotkey?.stop()
        hotkey = nil
    }

    // MARK: Ingest-driven presentation

    /// Called after the shared lane snapshot changes; keeps the ambient cockpit
    /// visible whenever there are lanes, hidden when there are none.
    public func lanesDidUpdate() async {
        guard presentation != .expanded else { return }
        if model.lanes.isEmpty {
            if presentation != .hidden {
                await notch?.hide()
                presentation = .hidden
            }
        } else if presentation != .cockpit {
            await showCockpit()
        }
    }

    /// Surface a specific envelope in the review console. Called by the socket
    /// handler ONLY for `wantsDecision` gates — the one deliberate auto-expand.
    /// (Non-decision taps go through `pulsePill`, never here.)
    public func present(envelope: HookEnvelope, reason: String) async {
        let context = makeContext(envelope: envelope, reason: reason)

        guard context.wantsDecision else {
            // Defensive: a non-decision surfacing must never clobber a pending
            // decision the broker is still awaiting.
            if let current = model.review, current.wantsDecision, await broker.isPending(current.id) {
                return
            }
            await show(context)
            return
        }

        // A decision gate. If a *different* still-pending gate is already on
        // screen, queue behind it rather than stranding the earlier decision.
        if let current = model.review,
           current.wantsDecision,
           current.id != context.id,
           await broker.isPending(current.id) {
            enqueueGate(context)
            return
        }
        await show(context)
    }

    /// A passive, non-interruptive cue for a non-decision tap: pulse the pill and
    /// keep the ambient cockpit exactly as it is. Never auto-expands.
    public func pulsePill() {
        model.pillPulse &+= 1
    }

    /// Open the single most-urgent session (summon hotkey / hover-intent).
    public func summon() {
        Task { await expandMostUrgent() }
    }

    // MARK: Private — building & showing reviews

    private func makeContext(envelope: HookEnvelope, reason: String) -> ReviewContext {
        let event = envelope.event
        return ReviewContext(
            id: envelope.id,
            sessionId: event.sessionId,
            cwd: event.cwd,
            toolName: event.toolName,
            command: event.commandDescription,
            wantsDecision: envelope.wantsDecision,
            reason: reason,
            outputTail: event.lastAssistantMessage
        )
    }

    /// Displays `context` in the expanded console, arming its expiry if it is a
    /// decision gate. Only called when the console is actually being shown, so
    /// the (hardened) git diff is computed only for on-screen reviews.
    private func show(_ context: ReviewContext) async {
        model.review = context
        model.waitingCount = pendingGates.count
        loadContext(for: context)
        if context.wantsDecision {
            armGateExpiry(for: context.id)
        }
        await expand()
    }

    private func enqueueGate(_ context: ReviewContext) {
        guard context.wantsDecision,
              model.review?.id != context.id,
              !pendingGates.contains(where: { $0.id == context.id }),
              pendingGates.count < maxQueuedGates else { return }
        pendingGates.append(context)
        model.waitingCount = pendingGates.count
    }

    /// Pops the next still-pending queued gate, skipping any that already
    /// resolved or timed out in the broker.
    private func dequeueNextGate() async -> ReviewContext? {
        while !pendingGates.isEmpty {
            let next = pendingGates.removeFirst()
            model.waitingCount = pendingGates.count
            if await broker.isPending(next.id) { return next }
        }
        return nil
    }

    // MARK: Private — expansion state machine

    private func expandMostUrgent() async {
        if model.review == nil {
            guard let lane = mostUrgentLane() else { return }
            let context = ReviewContext(
                id: UUID(),
                sessionId: lane.id,
                cwd: lane.cwd,
                toolName: nil,
                command: lane.lastCommand,
                wantsDecision: false,
                reason: "summoned",
                outputTail: nil
            )
            model.review = context
            loadContext(for: context)
        }
        await expand()
    }

    private func expand() async {
        autoCollapseTask?.cancel()
        hoverIntentTask?.cancel()
        presentation = .expanded
        await notch?.expand()
        scheduleAutoCollapse()
    }

    /// Present the ambient cockpit.
    ///
    /// On notched Macs the cockpit lives in the compact (trailing) slot, so we
    /// `compact()`. On FLOATING screens (external monitors / non-notch Macs)
    /// there is no compact slot — DynamicNotchKit's `compact()` would *hide* the
    /// window, breaking the fallback — so we instead present the cockpit as a
    /// persistent small floating view via `expand()` of the adaptive root (with
    /// `review == nil`, that root renders the cockpit, not the console).
    ///
    /// `presentation` is set to `.cockpit` only AFTER the window is actually
    /// shown, so the state machine never desyncs from what's on screen.
    private func showCockpit() async {
        if primaryScreenIsFloating {
            await notch?.expand()
        } else {
            await notch?.compact()
        }
        presentation = .cockpit
    }

    /// User- or ESC-driven dismissal: furl the current review and, if any
    /// decision gates are queued, surface the next one; otherwise settle to the
    /// cockpit / hidden.
    public func collapse() async {
        cancelGateExpiry(for: model.review?.id)
        model.review = nil
        model.isPinned = false
        if let next = await dequeueNextGate() {
            await show(next)
            return
        }
        await settle()
    }

    /// Idle auto-furl: drop the console back to the ambient cockpit WITHOUT
    /// draining the queue — an inactive user shouldn't get gate after gate
    /// auto-popping (silence-by-default). Queued/pending gates stay in the broker
    /// and can be re-summoned; each still fails open on its own timeout.
    private func furl() async {
        cancelGateExpiry(for: model.review?.id)
        model.review = nil
        model.isPinned = false
        await settle()
    }

    private func settle() async {
        model.waitingCount = pendingGates.count
        if model.lanes.isEmpty {
            await notch?.hide()
            presentation = .hidden
        } else {
            await showCockpit()
        }
    }

    // MARK: Private — gate expiry (F)

    private func armGateExpiry(for id: UUID) {
        gateExpiryTasks[id]?.cancel()
        let seconds = gateTimeoutSeconds
        gateExpiryTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.expireGate(id: id)
        }
    }

    private func cancelGateExpiry(for id: UUID?) {
        guard let id else { return }
        gateExpiryTasks[id]?.cancel()
        gateExpiryTasks[id] = nil
    }

    /// A shown/queued gate outlived its app-side lifetime. Disable its controls
    /// (belt-and-suspenders — the broker also no-ops a stale resolve) and move on.
    private func expireGate(id: UUID) async {
        gateExpiryTasks[id] = nil
        if let idx = pendingGates.firstIndex(where: { $0.id == id }) {
            pendingGates.remove(at: idx)
            model.waitingCount = pendingGates.count
        }
        if model.review?.id == id {
            model.review?.isExpired = true
            await collapse()
        }
    }

    // MARK: Private — timers & hover intent

    private func scheduleAutoCollapse() {
        autoCollapseTask?.cancel()
        let seconds = autoCollapseSeconds
        autoCollapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if !self.model.isPinned, !self.isHovering {
                await self.furl()
            }
        }
    }

    private func observeHover() {
        guard let notch = notch else { return }
        hoverObserverTask = Task { [weak self, notch] in
            for await hovering in notch.$isHovering.values {
                guard let self else { break }
                self.isHovering = hovering
                if hovering {
                    self.beginHoverIntent()
                } else if self.presentation == .expanded {
                    self.scheduleAutoCollapse()
                }
            }
        }
    }

    private func beginHoverIntent() {
        guard presentation != .expanded else { return }
        guard model.review != nil || mostUrgentLane() != nil else { return }
        let delay = hoverIntentSeconds
        hoverIntentTask?.cancel()
        hoverIntentTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isHovering else { return }
            await self.expandMostUrgent()
        }
    }

    // MARK: Private — decisions & data loading

    private func wireModelCallbacks() {
        model.onDecide = { [weak self] permission, reason, redirect in
            self?.handleDecision(permission: permission, reason: reason, redirect: redirect)
        }
        model.onApproveRemember = { [weak self] in
            self?.handleApproveRemember()
        }
        model.onCollapse = { [weak self] in
            Task { await self?.collapse() }
        }
        model.onTogglePin = { [weak self] in
            guard let self else { return }
            self.model.isPinned.toggle()
            if self.model.isPinned {
                self.autoCollapseTask?.cancel()
            } else {
                self.scheduleAutoCollapse()
            }
        }
        model.onJumpToTerminal = { [weak self] cwd in
            self?.terminalJumper.jump(cwd: cwd)
        }
    }

    private func handleDecision(permission: PermissionDecision, reason: String?, redirect: String?) {
        guard let review = model.review else { return }
        let id = review.id
        if review.wantsDecision {
            let message = DecisionMessage(id: id, permission: permission, reason: reason, redirect: redirect)
            let broker = self.broker
            Task { await broker.resolve(id: id, decision: message) }
        }
        Task { await collapse() }
    }

    private func handleApproveRemember() {
        guard let review = model.review else { return }
        if let command = review.command {
            let store = remembered
            Task { await store.remember(command) }
        }
        handleDecision(permission: .allow, reason: nil, redirect: nil)
    }

    /// Asynchronously fills in the branch + git diff for a review already on screen.
    private func loadContext(for context: ReviewContext) {
        let cwd = context.cwd
        let id = context.id
        let provider = diffProvider
        Task { [weak self] in
            let branch = await provider.currentBranch(cwd: cwd)
            let diff = await provider.loadDiff(cwd: cwd)
            guard let self, self.model.review?.id == id else { return }
            self.model.review?.branch = branch
            self.model.review?.diff = diff
        }
    }

    private func mostUrgentLane() -> Lane? {
        model.lanes.max { a, b in
            let ra = Self.urgencyRank(a.state)
            let rb = Self.urgencyRank(b.state)
            if ra != rb { return ra < rb }
            return a.updatedAt < b.updatedAt
        }
    }

    private static func urgencyRank(_ state: LaneState) -> Int {
        switch state {
        case .needsYou: return 3
        case .error: return 2
        case .done: return 1
        case .flowing: return 0
        }
    }

    // MARK: Private — screen style

    /// Whether the primary screen (DynamicNotchKit's default) has no notch, so
    /// the library resolves `.auto` to its floating style. Mirrors the library's
    /// own `NSScreen.hasNotch` check so our decision agrees with what
    /// `compact()`/`expand()` will actually do.
    private var primaryScreenIsFloating: Bool {
        guard let screen = NSScreen.screens.first else { return true }
        let hasNotch = screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
        return !hasNotch
    }
}
