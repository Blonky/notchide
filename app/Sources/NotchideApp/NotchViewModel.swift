import SwiftUI
import NotchideKit

/// The read-only payload the review console renders for a single session.
public struct ReviewContext: Identifiable, Equatable {
    /// The envelope UUID — the correlation key for the decision round-trip.
    public let id: UUID
    public let sessionId: String
    public let cwd: String
    public let toolName: String?
    /// The exact pending command / tool invocation, shown in full (never truncated).
    public let command: String?
    /// Whether the blocked hook is actually awaiting a decision from us.
    public let wantsDecision: Bool
    /// The Suppressor's "why did this tap?" reason.
    public let reason: String
    /// A short tail of the agent's recent output, if available.
    public let outputTail: String?

    // Filled in asynchronously after the console is already on screen.
    public var branch: String?
    public var diff: GitDiff?

    /// Destructive tokens detected in `command` (drives the red highlight + tag).
    public let destructiveTokens: [String]
    public var isDestructive: Bool { !destructiveTokens.isEmpty }

    /// A short, display-friendly agent id derived from the session id.
    public var shortSessionId: String {
        sessionId.count > 8 ? String(sessionId.prefix(8)) : sessionId
    }

    public init(
        id: UUID,
        sessionId: String,
        cwd: String,
        toolName: String?,
        command: String?,
        wantsDecision: Bool,
        reason: String,
        outputTail: String?,
        branch: String? = nil,
        diff: GitDiff? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.cwd = cwd
        self.toolName = toolName
        self.command = command
        self.wantsDecision = wantsDecision
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

    // Callbacks wired by NotchController. Kept as closures so the views never
    // reach across into the actor/socket machinery directly.

    /// (permission, reason, redirect) — the user's decision on the pending gate.
    public var onDecide: ((PermissionDecision, String?, String?) -> Void)?
    /// Collapse the console back to the cockpit.
    public var onCollapse: (() -> Void)?
    /// Toggle the pinned state.
    public var onTogglePin: (() -> Void)?
    /// Jump to the terminal for the given working directory.
    public var onJumpToTerminal: ((String) -> Void)?

    public init() {}
}
