import Foundation

/// The set of Claude Code hook event names that notchide models explicitly.
///
/// Claude Code emits many more event names than these; unknown names decode to
/// `nil` on `HookEvent.hookEventName` (with the raw string preserved in
/// `HookEvent.rawHookEventName`) rather than causing a decode failure.
///
/// The exact string values below are the ones Claude Code sends on stdin as
/// `hook_event_name`. Confirmed against the official hooks reference:
/// https://code.claude.com/docs/en/hooks
/// (301 redirect from https://docs.anthropic.com/en/docs/claude-code/hooks)
public enum HookEventName: String, Codable, Sendable, CaseIterable {
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case notification = "Notification"
    case stop = "Stop"
    case subagentStop = "SubagentStop"
    case userPromptSubmit = "UserPromptSubmit"
    case sessionStart = "SessionStart"
}

/// A decoded Claude Code hook event.
///
/// The JSON arrives on the hook command's stdin. Field names use snake_case
/// (`session_id`, `hook_event_name`, `tool_input`, …). The decoder is
/// deliberately lenient: it never throws on unknown or extra fields, and it
/// tolerates missing common fields (defaulting `sessionId`/`cwd` to `""`).
/// Any keys not modelled explicitly are preserved in `extra`, so the value
/// round-trips losslessly through `Codable` (used for IPC).
public struct HookEvent: Codable, Sendable, Equatable {
    /// `session_id`
    public let sessionId: String
    /// `cwd`
    public let cwd: String
    /// Parsed `hook_event_name`; `nil` when the event name is not modelled.
    public let hookEventName: HookEventName?
    /// The raw `hook_event_name` string exactly as sent (may be empty).
    public let rawHookEventName: String
    /// `transcript_path`
    public let transcriptPath: String?
    /// `tool_name` (PreToolUse / PostToolUse)
    public let toolName: String?
    /// `tool_input` (PreToolUse / PostToolUse) as a flexible JSON value.
    public let toolInput: JSONValue?
    /// `message` (Notification)
    public let message: String?
    /// `notification_type` (Notification)
    public let notificationType: String?
    /// `prompt` (UserPromptSubmit)
    public let prompt: String?
    /// `last_assistant_message` (Stop / SubagentStop)
    public let lastAssistantMessage: String?
    /// Catch-all for any other fields present in the payload.
    public let extra: [String: JSONValue]

    static let knownKeys: Set<String> = [
        "session_id", "cwd", "hook_event_name", "transcript_path",
        "tool_name", "tool_input", "message", "notification_type",
        "prompt", "last_assistant_message",
    ]

    /// Designated initializer for constructing events in code (tests, self-test).
    public init(
        sessionId: String,
        cwd: String,
        hookEventName: HookEventName?,
        rawHookEventName: String? = nil,
        transcriptPath: String? = nil,
        toolName: String? = nil,
        toolInput: JSONValue? = nil,
        message: String? = nil,
        notificationType: String? = nil,
        prompt: String? = nil,
        lastAssistantMessage: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.rawHookEventName = rawHookEventName ?? hookEventName?.rawValue ?? ""
        self.transcriptPath = transcriptPath
        self.toolName = toolName
        self.toolInput = toolInput
        self.message = message
        self.notificationType = notificationType
        self.prompt = prompt
        self.lastAssistantMessage = lastAssistantMessage
        self.extra = extra
    }

    /// Builds an event from a raw JSON object, extracting known keys and
    /// preserving the remainder in `extra`.
    public init(dictionary dict: [String: JSONValue]) {
        self.sessionId = dict["session_id"]?.stringValue ?? ""
        self.cwd = dict["cwd"]?.stringValue ?? ""
        let rawName = dict["hook_event_name"]?.stringValue ?? ""
        self.rawHookEventName = rawName
        self.hookEventName = HookEventName(rawValue: rawName)
        self.transcriptPath = dict["transcript_path"]?.stringValue
        self.toolName = dict["tool_name"]?.stringValue
        self.toolInput = dict["tool_input"]
        self.message = dict["message"]?.stringValue
        self.notificationType = dict["notification_type"]?.stringValue
        self.prompt = dict["prompt"]?.stringValue
        self.lastAssistantMessage = dict["last_assistant_message"]?.stringValue
        var extra = dict
        for key in HookEvent.knownKeys { extra.removeValue(forKey: key) }
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Decoding the whole payload as an object never throws on unknown or
        // extra fields; a non-object payload degrades to an empty event.
        let dict = (try? container.decode([String: JSONValue].self)) ?? [:]
        self.init(dictionary: dict)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(dictionaryRepresentation())
    }

