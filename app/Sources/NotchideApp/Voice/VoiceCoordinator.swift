import Foundation
import NotchideKit

/// Owns the whole voice-driven ACTUATE session: the pure `VoiceController` state
/// machine, the mic-bound `VoiceProvider`, the real-time clock that drives the
/// machine's caps, and the mapping of committed intents onto AAP actions.
///
/// `NotchController` forwards PTT + keyboard events here and supplies small
/// closures for the things only it can do (grow/settle the notch panel, pick the
/// most-urgent lane). Gate verdicts are resolved through the same
/// `NotchViewModel.onDecide` path a click uses.
///
/// Lifecycle hygiene: every session cancels its transcript + tick tasks, stops
/// the provider, and detaches the controller's callbacks on teardown, and a new
/// press supersedes any prior session cleanly.
@MainActor
final class VoiceCoordinator {
    private let model: NotchViewModel
    private let actuate: @Sendable (AgentAction) async -> Void
    private let attachActuator: AttachActuator
    private let makeProvider: () -> VoiceProvider
    private let mostUrgentSession: () -> SessionKey?
    private let expandPanel: () async -> Void
    private let settlePanel: () async -> Void

    /// Provider ids whose sessions can receive server-pushed actuate frames (HOST
    /// mode). A target NOT in this set is routed through the attach fallback.
    var actuatableProviders: Set<ProviderID> = []

    private enum Mode { case prompt, gate }
    private var mode: Mode = .prompt
    /// Sticky target so a running agent stays selected across presses.
    private var target: SessionKey?
    /// A prompt was sent and the agent is presumably still working on it — the
    /// next PTT press barges in with an interrupt before starting fresh.
    private var inFlight = false
    private var matchedVerdict = false

    private var controller: VoiceController?
    private var provider: VoiceProvider?
    private var transcriptTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var errorDismissTask: Task<Void, Never>?

    // Wall-clock anchors for driving the (deterministic) machine + the HUD meter.
    private var lastTick = Date()
    private var listenActivityAt = Date()
    private var reviewStart = Date()

    init(
        model: NotchViewModel,
        actuate: @escaping @Sendable (AgentAction) async -> Void,
        attachActuator: AttachActuator,
        makeProvider: @escaping () -> VoiceProvider,
        mostUrgentSession: @escaping () -> SessionKey?,
        expandPanel: @escaping () async -> Void,
        settlePanel: @escaping () async -> Void
    ) {
        self.model = model
        self.actuate = actuate
        self.attachActuator = attachActuator
        self.makeProvider = makeProvider
        self.mostUrgentSession = mostUrgentSession
        self.expandPanel = expandPanel
        self.settlePanel = settlePanel

        // Own the HUD's keyboard affordances.
        model.onVoiceSendNow = { [weak self] in self?.returnPressed() }
        model.onVoiceCancel = { [weak self] in self?.escapePressed() }
        model.onVoiceHoldToEdit = { [weak self] in self?.holdToEdit() }
        model.onVoiceEdit = { [weak self] text in self?.editText(text) }
    }

    /// Whether a voice session is currently on screen.
    var isActive: Bool { model.voiceState.isActive }

    // MARK: - PTT

    /// Push-to-talk pressed: barge-in if needed, pick a target + mode, and begin
    /// capturing.
    func pttPressed() {
        // Barge-in: a press while a prior prompt is still in flight interrupts the
        // target first, then we start a fresh utterance.
        if inFlight, let target {
            routeInterrupt(target)
            inFlight = false
        }

        let (target, mode) = resolveTargetAndMode()
        startSession(target: target, mode: mode)
    }

    /// Push-to-talk released: finalize (prompt) or take a last verdict read (gate).
    func pttReleased() {
        guard let controller else { return }
        switch mode {
        case .prompt:
            controller.release()
        case .gate:
            controller.release()
            checkGateVerdict(controller.currentText)
            if !matchedVerdict {
                // No verdict spoken — leave the gate untouched for a click/hotkey.
                endSession(hud: .inactive)
                return
            }
        }
        // Flush the mic; late finals still arrive and update the committable text.
        provider?.stop()
    }

    /// The chord was interrupted by a real keystroke — abandon the session.
    func pttCancelled() {
        controller?.cancel()
        endSession(hud: .inactive)
    }

    // MARK: - Keyboard (from the HUD / hotkey monitor)

    func returnPressed() {
        guard let controller, model.voiceState == .review else { return }
        if model.voiceEditing { controller.edit(model.voiceText) }
        controller.sendNow()
    }

