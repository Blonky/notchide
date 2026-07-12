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

    public let socketPath: String
    private let handler: Handler
    private let onHandshake: HandshakeObserver?

    private let lock = NSLock()
    private var running = false
    private var listenFD: Int32 = -1

    /// - Parameters:
    ///   - socketPath: Filesystem path to bind. Overridable for tests.
    ///   - onHandshake: Optional callback invoked with each connection's
    ///     validated handshake (used to register the provider's capabilities).
    ///   - handler: Async handler invoked for every received envelope.
    public init(
        socketPath: String = NotchidePaths.socketPath,
        onHandshake: HandshakeObserver? = nil,
        handler: @escaping Handler
    ) {
        self.socketPath = socketPath
        self.onHandshake = onHandshake
        self.handler = handler
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

            // Each connection gets its own thread so a slow handler (e.g. a
            // human deciding a permission gate) cannot block other connections.
            let connectionHandler = handler
            let connectionHandshake = onHandshake
            Thread.detachNewThread {
                UnixSocketServer.handleConnection(
                    fd: clientFD, handler: connectionHandler, onHandshake: connectionHandshake)
            }
        }
    }

    private static func handleConnection(
        fd: Int32,
        handler: @escaping Handler,
        onHandshake: HandshakeObserver?
    ) {
        defer { close(fd) }
        let reader = FDLineReader(fd: fd)

        // ── AAP handshake: the first line MUST be a supported handshake ────────
        // An absent, malformed, or wrong-version handshake closes the connection
        // (the client then sees EOF and falls open). An `AgentEnvelope` frame has
        // no `aap` field, so it can never be mistaken for a valid handshake.
        let firstLine = reader.nextLine()
        guard case .line(let handshakeBytes) = firstLine,
              let handshake = try? JSONDecoder().decode(AAPHandshake.self, from: Data(handshakeBytes)),
              handshake.isSupportedVersion else {
            return
        }
        if let onHandshake {
            runBlocking { await onHandshake(handshake) }
        }
        let capabilities = handshake.capabilities

        loop: while true {
            switch reader.nextLine() {
            case .closed, .timedOut:
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
                let decision = runBlocking { await handler(envelope, capabilities) }
                if decisionAllowed, let decision, let frame = try? NDJSON.encode(decision) {
                    writeAllBytes(fd: fd, Array(frame))
                }
            }
        }
    }
}
