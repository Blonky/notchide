import Foundation

// AAP — the Agent Adapter Protocol ("LSP/DAP for agents").
//
// These are the vendor-neutral core value types. Any agent — Claude Code today,
// something else tomorrow — feeds the SAME lane/glyph/console model by emitting
// `AgentEvent`s tagged with a `ProviderID`. Nothing in this file knows about
// Claude Code; that knowledge lives entirely in `ClaudeCodeProvider`.

/// Stable identity of an agent provider, e.g. `"sh.claude"`.
///
/// Encodes on the wire as a bare JSON string (`"sh.claude"`), not an object.
public struct ProviderID: Hashable, Sendable, Codable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }

    public init(from decoder: Decoder) throws {
        self.raw = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// Identifies a single session lane, namespaced by provider.
///
/// Replaces the old bare-`String` session key. Enrichment providers merge on the
/// full tuple `(provider, agentSessionID, cwd)`, so two providers reporting the
/// same `agentSessionID` never cross-wire into one lane.
public struct SessionKey: Hashable, Sendable {
    public let provider: ProviderID
    public let agentSessionID: String
    public let cwd: String

    public init(provider: ProviderID, agentSessionID: String, cwd: String) {
        self.provider = provider
        self.agentSessionID = agentSessionID
        self.cwd = cwd
    }
}

/// What a provider is able to do. Advertised in the AAP handshake.
///
/// - `observe`: report status/progress (read-only).
/// - `gate`: block the agent awaiting a permission decision.
/// - `actuate`: accept actions back (resume/answer).
public enum Capability: String, Sendable, Codable, CaseIterable {
    case observe
    case gate
    case actuate
}

/// Whether a provider's decisions may seize the user.
///
/// Only `.blocking` may reach the `needsYou` lane state or show decision buttons;
/// a `.notifyOnly` provider is STRUCTURALLY unable to escalate to `needsYou`
/// (enforced in `SessionStore` and `Suppressor`). Derived from the handshake:
/// a provider that advertises `.gate` is `.blocking`, otherwise `.notifyOnly`.
public enum DecisionCapability: Sendable, Codable, Equatable {
    case blocking
    case notifyOnly

    /// The decision capability implied by a handshake's capability set.
    public init(capabilities: Set<Capability>) {
        self = capabilities.contains(.gate) ? .blocking : .notifyOnly
    }
}

/// The kind of an agent event. Maps onto the four fixed lane states.
///
/// A provider translates its own vendor events into these; downstream code never
/// sees vendor event names.
public enum AgentEventKind: String, Sendable, Codable, CaseIterable {
    case started
    case progress
    case needsDecision
    case notified
    case finished
    case errored
}

/// A provider's mapping into the FIXED four-state glyph palette.
///
/// Providers map their event kinds into these four tints; they do not invent
/// their own colors. Mirrors `LaneState` one-to-one.
public enum GlyphTint: String, Sendable, Codable, Equatable {
    case flowing
    case needsYou
    case done
    case error

    public init(_ state: LaneState) {
        switch state {
        case .flowing: self = .flowing
        case .needsYou: self = .needsYou
        case .done: self = .done
        case .error: self = .error
        }
    }

    /// The default kind→tint mapping (identical to the kind→state classifier).
    public static let defaultTints: [AgentEventKind: GlyphTint] = [
        .started: .flowing,
        .progress: .flowing,
        .needsDecision: .needsYou,
        .notified: .needsYou,
        .finished: .done,
        .errored: .error,
    ]
}
