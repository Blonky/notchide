import Foundation

/// The coarse state of a session lane, as surfaced on the notch.
public enum LaneState: Sendable, Equatable {
    /// The agent is working; nothing needed from the user.
    case flowing
    /// The agent is blocked and needs the user (permission gate, notification).
    case needsYou
    /// The turn finished.
    case done
    /// An event could not be classified (unknown / undecodable event).
    case error
}

/// A single tracked session ("lane"), owned by exactly one provider.
public struct Lane: Sendable, Equatable, Identifiable {
    public var id: SessionKey
    /// The provider that owns this lane.
    public var providerID: ProviderID
    /// Whether this provider's decisions may seize the user. Drives whether the
    /// lane can show decision buttons.
    public var decisionCapability: DecisionCapability
    public var cwd: String
    public var state: LaneState
    /// The kind of the most recent event (raw value).
    public var lastEvent: String
    /// Human-readable command from the most recent tool invocation, if any.
    public var lastCommand: String?
    /// A pending blocking decision, present only when this lane is awaiting one
    /// from a `.blocking` provider.
    public var pendingDecision: DecisionRequest?
    public var updatedAt: Date

    public init(
        id: SessionKey,
        providerID: ProviderID,
        decisionCapability: DecisionCapability,
        cwd: String,
        state: LaneState,
        lastEvent: String,
        lastCommand: String?,
        pendingDecision: DecisionRequest? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.providerID = providerID
        self.decisionCapability = decisionCapability
        self.cwd = cwd
        self.state = state
        self.lastEvent = lastEvent
        self.lastCommand = lastCommand
        self.pendingDecision = pendingDecision
        self.updatedAt = updatedAt
    }

    /// Whether the app should render allow/deny/ask decision buttons: only a
    /// `.blocking` provider, in the `needsYou` state, with a pending decision.
    public var showsDecisionButtons: Bool {
        decisionCapability == .blocking && state == .needsYou && pendingDecision != nil
    }
}

/// UI-agnostic store of session lanes.
///
/// An `actor` so it is safe to feed from many concurrent providers. UI layers
/// observe lane snapshots via `snapshots()` (an `AsyncStream`). The classifier is
/// a trivial `AgentEventKind -> LaneState` map with NO vendor knowledge; per-
/// provider `DecisionCapability` is looked up from the registered descriptors.
public actor SessionStore {
    private var lanes: [SessionKey: Lane] = [:]
    private var decisionCapabilities: [ProviderID: DecisionCapability] = [:]
    private var observers: [UUID: AsyncStream<[Lane]>.Continuation] = [:]
    private let now: @Sendable () -> Date

    /// - Parameter now: Injectable clock for deterministic tests.
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Records a provider's decision capability so its lanes are classified
    /// correctly. Unknown providers default to `.blocking` (the safe default that
    /// preserves the ability to reach `needsYou`).
    public func register(_ providerID: ProviderID, decisionCapability: DecisionCapability) {
        decisionCapabilities[providerID] = decisionCapability
    }

    /// The recorded decision capability for a provider (default `.blocking`).
    public func decisionCapability(for providerID: ProviderID) -> DecisionCapability {
        decisionCapabilities[providerID] ?? .blocking
    }

    /// Ingests an agent event, updating (or creating) the corresponding lane, and
    /// returns the lane's new state.
    @discardableResult
    public func ingest(_ event: AgentEvent) -> LaneState {
        let key = event.sessionKey
        let capability = decisionCapability(for: event.providerID)
        let state = SessionStore.laneState(for: event.kind, decisionCapability: capability)
        let command = event.command
        let timestamp = now()
        // A pending decision is retained only for a real blocking gate.
        let pending: DecisionRequest? =
            (state == .needsYou && event.kind == .needsDecision && capability == .blocking)
            ? event.decision : nil

        var lane = lanes[key] ?? Lane(
            id: key,
            providerID: event.providerID,
            decisionCapability: capability,
            cwd: event.sessionKey.cwd,
            state: state,
            lastEvent: event.kind.rawValue,
            lastCommand: command,
            pendingDecision: pending,
            updatedAt: timestamp
        )
        lane.providerID = event.providerID
        lane.decisionCapability = capability
        if !event.sessionKey.cwd.isEmpty { lane.cwd = event.sessionKey.cwd }
        lane.state = state
        lane.lastEvent = event.kind.rawValue
        if let command { lane.lastCommand = command }
        lane.pendingDecision = pending
        lane.updatedAt = timestamp
        lanes[key] = lane

        broadcast()
        return state
    }

    /// The base `AgentEventKind -> LaneState` classifier (no capability). Fixed,
    /// vendor-agnostic.
    public static func baseState(for kind: AgentEventKind) -> LaneState {
        switch kind {
        case .started, .progress:
            return .flowing
        case .needsDecision, .notified:
            return .needsYou
        case .finished:
            return .done
        case .errored:
            return .error
        }
    }

    /// The classifier with capability enforcement: a `.notifyOnly` provider is
    /// STRUCTURALLY unable to reach `needsYou`, so any `needsYou`-producing kind
    /// is clamped to `flowing`.
    public static func laneState(for kind: AgentEventKind, decisionCapability: DecisionCapability) -> LaneState {
        let base = baseState(for: kind)
        if decisionCapability == .notifyOnly, base == .needsYou {
            return .flowing
        }
        return base
    }

    /// A snapshot of all lanes, most-recently-updated first.
    public func currentLanes() -> [Lane] {
        lanes.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The single most pressing lane, or `nil` if there are none.
    ///
    /// Priority: `needsYou` > `error` > `done` > `flowing`; ties broken by most
    /// recent update.
    public func mostUrgent() -> Lane? {
        lanes.values.max { a, b in
            let ra = SessionStore.urgencyRank(a.state)
            let rb = SessionStore.urgencyRank(b.state)
            if ra != rb { return ra < rb }
            return a.updatedAt < b.updatedAt
        }
    }

    private static func urgencyRank(_ state: LaneState) -> Int {
        switch state {
        case .needsYou: return 3
        case .error: return 2
        case .done: return 1
        case .flowing: return 0
        }
    }

    /// An `AsyncStream` of lane snapshots. Yields the current snapshot
    /// immediately, then a fresh snapshot on every `ingest`.
    public func snapshots() -> AsyncStream<[Lane]> {
        AsyncStream { continuation in
            let id = UUID()
            observers[id] = continuation
            continuation.yield(currentLanes())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func broadcast() {
        let snapshot = currentLanes()
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }
}
