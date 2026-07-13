import Foundation

/// The level of screen access an agent has been granted for a workspace.
///
/// A monotonic privilege ladder: `.none` < `.observe` < `.control`. `.observe`
/// permits an on-request screenshot as context; `.control` additionally permits
/// driving the pointer/keyboard.
public enum ScreenAccess: String, Sendable, Codable, CaseIterable {
    case none
    case observe
    case control
}

/// A persisted record of the screen access granted to a single workspace.
///
/// `access` is a `var` so a grant can be upgraded/downgraded in place without
/// re-keying; `workspaceID` is the stable identity it is keyed on.
public struct ScreenContextGrant: Sendable, Codable, Hashable {
    public let workspaceID: UUID
    public var access: ScreenAccess

    public init(workspaceID: UUID, access: ScreenAccess) {
        self.workspaceID = workspaceID
        self.access = access
    }
}

/// How a screen action was initiated.
///
/// The distinction is load-bearing for `ScreenContextBroker.authorizeControl`:
/// `.voice` may never drive pointer/keyboard, no matter what grant is held.
public enum ScreenActionOrigin: Sendable {
    case voice
    case click
}

/// The single source of truth for per-workspace screen access.
///
/// An `actor` because grants are shared mutable state under Swift 6 strict
/// concurrency. Callers must route every "may the agent observe/control the
/// screen?" question through this broker rather than caching answers.
public actor ScreenContextBroker {
    private var grants: [UUID: ScreenAccess]

    public init(grants: [UUID: ScreenAccess] = [:]) {
        self.grants = grants
    }

    /// The access currently granted to `id`. Defaults to `.none` for any
    /// workspace that has never been granted anything.
    public func access(for id: UUID) -> ScreenAccess {
        grants[id] ?? .none
    }

    /// Grant (or re-grant) `access` to `id`, replacing any prior level.
    public func grant(_ access: ScreenAccess, for id: UUID) {
        grants[id] = access
    }

    /// Revoke all screen access for `id` (returns it to the `.none` default).
    public func revoke(for id: UUID) {
        grants[id] = nil
    }

    /// Whether `id` may be handed an on-request screenshot. True for any grant
    /// other than `.none`.
    public func canObserve(_ id: UUID) -> Bool {
        access(for: id) != .none
    }

    /// The load-bearing safety invariant of the screen-control path.
    ///
    /// Returns `true` ONLY IF `id` holds a `.control` grant AND the action was
    /// initiated by a `.click`. A `.voice` origin ALWAYS returns `false`, even
    /// when a full `.control` grant is present: voice may never drive the
    /// pointer/keyboard. This voice-refusal is the invariant the whole
    /// screen-control feature rests on — do not relax it.
    public func authorizeControl(_ id: UUID, origin: ScreenActionOrigin) -> Bool {
        grants[id] == .control && origin == .click
    }
}
