import Foundation

/// The observable state of the voice HUD.
///
/// The lifecycle is: `.idle`/`.armed` → `.listening` → `.review` (finalizing +
/// short editable grace) → `.sent`. From `.listening`/`.review` a cap can fire
/// into `.error`. The post-send *awaitingApproval* step is NOT modeled here — it
/// is handled by the existing gate/`needsYou` path once the prompt reaches the
/// agent.
public enum VoiceState: Sendable, Equatable {
    /// Nothing happening; mic not engaged.
    case idle
    /// Mic engaged and ready, not yet capturing (pre-listening).
    case armed
    /// Push-to-talk held; capturing transcripts.
    case listening
    /// PTT released; the (editable) final transcript is in a short grace window
    /// before it auto-sends.
    case review
    /// The intent was committed and emitted.
    case sent
    /// A cap fired before the utterance could be sent.
    case error(VoiceError)
}

/// Why a voice session ended in `.error`.
public enum VoiceError: Sendable, Equatable {
    /// No new speech for the silence cap while listening (default 15s).
    case silenceTimeout
    /// The total-utterance cap elapsed (default 2min).
    case totalTimeout
}

/// A PURE, headless state machine for voice-driven ACTUATE.
///
/// It contains NO AVFoundation/AppKit and does NOT paste or route text: on a
/// committed final transcript it merely emits a `VoiceIntent`; delivering that to
/// a session is the app's job. Time is fully injectable — the machine holds an
/// internal monotonic clock advanced only by `advance(by:)`, so every timer (the
/// silence cap, the total cap, the review grace window) is deterministic in unit
/// tests with no real waiting.
///
/// Not `Sendable`: drive it from a single concurrency domain (e.g. the main
/// actor in the app, or one test function).
public final class VoiceController {

    // MARK: - Configuration

    /// No-new-speech cap while listening.
    public let silenceCap: TimeInterval
    /// Total-utterance cap (from press to send).
    public let totalCap: TimeInterval
    /// Editable grace window after release before an auto-send.
    public let reviewGrace: TimeInterval
    /// Minimum word count a final must have to be sent (shorter finals never
    /// auto-send).
    public let minWords: Int

    // MARK: - Observable state

    /// The current HUD state. Mutations also fire `onStateChange`.
    public private(set) var state: VoiceState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    /// The live transcript text surfaced to the HUD. Updated on every transcript
    /// (volatile or final); the HUD renders this. The value actually COMMITTED on
    /// send is the last *final* transcript (see `finalText`), never a volatile.
    public private(set) var currentText: String = ""

    /// Called on every state transition (for the HUD).
    public var onStateChange: ((VoiceState) -> Void)?
    /// Called once when an intent is committed.
    public var onIntent: ((VoiceIntent) -> Void)?

    // MARK: - Private state

    /// Last *final* transcript — the only text eligible to be committed.
    private var finalText: String = ""
    private var targetSession: SessionKey?

    /// Monotonic internal clock (seconds); advanced only via `advance(by:)`.
    private var clock: TimeInterval = 0
    /// Absolute fire times on `clock`; `nil` means inactive.
    private var totalDeadline: TimeInterval?
    private var silenceDeadline: TimeInterval?
    private var reviewDeadline: TimeInterval?

    private var intentContinuation: AsyncStream<VoiceIntent>.Continuation?

    public init(
        silenceCap: TimeInterval = 15,
        totalCap: TimeInterval = 120,
        reviewGrace: TimeInterval = 1.5,
        minWords: Int = 3
    ) {
        self.silenceCap = silenceCap
        self.totalCap = totalCap
        self.reviewGrace = reviewGrace
        self.minWords = minWords
    }

    /// A stream of committed intents (app-facing). Single-observer: the most
    /// recent caller receives subsequent intents. `onIntent` fires in addition.
    public func intents() -> AsyncStream<VoiceIntent> {
        AsyncStream { continuation in
            self.intentContinuation = continuation
        }
    }

    // MARK: - Inputs (PTT + transcripts)

    /// Ready the mic (pre-listening). Valid from a resting state; a no-op while
    /// already listening/reviewing.
    public func arm() {
        switch state {
        case .idle, .sent, .error:
            resetSession()
            state = .armed
        case .armed, .listening, .review:
            break
        }
    }

    /// Push-to-talk pressed: start capturing. Optionally binds the utterance to a
    /// target session, carried into the emitted `VoiceIntent`.
    public func press(target: SessionKey? = nil) {
        switch state {
        case .idle, .armed, .sent, .error:
            resetSession()
            targetSession = target
            totalDeadline = clock + totalCap
            silenceDeadline = clock + silenceCap
            state = .listening
        case .listening, .review:
            break
        }
    }

