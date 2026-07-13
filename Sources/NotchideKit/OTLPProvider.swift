import Foundation
import Darwin

/// A zero-dependency, loopback-only OTLP/HTTP receiver.
///
/// Binds an `AF_INET` TCP listener to `127.0.0.1` (NEVER `0.0.0.0`) — mirroring
/// the low-level POSIX style of `UnixSocketServer`, but over loopback TCP — and
/// accepts `POST /v1/logs` and `POST /v1/metrics` with `application/json` bodies.
/// Each request body is mapped by `OTLPMapping` into vendor-neutral `AgentEvent`s
/// and handed to a caller-supplied sink; the app wires that sink to
/// `SessionStore`. This is an OBSERVE-only ENRICHMENT source: it advertises
/// `Capability.observe` and nothing else, and the events it produces are never
/// `.needsDecision`.
///
/// Safety properties:
/// - Loopback only. The bind address is hard-wired to `127.0.0.1`, so the port is
///   never exposed off-host.
/// - Bounded memory. A request whose `Content-Length` exceeds `maxBodyBytes`
///   (default 1 MiB) is answered `413` and its connection dropped, before the
///   oversized body is ever buffered — a hostile or buggy exporter can never OOM
///   the process.
/// - Never crashes on a port clash. `start()` throws `SocketError.bind` (carrying
///   `EADDRINUSE`) when the port is taken, so the caller can fall back to another
///   port instead of trapping.
///
/// Concurrency model matches `UnixSocketServer`: the accept loop and each
/// connection run on their own dedicated `Thread`s using blocking POSIX I/O, off
/// the Swift cooperative pool.
public final class OTLPProvider: @unchecked Sendable {

    /// Receives each request's mapped events. Called on a connection thread, so a
    /// slow sink only ties up that one connection.
    public typealias Sink = @Sendable ([AgentEvent]) -> Void

    /// The default OTLP/HTTP port.
    public static let defaultPort: UInt16 = 4318
    /// The default maximum request body size (1 MiB).
    public static let defaultMaxBodyBytes = 1 << 20

    /// The transport's own id. Mapped events carry their real originating
    /// `providerID` (`sh.claude` / `sh.codex`) inside the `AgentEvent`.
    public static let providerID = ProviderID("sh.otlp")
    /// This provider observes only — it never gates, actuates, or sees the screen.
    public static let capabilities: Set<Capability> = [.observe]

    /// The port requested at construction. `0` asks the OS for an ephemeral port;
    /// the actual bound port is then available as `boundPort` after `start()`.
    public let port: UInt16
    private let maxBodyBytes: Int
    private let sink: Sink

    private let lock = NSLock()
    private var running = false
    private var listenFD: Int32 = -1
    private var _boundPort: UInt16 = 0

    /// - Parameters:
    ///   - port: TCP port to bind on `127.0.0.1`. Defaults to `4318`. Pass `0` for
    ///     an OS-assigned ephemeral port (read it back via `boundPort`).
    ///   - maxBodyBytes: Hard cap on a request body; oversize → `413` + drop.
    ///   - sink: Delivers each request's mapped `AgentEvent`s.
    public init(
        port: UInt16 = OTLPProvider.defaultPort,
        maxBodyBytes: Int = OTLPProvider.defaultMaxBodyBytes,
        sink: @escaping Sink
    ) {
        self.port = port
        self.maxBodyBytes = maxBodyBytes
        self.sink = sink
    }

