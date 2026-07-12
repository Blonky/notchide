import Foundation
import Darwin

/// Client side of the AAP socket, used by the `notchide-hook` reference adapter
/// and by tests. Connects to a socket path, performs the AAP handshake, sends
/// exactly one `AgentEnvelope`, and — when requested — waits for exactly one
/// `AgentDecision` bounded by a hard timeout, then closes.
public enum UnixSocketClient {

    /// Handshakes, sends one envelope, and optionally awaits one decision.
    ///
    /// - Parameters:
    ///   - envelope: The message to send.
    ///   - handshake: The AAP handshake written as the first line.
    ///   - socketPath: Path of the server socket.
    ///   - awaitDecision: When `true`, blocks (up to `timeout`) for a reply.
    ///   - timeout: Maximum time to wait for a decision. On timeout this returns
    ///     `nil` (never throws for the timeout case).
    /// - Returns: The decision, or `nil` if `awaitDecision` is `false`, the
    ///   timeout elapses, or the reply is malformed / the peer closes.
    /// - Throws: `SocketError` only for connect/write failures (used by the
    ///   adapter to trigger its fail-open path).
    @discardableResult
    public static func send(
        _ envelope: AgentEnvelope,
        handshake: AAPHandshake,
        to socketPath: String,
        awaitDecision: Bool,
        timeout: TimeInterval
    ) throws -> AgentDecision? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }
        disableSIGPIPE(fd)
        defer { close(fd) }

        var addr = try makeUnixSockaddr(path: socketPath)
        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw SocketError.connect(errno) }

        // Handshake first, then the envelope.
        let handshakeFrame = try NDJSON.encode(handshake)
        guard writeAllBytes(fd: fd, Array(handshakeFrame)) else { throw SocketError.write }
        let frame = try NDJSON.encode(envelope)
        guard writeAllBytes(fd: fd, Array(frame)) else { throw SocketError.write }

        guard awaitDecision else { return nil }

        let reader = FDLineReader(fd: fd)
        let deadline = Date().addingTimeInterval(timeout)
        switch reader.nextLine(deadline: deadline) {
        case .line(let bytes):
            return try? JSONDecoder().decode(AgentDecision.self, from: Data(bytes))
        case .timedOut, .closed:
            return nil
        }
    }
}
