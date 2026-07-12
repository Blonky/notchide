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

    /// The DynamicNotchKit panel. `.auto` style resolves to a real notch on
    /// notched Macs and to the first-class floating pill everywhere else.
    private var notch: DynamicNotch<ReviewConsoleView, EmptyView, CockpitView>?
    private var hotkey: HotkeyMonitor?

    private enum Presentation { case hidden, cockpit, expanded }
    private var presentation: Presentation = .hidden
    private var isHovering = false

    private var hoverIntentTask: Task<Void, Never>?
    private var autoCollapseTask: Task<Void, Never>?
    private var hoverObserverTask: Task<Void, Never>?

    /// How long the console stays down before auto-furling (unless pinned/hovered).
    public var autoCollapseSeconds: Double = 12
    /// Hover-intent delay before a peek expands the console.
    public var hoverIntentSeconds: Double = 0.2

    public init(
        model: NotchViewModel,
        broker: DecisionBroker,
        diffProvider: GitDiffProvider,
        terminalJumper: TerminalJumper
    ) {
        self.model = model
        self.broker = broker
        self.diffProvider = diffProvider
        self.terminalJumper = terminalJumper
    }

    // MARK: Lifecycle

    public func start() {
        let model = self.model
        let notch = DynamicNotch(
            hoverBehavior: .all,
            style: .auto,
            expanded: { ReviewConsoleView(model: model) },
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

    // MARK: Ingest-driven presentation

    /// Called after the shared lane snapshot changes; keeps the ambient cockpit
    /// visible whenever there are lanes, hidden when there are none.
    public func lanesDidUpdate() async {
        guard presentation != .expanded else { return }
        if model.lanes.isEmpty {
            if presentation != .hidden {
                presentation = .hidden
                await notch?.hide()
            }
        } else if presentation != .cockpit {
            presentation = .cockpit
            await notch?.compact()
        }
    }

    /// Surface a specific envelope in the review console. Called by the socket
    /// handler for taps and for gates awaiting a decision.
    public func present(envelope: HookEnvelope, reason: String) async {
        let event = envelope.event
        let context = ReviewContext(
            id: envelope.id,
            sessionId: event.sessionId,
            cwd: event.cwd,
            toolName: event.toolName,
            command: event.commandDescription,
            wantsDecision: envelope.wantsDecision,
            reason: reason,
            outputTail: event.lastAssistantMessage
        )
        model.review = context
        loadContext(for: context)
        await expand()
    }

    /// Open the single most-urgent session (summon hotkey / hover-intent).
    public func summon() {
        Task { await expandMostUrgent() }
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

    private func showCockpit() async {
        presentation = .cockpit
        await notch?.compact()
    }

    public func collapse() async {
        model.review = nil
        model.isPinned = false
        if model.lanes.isEmpty {
            presentation = .hidden
            await notch?.hide()
        } else {
            await showCockpit()
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
                await self.collapse()
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
}
