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
///
/// In the AAP model the socket transport lives entirely inside
/// `SocketAAPProvider`, which owns decision correlation. This controller no
/// longer brokers decisions itself: it consumes vendor-neutral `AgentEvent`s
/// (via `consider`) and lane snapshots (via `lanesDidUpdate`), and on a decision
/// button press hands an `AgentDecision` back through `resolveDecision`, which the
/// provider writes onto the correlated open connection.
@MainActor
public final class NotchController {
    private let model: NotchViewModel
    private let suppressor: Suppressor
    private let frontmost: FrontmostContextProviding
    private let diffProvider: GitDiffProvider
    private let terminalJumper: TerminalJumper
    private let remembered: RememberedStore
    /// Hands a resolved decision back to the owning provider (which writes the
    /// frame onto the correlated open connection). Replaces the old DecisionBroker.
    private let resolveDecision: @Sendable (AgentDecision) async -> Void
    /// Pushes a voice-driven ACTUATE action to the owning provider (host mode).
    private let actuate: @Sendable (AgentAction) async -> Void
    /// The attach fallback for non-host (hook-adapter) sessions.
    private let attachActuator: AttachActuator

    /// Push-to-talk (Control+Option hold) summon monitor.
    private var pttMonitor: PTTMonitor?
    /// The voice-drive coordinator (state machine + mic + actuation routing).
    private var voice: VoiceCoordinator?

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

    /// The most recent event per session, kept so a summoned/hover-expanded lane
    /// can still render a rich console (tool name + last message) even though a
    /// `Lane` snapshot alone does not carry the payload.
    private var latestEvents: [SessionKey: AgentEvent] = [:]

    /// Decision ids for gates still awaiting the user (on screen or queued). The
    /// provider owns wire correlation; this is the app-side "still pending?" gate
    /// used for queueing and dequeue-skipping (replaces `DecisionBroker.isPending`).
    private var outstandingGates: Set<UUID> = []

    /// Outstanding decision gates queued behind the one currently on screen, in
    /// arrival order. A newer gate (or a non-decision tap) must never replace a
    /// still-pending decision (see `present`).
    private var pendingGates: [ReviewContext] = []
    private let maxQueuedGates = 32

