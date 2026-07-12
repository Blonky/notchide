import Foundation
import Darwin

/// Errors thrown by the low-level POSIX socket helpers.
public enum SocketError: Error, Sendable, Equatable {
    case create(Int32)
    case bind(Int32)
    case listen(Int32)
    case connect(Int32)
    case write
    case pathTooLong(String)
}

/// Fills a `sockaddr_un` for the given filesystem path.
///
/// Throws `SocketError.pathTooLong` if the path does not fit in `sun_path`
/// (104 bytes on Darwin, including the trailing NUL).
func makeUnixSockaddr(path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    let bytes = Array(path.utf8)
    guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
    withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
        rawPtr.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
            for i in 0..<bytes.count { dst[i] = bytes[i] }
            dst[bytes.count] = 0
        }
    }
    return addr
}

/// Disables SIGPIPE for a socket descriptor (Darwin `SO_NOSIGPIPE`).
///
/// Without this, writing to a socket whose peer has closed raises SIGPIPE,
/// whose default disposition terminates the process. With it, such a write
/// simply fails with `EPIPE`, which the write/read helpers handle gracefully.
func disableSIGPIPE(_ fd: Int32) {
    var on: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

/// Writes all bytes to `fd`, handling partial writes and `EINTR`.
/// Returns `true` only if every byte was written.
@discardableResult
func writeAllBytes(fd: Int32, _ bytes: [UInt8]) -> Bool {
    let count = bytes.count
    if count == 0 { return true }
    return bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard let base = raw.baseAddress else { return false }
        var total = 0
        while total < count {
            let n = write(fd, base.advanced(by: total), count - total)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            total += n
        }
        return true
    }
}

/// Result of attempting to read one newline-delimited line from a descriptor.
enum ReadOutcome: Sendable, Equatable {
    case line([UInt8])
    case closed
    case timedOut
}

/// Reads newline-delimited (`\n`) frames from a file descriptor.
///
/// Handles partial reads (buffering across `read` calls), `EINTR`, client
/// disconnects (`EOF`), and — when a deadline is supplied — read timeouts via
/// `poll`. Not thread-safe: use one reader per connection/thread.
final class FDLineReader {
    private let fd: Int32
    private var buffer: [UInt8] = []

    init(fd: Int32) {
        self.fd = fd
    }

    /// Returns the next line (without the trailing newline).
    ///
    /// - Parameter deadline: When non-`nil`, the read is bounded; if no complete
    ///   line arrives by the deadline, `.timedOut` is returned. When `nil`, the
    ///   read blocks until data or EOF.
    func nextLine(deadline: Date? = nil) -> ReadOutcome {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[..<index])
                buffer.removeSubrange(...index)
                return .line(line)
            }

            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return .timedOut }
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let milliseconds = Int32(min(remaining * 1000.0, Double(Int32.max)))
                let pr = poll(&pfd, 1, milliseconds)
                if pr < 0 {
                    if errno == EINTR { continue }
                    return .closed
                }
                if pr == 0 { return .timedOut }
            }

            var tmp = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &tmp, tmp.count)
            if n < 0 {
                if errno == EINTR { continue }
                return .closed
            }
            if n == 0 {
                // EOF. Flush any trailing partial line, otherwise signal closed.
                if buffer.isEmpty { return .closed }
                let line = buffer
                buffer.removeAll()
                return .line(line)
            }
            buffer.append(contentsOf: tmp[0..<n])
        }
    }
}

/// A minimal `Sendable` box used to hand a value out of a `Task` and across a
/// semaphore boundary. Safe because access is serialized by the semaphore's
/// happens-before relationship (signal → wait).
final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Runs an async operation to completion from a synchronous (blocking) context
/// and returns its result. Intended for bridging blocking POSIX I/O threads to
/// an injected async handler. Must NOT be called from the Swift concurrency
/// cooperative thread pool (it blocks the calling thread on a semaphore).
func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = UncheckedBox<T?>(nil)
    Task.detached {
        let result = await operation()
        box.value = result
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}
