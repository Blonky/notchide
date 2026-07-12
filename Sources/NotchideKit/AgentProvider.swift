import Foundation

/// Static, declarative description of a provider: who it is and what it can do.
public struct ProviderDescriptor: Sendable {
    public let id: ProviderID
    public let displayName: String
    public let capabilities: Set<Capability>
    public let decisionCapability: DecisionCapability
    /// How this provider maps its event kinds into the fixed four-state palette.
    public let glyphTints: [AgentEventKind: GlyphTint]

    public init(
        id: ProviderID,
        displayName: String,
        capabilities: Set<Capability>,
        decisionCapability: DecisionCapability,
        glyphTints: [AgentEventKind: GlyphTint] = GlyphTint.defaultTints
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.decisionCapability = decisionCapability
        self.glyphTints = glyphTints
    }
}

/// A source of `AgentEvent`s — the "LSP/DAP for agents" server interface.
///
/// A provider streams events, resolves blocking decisions, and optionally accepts
/// actions. `actuate` has a no-op default so observe/gate-only providers need not
/// implement it.
public protocol AgentProvider: Sendable {
    static var providerID: ProviderID { get }
    var descriptor: ProviderDescriptor { get }

    /// A stream of this provider's events. Consumed once, by the fan-in.
    func events() -> AsyncStream<AgentEvent>

    /// Resolve a blocking decision previously surfaced via a `.needsDecision`
    /// event. For a socket provider this writes the decision frame back on the
    /// correlated open connection.
    func resolve(_ decision: AgentDecision) async

    /// Push an action back to the agent. No-op by default.
    func actuate(_ action: AgentAction) async
}

public extension AgentProvider {
    func actuate(_ action: AgentAction) async {}
}
