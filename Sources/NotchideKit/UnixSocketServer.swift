import Foundation
import Darwin

/// A Unix-domain-socket server built on low-level POSIX (`socket`/`bind`/
/// `listen`/`accept`).
///
/// It listens on a filesystem socket path and accepts connections. Each
/// connection begins with an AAP handshake (`AAPHandshake`); the server validates
/// the version and records the advertised capabilities. Subsequent lines are
/// `AgentEnvelope`s handed to an injected async handler. If the handler returns
/// an `AgentDecision`, the envelope requested a decision (`wantsDecision`), AND
/// the provider advertised `gate`, the decision is written back on the same
/// connection.
///
/// Concurrency model: the accept loop and each connection run on their own
/// dedicated `Thread`s using blocking POSIX I/O (never on the Swift cooperative
/// pool). The injected async handler is invoked via `runBlocking`, so a handler
/// that legitimately blocks for minutes (a human deciding on a permission gate)
/// only ties up that one connection thread, not the whole server.
public final class UnixSocketServer: @unchecked Sendable {
    /// Invoked for every received envelope, given the connection's negotiated
    /// capabilities. Return an `AgentDecision` to answer a blocking (`gate` +
    /// `wantsDecision`) client; return `nil` to send nothing back.
    public typealias Handler = @Sendable (_ envelope: AgentEnvelope, _ capabilities: Set<Capability>) async -> AgentDecision?
    /// Invoked once per connection with its validated handshake, before any
    /// envelopes are processed.
    public typealias HandshakeObserver = @Sendable (_ handshake: AAPHandshake) async -> Void
    /// Invoked when an in-flight decision is ABANDONED because the peer closed
    /// the connection before the handler answered (rail 1). Gives the app the
    /// hook it needs to clear the wedged lane (e.g. `SessionStore.abandonGate`).
    /// No decision frame is written for an abandoned request.
    public typealias AbandonObserver = @Sendable (_ envelope: AgentEnvelope) async -> Void

    /// The default cap on concurrent connection handlers.
    public static let defaultMaxConnections = 32
    /// The default hard cap on a single NDJSON line (1 MiB).
    public static let defaultMaxLineBytes = 1 << 20

    public let socketPath: String
    private let handler: Handler
    private let onHandshake: HandshakeObserver?
    private let onAbandon: AbandonObserver?
    private let maxLineBytes: Int

    /// Bounds the number of connection handlers running at once (rail 2). A slot
    /// is taken before a connection thread is spawned and released when it ends;
    /// a connection that arrives at capacity is accepted-then-immediately-closed
    /// so the fail-open adapter treats it as "proceed".
    private let connectionSlots: DispatchSemaphore

    /// Live actuate-capable connections, so the server can PUSH `ActuateFrame`s
    /// back to a specific provider's connection (the duplex direction).
    private let actuateRegistry: ActuateRegistry

    private let lock = NSLock()
    private var running = false
    private var listenFD: Int32 = -1

    /// - Parameters:
    ///   - socketPath: Filesystem path to bind. Overridable for tests.
    ///   - maxConnections: Cap on concurrent connection handlers (default 32).
    ///     Excess connections are accepted then immediately closed (fail-open).
    ///   - maxLineBytes: Hard cap on a single NDJSON line (default 1 MiB). A
    ///     connection sending more than the cap with no newline is dropped.
    ///   - onHandshake: Optional callback invoked with each connection's
    ///     validated handshake (used to register the provider's capabilities).
    ///   - onAbandon: Optional callback invoked when an in-flight decision is
    ///     abandoned by peer-close, so the app can clear the affected lane.
    ///   - handler: Async handler invoked for every received envelope.
    public init(
        socketPath: String = NotchidePaths.socketPath,
        maxConnections: Int = UnixSocketServer.defaultMaxConnections,
        maxLineBytes: Int = UnixSocketServer.defaultMaxLineBytes,
        onHandshake: HandshakeObserver? = nil,
        onAbandon: AbandonObserver? = nil,
        handler: @escaping Handler
    ) {
        self.socketPath = socketPath
        self.onHandshake = onHandshake
        self.onAbandon = onAbandon
        self.maxLineBytes = maxLineBytes
        self.connectionSlots = DispatchSemaphore(value: max(1, maxConnections))
        self.handler = handler
        self.actuateRegistry = ActuateRegistry()
    }

