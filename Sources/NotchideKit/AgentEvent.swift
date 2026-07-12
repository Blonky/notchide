import Foundation

/// A verdict on a blocking permission decision. Reused across the whole stack:
/// the AAP `AgentDecision` on the wire, and Claude Code's `HookDecision` output.
///
/// `"allow"` approves, `"deny"` blocks, `"ask"` escalates to the agent's own
/// permission prompt. (Emitting no decision at all is how the fail-open path
/// expresses "defer", so there is no `defer` case here.)
public enum PermissionDecision: String, Codable, Sendable {
    case allow
    case deny
    case ask
}

/// A request for a blocking decision, carried on a `.needsDecision` event.
///
/// `id` correlates the request with the eventual `AgentDecision` reply.
public struct DecisionRequest: Sendable, Codable, Equatable {
    public let id: UUID
    public let prompt: String

    public init(id: UUID = UUID(), prompt: String) {
        self.id = id
        self.prompt = prompt
    }
}

/// A single vendor-neutral agent event — the one currency the lane/glyph/console
/// model consumes.
///
/// Decoding is deliberately lenient (mirrors `HookEvent`): it never throws on
/// unknown or missing fields, so a newer/odd provider frame degrades gracefully
/// instead of breaking the fan-in. The original vendor payload is preserved
/// losslessly in `payload`.
///
/// Invariant (produced by providers, not enforced by the decoder): `decision` is
/// non-nil iff `kind == .needsDecision`.
public struct AgentEvent: Sendable, Codable, Equatable {
    public let providerID: ProviderID
    public let sessionKey: SessionKey
    public let kind: AgentEventKind
    /// Working directory hint (mirrors `sessionKey.cwd`); `nil` when unknown.
    public let cwd: String?
    public let title: String?
    public let command: String?
    public let decision: DecisionRequest?
    /// The full original vendor payload, preserved for lossless round-tripping.
    public let payload: JSONValue
    public let at: Date

    public init(
        providerID: ProviderID,
        sessionKey: SessionKey,
        kind: AgentEventKind,
        cwd: String? = nil,
        title: String? = nil,
        command: String? = nil,
        decision: DecisionRequest? = nil,
        payload: JSONValue = .object([:]),
        at: Date = Date()
    ) {
        self.providerID = providerID
        self.sessionKey = sessionKey
        self.kind = kind
        self.cwd = cwd ?? (sessionKey.cwd.isEmpty ? nil : sessionKey.cwd)
        self.title = title
        self.command = command
        self.decision = decision
        self.payload = payload
        self.at = at
    }

    // MARK: - Lenient Codable (flat wire shape; never throws on odd input)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Decoding as an object never throws on unknown/extra fields; a non-object
        // payload degrades to an empty event.
        let dict = (try? container.decode([String: JSONValue].self)) ?? [:]

        let provider = ProviderID(dict["providerID"]?.stringValue ?? "")
        let agentSessionID = dict["agentSessionID"]?.stringValue ?? ""
        let cwd = dict["cwd"]?.stringValue ?? ""

        self.providerID = provider
        self.sessionKey = SessionKey(provider: provider, agentSessionID: agentSessionID, cwd: cwd)
        // Unknown/absent kind degrades to `.errored` (an unclassifiable event).
        self.kind = AgentEventKind(rawValue: dict["kind"]?.stringValue ?? "") ?? .errored
        self.cwd = cwd.isEmpty ? nil : cwd
        self.title = dict["title"]?.stringValue
        self.command = dict["command"]?.stringValue

        if case .object(let obj)? = dict["decision"],
           let idString = obj["id"]?.stringValue,
           let uuid = UUID(uuidString: idString) {
            self.decision = DecisionRequest(id: uuid, prompt: obj["prompt"]?.stringValue ?? "")
        } else {
            self.decision = nil
        }

        self.payload = dict["payload"] ?? .object([:])
        if let seconds = dict["at"]?.doubleValue {
            self.at = Date(timeIntervalSince1970: seconds)
        } else {
            self.at = Date(timeIntervalSince1970: 0)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var dict: [String: JSONValue] = [:]
        dict["providerID"] = .string(providerID.raw)
        dict["agentSessionID"] = .string(sessionKey.agentSessionID)
        dict["cwd"] = .string(sessionKey.cwd)
        dict["kind"] = .string(kind.rawValue)
        if let title { dict["title"] = .string(title) }
        if let command { dict["command"] = .string(command) }
        if let decision {
            dict["decision"] = .object([
                "id": .string(decision.id.uuidString),
                "prompt": .string(decision.prompt),
            ])
        }
        dict["payload"] = payload
        dict["at"] = .number(at.timeIntervalSince1970)

        var container = encoder.singleValueContainer()
        try container.encode(dict)
    }
}

/// The decision frame sent back to a blocking (`gate`) provider.
///
/// `id` correlates with the originating `AgentEnvelope`/`DecisionRequest`.
/// `redirect` is an app-level concept (steer the agent elsewhere) and is never
/// leaked into a vendor's own decision output.
public struct AgentDecision: Sendable, Codable, Equatable {
    public let id: UUID
    public let verdict: PermissionDecision
    public let reason: String?
    public let redirect: String?

    public init(id: UUID, verdict: PermissionDecision, reason: String? = nil, redirect: String? = nil) {
        self.id = id
        self.verdict = verdict
        self.reason = reason
        self.redirect = redirect
    }
}

/// A minimal action a caller can push back to a provider via `actuate`.
///
/// Deliberately small for now; `actuate` has a no-op default so providers that
/// only observe/gate need not implement it.
public enum AgentAction: Sendable, Equatable {
    /// Resume a paused/blocked session.
    case resume(SessionKey)
    /// Send free-text back to the agent (e.g. answer a prompt).
    case answer(SessionKey, String)
}