    func escapePressed() {
        switch model.voiceState {
        case .listening:
            controller?.cancel()
            endSession(hud: .inactive)
        case .review:
            holdToEdit()
        case .error:
            endSession(hud: .inactive)
        case .inactive:
            break
        }
    }

    /// Esc during review: freeze the auto-send so the transcript can be edited.
    private func holdToEdit() {
        guard model.voiceState == .review else { return }
        model.voiceEditing = true
        model.voiceMeter = 0
    }

    private func editText(_ text: String) {
        guard model.voiceState == .review else { return }
        controller?.edit(text)
    }

    // MARK: - Event feedback

    /// Clears the in-flight flag once the target session stops working on our
    /// prompt (so a later press starts fresh instead of barging in).
    func noteEvent(_ event: AgentEvent) {
        guard inFlight, event.sessionKey == target else { return }
        switch event.kind {
        case .finished, .errored, .needsDecision, .notified:
            inFlight = false
        case .started, .progress:
            break
        }
    }

    /// Cancels everything on app teardown.
    func teardown() {
        errorDismissTask?.cancel(); errorDismissTask = nil
        stopEngine()
        model.voiceState = .inactive
    }

    // MARK: - Session lifecycle

    private func resolveTargetAndMode() -> (SessionKey?, Mode) {
        // A live blocking gate on screen → verdict (gate-listen) mode.
        if let review = model.review, review.wantsDecision {
            return (review.id, .gate)
        }
        // Prompt mode target: the current review, else a still-present sticky
        // target, else the most-urgent lane.
        if let review = model.review {
            return (review.id, .prompt)
        }
        if let target, model.lanes.contains(where: { $0.id == target }) {
            return (target, .prompt)
        }
        return (mostUrgentSession(), .prompt)
    }

    private func startSession(target: SessionKey?, mode: Mode) {
        stopEngine()
        errorDismissTask?.cancel(); errorDismissTask = nil

        self.mode = mode
        self.target = target
        matchedVerdict = false

        model.voiceGateMode = (mode == .gate)
        model.voiceApproveDisabled = false
        model.voiceEditing = false
        model.voiceText = ""
        model.voiceMeter = 0
        model.voiceTargetLabel = target.map(Self.targetLabel)

        let controller = VoiceController()
        controller.onStateChange = { [weak self] state in self?.stateChanged(state) }
        controller.onIntent = { [weak self] intent in self?.intentEmitted(intent) }
        self.controller = controller

        let provider = makeProvider()
        self.provider = provider

        controller.arm()
        controller.press(target: target)

        let stream = provider.start()
        lastTick = Date()
        listenActivityAt = Date()
        transcriptTask = Task { [weak self] in
            for await transcript in stream {
                guard let self else { break }
                self.ingest(transcript)
            }
            self?.streamEnded()
        }
        startTick()

        Task { await self.expandPanel() }
    }

    private func ingest(_ transcript: Transcript) {
        guard let controller else { return }
        controller.ingest(transcript)
        model.voiceText = controller.currentText
        listenActivityAt = Date()

        switch mode {
        case .gate:
            checkGateVerdict(transcript.text)
        case .prompt:
            // A late final that lands during the review window sends promptly
            // (unless the user paused to edit).
            if transcript.isFinal, controller.state == .review, !model.voiceEditing {
                controller.sendNow()
            }
        }
    }

    private func streamEnded() {
        guard let controller else { return }
        // The mic ended while still listening with nothing captured — a provider
        // failure (denied permission / unavailable), not a normal finalize.
        if controller.state == .listening, controller.currentText.isEmpty {
            model.voiceState = .error("microphone unavailable")
            provider?.stop()
            scheduleErrorDismiss()
        }
    }

    private func stopEngine() {
        transcriptTask?.cancel(); transcriptTask = nil
        tickTask?.cancel(); tickTask = nil
        if let controller {
            controller.onStateChange = nil
            controller.onIntent = nil
        }
        controller = nil
        provider?.stop()
        provider = nil
    }

    /// Stops the machinery and settles the HUD to `hud`. An error state lingers
    /// briefly then auto-dismisses; anything else settles the panel immediately.
    private func endSession(hud: VoiceHUDState) {
        stopEngine()
        model.voiceGateMode = false
        model.voiceApproveDisabled = false
        model.voiceEditing = false
        model.voiceMeter = 0
        model.voiceState = hud
        if case .error = hud {
            scheduleErrorDismiss()
        } else {
            model.voiceText = ""
            Task { await self.settlePanel() }
        }
    }

    // MARK: - Machine callbacks