    /// The observe-only descriptor advertised for this transport.
    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: OTLPProvider.providerID,
            displayName: "OTLP",
            capabilities: OTLPProvider.capabilities,
            decisionCapability: .notifyOnly)
    }

    /// The actual bound port. `0` until `start()` has succeeded; equals `port`
    /// when a fixed port was requested, or the OS-assigned port when `port == 0`.
    public var boundPort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return _boundPort
    }

    /// Binds the loopback listener and starts accepting connections on a
    /// background thread.
    ///
    /// - Returns: the actual bound port (useful when `port == 0`).
    /// - Throws: `SocketError.bind` — carrying `EADDRINUSE` when the port is
    ///   already in use — so the caller can fall back to another port rather than
    ///   crash. `SocketError.create` / `.listen` cover the other failure points.
    @discardableResult
    public func start() throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return _boundPort }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }
        disableSIGPIPE(fd)

        // SO_REUSEADDR avoids spurious TIME_WAIT clashes on a quick restart, but
        // does NOT let two live listeners share a loopback port — a second bind on
        // an actively-listening port still returns EADDRINUSE, which is exactly the
        // in-use signal the caller relies on to fall back.
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = OTLPProvider.loopbackAddress(port: port)
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
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

        _boundPort = OTLPProvider.readBoundPort(fd: fd, requested: port)

        // Non-blocking listen fd so the accept loop can poll and observe stop().
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        listenFD = fd
        running = true

        let thread = Thread { [weak self] in
            self?.acceptLoop(listenFD: fd)
        }
        thread.name = "notchide.otlp.accept"
        thread.stackSize = 512 * 1024
        thread.start()

        return _boundPort
    }

    /// Stops accepting connections and closes the listening socket. In-flight
    /// connection threads finish on their own.
    public func stop() {
        lock.lock()
        let fd = listenFD
        running = false
        listenFD = -1
        lock.unlock()

        if fd >= 0 { close(fd) }
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
                if !isRunning() { break }
                usleep(50_000) // 50ms back-off on a transient poll error
                continue
            }
            if pr == 0 { continue }
            if (pfd.revents & Int16(POLLIN)) == 0 { continue }

            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                let err = errno
                if err == EINTR || err == EAGAIN || err == EWOULDBLOCK { continue }
                // Only teardown ends the loop; every other accept() error is
                // transient and must never permanently kill the server.
                if !isRunning() { break }
                if err == EMFILE || err == ENFILE { usleep(50_000) }
                continue
            }
            disableSIGPIPE(clientFD)
            // The accepted socket can inherit O_NONBLOCK from the listener; force
            // blocking mode so the connection uses blocking reads/writes.
            let clientFlags = fcntl(clientFD, F_GETFL, 0)
            _ = fcntl(clientFD, F_SETFL, clientFlags & ~O_NONBLOCK)

            let connectionSink = sink
            let cap = maxBodyBytes
            Thread.detachNewThread {
                OTLPProvider.handleConnection(fd: clientFD, maxBodyBytes: cap, sink: connectionSink)
            }
        }
    }

    // MARK: - Connection handling

    private enum RequestReadResult {
        case request(method: String, path: String, body: Data)
        case oversize
        case malformed
    }

    private static func handleConnection(fd: Int32, maxBodyBytes: Int, sink: @escaping Sink) {
        defer { close(fd) }

        switch readRequest(fd: fd, maxBodyBytes: maxBodyBytes) {
        case .oversize:
            // Reject before buffering the body, then drop the connection.
            writeResponse(fd: fd, status: "413 Payload Too Large")
        case .malformed:
            writeResponse(fd: fd, status: "400 Bad Request")
        case .request(let method, let path, let body):
            guard method == "POST" else {
                writeResponse(fd: fd, status: "405 Method Not Allowed")
                return
            }
            switch route(for: path) {
            case .logs:
                deliver(OTLPMapping.events(fromLogsJSON: body), to: sink, fd: fd)
            case .metrics:
                deliver(OTLPMapping.events(fromMetricsJSON: body), to: sink, fd: fd)
            case .unknown:
                writeResponse(fd: fd, status: "404 Not Found")
            }
        }
    }

    private enum Route {
        case logs
        case metrics
        case unknown
    }

    private static func route(for path: String) -> Route {
        // Ignore any query string when matching the export path.
        let base = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        switch base {
        case "/v1/logs": return .logs
        case "/v1/metrics": return .metrics
        default: return .unknown
        }
    }

    private static func deliver(_ events: [AgentEvent], to sink: Sink, fd: Int32) {
        if !events.isEmpty { sink(events) }
        // OTLP/HTTP JSON success is a (possibly empty) ExportServiceResponse.
        writeResponse(
            fd: fd,
            status: "200 OK",
            contentType: "application/json",
            body: Data(#"{"partialSuccess":{}}"#.utf8))
    }

    /// Reads one HTTP/1.1 request: headers up to `CRLFCRLF`, then a body bounded by
    /// `Content-Length`. Rejects (`.oversize`) as soon as the declared or observed
    /// body would exceed `maxBodyBytes`, so an oversized body is never buffered.
    private static func readRequest(fd: Int32, maxBodyBytes: Int) -> RequestReadResult {
        let headerCap = 64 * 1024
        var buffer: [UInt8] = []
        var headerEnd: Int? = indexOfHeaderTerminator(buffer)

        while headerEnd == nil {
            if buffer.count > headerCap { return .malformed }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                return .malformed
            }
            if n == 0 { return .malformed } // EOF before headers completed
            buffer.append(contentsOf: chunk[0..<n])
            headerEnd = indexOfHeaderTerminator(buffer)
        }

        guard let terminator = headerEnd,
              let headerText = String(bytes: buffer[0..<terminator], encoding: .utf8) else {
            return .malformed
        }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestParts = (lines.first ?? "").split(separator: " ")
        guard requestParts.count >= 2 else { return .malformed }
        let method = String(requestParts[0])
        let path = String(requestParts[1])

        var contentLength: Int?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else {
                continue
            }
            contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces))
        }

        if let contentLength, contentLength > maxBodyBytes { return .oversize }

        var body = Array(buffer[(terminator + 4)...])
        let target = contentLength ?? body.count
        if target > maxBodyBytes { return .oversize }

        while body.count < target {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                return .malformed
            }
            if n == 0 { break } // EOF: use whatever arrived
            body.append(contentsOf: chunk[0..<n])
            if body.count > maxBodyBytes { return .oversize }
        }

        return .request(method: method, path: path, body: Data(body))
    }

    /// Index of the first `CRLFCRLF` (header/body boundary), or `nil`.
    private static func indexOfHeaderTerminator(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var i = 0
        while i <= bytes.count - 4 {
            if bytes[i] == 13, bytes[i + 1] == 10, bytes[i + 2] == 13, bytes[i + 3] == 10 {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func writeResponse(
        fd: Int32,
        status: String,
        contentType: String? = nil,
        body: Data = Data()
    ) {
        var header = "HTTP/1.1 \(status)\r\n"
        if let contentType { header += "Content-Type: \(contentType)\r\n" }
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Array(header.utf8)
        out.append(contentsOf: body)
        writeAllBytes(fd: fd, out)
    }

    // MARK: - Address helpers

    /// A `sockaddr_in` for `127.0.0.1:port` (loopback, never the wildcard).
    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian // host → network byte order
        addr.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian // 127.0.0.1
        return addr
    }

    /// Reads back the actual bound port via `getsockname` (resolves an ephemeral
    /// `port == 0` to the OS-assigned port).
    private static func readBoundPort(fd: Int32, requested: UInt16) -> UInt16 {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getsockname(fd, sockaddrPtr, &len)
            }
        }
        guard result == 0 else { return requested }
        return UInt16(bigEndian: addr.sin_port)
    }
}