    /// The JSON-object representation, merging modelled fields over `extra`.
    public func dictionaryRepresentation() -> [String: JSONValue] {
        var dict = extra
        dict["session_id"] = .string(sessionId)
        dict["cwd"] = .string(cwd)
        if !rawHookEventName.isEmpty { dict["hook_event_name"] = .string(rawHookEventName) }
        if let transcriptPath { dict["transcript_path"] = .string(transcriptPath) }
        if let toolName { dict["tool_name"] = .string(toolName) }
        if let toolInput { dict["tool_input"] = toolInput }
        if let message { dict["message"] = .string(message) }
        if let notificationType { dict["notification_type"] = .string(notificationType) }
        if let prompt { dict["prompt"] = .string(prompt) }
        if let lastAssistantMessage { dict["last_assistant_message"] = .string(lastAssistantMessage) }
        return dict
    }

    /// A human-readable command string for this event's tool invocation, if any.
    public var commandDescription: String? {
        guard let toolInput, let toolName else { return nil }
        return toolInput.humanReadableCommand(toolName: toolName)
    }
}

// MARK: - PreToolUse decision output

/// The permission decision a PreToolUse hook can return to Claude Code.
///
/// Confirmed values from https://code.claude.com/docs/en/hooks:
/// `"allow"` approves the call, `"deny"` blocks it, `"ask"` escalates to the
/// user's normal permission prompt. (Claude Code also documents `"defer"` to
/// fall back to the default flow; notchide expresses that by emitting no
/// decision at all — see `notchide-hook`'s fail-open contract — so it is not
/// part of this enum.)
public enum PermissionDecision: String, Codable, Sendable {
    case allow
    case deny
    case ask
}

/// The PreToolUse decision output, serialized to the modern
/// `hookSpecificOutput` schema that Claude Code expects on stdout:
///
/// ```json
/// {
///   "hookSpecificOutput": {
///     "hookEventName": "PreToolUse",
///     "permissionDecision": "deny",
///     "permissionDecisionReason": "Destructive command blocked by hook"
///   }
/// }
/// ```
///
/// Schema confirmed against the official hooks reference:
/// https://code.claude.com/docs/en/hooks
/// (301 redirect from https://docs.anthropic.com/en/docs/claude-code/hooks)
public struct HookDecision: Codable, Sendable, Equatable {
    public var permissionDecision: PermissionDecision
    public var reason: String?

    public init(permissionDecision: PermissionDecision, reason: String? = nil) {
        self.permissionDecision = permissionDecision
        self.reason = reason
    }

    private enum RootKeys: String, CodingKey {
        case hookSpecificOutput
    }

    private enum InnerKeys: String, CodingKey {
        case hookEventName
        case permissionDecision
        case permissionDecisionReason
    }

    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: RootKeys.self)
        var inner = root.nestedContainer(keyedBy: InnerKeys.self, forKey: .hookSpecificOutput)
        try inner.encode("PreToolUse", forKey: .hookEventName)
        try inner.encode(permissionDecision, forKey: .permissionDecision)
        try inner.encodeIfPresent(reason, forKey: .permissionDecisionReason)
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let inner = try root.nestedContainer(keyedBy: InnerKeys.self, forKey: .hookSpecificOutput)
        self.permissionDecision = try inner.decode(PermissionDecision.self, forKey: .permissionDecision)
        self.reason = try inner.decodeIfPresent(String.self, forKey: .permissionDecisionReason)
    }

    /// The decision serialized as a single-line JSON string for stdout.
    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