    /// Push-to-talk released: finalize and enter the review grace window.
    public func release() {
        guard state == .listening else { return }
        silenceDeadline = nil
        reviewDeadline = clock + reviewGrace
        state = .review
    }

    /// Feed a transcript. Volatiles surface to `currentText` (and reset the
    /// silence cap) but never commit; a final also updates the committable text.
    public func ingest(_ transcript: Transcript) {
        switch state {
        case .listening:
            currentText = transcript.text
            if transcript.isFinal { finalText = transcript.text }
            silenceDeadline = clock + silenceCap
        case .review:
            // A late final or edit updates the text but does not restart grace.
            currentText = transcript.text
            if transcript.isFinal { finalText = transcript.text }
        default:
            break
        }
    }

    /// Edit the pending text during the review window (the editable part of the
    /// grace). Only valid in `.review`.
    public func edit(_ text: String) {
        guard state == .review else { return }
        currentText = text
        finalText = text
    }

    /// Send immediately (e.g. Return), skipping the remaining grace. Subject to
    /// the same ≥`minWords` guard as an auto-send.
    public func sendNow() {
        guard state == .review else { return }
        attemptSend()
    }

    /// Cancel (e.g. ESC): return cleanly to idle without emitting anything.
    public func cancel() {
        switch state {
        case .armed, .listening, .review:
            resetSession()
            state = .idle
        case .idle, .sent, .error:
            resetSession()
            state = .idle
        }
    }

    /// Reset to idle unconditionally.
    public func reset() {
        resetSession()
        state = .idle
    }

    // MARK: - Injectable time

    /// Advance the internal clock by `seconds`, firing any caps/grace crossed in
    /// chronological order. This is the ONLY way time passes — no wall clock is
    /// consulted — so timer behavior is fully deterministic.
    public func advance(by seconds: TimeInterval) {
        let target = clock + max(0, seconds)
        while let event = nextDueEvent(upTo: target) {
            clock = event.time
            fire(event.kind)
        }
        clock = target
    }

    /// The current internal clock value (seconds since the machine was created).
    public var elapsed: TimeInterval { clock }

    // MARK: - Timer engine

    private enum TimerKind { case silence, total, review }
    private struct TimerEvent { let time: TimeInterval; let kind: TimerKind }

    /// Active deadlines given the current state, as (time, kind) pairs.
    private func activeDeadlines() -> [TimerEvent] {
        var events: [TimerEvent] = []
        switch state {
        case .listening:
            if let d = silenceDeadline { events.append(TimerEvent(time: d, kind: .silence)) }
            if let d = totalDeadline { events.append(TimerEvent(time: d, kind: .total)) }
        case .review:
            if let d = reviewDeadline { events.append(TimerEvent(time: d, kind: .review)) }
            if let d = totalDeadline { events.append(TimerEvent(time: d, kind: .total)) }
        default:
            break
        }
        return events
    }

    /// The earliest active deadline at or before `target`, or `nil` if none is
    /// due. Ties break by a fixed priority for determinism.
    private func nextDueEvent(upTo target: TimeInterval) -> TimerEvent? {
        activeDeadlines()
            .filter { $0.time <= target }
            .min { a, b in
                a.time != b.time ? a.time < b.time : priority(a.kind) < priority(b.kind)
            }
    }

    private func priority(_ kind: TimerKind) -> Int {
        switch kind {
        case .silence: return 0
        case .total: return 1
        case .review: return 2
        }
    }

    private func fire(_ kind: TimerKind) {
        switch kind {
        case .silence:
            guard state == .listening else { return }
            clearTimers()
            state = .error(.silenceTimeout)
        case .total:
            guard state == .listening || state == .review else { return }
            clearTimers()
            state = .error(.totalTimeout)
        case .review:
            guard state == .review else { return }
            attemptSend()
        }
    }

    // MARK: - Commit

    private func attemptSend() {
        let candidate = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wordCount(candidate) >= minWords else {
            // The ≥minWords guard blocks the send: stop the grace timer and stay
            // in review (awaiting an edit, a longer final, cancel, or the total
            // cap). Nothing is emitted.
            reviewDeadline = nil
            return
        }
        clearTimers()
        emit(VoiceIntent(targetSession: targetSession, text: candidate))
        state = .sent
    }

    private func emit(_ intent: VoiceIntent) {
        onIntent?(intent)
        intentContinuation?.yield(intent)
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: - Helpers

    private func clearTimers() {
        totalDeadline = nil
        silenceDeadline = nil
        reviewDeadline = nil
    }

    private func resetSession() {
        clearTimers()
        currentText = ""
        finalText = ""
        targetSession = nil
    }
}
