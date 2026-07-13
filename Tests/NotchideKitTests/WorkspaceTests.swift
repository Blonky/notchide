import Testing
import Foundation
@testable import NotchideKit

// MARK: - Workspace / WorkspaceSource Codable

@Suite("Workspace model")
struct WorkspaceModelTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("WorkspaceSource round-trips through JSON for both cases")
    func sourceRoundTrip() throws {
        #expect(try roundTrip(WorkspaceSource.folder) == .folder)

        let gitWithBranch = WorkspaceSource.git(remote: "https://example.com/r.git", branch: "main")
        #expect(try roundTrip(gitWithBranch) == gitWithBranch)

        let gitNoBranch = WorkspaceSource.git(remote: "git@github.com:me/r.git", branch: nil)
        #expect(try roundTrip(gitNoBranch) == gitNoBranch)
    }

    @Test("Workspace round-trips through JSON for both source cases")
    func workspaceRoundTrip() throws {
        let key = SessionKey(provider: ProviderID("sh.test"), agentSessionID: "s1", cwd: "/tmp/w")

        let folderWorkspace = Workspace(
            name: "Folder Project",
            root: URL(fileURLWithPath: "/tmp/folder"),
            source: .folder,
            sessions: [key]
        )
        #expect(try roundTrip(folderWorkspace) == folderWorkspace)

        let gitWorkspace = Workspace(
            name: "Git Project",
            root: URL(fileURLWithPath: "/tmp/git"),
            source: .git(remote: "https://example.com/r.git", branch: "dev"),
            sessions: []
        )
        #expect(try roundTrip(gitWorkspace) == gitWorkspace)
    }
}

// MARK: - WorkspaceStore

@Suite("WorkspaceStore")
struct WorkspaceStoreTests {

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notchide-ws-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("workspaces.json", isDirectory: false)
    }

    private func workspace(_ name: String) -> Workspace {
        Workspace(name: name, root: URL(fileURLWithPath: "/tmp/\(name)"), source: .folder)
    }

    @Test("add makes all() reflect the workspace")
    func addReflected() async {
        let store = WorkspaceStore(fileURL: tempFileURL())
        let w = workspace("alpha")
        await store.add(w)
        #expect(await store.all() == [w])
    }

    @Test("remove drops the workspace with the given id")
    func removeDrops() async {
        let store = WorkspaceStore(fileURL: tempFileURL())
        let w1 = workspace("one")
        let w2 = workspace("two")
        await store.add(w1)
        await store.add(w2)

        await store.remove(id: w1.id)

        let all = await store.all()
        #expect(all.count == 1)
        #expect(all.first?.id == w2.id)
    }

    @Test("attachSession appends to the right workspace only")
    func attachSessionTargeted() async {
        let store = WorkspaceStore(fileURL: tempFileURL())
        let w1 = workspace("one")
        let w2 = workspace("two")
        await store.add(w1)
        await store.add(w2)

        let key = SessionKey(provider: ProviderID("sh.test"), agentSessionID: "s1", cwd: "/tmp/two")
        await store.attachSession(key, to: w2.id)

        let all = await store.all()
        #expect(all.first(where: { $0.id == w2.id })?.sessions == [key])
        #expect(all.first(where: { $0.id == w1.id })?.sessions.isEmpty == true)

        // Idempotent: attaching the same key again does not duplicate it.
        await store.attachSession(key, to: w2.id)
        #expect(await store.all().first(where: { $0.id == w2.id })?.sessions == [key])
    }

    @Test("persist then reload from the same file returns an equal list")
    func persistReloadEqual() async throws {
        let fileURL = tempFileURL()
        let store = WorkspaceStore(fileURL: fileURL)

        let w1 = workspace("one")
        let w2 = Workspace(
            name: "two",
            root: URL(fileURLWithPath: "/tmp/two"),
            source: .git(remote: "https://example.com/r.git", branch: "main")
        )
        await store.add(w1)
        await store.add(w2)
        let expected = await store.all()

        let reloaded = WorkspaceStore(fileURL: fileURL)
        try await reloaded.load()
        #expect(await reloaded.all() == expected)
    }

    @Test("the persisted file is created with 0600 permissions")
    func fileIsOwnerOnly() async throws {
        let fileURL = tempFileURL()
        let store = WorkspaceStore(fileURL: fileURL)
        await store.add(workspace("alpha"))

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value
        #expect(perms == Int16(0o600))
    }

    @Test("load on a missing file yields an empty store")
    func loadMissingIsEmpty() async throws {
        let store = WorkspaceStore(fileURL: tempFileURL())
        try await store.load()
        #expect(await store.all().isEmpty)
    }
}

