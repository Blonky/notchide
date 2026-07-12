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
///  1. the event is a hard block (PreToolUse permission, Notification, Stop),
///  2. the session is NOT already visible to the user, and
///  3. the session is NOT muted.
public struct Suppressor: Sendable {
    public init() {}

    /// - Returns: `tap` — whether to actively surface the alert; `reason` — a
    ///   human-readable explanation of the decision.
    public func shouldTap(
        event: HookEvent,
        key: SessionKey,
        muted: Bool,
        context: FrontmostContextProviding
    ) async -> (tap: Bool, reason: String) {
        guard Suppressor.isHardBlock(event) else {
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

    /// Whether the event is a hard block that could justify tapping the user.
    /// Hard blocks: PreToolUse (permission gate), Notification, Stop.
    static func isHardBlock(_ event: HookEvent) -> Bool {
        switch event.hookEventName {
        case .preToolUse, .notification, .stop:
            return true
        default:
            return false
        }
    }
}
