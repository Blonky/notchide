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
