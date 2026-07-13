import Testing
import Foundation
import Darwin
@testable import NotchideKit

@Suite("PidFile")
struct PidFileTests {

    /// A unique temp `sidecar.pid` path inside a fresh directory the pid file
    /// will create on first write.
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notchide-pid-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sidecar.pid")
    }

    @Test("write then read round-trips the pgid")
    func writeReadRoundTrip() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pidFile = PidFile(fileURL: url)
        try pidFile.write(pgid: 424_242)
        #expect(pidFile.read() == 424_242)
    }

    @Test("read of an absent file is nil")
    func readAbsentIsNil() {
        let pidFile = PidFile(fileURL: tempFileURL())
        #expect(pidFile.read() == nil)
    }

    @Test("read of a garbage file is nil")
    func readGarbageIsNil() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-a-number\n".utf8).write(to: url)
        let pidFile = PidFile(fileURL: url)
        #expect(pidFile.read() == nil)
    }

    @Test("the pid file is written owner-only 0600")
    func fileModeIs0600() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pidFile = PidFile(fileURL: url)
        try pidFile.write(pgid: 12_345)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value
        #expect(perms == Int16(0o600))
    }

    @Test("reclaim of a dead/bogus pgid is a safe no-op that clears the record")
    func reclaimDeadPgidIsNoOp() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // A pgid guaranteed dead: a value far above any pid Darwin will ever
        // assign. Prove it is dead (`kill(pgid, 0) != 0`) BEFORE reclaim, so the
        // no-op path can never signal a real, unrelated process group.
        let deadPgid: Int32 = 0x7FFF_FFF0  // ~2.1e9
        try #require(kill(deadPgid, 0) != 0, "the chosen pgid must be dead before we test reclaim")

        // graceSeconds: 0 keeps the test fast; the dead-pgid path never sleeps
        // anyway (it short-circuits before the SIGTERM/grace/SIGKILL steps).
        let pidFile = PidFile(fileURL: url, graceSeconds: 0)
        try pidFile.write(pgid: deadPgid)

        // Must not throw, must not signal anything, and must drop the stale record.
        pidFile.reclaim()
        #expect(pidFile.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("reclaim with no pid file is a safe no-op")
    func reclaimAbsentIsNoOp() {
        let pidFile = PidFile(fileURL: tempFileURL())
        pidFile.reclaim()  // must not throw / crash
        #expect(pidFile.read() == nil)
    }
}
