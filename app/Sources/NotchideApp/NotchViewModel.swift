import SwiftUI
import NotchideKit

/// The read-only payload the review console renders for a single session.
///
/// Keyed by the lane's `SessionKey` (was a bare envelope UUID). The blocking
/// decision, when present, correlates back to the provider via `decisionID`.
public struct ReviewContext: Identifiable, Equatable {
    /// The lane identity — the presentation/queue correlation key.
    public let id: SessionKey
    /// The provider that owns this lane (drives the provider badge).
    public let providerID: ProviderID
    /// Whether this provider's decisions may seize the user. Drives the console
    /// branch: `.blocking` shows the decision row; `.notifyOnly` shows the quiet
    /// capability banner instead.
    public let decisionCapability: DecisionCapability
    public let cwd: String
    /// The tool name from the underlying event, if any (header chip).
    public let toolName: String?
    /// The exact pending command / tool invocation, shown in full (never truncated).
    public let command: String?
    /// Correlates the eventual `AgentDecision`; non-nil only for a live blocking
    /// gate. `nil` for observe-only lanes or a summoned lane with no pending gate.
    public let decisionID: UUID?
    /// The Suppressor's "why did this tap?" reason.
    public let reason: String
    /// A short tail of the agent's recent output, if available.
    public let outputTail: String?

    /// Set once the gate has timed out / been dropped app-side. Disables the
    /// decision controls so a stale click can't "decide" something already gone.
    public var isExpired: Bool = false

    // Filled in asynchronously after the console is already on screen.
    public var branch: String?
    public var diff: GitDiff?

    /// Destructive tokens detected in `command` (drives the red highlight + tag).
    public let destructiveTokens: [String]
    public var isDestructive: Bool { !destructiveTokens.isEmpty }

    /// A blocking gate is actually awaiting a decision from us.
    public var wantsDecision: Bool { decisionCapability == .blocking && decisionID != nil }
    /// Whether to render allow/deny/ask buttons: a live blocking gate that has
    /// not expired. Mirrors `Lane.showsDecisionButtons` plus app-side expiry.
    public var showsDecisionButtons: Bool { wantsDecision && !isExpired }
    /// An observe-only (`.notifyOnly`) lane: never shows decision buttons, shows a
    /// quiet capability banner instead. (Gallery state 6.)
    public var isObserveOnly: Bool { decisionCapability == .notifyOnly }

    /// A short, display-friendly agent id derived from the session id.
    public var shortSessionId: String {
        let sid = id.agentSessionID
        return sid.count > 8 ? String(sid.prefix(8)) : sid
    }

    public init(
        id: SessionKey,
        providerID: ProviderID,
        decisionCapability: DecisionCapability,
        cwd: String,
        toolName: String?,
        command: String?,
        decisionID: UUID?,
        reason: String,
        outputTail: String?,
        branch: String? = nil,
        diff: GitDiff? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.decisionCapability = decisionCapability
        self.cwd = cwd
        self.toolName = toolName
        self.command = command
        self.decisionID = decisionID
        self.reason = reason
        self.outputTail = outputTail
        self.branch = branch
        self.diff = diff
        self.destructiveTokens = DestructiveScanner.scan(command)
    }
}

/// The on-screen state of the voice HUD, mirrored from `VoiceController.VoiceState`
/// but flattened for the view layer (carrying the error message inline).
///
/// This is the app-side presentation enum; the pure state machine lives in the
/// core `VoiceController`. `NotchController` maps one onto the other.
public enum VoiceHUDState: Equatable {
    /// The HUD is not on screen.
    case inactive
    /// Push-to-talk is engaged and capturing (or arming). Shows the waveform orb,
    /// the live partial transcript, and the silence meter.
    case listening
    /// PTT released; the solidified transcript sits in the editable grace window
    /// before it auto-sends.
    case review
    /// A cap fired (or a provider failed) before anything could be sent. Quiet,
    /// auto-dismissing.
    case error(String)

