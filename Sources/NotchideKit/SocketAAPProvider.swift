import Foundation

/// A concrete `AgentProvider` that wraps the Unix-socket AAP transport.
///
/// This is the app-side ingress: any AAP adapter (the `notchide-hook` reference
/// adapter today, anything else tomorrow) connects, performs the handshake, and
/// streams `AgentEnvelope`s. All the proven robustness lives inside the
/// `UnixSocketServer` it owns — 0600 perms, UUID correlation, NDJSON framing,
/// per-connection threads, the fail-open timeout on the client side — and simply
/// becomes provider-internal.
///
/// `events()` surfaces inbound frames; `resolve(_:)` writes the decision frame
/// back on the correlated open connection (the connection thread is parked in the
/// handler awaiting exactly that).
public final class SocketAAPProvider: AgentProvider, @unchecked Sendable {
    /// The transport's own id. Emitted events carry their real originating
    /// `providerID` (e.g. `sh.claude`) inside the `AgentEvent`.
    public static let providerID = ProviderID("sh.notchide.socket")

    public let descriptor: ProviderDescriptor

    private let stream: AsyncStream<AgentEvent>
    private let streamContinuation: AsyncStream<AgentEvent>.Continuation
    private let onProviderAnnounced: (@Sendable (ProviderID, DecisionCapability) async -> Void)?
    private let onGateAbandoned: (@Sendable (SessionKey) async -> Void)?

    private let lock = NSLock()
    private var pending: [UUID: CheckedContinuation<AgentDecision?, Never>] = [:]

    // Implicitly-unwrapped so the handler closure can capture `self` once all the
    // other stored properties are initialized.
    private var server: UnixSocketServer!

    /// - Parameters:
    ///   - socketPath: Path to bind (defaults to the canonical `agent.sock`).
    ///   - descriptor: The transport descriptor.
    ///   - onProviderAnnounced: Called for each connection's handshake with the
    ///     announced provider id and its derived `DecisionCapability` — wire this
    ///     to `SessionStore.register` so lanes are classified per the handshake.
    ///   - onGateAbandoned: Called with the abandoned gate's `SessionKey` when the
    ///     peer disconnects mid-decision (after the parked continuation has been
    ///     resumed with no decision) — wire this to `SessionStore.abandonGate` so
    ///     the wedged lane is cleared.
    public init(
        socketPath: String = NotchidePaths.socketPath,
        descriptor: ProviderDescriptor = SocketAAPProvider.defaultDescriptor,
        onProviderAnnounced: (@Sendable (ProviderID, DecisionCapability) async -> Void)? = nil,
        onGateAbandoned: (@Sendable (SessionKey) async -> Void)? = nil
    ) {
        self.descriptor = descriptor
        self.onProviderAnnounced = onProviderAnnounced
        self.onGateAbandoned = onGateAbandoned
        var continuation: AsyncStream<AgentEvent>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.streamContinuation = continuation

        self.server = UnixSocketServer(
            socketPath: socketPath,
            onHandshake: { [weak self] handshake in
                await self?.announce(handshake)
            },
            onAbandon: { [weak self] envelope in
                await self?.abandon(envelope)
            },
            handler: { [weak self] envelope, capabilities in
                await self?.handle(envelope, capabilities: capabilities) ?? nil
            }
        )
    }

    public static let defaultDescriptor = ProviderDescriptor(
        id: SocketAAPProvider.providerID,
        displayName: "AAP Socket",
        capabilities: [.observe, .gate, .actuate],
        decisionCapability: .blocking
    )

    /// The bound socket path.
    public var socketPath: String { server.socketPath }

    /// Binds the socket and starts accepting connections.
    public func start() throws { try server.start() }

    /// Stops the server and finishes the event stream.
    public func stop() {
        server.stop()
        streamContinuation.finish()
    }

    // MARK: - AgentProvider

    public func events() -> AsyncStream<AgentEvent> { stream }

    public func resolve(_ decision: AgentDecision) async {
        takePending(decision.id)?.resume(returning: decision)
    }

