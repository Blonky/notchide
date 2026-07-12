import Foundation

/// The Claude Code vendor adapter.
///
/// This is the ONE place that knows Claude Code's snake_case field names and
/// event vocabulary. It owns the translation `HookEvent -> AgentEvent`; downstream
/// (SessionStore, Suppressor, the app) sees only vendor-neutral `AgentEvent`s.
///
/// On the app side, Claude events actually arrive over the socket transport
/// (`SocketAAPProvider`); this type provides the descriptor and the translation
/// used by the `notchide-hook` reference adapter to build the events it sends.
public enum ClaudeCodeProvider {
    public static let providerID = ProviderID("sh.claude")

    /// Claude Code can observe status and gate tool calls (blocking permission).
    public static let capabilities: Set<Capability> = [.observe, .gate]

    public static var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: providerID,
            displayName: "Claude Code",
            capabilities: capabilities,
            decisionCapability: .blocking,
            glyphTints: GlyphTint.defaultTints
        )
    }

    /// The handshake this provider presents on the AAP socket.
    public static var handshake: AAPHandshake {
        AAPHandshake(providerID: providerID, capabilities: capabilities)
    }

    /// Translates a Claude hook event name into an AAP event kind.
    ///
    /// - `PreToolUse` → `.needsDecision` (blocking permission gate)
    /// - `Notification` → `.notified`
    /// - `Stop` → `.finished`
    /// - `SubagentStop` → `.progress` (a subagent finishing is progress toward
    ///   the parent turn, not the parent finishing; this also preserves the
    ///   pre-AAP "SubagentStop does not tap the user" rule)
    /// - `PostToolUse` / `UserPromptSubmit` → `.progress`
    /// - `SessionStart` → `.started`
    /// - unknown (`nil`) → `.errored`
    public static func kind(for name: HookEventName?) -> AgentEventKind {
        switch name {
        case .preToolUse:
            return .needsDecision
        case .notification:
            return .notified
        case .stop:
            return .finished
        case .subagentStop:
            return .progress
        case .postToolUse, .userPromptSubmit:
            return .progress
        case .sessionStart:
            return .started
        case .none:
            return .errored
        }
    }

    /// Builds an `AgentEvent` from a decoded Claude `HookEvent`.
    ///
    /// - Parameters:
    ///   - event: The decoded Claude hook payload.
    ///   - kindOverride: Forces the AAP kind (used by the adapter when the CLI's
    ///     positional/`--event` argument overrides the payload's own name).
    ///   - correlationID: The id shared by the `DecisionRequest`, the
    ///     `AgentEnvelope`, and the eventual `AgentDecision`.
    ///   - at: Event timestamp.
    public static func agentEvent(
        from event: HookEvent,
        kindOverride: AgentEventKind? = nil,
        correlationID: UUID = UUID(),
        at: Date = Date()
    ) -> AgentEvent {
        let resolvedKind = kindOverride ?? kind(for: event.hookEventName)
        let sessionKey = SessionKey(
            provider: providerID,
            agentSessionID: event.sessionId,
            cwd: event.cwd
        )
        let command = event.commandDescription
        let title = event.message ?? event.lastAssistantMessage
        let decision: DecisionRequest? = resolvedKind == .needsDecision
            ? DecisionRequest(id: correlationID, prompt: command ?? event.toolName ?? "permission requested")
            : nil

        return AgentEvent(
            providerID: providerID,
            sessionKey: sessionKey,
            kind: resolvedKind,
            cwd: event.cwd.isEmpty ? nil : event.cwd,
            title: title,
            command: command,
            decision: decision,
            payload: .object(event.dictionaryRepresentation()),
            at: at
        )
    }
}
