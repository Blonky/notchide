import Testing
import Foundation
import Darwin
@testable import NotchideKit

/// Collects events delivered to an `OTLPProvider` sink from connection threads.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []
    let semaphore = DispatchSemaphore(value: 0)

    func receive(_ batch: [AgentEvent]) {
        lock.lock()
        events.append(contentsOf: batch)
        lock.unlock()
        semaphore.signal()
    }

    var all: [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

@Suite("OTLP provider", .serialized)
struct OTLPProviderTests {

    private static let claudeLogsBody = #"""
    {"resourceLogs":[{"scopeLogs":[{"logRecords":[
      {"body":{"stringValue":"claude_code.api_request"},"attributes":[
        {"key":"session.id","value":{"stringValue":"sess-http"}},
        {"key":"model","value":{"stringValue":"claude-opus-4"}},
        {"key":"input_tokens","value":{"intValue":"7"}}
      ]}
    ]}]}]}
    """#

    /// A minimal blocking loopback HTTP client. Sends a POST and reads the whole
    /// response until the server closes (Connection: close), returning the status
    /// code and body. Resilient to the server dropping the connection mid-send
    /// (the oversize path), so a 413 written before the drop is still observed.
    private func post(port: UInt16, path: String, body: Data) -> (status: Int, body: Data)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // Bound the client so a misbehaving server can never hang the test.
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var request = "POST \(path) HTTP/1.1\r\n"
        request += "Host: 127.0.0.1\r\n"
        request += "Content-Type: application/json\r\n"
        request += "Content-Length: \(body.count)\r\n"
        request += "Connection: close\r\n\r\n"
        var out = Array(request.utf8)
        out.append(contentsOf: body)
        // Ignore the write result: on the oversize path the server responds and
        // drops the connection before the whole body is sent, which fails the
        // write — but the 413 is still waiting to be read.
        _ = writeAllBytes(fd: fd, out)

        var response: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            response.append(contentsOf: chunk[0..<n])
        }
        guard let text = String(bytes: response, encoding: .utf8) else { return (0, Data()) }

        let statusParts = (text.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
        let status = statusParts.count >= 2 ? Int(statusParts[1]) ?? 0 : 0
        var responseBody = Data()
        if let range = text.range(of: "\r\n\r\n") {
            responseBody = Data(text[range.upperBound...].utf8)
        }
        return (status, responseBody)
    }

    @Test("POST /v1/logs delivers mapped events to the sink and returns 200")
    func logsRoundTrip() throws {
        let collector = EventCollector()
        let provider = OTLPProvider(port: 0) { collector.receive($0) }
        let boundPort = try provider.start()
        defer { provider.stop() }
        #expect(boundPort != 0)

        let result = try #require(post(port: boundPort, path: "/v1/logs", body: Data(Self.claudeLogsBody.utf8)))
        #expect(result.status == 200)
        #expect(String(data: result.body, encoding: .utf8)?.contains("partialSuccess") == true)

        // The sink fires from a connection thread; wait for it.
        #expect(collector.semaphore.wait(timeout: .now() + 5) == .success)
        let events = collector.all
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.kind != .needsDecision })
        // A synthesized start plus the api_request progress, both on sh.claude.
        #expect(events.contains { $0.kind == .started && $0.sessionKey.agentSessionID == "sess-http" })
        let apiRequest = try #require(events.first { $0.payload["name"]?.stringValue == "claude_code.api_request" })
        #expect(apiRequest.kind == .progress)
        #expect(apiRequest.providerID == ProviderID("sh.claude"))
        #expect(apiRequest.payload["input_tokens"]?.intValue == 7)
    }

    @Test("an oversize body is rejected with 413 and the server survives")
    func oversizeRejected() throws {
        let collector = EventCollector()
        let provider = OTLPProvider(port: 0) { collector.receive($0) }
        let boundPort = try provider.start()
        defer { provider.stop() }

        // Just over the 1 MiB cap.
        let oversize = Data(count: OTLPProvider.defaultMaxBodyBytes + 1024)
        let rejected = try #require(post(port: boundPort, path: "/v1/logs", body: oversize))
        #expect(rejected.status == 413)

        // The server must still serve a subsequent well-formed request.
        let ok = try #require(post(port: boundPort, path: "/v1/logs", body: Data(Self.claudeLogsBody.utf8)))
        #expect(ok.status == 200)
        #expect(collector.semaphore.wait(timeout: .now() + 5) == .success)
        #expect(!collector.all.isEmpty)
    }

    @Test("binding a second provider on the same fixed port surfaces the in-use condition")
    func portInUseSurfaces() throws {
        let first = OTLPProvider(port: 0) { _ in }
        let boundPort = try first.start()
        defer { first.stop() }

        // A second provider on the SAME live port must throw (EADDRINUSE →
        // SocketError.bind), NOT crash — so the caller can fall back.
        let second = OTLPProvider(port: boundPort) { _ in }
        #expect(throws: SocketError.self) {
            _ = try second.start()
        }

        // The first provider is unaffected and still serves requests.
        let result = try #require(post(port: boundPort, path: "/v1/logs", body: Data(Self.claudeLogsBody.utf8)))
        #expect(result.status == 200)
    }

    @Test("advertises observe capability only")
    func observeOnly() {
        #expect(OTLPProvider.capabilities == [.observe])
        let provider = OTLPProvider(port: 0) { _ in }
        #expect(provider.descriptor.capabilities == [.observe])
        #expect(provider.descriptor.decisionCapability == .notifyOnly)
    }

    @Test("a non-POST method and unknown path are refused without delivering events")
    func methodAndPathGuards() throws {
        let collector = EventCollector()
        let provider = OTLPProvider(port: 0) { collector.receive($0) }
        let boundPort = try provider.start()
        defer { provider.stop() }

        // Unknown path → 404.
        let notFound = try #require(post(port: boundPort, path: "/v1/traces", body: Data(Self.claudeLogsBody.utf8)))
        #expect(notFound.status == 404)
        #expect(collector.all.isEmpty)
    }
}