    /// Pushes an ACTUATE action to the HOST provider that owns the target
    /// session, over the live actuate-capable connection registered at handshake
    /// time.
    ///
    /// Only `.prompt` / `.interrupt` travel the actuate wire; `.resume` /
    /// `.answer` are handled elsewhere and are safe no-ops here (preserving the
    /// previous no-op behavior). If there is no live actuate connection owning
    /// the target session's provider — unknown session, or the adapter has
    /// disconnected — the push is dropped safely (a logged no-op), never a crash.
    public func actuate(_ action: AgentAction) async {
        guard let frame = SocketAAPProvider.actuateFrame(for: action) else { return }
        server.sendActuate(frame, to: action.sessionKey.provider)
    }

    /// Maps an `AgentAction` to the `ActuateFrame` pushed on the wire, or `nil`
    /// for actions that are not carried on the actuate channel.
    static func actuateFrame(for action: AgentAction) -> ActuateFrame? {
        switch action {
        case .prompt(let key, let text):
            return ActuateFrame(sessionKey: key, kind: .prompt, text: text)
        case .interrupt(let key):
            return ActuateFrame(sessionKey: key, kind: .interrupt)
        case .resume, .answer:
            return nil
        }
    }

    // MARK: - Internals

    private func announce(_ handshake: AAPHandshake) async {
        await onProviderAnnounced?(
            handshake.providerID,
            DecisionCapability(capabilities: handshake.capabilities)
        )
    }

    private func handle(_ envelope: AgentEnvelope, capabilities: Set<Capability>) async -> AgentDecision? {
        streamContinuation.yield(envelope.event)

        // Only a `gate` provider asking for a decision blocks awaiting resolve().
        guard envelope.wantsDecision, capabilities.contains(.gate) else {
            return nil
        }
        // Park until either `resolve(_:)` delivers a verdict or `abandon(_:)`
        // resumes us with `nil` because the peer disconnected mid-decision. The
        // parked continuation therefore never leaks: exactly one of those two
        // paths resumes it (see `takePending`'s remove-under-lock).
        return await withCheckedContinuation { (continuation: CheckedContinuation<AgentDecision?, Never>) in
            storePending(envelope.id, continuation)
        }
    }

    /// Abandons the in-flight decision for `envelope` because the server observed
    /// the peer close before the handler answered (`UnixSocketServer.onAbandon`).
    ///
    /// Resumes the parked continuation with `nil` — NO decision is emitted, so no
    /// frame is written and the connection thread unblocks instead of leaking a
    /// continuation or hanging. `takePending` removes the continuation under the
    /// lock, so this can never double-resume one that `resolve(_:)` also raced
    /// for: whichever call wins takes it, the loser is a safe no-op. Then it
    /// notifies the app (`onGateAbandoned`) so the wedged lane can be cleared.
    ///
    /// Ordering: the server only fires `onAbandon` for an envelope on the same
    /// (`wantsDecision` + `gate`) path that makes `handle` park, and it does so
    /// after the connection has been serving long enough to reach `poll`, so the
    /// continuation is already parked by the time this runs. The continuation is
    /// resumed synchronously up front, before the (awaited) app notification, so
    /// the parked handler unblocks promptly regardless of the callback.
    private func abandon(_ envelope: AgentEnvelope) async {
        takePending(envelope.id)?.resume(returning: nil)
        await onGateAbandoned?(envelope.event.sessionKey)
    }

    /// The number of decision continuations currently parked awaiting a verdict.
    ///
    /// Internal test seam: after a peer abandons an in-flight gate this must fall
    /// back to zero promptly — a value that stays above zero is a leaked
    /// continuation.
    var parkedDecisionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    // Synchronous lock helpers (NSLock's lock/unlock are unavailable from async
    // contexts under Swift 6 strict concurrency).
    private func storePending(_ id: UUID, _ continuation: CheckedContinuation<AgentDecision?, Never>) {
        lock.lock()
        pending[id] = continuation
        lock.unlock()
    }

    private func takePending(_ id: UUID) -> CheckedContinuation<AgentDecision?, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }
}
