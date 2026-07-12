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
    public init(
        socketPath: String = NotchidePaths.socketPath,
        descriptor: ProviderDescriptor = SocketAAPProvider.defaultDescriptor,
        onProviderAnnounced: (@Sendable (ProviderID, DecisionCapability) async -> Void)? = nil
    ) {
        self.descriptor = descriptor
        self.onProviderAnnounced = onProviderAnnounced
        var continuation: AsyncStream<AgentEvent>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.streamContinuation = continuation

        self.server = UnixSocketServer(
            socketPath: socketPath,
            onHandshake: { [weak self] handshake in
                await self?.announce(handshake)
            },
            handler: { [weak self] envelope, capabilities in
                await self?.handle(envelope, capabilities: capabilities) ?? nil
            }
        )
    }

    public static let defaultDescriptor = ProviderDescriptor(
        id: SocketAAPProvider.providerID,
        displayName: "AAP Socket",
        capabilities: [.observe, .gate],
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
        return await withCheckedContinuation { (continuation: CheckedContinuation<AgentDecision?, Never>) in
            storePending(envelope.id, continuation)
        }
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
