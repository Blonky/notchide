import Testing
import Foundation
@testable import NotchideKit

@Suite("ToolRegistry")
struct ToolRegistryTests {

    /// A unique temp `tools.json` path inside a fresh directory the registry will
    /// create on first save.
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notchide-tools-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("tools.json")
    }

    @Test("register upserts by id: the same id twice yields one updated entry")
    func registerUpserts() async throws {
        let registry = ToolRegistry(fileURL: tempFileURL())
        try await registry.register(ToolConnector(id: "gh", name: "GitHub", kind: .github))
        try await registry.register(
            ToolConnector(id: "gh", name: "GitHub (org)", kind: .github, enabled: false)
        )

        let all = await registry.all()
        #expect(all.count == 1)
        #expect(all.first?.name == "GitHub (org)")
        #expect(all.first?.enabled == false)
    }

    @Test("setEnabled toggles the enabled flag")
    func setEnabledToggles() async throws {
        let registry = ToolRegistry(fileURL: tempFileURL())
        try await registry.register(ToolConnector(id: "sh", name: "Shell", kind: .shell))

        try await registry.setEnabled(false, id: "sh")
        #expect(await registry.all().first?.enabled == false)

        try await registry.setEnabled(true, id: "sh")
        #expect(await registry.all().first?.enabled == true)
    }

    @Test("remove deletes a connector by id")
    func removeDeletes() async throws {
        let registry = ToolRegistry(fileURL: tempFileURL())
        try await registry.register(ToolConnector(id: "a", name: "A", kind: .mcp))
        try await registry.register(ToolConnector(id: "b", name: "B", kind: .browser))

        try await registry.remove(id: "a")
        let all = await registry.all()
        #expect(all.count == 1)
        #expect(all.first?.id == "b")
    }

    @Test("persists to the injected fileURL and reloads equal from a fresh registry")
    func persistAndReload() async throws {
        let url = tempFileURL()
        let registry = ToolRegistry(fileURL: url)
        let connectors = [
            ToolConnector(id: "gh", name: "GitHub", kind: .github),
            ToolConnector(id: "mail", name: "Mail", kind: .mail, enabled: false),
        ]
        for connector in connectors {
            try await registry.register(connector)
        }

        let reloaded = ToolRegistry(fileURL: url)
        try await reloaded.load()
        #expect(await reloaded.all() == connectors)
    }

    @Test("load with no file on disk leaves an empty registry")
    func loadMissingFile() async throws {
        let registry = ToolRegistry(fileURL: tempFileURL())
        try await registry.load()
        #expect(await registry.all().isEmpty)
    }

    @Test("the persisted file is owner read/write only (0600)")
    func savedFilePermissions() async throws {
        let url = tempFileURL()
        let registry = ToolRegistry(fileURL: url)
        try await registry.register(ToolConnector(id: "x", name: "X", kind: .custom))

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value
        #expect(permissions == Int16(0o600))
    }

    @Test("ToolConnector and ToolKind round-trip through Codable for every kind")
    func codableRoundTrip() throws {
        for kind in ToolKind.allCases {
            let connector = ToolConnector(
                id: kind.rawValue,
                name: kind.rawValue.capitalized,
                kind: kind,
                enabled: false
            )
            let data = try JSONEncoder().encode(connector)
            let decoded = try JSONDecoder().decode(ToolConnector.self, from: data)
            #expect(decoded == connector)
        }
    }
}