    /// Per-gate app-side expiry timers (see F): when a shown gate expires, its
    /// console controls are disabled and it is furled so a stale click can't
    /// "decide" something already dropped. Keyed by decision id.
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
        suppressor: Suppressor,
        frontmost: FrontmostContextProviding,
        diffProvider: GitDiffProvider,
        terminalJumper: TerminalJumper,
        remembered: RememberedStore,
        resolveDecision: @escaping @Sendable (AgentDecision) async -> Void,
        actuate: @escaping @Sendable (AgentAction) async -> Void = { _ in },
        attachActuator: AttachActuator = AttachActuator()
    ) {
        self.model = model
        self.suppressor = suppressor
        self.frontmost = frontmost
        self.diffProvider = diffProvider
        self.terminalJumper = terminalJumper
        self.remembered = remembered
        self.resolveDecision = resolveDecision
        self.actuate = actuate
        self.attachActuator = attachActuator
    }

    /// Records which providers can receive server-pushed actuate frames (HOST
    /// mode). Sessions from any other provider fall back to the attach path.
    public func setActuatableProviders(_ providers: Set<ProviderID>) {
        voice?.actuatableProviders = providers
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

        // Voice drive: the coordinator owns the state machine + mic; this
        // controller only lends it the panel-motion + most-urgent-lane hooks.
        let voice = VoiceCoordinator(
            model: model,
            actuate: actuate,
            attachActuator: attachActuator,
            makeProvider: { Self.makeVoiceProvider() },
            mostUrgentSession: { [weak self] in self?.mostUrgentLane()?.id },
            expandPanel: { [weak self] in await self?.expandForVoice() },
            settlePanel: { [weak self] in await self?.settleAfterVoice() }
        )
        self.voice = voice

        let ptt = PTTMonitor()
        ptt.onPress = { [weak self] in self?.voice?.pttPressed() }
        ptt.onRelease = { [weak self] in self?.voice?.pttReleased() }
        ptt.onCancel = { [weak self] in self?.voice?.pttCancelled() }
        ptt.start()
        self.pttMonitor = ptt

        let hotkey = HotkeyMonitor()
        hotkey.onSummon = { [weak self] in self?.summon() }
        hotkey.onEscape = { [weak self] in self?.handleEscape() }
        hotkey.onReturn = { [weak self] in self?.handleReturn() }
        hotkey.start()
        self.hotkey = hotkey
    }

    /// Builds the best available voice provider: the on-device SpeechAnalyzer on
    /// macOS 26+, else the (stubbed) WhisperKit fallback.
    private static func makeVoiceProvider() -> VoiceProvider {
        if #available(macOS 26.0, *) {
            return SpeechTranscriberVoiceProvider()
        } else {
            return WhisperKitVoiceProvider()
        }
    }

    /// ESC: cancel/edit an active voice session first; otherwise furl the console.
    private func handleEscape() {
        if model.voiceState.isActive {
            voice?.escapePressed()
        } else {
            Task { await collapse() }
        }
    }

    /// Return: send the reviewed voice transcript now, when one is on screen.
    private func handleReturn() {
        guard model.voiceState.isActive else { return }
        voice?.returnPressed()
    }

    /// Grow the notch to host the voice HUD without arming the idle auto-collapse
    /// (a voice session is bounded by its own caps).
    func expandForVoice() async {
        autoCollapseTask?.cancel()
        hoverIntentTask?.cancel()
        presentation = .expanded
        await notch?.expand()
    }

    /// Restore the panel after a voice session ends: keep the console if a review
    /// is on screen, else settle to the cockpit / hidden.
    func settleAfterVoice() async {
        if model.review != nil {
            await expand()
        } else {
            await settle()
        }
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
        pttMonitor?.stop()
        pttMonitor = nil
        voice?.teardown()
        voice = nil
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

    /// The attention router for a single incoming event. Decides whether it taps
    /// the user, applies the approve-and-remember fast path, and — for a blocking
    /// gate — auto-surfaces the review console. Non-decision taps (Stop /
    /// Notification) stay passive: they pulse the pill, never auto-expand.
    public func consider(event: AgentEvent, capability: DecisionCapability) async {
        latestEvents[event.sessionKey] = event
        // Let the voice coordinator clear its in-flight barge-in latch when the
        // target session stops working on a voice prompt.
        voice?.noteEvent(event)

        let isGate = event.kind == .needsDecision
            && capability == .blocking
            && event.decision != nil

        // Approve-and-remember fast path: a blocking gate whose exact, normalized
        // command was previously remembered resolves .allow immediately and
        // silently — the console is never shown.
        if isGate,
           let decisionID = event.decision?.id,
           let command = event.command,
           await remembered.contains(command) {
            await resolveDecision(AgentDecision(id: decisionID, verdict: .allow, reason: "remembered by notchide"))
            return
        }

        // Attention routing: should this actually tap the user? (Global mute is
        // threaded through here — a muted user is never tapped.)
        let (tap, reason) = await suppressor.shouldTap(
            kind: event.kind,
            decisionCapability: capability,
            key: event.sessionKey,
            muted: MuteSettings.isMuted,
            context: frontmost
        )

        if isGate {
            // A blocking gate is the ONE deliberate auto-expand (it blocks a real
            // agent). It surfaces regardless of the tap verdict; `reason` still
            // powers the "why did this tap?" line.
            let context = makeContext(fromEvent: event, capability: capability, reason: reason)
            await present(context)
        } else if tap {
            // A non-decision tap is passive: it only pulses the pill — never drops
            // the full console (silence-by-default, DESIGN §4.1/§8).
            pulsePill()
        }
    }

    /// A passive, non-interruptive cue for a non-decision tap: pulse the pill and
    /// keep the ambient cockpit exactly as it is. Never auto-expands.
    private func pulsePill() {
        model.pillPulse &+= 1
    }

    /// Open the single most-urgent session (summon hotkey / hover-intent).
    public func summon() {
        Task { await expandMostUrgent() }
    }

    // MARK: Private — building & showing reviews

    /// Surface a blocking gate in the review console. A newer gate for a
    /// *different* still-pending session queues behind the one on screen rather
    /// than stranding the earlier decision.
    private func present(_ context: ReviewContext) async {
        guard let decisionID = context.decisionID, context.wantsDecision else {
            // Defensive: a non-gate surfacing must never clobber a pending gate.
            if let current = model.review, current.wantsDecision, isPending(current) { return }
            await show(context)
            return
        }

        // Track this gate app-side so queueing/dequeue-skipping works.
        outstandingGates.insert(decisionID)

        if let current = model.review,
           current.wantsDecision,
           current.id != context.id,
           isPending(current) {
            enqueueGate(context)
            return
        }
        await show(context)
    }

    private func makeContext(fromEvent event: AgentEvent, capability: DecisionCapability, reason: String) -> ReviewContext {
        ReviewContext(
            id: event.sessionKey,
            providerID: event.providerID,
            decisionCapability: capability,
            cwd: event.cwd ?? event.sessionKey.cwd,
            toolName: event.payload["tool_name"]?.stringValue,
            command: event.command,
            decisionID: event.decision?.id,
            reason: reason,
            outputTail: event.payload["last_assistant_message"]?.stringValue ?? event.title
        )
    }

    /// Builds a console context from a `Lane` snapshot, enriched from the last
    /// event seen for that session (payload/last message the Lane doesn't carry).
    private func makeContext(fromLane lane: Lane, reason: String) -> ReviewContext {
        let latest = latestEvents[lane.id]
        return ReviewContext(
            id: lane.id,
            providerID: lane.providerID,
            decisionCapability: lane.decisionCapability,
            cwd: lane.cwd,
            toolName: latest?.payload["tool_name"]?.stringValue,
            command: lane.lastCommand ?? latest?.command,
            decisionID: lane.pendingDecision?.id,
            reason: reason,
            outputTail: latest?.payload["last_assistant_message"]?.stringValue ?? latest?.title
        )
    }

    /// Displays `context` in the expanded console, arming its expiry if it is a
    /// decision gate. Only called when the console is actually being shown, so
    /// the (hardened) git diff is computed only for on-screen reviews.
    private func show(_ context: ReviewContext) async {
        model.review = context
        model.waitingCount = pendingGates.count
        loadContext(for: context)
        if let decisionID = context.decisionID, context.wantsDecision {
            armGateExpiry(for: decisionID)
        }
        await expand()
    }

    private func enqueueGate(_ context: ReviewContext) {
        guard let decisionID = context.decisionID,
              model.review?.decisionID != decisionID,
              !pendingGates.contains(where: { $0.decisionID == decisionID }),
              pendingGates.count < maxQueuedGates else { return }
        pendingGates.append(context)
        model.waitingCount = pendingGates.count
    }

    /// Pops the next still-pending queued gate, skipping any that already resolved
    /// or timed out.
    private func dequeueNextGate() -> ReviewContext? {
        while !pendingGates.isEmpty {
            let next = pendingGates.removeFirst()
            model.waitingCount = pendingGates.count
            if isPending(next) { return next }
        }
        return nil
    }

    /// Whether a gate context is still awaiting the user app-side.
    private func isPending(_ context: ReviewContext) -> Bool {
        guard let decisionID = context.decisionID else { return false }
        return outstandingGates.contains(decisionID)
    }

    // MARK: Private — expansion state machine

    private func expandMostUrgent() async {
        if model.review == nil {
            guard let lane = mostUrgentLane() else { return }
            let context = makeContext(fromLane: lane, reason: "summoned")
            // A summoned lane that happens to be a live gate must be tracked so it
            // can be resolved / expired like any other gate.
            if let decisionID = context.decisionID, context.wantsDecision {
                outstandingGates.insert(decisionID)
            }
            await show(context)
            return
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
        cancelGateExpiry(for: model.review?.decisionID)
        model.review = nil
        model.isPinned = false
        if let next = dequeueNextGate() {
            await show(next)
            return
        }
        await settle()
    }

    /// Idle auto-furl: drop the console back to the ambient cockpit WITHOUT
    /// draining the queue — an inactive user shouldn't get gate after gate
    /// auto-popping (silence-by-default). Queued/pending gates stay outstanding
    /// and can be re-summoned; each still fails open on its own timeout.
    private func furl() async {
        cancelGateExpiry(for: model.review?.decisionID)
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
    /// (belt-and-suspenders — a stale resolve is a no-op at the provider) and move
    /// on. We deliberately do NOT resolve here: the adapter fails open on its own
    /// timeout, which is the correct "defer to the agent's own prompt" behavior.
    private func expireGate(id: UUID) async {
        gateExpiryTasks[id] = nil
        outstandingGates.remove(id)
        if let idx = pendingGates.firstIndex(where: { $0.decisionID == id }) {
            pendingGates.remove(at: idx)
            model.waitingCount = pendingGates.count
        }
        if model.review?.decisionID == id {
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
        if let decisionID = review.decisionID, review.wantsDecision {
            outstandingGates.remove(decisionID)
            cancelGateExpiry(for: decisionID)
            let decision = AgentDecision(id: decisionID, verdict: permission, reason: reason, redirect: redirect)
            let resolve = self.resolveDecision
            Task { await resolve(decision) }
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
