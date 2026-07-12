import Foundation

/// Supplies whether a given session is currently visible to the user (its
/// terminal/window is frontmost). The real AppKit-backed implementation lives
/// in the GUI app; `StubFrontmostContext` is provided here for tests.
public protocol FrontmostContextProviding: Sendable {
    func isSessionVisible(_ key: SessionKey) async -> Bool
}

/// A deterministic `FrontmostContextProviding` for tests: any session in
/// `visibleSessions` is considered visible.
public struct StubFrontmostContext: FrontmostContextProviding {
    public let visibleSessions: Set<SessionKey>

    public init(visibleSessions: Set<SessionKey> = []) {
        self.visibleSessions = visibleSessions
    }

    public func isSessionVisible(_ key: SessionKey) async -> Bool {
        visibleSessions.contains(key)
    }
}

/// Pure decision logic for whether a "needs-you" lane should actively *tap* the
/// user (surface a notch alert) versus staying quiet.
///
/// A tap happens only when all of the following hold:
///  1. the event is escalation-eligible (see `isHardBlock`),
///  2. the session is NOT already visible to the user, and
///  3. the session is NOT muted.
///
/// Escalation eligibility is now vendor-agnostic: it comes from the provider's
/// `DecisionCapability` plus the event kind. A `.notifyOnly` provider is
/// STRUCTURALLY unable to tap the user.
public struct Suppressor: Sendable {
    public init() {}

    /// - Returns: `tap` — whether to actively surface the alert; `reason` — a
    ///   human-readable explanation of the decision.
    public func shouldTap(
        kind: AgentEventKind,
        decisionCapability: DecisionCapability,
        key: SessionKey,
        muted: Bool,
        context: FrontmostContextProviding
    ) async -> (tap: Bool, reason: String) {
        guard Suppressor.isHardBlock(kind: kind, decisionCapability: decisionCapability) else {
            return (false, "not a blocking event")
        }
        if muted {
            return (false, "muted")
        }
        if await context.isSessionVisible(key) {
            return (false, "already visible")
        }
        return (true, "terminal not visible")
    }

    /// Whether an event is a hard block that could justify tapping the user.
    ///
    /// A `.notifyOnly` provider can never tap. For a `.blocking` provider the
    /// hard-block kinds are `.needsDecision` (permission gate), `.notified`
    /// (notification), and `.finished` (turn done) — matching the pre-AAP
    /// PreToolUse / Notification / Stop rule.
    public static func isHardBlock(kind: AgentEventKind, decisionCapability: DecisionCapability) -> Bool {
        guard decisionCapability == .blocking else { return false }
        switch kind {
        case .needsDecision, .notified, .finished:
            return true
        default:
            return false
        }
    }
}