    private func stateChanged(_ state: VoiceState) {
        switch state {
        case .idle, .sent:
            break
        case .armed, .listening:
            model.voiceState = .listening
        case .review:
            model.voiceState = .review
            reviewStart = Date()
            model.voiceEditing = false
        case .error(let error):
            model.voiceState = .error(Self.errorMessage(error))
            provider?.stop()
            scheduleErrorDismiss()
        }
    }

    private func intentEmitted(_ intent: VoiceIntent) {
        guard mode == .prompt else { return }
        if let target = intent.targetSession {
            routePrompt(target, text: intent.text)
            inFlight = true
        } else {
            NSLog("notchide: voice intent has no target session; dropping: \(intent.text)")
        }
        endSession(hud: .inactive)
    }

    // MARK: - Gate verdicts

    private enum Verdict { case allow, deny }

    private func checkGateVerdict(_ text: String) {
        guard mode == .gate, !matchedVerdict,
              let review = model.review, review.wantsDecision,
              let verdict = Self.matchVerdict(text) else { return }

        switch verdict {
        case .deny:
            matchedVerdict = true
            model.onDecide?(.deny, "denied by voice", nil)
            endSession(hud: .inactive)
        case .allow:
            // Approved safety rule: a destructive command can never be approved by
            // voice — require a click / hotkey. Deny-by-voice stays allowed.
            if review.isDestructive {
                model.voiceApproveDisabled = true
                return
            }
            matchedVerdict = true
            model.onDecide?(.allow, "approved by voice", nil)
            endSession(hud: .inactive)
        }
    }

    /// Deny is checked first so an ambiguous utterance fails safe.
    private static func matchVerdict(_ text: String) -> Verdict? {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        let deny: Set<String> = ["deny", "denied", "stop", "no", "nope", "cancel", "reject", "rejected", "block"]
        let allow: Set<String> = ["approve", "approved", "allow", "allowed", "yes", "yeah", "yep", "confirm", "confirmed", "ok", "okay"]
        if !words.isDisjoint(with: deny) { return .deny }
        if !words.isDisjoint(with: allow) { return .allow }
        return nil
    }

    // MARK: - Actuation routing

    private func routePrompt(_ key: SessionKey, text: String) {
        if actuatableProviders.contains(key.provider) {
            let actuate = self.actuate
            Task { await actuate(.prompt(key, text)) }
        } else {
            let attach = attachActuator
            Task { await attach.prompt(key, text: text) }
        }
    }

    private func routeInterrupt(_ key: SessionKey) {
        if actuatableProviders.contains(key.provider) {
            let actuate = self.actuate
            Task { await actuate(.interrupt(key)) }
        } else {
            let attach = attachActuator
            Task { await attach.interrupt(key) }
        }
    }

    // MARK: - Real-time tick (drives the machine + the meter)

    private func startTick() {
        lastTick = Date()
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self else { break }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let controller else { return }
        let now = Date()
        let delta = now.timeIntervalSince(lastTick)
        lastTick = now
        // Editing freezes the auto-send: simply stop advancing the clock.
        if !model.voiceEditing {
            controller.advance(by: delta)
        }
        updateMeter(controller, now: now)
    }

    private func updateMeter(_ controller: VoiceController, now: Date) {
        switch controller.state {
        case .listening:
            model.voiceMeter = min(1, now.timeIntervalSince(listenActivityAt) / controller.silenceCap)
        case .review:
            model.voiceMeter = model.voiceEditing
                ? 0
                : min(1, now.timeIntervalSince(reviewStart) / controller.reviewGrace)
        default:
            model.voiceMeter = 0
        }
    }

    private func scheduleErrorDismiss() {
        errorDismissTask?.cancel()
        errorDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard let self, !Task.isCancelled else { return }
            if case .error = self.model.voiceState {
                self.stopEngine()
                self.model.voiceState = .inactive
                self.model.voiceText = ""
                await self.settlePanel()
            }
        }
    }

    // MARK: - Labels

    private static func targetLabel(_ key: SessionKey) -> String {
        let provider = key.provider.raw.split(separator: ".").last.map(String.init) ?? key.provider.raw
        let sid = key.agentSessionID
        let shortSid = sid.count > 8 ? String(sid.prefix(8)) : sid
        return shortSid.isEmpty ? provider : "\(provider) · \(shortSid)"
    }

    private static func errorMessage(_ error: VoiceError) -> String {
        switch error {
        case .silenceTimeout: return "no speech heard"
        case .totalTimeout: return "voice session timed out"
        }
    }
}
