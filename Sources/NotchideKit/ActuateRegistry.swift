import Foundation
import Darwin

/// A single live, actuate-capable connection that can receive server-pushed
/// `ActuateFrame`s.
///
/// The owning connection thread is parked in its blocking reader loop; actuate
/// pushes arrive on a DIFFERENT thread. Concurrent read + write on one socket fd
/// is safe, but two writers are not — so all writes (actuate pushes AND any gate
/// decision writeback on the same connection) funnel through `write(_:)`, which
/// is serialized by `writeLock`.
///
/// Lifetime: the reader thread `deregister`s this connection (which calls
/// `markClosed()` under `writeLock`) BEFORE it closes the fd. `markClosed()`
/// therefore cannot return until any in-flight write has finished, and no write
/// can begin afterward — so the fd is never touched after it is closed.
final class ActuateConnection: @unchecked Sendable {
    /// Per-connection identity, so a stale connection cannot deregister a newer
    /// one that reconnected under the same `providerID`.
    let id = UUID()
    let providerID: ProviderID
    private let fd: Int32
    private let writeLock = NSLock()
    private var closed = false

    init(providerID: ProviderID, fd: Int32) {
        self.providerID = providerID
        self.fd = fd
    }

    /// Writes one already-framed NDJSON line. Returns `false` if the connection
    /// is closed or the write fails (peer gone); on write failure the connection
    /// marks itself closed so no further writes are attempted.
    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        if closed { return false }
        let ok = writeAllBytes(fd: fd, bytes)
        if !ok { closed = true }
        return ok
    }

    /// Marks the connection closed. Blocks until any in-flight `write` completes,
    /// guaranteeing the caller may then safely `close(fd)`.
    func markClosed() {
        writeLock.lock()
        closed = true
        writeLock.unlock()
    }
}

/// Registry of live actuate-capable connections, keyed by `providerID`.
///
/// The server registers a connection when its handshake advertises `.actuate`
/// and deregisters it when the reader loop ends. Pushing to a provider with no
/// live connection is a logged no-op (never a crash) — the fail-safe demanded by
/// a disconnected/reconnecting adapter.
final class ActuateRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ProviderID: ActuateConnection] = [:]
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void = ActuateRegistry.stderrLog) {
        self.log = log
    }

    /// Registers (or replaces) the live connection for its `providerID`. A
    /// reconnect under the same id simply supersedes the previous registration.
    func register(_ connection: ActuateConnection) {
        lock.lock()
        connections[connection.providerID] = connection
        lock.unlock()
    }

    /// Removes `connection` from the registry and marks it closed. The removal is
    /// identity-guarded: if a newer connection already reclaimed the
    /// `providerID` (reconnect), the newer registration is left intact.
    func deregister(_ connection: ActuateConnection) {
        lock.lock()
        if connections[connection.providerID]?.id == connection.id {
            connections[connection.providerID] = nil
        }
        lock.unlock()
        connection.markClosed()
    }

    /// The live connection owning `providerID`, if any.
    func connection(for providerID: ProviderID) -> ActuateConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connections[providerID]
    }

    /// Pushes `frame` to the live actuate connection owning `providerID`.
    ///
    /// Returns `true` iff the frame was written. A missing connection, an encode
    /// failure, or a dead peer are all safe, logged no-ops that return `false`.
    @discardableResult
    func send(_ frame: ActuateFrame, to providerID: ProviderID) -> Bool {
        guard let connection = connection(for: providerID) else {
            log("actuate: no live connection for \(providerID.raw); dropping \(frame.kind.rawValue)")
            return false
        }
        guard let framed = try? NDJSON.encode(frame) else {
            log("actuate: failed to encode \(frame.kind.rawValue) for \(providerID.raw); dropping")
            return false
        }
        let ok = connection.write(Array(framed))
        if !ok {
            log("actuate: write failed for \(providerID.raw); connection is gone, dropping")
        }
        return ok
    }

    static let stderrLog: @Sendable (String) -> Void = { message in
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
