import Foundation

/// The kind of an external tool notchide can connect an agent to.
///
/// Drives the connector's default glyph/affordances in the UI; `.custom` is the
/// escape hatch for anything not modeled explicitly.
public enum ToolKind: String, Sendable, Codable, CaseIterable {
    case github
    case mcp
    case browser
    case mail
    case slack
    case shell
    case custom
}

/// A single configured tool connector.
///
/// `id` is stable and provided by the caller (used for UPSERT and as the
/// `Identifiable` key); `name` and `kind` are display/routing metadata; `enabled`
/// gates whether the connector is offered to agents.
public struct ToolConnector: Identifiable, Sendable, Codable, Hashable {
    public let id: String
    public var name: String
    public var kind: ToolKind
    public var enabled: Bool

    public init(id: String, name: String, kind: ToolKind, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
    }
}

/// Persistent, concurrency-safe registry of tool connectors.
///
/// An `actor` because the connector list is shared mutable state written to disk
/// as JSON. The backing `fileURL` is injectable so tests can point it at a temp
/// location; production uses `defaultFileURL` under notchide's app-support dir.
public actor ToolRegistry {
    /// The current connectors, in insertion order (UPSERT keeps position).
    public private(set) var connectors: [ToolConnector]
    private let fileURL: URL

    /// `~/Library/Application Support/notchide/tools.json`.
    public static var defaultFileURL: URL {
        NotchidePaths.supportDirectory.appendingPathComponent("tools.json")
    }

    /// - Parameter fileURL: Where connectors are persisted. Defaults to
    ///   `defaultFileURL`; inject a temp URL in tests. The registry starts empty;
    ///   call `load()` to hydrate from disk.
    public init(fileURL: URL = ToolRegistry.defaultFileURL) {
        self.fileURL = fileURL
        self.connectors = []
    }

    /// A snapshot of the current connectors.
    public func all() -> [ToolConnector] {
        connectors
    }

    /// Inserts `connector`, or replaces an existing one with the same `id`
    /// in place (UPSERT), then persists.
    public func register(_ connector: ToolConnector) throws {
        if let index = connectors.firstIndex(where: { $0.id == connector.id }) {
            connectors[index] = connector
        } else {
            connectors.append(connector)
        }
        try save()
    }

    /// Sets the `enabled` flag on the connector with the given `id` (a no-op if
    /// none matches), then persists.
    public func setEnabled(_ enabled: Bool, id: String) throws {
        guard let index = connectors.firstIndex(where: { $0.id == id }) else { return }
        connectors[index].enabled = enabled
        try save()
    }

    /// Removes the connector with the given `id` (a no-op if none matches), then
    /// persists.
    public func remove(id: String) throws {
        let before = connectors.count
        connectors.removeAll { $0.id == id }
        if connectors.count != before {
            try save()
        }
    }

    /// Replaces the in-memory connectors with those persisted at `fileURL`. A
    /// missing file is treated as "no connectors" rather than an error.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            connectors = []
            return
        }
        let data = try Data(contentsOf: fileURL)
        connectors = try JSONDecoder().decode([ToolConnector].self, from: data)
    }

    /// Atomically writes the current connectors to `fileURL` with `0600`
    /// permissions. Writes to a sibling temp file and swaps it into place so a
    /// concurrent reader never observes a half-written file.
    private func save() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )

        let data = try JSONEncoder().encode(connectors)
        let tmp = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try data.write(to: tmp, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: tmp.path
        )

        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }
        // Re-assert 0600 on the final file regardless of how it landed there.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }
}