    /// Whether the HUD should be shown at all.
    public var isActive: Bool { self != .inactive }
    /// Whether the HUD is actively capturing (drives the orb animation).
    public var isListening: Bool { self == .listening }
}

/// The single `@MainActor` source of truth the SwiftUI views observe.
///
/// `NotchController` owns this and pushes lane snapshots and review payloads into
/// it; the views read `lanes` (collapsed cockpit) and `review` (expanded console)
/// and call back through the closures for decisions and navigation.
@MainActor
public final class NotchViewModel: ObservableObject {
    /// Live lane snapshots, most-recently-updated first.
    @Published public var lanes: [Lane] = []
    /// The current expanded review, if any.
    @Published public var review: ReviewContext?
    /// Whether the user pinned the console open (suspends auto-collapse).
    @Published public var isPinned: Bool = false
    /// Number of additional decision gates queued behind the one on screen.
    @Published public var waitingCount: Int = 0
    /// Bumped to trigger a subtle passive pulse of the collapsed pill (a
    /// non-decision tap pulses; it never auto-expands).
    @Published public var pillPulse: Int = 0
    /// Global mute. Persisted; when set, the Suppressor never taps the user.
    @Published public var muted: Bool = MuteSettings.isMuted {
        didSet { MuteSettings.set(muted) }
    }

    // MARK: Voice HUD

    /// The current voice HUD state. `.inactive` hides the overlay entirely.
    @Published public var voiceState: VoiceHUDState = .inactive
    /// The live (volatile-or-final) transcript surfaced under the orb / in the
    /// review editor. Bound two-way while editing so the user can correct it.
    @Published public var voiceText: String = ""
    /// A short label for the target session the utterance is bound to (the chip).
    @Published public var voiceTargetLabel: String?
    /// The silence-while-listening / grace-until-send meter, `0...1`.
    @Published public var voiceMeter: Double = 0
    /// Set in the review window when the user hits Esc to hold the auto-send and
    /// edit the transcript (freezes the grace timer).
    @Published public var voiceEditing: Bool = false
    /// True while in a gate-verdict (`gate-listen`) session rather than a fresh
    /// ACTUATE prompt — the HUD then reads as "say approve / deny".
    @Published public var voiceGateMode: Bool = false
    /// Set when a spoken *approval* was refused because the pending command was
    /// flagged destructive: voice-approve is disabled and a click/hotkey is
    /// required (the approved safety rule). Drives the HUD hint.
    @Published public var voiceApproveDisabled: Bool = false

    /// Send the reviewed transcript immediately (Return), skipping the grace.
    public var onVoiceSendNow: (() -> Void)?
    /// Cancel the voice session (Esc while listening) — discards, emits nothing.
    public var onVoiceCancel: (() -> Void)?
    /// Hold the auto-send and edit the transcript (Esc while reviewing).
    public var onVoiceHoldToEdit: (() -> Void)?
    /// Commit an edit of the pending transcript during the review window.
    public var onVoiceEdit: ((String) -> Void)?

    // Callbacks wired by NotchController. Kept as closures so the views never
    // reach across into the actor/socket machinery directly.

    /// (permission, reason, redirect) — the user's decision on the pending gate.
    public var onDecide: ((PermissionDecision, String?, String?) -> Void)?
    /// Approve the pending command AND remember it for future auto-approval.
    public var onApproveRemember: (() -> Void)?
    /// Collapse the console back to the cockpit.
    public var onCollapse: (() -> Void)?
    /// Toggle the pinned state.
    public var onTogglePin: (() -> Void)?
    /// Jump to the terminal for the given working directory.
    public var onJumpToTerminal: ((String) -> Void)?

    public init() {}
}

/// The single persisted source of truth for the global mute toggle.
///
/// Backed by `UserDefaults` so it is readable off the main actor (the socket
/// handler needs the current value per event) without capturing the `@MainActor`
/// view model in a `@Sendable` closure.
public enum MuteSettings {
    private static let key = "notchide.globalMute"

    public static var isMuted: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    public static func set(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
