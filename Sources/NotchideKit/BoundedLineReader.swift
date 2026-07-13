import Foundation
import Darwin

/// Outcome of reading one newline-delimited line under a hard length cap.
///
/// Mirrors `ReadOutcome` but adds `.overflow`: a line that grows past the cap
/// without a terminating newline. The server treats `.overflow` exactly like a
/// drop (close the connection), so an adapter can never force the hub to buffer
/// an unbounded line in memory.
enum BoundedReadOutcome: Sendable, Equatable {
    case line([UInt8])
    case closed
    case timedOut
    case overflow
}

/// A newline-delimited (`\n`) reader with a hard per-line byte cap.
///
/// Behaves exactly like `FDLineReader` — partial reads, `EINTR`, EOF, and an
/// optional `poll`-bounded deadline — with one addition: if the un-terminated
/// buffer ever exceeds `maxLineBytes`, it stops reading and returns `.overflow`
/// instead of growing without bound. This is the NDJSON line cap (rail 3): a
/// peer that streams more than the cap with no newline is dropped, never
/// buffered unboundedly, and never crashes the process.
///
/// Not thread-safe: use one reader per connection/thread.
final class BoundedLineReader {
    private let fd: Int32
    private let maxLineBytes: Int
    private var buffer: [UInt8] = []

    /// - Parameters:
    ///   - fd: The descriptor to read from.
    ///   - maxLineBytes: Hard cap on a single un-terminated line (default 1 MiB).
    init(fd: Int32, maxLineBytes: Int = 1 << 20) {
        self.fd = fd
        self.maxLineBytes = maxLineBytes
    }

    /// Returns the next line (without the trailing newline), or `.overflow` if a
    /// line exceeds the cap before any newline arrives.
    ///
    /// - Parameter deadline: When non-`nil`, the read is bounded; if no complete
    ///   line arrives by the deadline, `.timedOut` is returned. When `nil`, the
    ///   read blocks until data or EOF.
    func nextLine(deadline: Date? = nil) -> BoundedReadOutcome {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[..<index])
                buffer.removeSubrange(...index)
                return .line(line)
            }

            // No newline yet: enforce the cap before reading (or buffering) more,
            // so the buffer is never held past `maxLineBytes` + one read chunk.
            if buffer.count > maxLineBytes { return .overflow }

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
                // EOF. Flush any trailing partial line — unless it already blew
                // the cap, in which case it is dropped like any oversized line.
                if buffer.isEmpty { return .closed }
                if buffer.count > maxLineBytes { return .overflow }
                let line = buffer
                buffer.removeAll()
                return .line(line)
            }
            buffer.append(contentsOf: tmp[0..<n])
        }
    }
}