// MARK: - WorkspaceGit (hermetic, no network)

@Suite("WorkspaceGit")
struct WorkspaceGitTests {

    /// A local `git` runner for TEST SETUP ONLY (creating a source repo). Uses an
    /// argv array and a scrubbed environment, and pins an identity + default
    /// branch so commits and branch names are deterministic.
    @discardableResult
    private func setupGit(_ args: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "user.name=Test",
            "-c", "user.email=test@example.com",
            "-c", "commit.gpgsign=false",
            "-c", "init.defaultBranch=main",
        ] + args
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self)
            throw SetupError.gitFailed(status: process.terminationStatus, message: message)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private enum SetupError: Error { case gitFailed(status: Int32, message: String) }

    /// Creates an existing, empty temp directory and returns it.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchide-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A unique temp path that does NOT exist yet (a clone destination).
    private func tempPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notchide-git-dest-\(UUID().uuidString)", isDirectory: true)
    }

    /// Builds a one-commit source repo on branch `main` with a `README.md`.
    private func makeSourceRepo() throws -> URL {
        let repo = try makeTempDir()
        try setupGit(["init"], in: repo)
        try "hello notchide\n".write(
            to: repo.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try setupGit(["add", "README.md"], in: repo)
        try setupGit(["commit", "-m", "initial"], in: repo)
        return repo
    }

    @Test("clone of a local repo lands the committed file at the destination")
    func cloneLandsFiles() throws {
        let source = try makeSourceRepo()
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = tempPath()
        defer { try? FileManager.default.removeItem(at: destination) }

        try WorkspaceGit.clone(remote: source.path, into: destination, branch: nil)

        let landed = destination.appendingPathComponent("README.md").path
        #expect(FileManager.default.fileExists(atPath: landed))
    }

    @Test("clone rejects the ext:: transport-helper injection")
    func cloneRejectsExtHelper() {
        let destination = tempPath()
        #expect(throws: WorkspaceGitError.self) {
            try WorkspaceGit.clone(remote: "ext::sh -c whoami", into: destination, branch: nil)
        }
        // It never even created the destination.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("clone rejects a shell-metacharacter payload")
    func cloneRejectsShellPayload() {
        let destination = tempPath()
        #expect(throws: WorkspaceGitError.self) {
            try WorkspaceGit.clone(remote: "; rm -rf /", into: destination, branch: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("clone rejects an option-shaped remote")
    func cloneRejectsOptionShaped() {
        let destination = tempPath()
        #expect(throws: WorkspaceGitError.self) {
            try WorkspaceGit.clone(remote: "--upload-pack=/bin/sh", into: destination, branch: nil)
        }
    }

    @Test("currentBranch reports the repo's branch")
    func currentBranchReported() throws {
        let source = try makeSourceRepo()
        defer { try? FileManager.default.removeItem(at: source) }

        #expect(try WorkspaceGit.currentBranch(root: source) == "main")
    }

    @Test("status is empty for a clean tree and shows an untracked file when dirty")
    func statusReflectsWorkingTree() throws {
        let source = try makeSourceRepo()
        defer { try? FileManager.default.removeItem(at: source) }

        // Clean immediately after the initial commit.
        #expect(try WorkspaceGit.status(root: source).isEmpty)

        // Introduce an untracked file; porcelain status must mention it.
        try "scratch\n".write(
            to: source.appendingPathComponent("dirty.txt"),
            atomically: true,
            encoding: .utf8
        )
        let status = try WorkspaceGit.status(root: source)
        #expect(status.contains("dirty.txt"))
    }
}
