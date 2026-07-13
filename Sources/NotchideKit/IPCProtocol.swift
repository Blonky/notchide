import Foundation

/// The AAP connection handshake — the FIRST NDJSON line on every connection.
///
/// ```json
/// {"aap":"1","providerID":"sh.claude","capabilities":["gate","observe"]}
/// ```
///
/// The server validates `aap == "1"`, records the advertised `capabilities`, and
/// ignores decision escalation from any provider that did not advertise `gate`.
/// Decoding is lenient: a missing version degrades to an empty string (which
/// fails validation), and unknown capability strings are dropped rather than
/// throwing — so a newer client cannot crash the handshake.
public struct AAPHandshake: Codable, Sendable, Equatable {
    /// The AAP wire version this build speaks/accepts.
    public static let version = "1"

    public let aap: String
    public let providerID: ProviderID
    public let capabilities: Set<Capability>

    public init(providerID: ProviderID, capabilities: Set<Capability>, aap: String = AAPHandshake.version) {
        self.aap = aap
        self.providerID = providerID
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case aap, providerID, capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.aap = (try? container.decode(String.self, forKey: .aap)) ?? ""
        self.providerID = (try? container.decode(ProviderID.self, forKey: .providerID)) ?? ProviderID("")
        let rawCapabilities = (try? container.decode([String].self, forKey: .capabilities)) ?? []
        self.capabilities = Set(rawCapabilities.compactMap(Capability.init(rawValue:)))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(aap, forKey: .aap)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(capabilities.map(\.rawValue).sorted(), forKey: .capabilities)
    }

    /// Whether this handshake is a version the server accepts.
    public var isSupportedVersion: Bool { aap == AAPHandshake.version }
}

/// Wire message carrying one `AgentEvent` from an AAP adapter to the app.
///
/// `wantsDecision` is set only when the adapter is blocking on a decision (a
/// `gate` provider's `.needsDecision`); `id` correlates the eventual
/// `AgentDecision` reply. Generalizes the old `HookEnvelope`.
public struct AgentEnvelope: Codable, Sendable, Equatable {
    public let id: UUID
    public let event: AgentEvent
    public let wantsDecision: Bool

    public init(id: UUID = UUID(), event: AgentEvent, wantsDecision: Bool) {
        self.id = id
        self.event = event
        self.wantsDecision = wantsDecision
    }
}

/// A server→adapter push frame carrying one ACTUATE action to a live,
/// actuate-capable connection.
///
/// Wire shape (the top-level `actuate` key is the framing tag):
/// ```json
/// {"actuate":{"sessionKey":{"provider":"sh.claude","agentSessionID":"s","cwd":"/tmp"},
///             "kind":"prompt","text":"run the tests"}}
/// ```
/// `text` is present iff `kind == .prompt` (a `.interrupt` carries no text).
/// Distinct from `AgentEnvelope`/`AgentDecision`, which travel the other
/// direction; the `actuate` wrapper key lets a duplex reader tell them apart.
public struct ActuateFrame: Sendable, Equatable {
    /// Whether this frame delivers a fresh prompt or a barge-in interrupt.
    public enum Kind: String, Sendable, Codable, Equatable {
        case prompt
        case interrupt
    }

    public let sessionKey: SessionKey
    public let kind: Kind
    /// The instruction text. Non-nil only for `.prompt`; normalized to `nil` for
    /// `.interrupt` so the invariant holds regardless of the caller.
    public let text: String?

    public init(sessionKey: SessionKey, kind: Kind, text: String? = nil) {
        self.sessionKey = sessionKey
        self.kind = kind
        self.text = (kind == .prompt) ? text : nil
    }
}

extension ActuateFrame: Codable {
    private enum RootKeys: String, CodingKey { case actuate }

    private struct Body: Codable {
        let sessionKey: SessionKey
        let kind: Kind
        let text: String?
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let body = try root.decode(Body.self, forKey: .actuate)
        self.init(sessionKey: body.sessionKey, kind: body.kind, text: body.text)
    }

    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: RootKeys.self)
        // `text` stays nil for `.interrupt`, so JSONEncoder omits the key — the
        // "text present iff prompt" invariant is preserved on the wire.
        try root.encode(
            Body(sessionKey: sessionKey, kind: kind, text: kind == .prompt ? text : nil),
            forKey: .actuate)
    }
}

/// Classification of one inbound NDJSON line on a duplex AAP connection.
///
/// The four AAP line shapes are structurally distinguishable by their top-level
/// keys — `aap` (handshake), `actuate` (push frame), `verdict` (decision), and
/// `event` (envelope) — so a reader can dispatch a line without an out-of-band
/// tag. `.unknown` degrades gracefully (a newer/odd frame is skipped, never a
/// crash), mirroring the lenient decoding used elsewhere.
public enum AAPFrame: Sendable, Equatable {
    case handshake(AAPHandshake)
    case envelope(AgentEnvelope)
    case decision(AgentDecision)
    case actuate(ActuateFrame)
    case unknown

    /// Classifies one raw NDJSON line by peeking at its top-level keys, then
    /// decoding the matching type. Never throws.
    public static func classify(line: Data) -> AAPFrame {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return .unknown
        }
        if object["aap"] != nil, let value = try? JSONDecoder().decode(AAPHandshake.self, from: line) {
            return .handshake(value)
        }
        if object["actuate"] != nil, let value = try? JSONDecoder().decode(ActuateFrame.self, from: line) {
            return .actuate(value)
        }
        if object["verdict"] != nil, let value = try? JSONDecoder().decode(AgentDecision.self, from: line) {
            return .decision(value)
        }
        if object["event"] != nil, let value = try? JSONDecoder().decode(AgentEnvelope.self, from: line) {
            return .envelope(value)
        }
        return .unknown
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

/// Parsing/clamping for the blocking-gate timeout (`NOTCHIDE_HOOK_TIMEOUT_MS`).
///
/// The PreToolUse gate blocks a real agent, so its timeout must be derived from
/// untrusted environment input without any chance of hanging unbounded or
/// crashing: NaN/inf, negative, non-numeric, or absurdly large values all fall
/// back to a safe default rather than propagating into the wait.
public enum HookTimeout {
    /// Default blocking-gate timeout: 10 minutes (a human may take a while to
    /// answer a permission prompt).
    public static let defaultMilliseconds = 600_000
    /// Upper clamp: 1 hour. Anything larger is clamped to this.
    public static let maxMilliseconds = 3_600_000

    /// Strictly parses a `NOTCHIDE_HOOK_TIMEOUT_MS` override into a finite,
    /// non-negative integer number of milliseconds, clamped to
    /// `0...maxMilliseconds`.
    ///
    /// Any invalid input — nil, empty, non-integer (including `"1.5"`,
    /// `"1e3"`, `"nan"`, `"inf"`), negative, or beyond `Int`'s range — yields
    /// `defaultMilliseconds`. The result can therefore never be NaN/inf,
    /// negative, or unbounded, which is what keeps the fail-open timeout path
    /// safe.
    public static func milliseconds(from raw: String?) -> Int {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty,
              let value = Int(trimmed),
              value >= 0 else {
            return defaultMilliseconds
        }
        return min(value, maxMilliseconds)
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

    /// The canonical agent socket path:
    /// `~/Library/Application Support/notchide/agent.sock`
    public static var socketPath: String {
        supportDirectory.appendingPathComponent("agent.sock").path
    }

    /// The legacy socket name (`hook.sock`) from before the AAP generalization.
    /// Kept as an alias for back-compat: the app may additionally listen here so
    /// an older adapter that still targets the old path keeps working.
    public static var legacySocketPath: String {
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
