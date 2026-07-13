import Foundation

/// Persistent, concurrency-safe store of the user's `Workspace`s.
///
/// An `actor` so it is safe to feed from many concurrent callers under Swift 6
/// strict concurrency. State is a plain `[Workspace]` array persisted as JSON at
/// `fileURL` (default `~/Library/Application Support/notchide/workspaces.json`,
/// reusing `NotchidePaths`' app-support helper). Every mutator persists after
/// mutating, and `save()` writes atomically then locks the file to owner-only
/// `0600` — the workspace list can reference private local paths.
public actor WorkspaceStore {
    /// The current workspaces, most-recently-added last.
    public private(set) var workspaces: [Workspace] = []

    /// The JSON file backing this store.
    private let fileURL: URL

    /// Creates a store backed by `fileURL`.
    ///
    /// The file is not read at init; call `load()` to hydrate from disk. This
    /// keeps `init` non-throwing and lets tests point at a temp file.
    public init(fileURL: URL = WorkspaceStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// The default backing file:
    /// `~/Library/Application Support/notchide/workspaces.json`.
    public static var defaultFileURL: URL {
        NotchidePaths.supportDirectory.appendingPathComponent("workspaces.json", isDirectory: false)
    }

    // MARK: - Queries

    /// A snapshot of all workspaces.
    public func all() -> [Workspace] {
        workspaces
    }

    // MARK: - Mutators (each persists after mutating)

    /// Adds a workspace, or replaces an existing one with the same `id`.
    public func add(_ workspace: Workspace) {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
        persist()
    }

    /// Removes the workspace with the given `id`, if present.
    public func remove(id: UUID) {
        workspaces.removeAll { $0.id == id }
        persist()
    }

    /// Attaches a session to the workspace with the given `id`.
    ///
    /// Appends `key` to that workspace's `sessions` (deduplicated). A no-op if no
    /// workspace has the given `id`.
    public func attachSession(_ key: SessionKey, to id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        if !workspaces[index].sessions.contains(key) {
            workspaces[index].sessions.append(key)
        }
        persist()
    }

    // MARK: - Persistence

    /// Loads workspaces from `fileURL`, replacing the in-memory list.
    ///
    /// A missing file is treated as an empty store (not an error) so a
    /// first-run load succeeds. A present-but-corrupt file surfaces the decode
    /// error to the caller.
    public func load() throws {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // No file yet → nothing to load.
            workspaces = []
            return
        }
        workspaces = try JSONDecoder().decode([Workspace].self, from: data)
    }

    /// Persists the current list, swallowing errors: mutators are non-throwing by
    /// design (they mutate in-memory state that stays valid regardless of disk
    /// outcome). Callers that need to observe I/O failures use `save()` directly.
    private func persist() {
        try? save()
    }

    /// Writes the current list to `fileURL` atomically, then restricts it to
    /// owner-only `0600`.
    private func save() throws {
        let data = try JSONEncoder().encode(workspaces)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try data.write(to: fileURL, options: [.atomic])
        // The atomic write's temp file is created with the process umask, so
        // clamp the final file to owner-only after the rename.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }
}
