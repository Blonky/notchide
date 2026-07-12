import Foundation
import Darwin

/// Client side of the notchide hook IPC, used by the `notchide-hook` CLI and by
/// tests. Connects to a socket path, sends exactly one `HookEnvelope`, and —
/// when requested — waits for exactly one `DecisionMessage` bounded by a hard
/// timeout, then closes.
public enum UnixSocketClient {

    /// Sends one envelope and optionally awaits one decision.
    ///
    /// - Parameters:
    ///   - envelope: The message to send.
    ///   - socketPath: Path of the server socket.
    ///   - awaitDecision: When `true`, blocks (up to `timeout`) for a reply.
    ///   - timeout: Maximum time to wait for a decision. On timeout this returns
    ///     `nil` (never throws for the timeout case).
    /// - Returns: The decision, or `nil` if `awaitDecision` is `false`, the
    ///   timeout elapses, or the reply is malformed / the peer closes.
    /// - Throws: `SocketError` only for connect/write failures (used by the CLI
    ///   to trigger its fail-open path).
    @discardableResult
    public static func send(
        _ envelope: HookEnvelope,
        to socketPath: String,
        awaitDecision: Bool,
        timeout: TimeInterval
    ) throws -> DecisionMessage? {
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

        let frame = try NDJSON.encode(envelope)
        guard writeAllBytes(fd: fd, Array(frame)) else { throw SocketError.write }

        guard awaitDecision else { return nil }

        let reader = FDLineReader(fd: fd)
        let deadline = Date().addingTimeInterval(timeout)
        switch reader.nextLine(deadline: deadline) {
        case .line(let bytes):
            return try? JSONDecoder().decode(DecisionMessage.self, from: Data(bytes))
        case .timedOut, .closed:
            return nil
        }
    }
}
