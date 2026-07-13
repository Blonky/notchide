import Foundation

/// Where a workspace's files came from — a plain folder the user opened, or a
/// git remote notchide cloned on their behalf.
///
/// `Codable` conformance is the default enum-with-payload synthesis, encoding as
/// `{"folder":{}}` or `{"git":{"remote":"…","branch":"…"}}`. Both cases are
/// value types with no reference identity, so a `Workspace` stays trivially
/// `Sendable`.
public enum WorkspaceSource: Hashable, Sendable, Codable {
    /// A folder the user picked; notchide only reads it, it did not create it.
    case folder
    /// A git remote notchide cloned. `branch` is `nil` when the clone tracked the
    /// remote's default branch.
    case git(remote: String, branch: String?)
}

/// A user-facing project the notch tracks: a named root directory plus the
/// agent sessions that have been attached to it.
///
/// A `Workspace` is a pure value type (`Sendable`, `Codable`, `Hashable`) so it
/// can be persisted by `WorkspaceStore` and handed across the actor boundary
/// without any shared mutable state. Identity is the stable `id`, not the
/// mutable `name`/`root`, so renaming or moving a workspace preserves its
/// attached sessions.
public struct Workspace: Identifiable, Hashable, Sendable, Codable {
    /// Stable identity, assigned once at creation and never mutated.
    public let id: UUID
    /// Human-readable display name.
    public var name: String
    /// The workspace's root directory on disk.
    public var root: URL
    /// How this workspace's files were obtained.
    public var source: WorkspaceSource
    /// The agent sessions attached to this workspace, in attachment order.
    public var sessions: [SessionKey]

    /// Creates a workspace.
    ///
    /// - Parameters:
    ///   - id: Stable identity; defaults to a fresh `UUID`.
    ///   - name: Human-readable display name.
    ///   - root: The workspace's root directory.
    ///   - source: How the files were obtained (folder or git clone).
    ///   - sessions: Attached agent sessions; defaults to empty.
    public init(
        id: UUID = UUID(),
        name: String,
        root: URL,
        source: WorkspaceSource,
        sessions: [SessionKey] = []
    ) {
        self.id = id
        self.name = name
        self.root = root
        self.source = source
        self.sessions = sessions
    }
}