    /// Pushes an `ActuateFrame` to the live actuate-capable connection owning
    /// `providerID` (the connection that advertised `.actuate` in its handshake).
    ///
    /// Returns `true` iff the frame was written. If there is no live actuate
    /// connection for the target — never connected, disconnected, or mid-
    /// reconnect — the push is a logged no-op returning `false`; it never crashes.
    @discardableResult
    func sendActuate(_ frame: ActuateFrame, to providerID: ProviderID) -> Bool {
        actuateRegistry.send(frame, to: providerID)
    }

    /// Binds the socket and starts accepting connections on a background thread.
    /// A stale socket file at `socketPath` is removed first; the live socket is
    /// chmod'd to `0600`.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        unlink(socketPath) // remove any stale socket file

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }
        disableSIGPIPE(fd)

        var addr = try makeUnixSockaddr(path: socketPath)
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw SocketError.bind(err)
        }

        // Restrict permissions to 0600 BEFORE listen(), so the socket is never
        // reachable while world-accessible. (A client cannot connect to a bound
        // socket until listen() is called, so doing chmod first closes the
        // permissions window entirely.)
        chmod(socketPath, 0o600)

        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw SocketError.listen(err)
        }

        // Non-blocking listen fd so the accept loop can poll and observe stop().
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        listenFD = fd
        running = true

        let thread = Thread { [weak self] in
            self?.acceptLoop(listenFD: fd)
        }
        thread.name = "notchide.socket.accept"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Stops accepting connections, closes the listening socket, and removes the
    /// socket file. In-flight connection threads finish on their own.
    public func stop() {
        lock.lock()
        let fd = listenFD
        running = false
        listenFD = -1
        lock.unlock()

        if fd >= 0 { close(fd) }
        unlink(socketPath)
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func acceptLoop(listenFD fd: Int32) {
        while isRunning() {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 100) // 100ms tick lets us observe stop()
            if pr < 0 {
                let err = errno
                if err == EINTR { continue }
                // Only a stop() teardown should end the loop; any other poll
                // error is treated as transient so the server is never
                // permanently disabled. Back off briefly to avoid a hot spin.
                if !isRunning() { break }
                usleep(50_000) // 50ms
                continue
            }
            if pr == 0 { continue } // timeout: re-check running
            if (pfd.revents & Int16(POLLIN)) == 0 { continue }

            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                let err = errno
                if err == EINTR || err == EAGAIN || err == EWOULDBLOCK { continue }
                // The listen fd being torn down by stop() is the ONLY reason to
                // exit. Every other accept() error — EMFILE/ENFILE (fd
                // exhaustion), ECONNABORTED, etc. — is transient and must never
                // permanently kill the server; back off on resource exhaustion
                // and keep accepting.
                if !isRunning() { break }
                if err == EMFILE || err == ENFILE { usleep(50_000) } // 50ms
                continue
            }
            disableSIGPIPE(clientFD)
            // The accepted socket can inherit O_NONBLOCK from the listening
            // socket; force blocking mode so the connection uses blocking reads.
            let clientFlags = fcntl(clientFD, F_GETFL, 0)
            _ = fcntl(clientFD, F_SETFL, clientFlags & ~O_NONBLOCK)

            // Bounded concurrency (rail 2): try to claim a handler slot without
            // blocking the accept loop. At capacity, close the connection
            // immediately — the fail-open adapter sees EOF and proceeds — so a
            // burst of connections can never exhaust threads/fds.
            if connectionSlots.wait(timeout: .now()) == .timedOut {
                close(clientFD)
                continue
            }

            // Each connection gets its own thread so a slow handler (e.g. a
            // human deciding a permission gate) cannot block other connections.
            let connectionHandler = handler
            let connectionHandshake = onHandshake
            let connectionAbandon = onAbandon
            let connectionRegistry = actuateRegistry
            let connectionMaxLineBytes = maxLineBytes
            let slots = connectionSlots
            Thread.detachNewThread {
                defer { slots.signal() } // release the slot when the handler ends
                UnixSocketServer.handleConnection(
                    fd: clientFD,
                    handler: connectionHandler,
                    onHandshake: connectionHandshake,
                    onAbandon: connectionAbandon,
                    maxLineBytes: connectionMaxLineBytes,
                    registry: connectionRegistry)
            }
        }
    }

    private static func handleConnection(
        fd: Int32,
        handler: @escaping Handler,
        onHandshake: HandshakeObserver?,
        onAbandon: AbandonObserver?,
        maxLineBytes: Int,
        registry: ActuateRegistry
    ) {
        defer { close(fd) }
        // Bounded reader (rail 3): a line longer than `maxLineBytes` with no
        // newline is dropped rather than buffered without bound.
        let reader = BoundedLineReader(fd: fd, maxLineBytes: maxLineBytes)

        // ── AAP handshake: the first line MUST be a supported handshake ────────
        // An absent, malformed, oversized, or wrong-version handshake closes the
        // connection (the client then sees EOF and falls open). An
        // `AgentEnvelope` frame has no `aap` field, so it can never be mistaken
        // for a valid handshake.
        let firstLine = reader.nextLine()
        guard case .line(let handshakeBytes) = firstLine,
              let handshake = try? JSONDecoder().decode(AAPHandshake.self, from: Data(handshakeBytes)),
              handshake.isSupportedVersion else {
            return
        }
        let capabilities = handshake.capabilities

        // ── Duplex registration ────────────────────────────────────────────────
        // A connection that advertises `.actuate` is kept alive by the reader
        // loop below AND registered as a writer so the server can push
        // `ActuateFrame`s to it. Registration happens BEFORE the handshake
        // observer fires, so an observer that immediately actuates finds the
        // connection live. The `deregister` defer runs before `close(fd)`
        // (defers are LIFO), marking the connection closed while the fd is still
        // valid — so no push can race the close.
        let actuateConnection: ActuateConnection?
        if capabilities.contains(.actuate) {
            let connection = ActuateConnection(providerID: handshake.providerID, fd: fd)
            registry.register(connection)
            actuateConnection = connection
        } else {
            actuateConnection = nil
        }
        defer {
            if let actuateConnection { registry.deregister(actuateConnection) }
        }

        if let onHandshake {
            runBlocking { await onHandshake(handshake) }
        }

        loop: while true {
            switch reader.nextLine() {
            case .closed, .timedOut, .overflow:
                // `.overflow` (rail 3): an oversized line drops the connection,
                // identically to EOF — never buffered, never a crash.
                break loop
            case .line(let bytes):
                if bytes.isEmpty { continue }
                guard let envelope = try? JSONDecoder().decode(AgentEnvelope.self, from: Data(bytes)) else {
                    continue // skip malformed frame, keep the connection open
                }
                // A decision reply is only ever written to a provider that
                // asked for one AND advertised `gate`; escalation from a
                // non-gate provider is ignored.
                let decisionAllowed = envelope.wantsDecision && capabilities.contains(.gate)
                if decisionAllowed {
                    // Rail 1: run the (possibly long-parked) decision while
                    // watching the fd for peer-close. If the peer disconnects
                    // first, the request is abandoned deterministically — no
                    // frame is written and the app is notified so it can clear
                    // the lane — instead of leaking a parked continuation.
                    switch awaitDecisionOrAbandon(
                        fd: fd, envelope: envelope,
                        capabilities: capabilities, handler: handler
                    ) {
                    case .decided(let decision):
                        if let decision, let frame = try? NDJSON.encode(decision) {
                            // On an actuate-capable connection, route the
                            // decision writeback through the same serialized
                            // writer used by pushes, so a concurrent actuate
                            // push cannot interleave with the decision on the
                            // shared fd. On a gate-only connection there is no
                            // second writer, so write directly.
                            if let actuateConnection {
                                actuateConnection.write(Array(frame))
                            } else {
                                writeAllBytes(fd: fd, Array(frame))
                            }
                        }
                    case .abandoned:
                        if let onAbandon {
                            runBlocking { await onAbandon(envelope) }
                        }
                        break loop // the peer is gone; end the connection
                    }
                } else {
                    // Fire-and-forget (observe/notify): drive the handler for
                    // its side effects but never write a decision back.
                    _ = runBlocking { await handler(envelope, capabilities) }
                }
            }
        }
    }

    /// Outcome of racing a decision handler against peer-close.
    private enum DecisionOutcome {
        /// The handler produced a verdict (possibly `nil`) before the peer left.
        case decided(AgentDecision?)
        /// The peer closed the connection before the handler answered.
        case abandoned
    }

    /// Runs `handler` on a cancellable task while this (blocking) connection
    /// thread polls `fd` for peer-close. Returns `.decided` if the handler
    /// answers first, or `.abandoned` if the peer disconnects while the decision
    /// is still pending.
    ///
    /// Only the connection thread ever reads `fd` here (the handler task is
    /// handed the envelope, not the fd), so there is no concurrent reader; once
    /// this returns, the caller resumes owning the fd exclusively.
    private static func awaitDecisionOrAbandon(
        fd: Int32,
        envelope: AgentEnvelope,
        capabilities: Set<Capability>,
        handler: @escaping Handler
    ) -> DecisionOutcome {
        let state = PendingDecision()
        let task = Task.detached {
            let decision = await handler(envelope, capabilities)
            state.complete(decision)
        }

        while true {
            // A ready decision always wins the race: deliver it even if the peer
            // also just left (a write to a gone peer fails harmlessly).
            if let decision = state.takeIfComplete() {
                return .decided(decision)
            }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 20) // 20ms tick: re-check completion + close
            if pr < 0 {
                if errno == EINTR { continue }
                // Cannot poll for close; fall back to simply awaiting the
                // decision so we neither spin nor abandon a live request.
                return .decided(state.waitForCompletion())
            }
            if pr == 0 { continue } // timeout: loop re-checks completion

            let revents = pfd.revents
            if (revents & (Int16(POLLHUP) | Int16(POLLERR) | Int16(POLLNVAL))) != 0 {
                task.cancel()
                return .abandoned
            }
            if (revents & Int16(POLLIN)) != 0 {
                // Readable during a pending decision means either EOF (peer
                // closed) or unexpected pipelined data. Peek without consuming:
                // a 0/Error peek is a clean close → abandon; stray data is
                // ignored (the decision, when it lands, still wins).
                var probe: UInt8 = 0
                let n = recv(fd, &probe, 1, Int32(MSG_PEEK))
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    task.cancel()
                    return .abandoned
                }
                // Stray data: brief nap so a flooding peer cannot hot-spin us.
                usleep(20_000)
            }
        }
    }
}

/// Thread-safe one-shot box holding a decision handler's result.
///
/// The handler task calls `complete`; the connection thread polls `takeIfComplete`.
/// A double optional distinguishes "not done yet" (`nil`) from "done with a
/// (possibly `nil`) decision" (`.some`).
private final class PendingDecision: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var completed = false
    private var decision: AgentDecision?

    func complete(_ decision: AgentDecision?) {
        lock.lock()
        if !completed {
            completed = true
            self.decision = decision
            done.signal()
        }
        lock.unlock()
    }

    /// Returns `.some(decision)` once completed, else `nil`.
    func takeIfComplete() -> AgentDecision?? {
        lock.lock()
        defer { lock.unlock() }
        return completed ? .some(decision) : nil
    }

    /// Blocks until the handler completes, then returns its decision. Used only
    /// on the poll-failure fallback path.
    func waitForCompletion() -> AgentDecision? {
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        return decision
    }
}
