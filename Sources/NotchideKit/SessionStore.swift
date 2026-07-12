import Foundation

/// Identifies a session lane. Currently the Claude Code `session_id`.
public typealias SessionKey = String

/// The coarse state of a session lane, as surfaced on the notch.
public enum LaneState: Sendable, Equatable {
    /// The agent is working; nothing needed from the user.
    case flowing
    /// The agent is blocked and needs the user (permission gate, notification, stop-with-question).
    case needsYou
    /// The turn finished (Stop / SubagentStop).
    case done
    /// An event could not be classified (unknown / undecodable event).
    case error
}

/// A single tracked Claude Code session ("lane").
public struct Lane: Sendable, Equatable, Identifiable {
    public var id: SessionKey
    public var cwd: String
    public var state: LaneState
    /// The raw name of the most recent hook event.
    public var lastEvent: String
    /// Human-readable command from the most recent tool invocation, if any.
    public var lastCommand: String?
    public var updatedAt: Date

    public init(
        id: SessionKey,
        cwd: String,
        state: LaneState,
        lastEvent: String,
        lastCommand: String?,
        updatedAt: Date
    ) {
        self.id = id
        self.cwd = cwd
        self.state = state
        self.lastEvent = lastEvent
        self.lastCommand = lastCommand
        self.updatedAt = updatedAt
    }
}

/// UI-agnostic store of session lanes.
///
/// An `actor` so it is safe to feed from many concurrent hook connections. UI
/// layers observe lane snapshots via `snapshots()` (an `AsyncStream`).
public actor SessionStore {
    private var lanes: [SessionKey: Lane] = [:]
    private var observers: [UUID: AsyncStream<[Lane]>.Continuation] = [:]
    private let now: @Sendable () -> Date

    /// - Parameter now: Injectable clock for deterministic tests.
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Ingests a hook event, updating (or creating) the corresponding lane, and
    /// returns the lane's new state.
    ///
    /// Mapping: PreToolUse / Notification → `needsYou`; Stop / SubagentStop →
    /// `done`; PostToolUse / UserPromptSubmit / SessionStart → `flowing`; an
    /// unclassifiable event (unknown `hook_event_name`) → `error`.
    @discardableResult
    public func ingest(_ event: HookEvent) -> LaneState {
        let key = event.sessionId
        let state = SessionStore.state(for: event)
        let command = event.commandDescription
        let timestamp = now()

        var lane = lanes[key] ?? Lane(
            id: key,
            cwd: event.cwd,
            state: state,
            lastEvent: event.rawHookEventName,
            lastCommand: command,
            updatedAt: timestamp
        )
        if !event.cwd.isEmpty { lane.cwd = event.cwd }
        lane.state = state
        lane.lastEvent = event.rawHookEventName
        if let command { lane.lastCommand = command }
        lane.updatedAt = timestamp
        lanes[key] = lane

        broadcast()
        return state
    }

    /// Classifies a hook event into a lane state.
    public static func state(for event: HookEvent) -> LaneState {
        switch event.hookEventName {
        case .preToolUse, .notification:
            return .needsYou
        case .stop, .subagentStop:
            return .done
        case .postToolUse, .userPromptSubmit, .sessionStart:
            return .flowing
        case .none:
            return .error
        }
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
