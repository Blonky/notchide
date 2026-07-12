import Foundation
import Darwin

/// A Unix-domain-socket server built on low-level POSIX (`socket`/`bind`/
/// `listen`/`accept`).
///
/// It listens on a filesystem socket path, accepts connections, reads
/// newline-delimited `HookEnvelope`s, and hands each to an injected async
/// handler. If the handler returns a `DecisionMessage` and the envelope
/// requested a decision (`wantsDecision == true`), the message is written back
/// on the same connection.
///
/// Concurrency model: the accept loop and each connection run on their own
/// dedicated `Thread`s using blocking POSIX I/O (never on the Swift cooperative
/// pool). The injected async handler is invoked via `runBlocking`, so a handler
/// that legitimately blocks for minutes (a human deciding on a permission gate)
/// only ties up that one connection thread, not the whole server.
public final class UnixSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HookEnvelope) async -> DecisionMessage?

    public let socketPath: String
    private let handler: Handler

    private let lock = NSLock()
    private var running = false
    private var listenFD: Int32 = -1

    /// - Parameters:
    ///   - socketPath: Filesystem path to bind. Overridable for tests.
    ///   - handler: Async handler invoked for every received envelope. Return a
    ///     `DecisionMessage` to answer a blocking (`wantsDecision`) client;
    ///     return `nil` to send nothing back.
    public init(socketPath: String = NotchidePaths.socketPath, handler: @escaping Handler) {
        self.socketPath = socketPath
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

        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw SocketError.listen(err)
        }

        chmod(socketPath, 0o600)

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
                if errno == EINTR { continue }
                break
            }
            if pr == 0 { continue } // timeout: re-check running
            if (pfd.revents & Int16(POLLIN)) == 0 { continue }

            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break // listen fd closed by stop()
            }
            disableSIGPIPE(clientFD)
            // The accepted socket can inherit O_NONBLOCK from the listening
            // socket; force blocking mode so the connection uses blocking reads.
            let clientFlags = fcntl(clientFD, F_GETFL, 0)
            _ = fcntl(clientFD, F_SETFL, clientFlags & ~O_NONBLOCK)

            // Each connection gets its own thread so a slow handler (e.g. a
            // human deciding a permission gate) cannot block other connections.
            let connectionHandler = handler
            Thread.detachNewThread {
                UnixSocketServer.handleConnection(fd: clientFD, handler: connectionHandler)
            }
        }
    }

    private static func handleConnection(fd: Int32, handler: @escaping Handler) {
        defer { close(fd) }
        let reader = FDLineReader(fd: fd)
        loop: while true {
            switch reader.nextLine() {
            case .closed, .timedOut:
                break loop
            case .line(let bytes):
                if bytes.isEmpty { continue }
                guard let envelope = try? JSONDecoder().decode(HookEnvelope.self, from: Data(bytes)) else {
                    continue // skip malformed frame, keep the connection open
                }
                // The handler is always invoked (it may update app state);
                // a reply is only written when the client is blocking on one.
                let decision = runBlocking { await handler(envelope) }
                if envelope.wantsDecision, let decision, let frame = try? NDJSON.encode(decision) {
                    writeAllBytes(fd: fd, Array(frame))
                }
            }
        }
    }
}
