import Foundation

/// The coarse state of a session lane, as surfaced on the notch.
///
/// `String`-backed and `Codable` so a lane can be snapshotted to disk and
/// restored with a stable, human-legible wire representation.
public enum LaneState: String, Sendable, Equatable, Codable {
    /// The agent is working; nothing needed from the user.
    case flowing
    /// The agent is blocked and needs the user (permission gate, notification).
    case needsYou
    /// The turn finished.
    case done
    /// An event could not be classified (unknown / undecodable event).
    case error
}

/// The liveness of a lane relative to its configured TTL.
///
/// A lane that has not produced an event within the TTL is `.stale` — the app
/// should treat its state as no longer trustworthy (the adapter may have died
/// without a `finished`/`errored`) rather than rendering it as live.
public enum Liveness: String, Sendable, Equatable, Codable {
    /// The lane produced an event within the TTL window.
    case live
    /// The lane's newest event is older than the TTL.
    case stale
    /// No such lane is tracked.
    case unknown
}

/// A single tracked session ("lane"), owned by exactly one provider.
///
/// `Codable` so the store can snapshot lanes to disk and restore them on
/// relaunch.
public struct Lane: Sendable, Equatable, Identifiable, Codable {
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
    /// When this lane last produced an event. Drives the liveness TTL: a lane
    /// whose `lastEventAt` is older than the store's TTL is reported `.stale`.
    /// Distinct from `updatedAt`, which also advances on non-event mutations
    /// like an abandoned gate.
    public var lastEventAt: Date

    public init(
        id: SessionKey,
        providerID: ProviderID,
        decisionCapability: DecisionCapability,
        cwd: String,
        state: LaneState,
        lastEvent: String,
        lastCommand: String?,
        pendingDecision: DecisionRequest? = nil,
        updatedAt: Date,
        lastEventAt: Date? = nil
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
        self.lastEventAt = lastEventAt ?? updatedAt
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
    /// A lane with no event within this window reports `.stale`.
    private let livenessTTL: TimeInterval
    /// Where `persist()`/`restore()` read and write the lane snapshot.
    private let persistenceURL: URL

    /// The default snapshot location: `lanes.json` under the 0700 support dir.
    public static var defaultPersistenceURL: URL {
        NotchidePaths.supportDirectory.appendingPathComponent("lanes.json")
    }

    /// - Parameters:
    ///   - now: Injectable clock for deterministic tests.
    ///   - livenessTTL: How long a lane may go without an event before it is
    ///     reported `.stale` (default 90s).
    ///   - persistenceURL: Where snapshots are written. Injectable for tests;
    ///     defaults to `lanes.json` under `NotchidePaths.supportDirectory`.
    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        livenessTTL: TimeInterval = 90,
        persistenceURL: URL? = nil
    ) {
        self.now = now
        self.livenessTTL = livenessTTL
        self.persistenceURL = persistenceURL ?? SessionStore.defaultPersistenceURL
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
            updatedAt: timestamp,
            lastEventAt: timestamp
        )
        lane.providerID = event.providerID
        lane.decisionCapability = capability
        if !event.sessionKey.cwd.isEmpty { lane.cwd = event.sessionKey.cwd }
        lane.state = state
        lane.lastEvent = event.kind.rawValue
        if let command { lane.lastCommand = command }
        lane.pendingDecision = pending
        lane.updatedAt = timestamp
        lane.lastEventAt = timestamp
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

    // MARK: - Gate abandonment

    /// Abandons the in-flight gate on `key`'s lane (the app-side dual of the
    /// hook's fail-open): clears any pending decision and flips a `needsYou` lane
    /// back to `.flowing`, so a lane never wedges in `needsYou` when its gate's
    /// peer disconnected while the human was still deciding.
    ///
    /// Wire this to `UnixSocketServer`'s abandonment notification (rail 1). A
    /// no-op if `key` is untracked or was not blocked. Does NOT touch
    /// `lastEventAt`, so an abandoned gate does not falsely refresh liveness.
    ///
    /// - Returns: The lane's resulting state, or `nil` if `key` is untracked.
    @discardableResult
    public func abandonGate(for key: SessionKey) -> LaneState? {
        guard var lane = lanes[key] else { return nil }
        lane.pendingDecision = nil
        if lane.state == .needsYou {
            lane.state = .flowing
        }
        lane.updatedAt = now()
        lanes[key] = lane
        broadcast()
        return lane.state
    }

    // MARK: - Liveness / TTL

    /// The liveness of `key`'s lane: `.unknown` if untracked, `.stale` if its
    /// newest event is older than the configured TTL, else `.live`.
    public func liveness(for key: SessionKey) -> Liveness {
        guard let lane = lanes[key] else { return .unknown }
        let age = now().timeIntervalSince(lane.lastEventAt)
        return age > livenessTTL ? .stale : .live
    }

    /// Whether `key`'s lane has gone stale (no event within the TTL). `false`
    /// for an untracked lane (there is nothing live to have gone stale).
    public func isStale(for key: SessionKey) -> Bool {
        liveness(for: key) == .stale
    }

    // MARK: - Snapshot persistence

    /// Encodes the current lanes to JSON at the store's `persistenceURL`.
    ///
    /// The containing directory is created `0700` and the file itself is written
    /// `0600` (owner-only), matching the socket's permission posture. The write
    /// is atomic, so a crash mid-write never leaves a truncated snapshot.
    public func persist() throws {
        let directory = persistenceURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(currentLanes())
        try data.write(to: persistenceURL, options: .atomic)
        // `.atomic` renames a temp file into place, so re-apply owner-only perms
        // to the final file regardless of the temp's default mode.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: persistenceURL.path
        )
    }

    /// Restores lanes from the snapshot at `persistenceURL`, replacing the
    /// in-memory set and broadcasting to observers.
    ///
    /// A missing or corrupt snapshot is a safe no-op (the store simply starts
    /// empty) — a bad file on disk must never prevent the app from launching.
    public func restore() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let decoded = try? JSONDecoder().decode([Lane].self, from: data) else {
            return
        }
        var restored: [SessionKey: Lane] = [:]
        for lane in decoded { restored[lane.id] = lane }
        lanes = restored
        broadcast()
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
