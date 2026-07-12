import Foundation

/// Wire message sent from the `notchide-hook` CLI to the app's socket server.
///
/// One envelope carries a single decoded hook event plus whether the CLI is
/// blocking on a decision (only PreToolUse permission gates do).
public struct HookEnvelope: Codable, Sendable, Equatable {
    public let id: UUID
    public let event: HookEvent
    public let wantsDecision: Bool

    public init(id: UUID = UUID(), event: HookEvent, wantsDecision: Bool) {
        self.id = id
        self.event = event
        self.wantsDecision = wantsDecision
    }
}

/// Wire message sent from the app back to the `notchide-hook` CLI in response
/// to an envelope with `wantsDecision == true`.
///
/// `redirect` is an app-level concept (steer the agent elsewhere); the CLI maps
/// `permission`/`reason` onto the Claude Code PreToolUse decision output.
public struct DecisionMessage: Codable, Sendable, Equatable {
    public let id: UUID
    public let permission: PermissionDecision
    public let reason: String?
    public let redirect: String?

    public init(id: UUID, permission: PermissionDecision, reason: String? = nil, redirect: String? = nil) {
        self.id = id
        self.permission = permission
        self.reason = reason
        self.redirect = redirect
    }
}

/// Newline-delimited JSON (NDJSON) framing helpers.
///
/// Each value is encoded as a single line of JSON terminated by `\n`, which is
/// the frame delimiter used by `UnixSocketServer` / `UnixSocketClient`.
public enum NDJSON {
    /// Encodes a value as one JSON line terminated by `\n`.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A) // '\n'
        return data
    }

    /// Decodes a value from a single line of JSON (with or without a trailing `\n`).
    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}

/// Filesystem locations used by notchide.
public enum NotchidePaths {
    /// `~/Library/Application Support/notchide`
    public static var supportDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("notchide", isDirectory: true)
    }

    /// The canonical hook socket path:
    /// `~/Library/Application Support/notchide/hook.sock`
    public static var socketPath: String {
        supportDirectory.appendingPathComponent("hook.sock").path
    }

    /// Ensures the support directory exists with `0700` permissions and returns it.
    @discardableResult
    public static func ensureSupportDirectory() throws -> URL {
        let dir = supportDirectory
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        // createDirectory only applies permissions to leaf dirs it creates; make
        // sure the leaf ends up 0700 even if it already existed.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: dir.path
        )
        return dir
    }
}
