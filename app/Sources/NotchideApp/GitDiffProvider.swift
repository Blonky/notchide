import Foundation

// MARK: - Diff model

/// A parsed unified diff for a working tree.
public struct GitDiff: Equatable, Sendable {
    public var files: [DiffFile]
    public var isEmpty: Bool { files.isEmpty }
    public init(files: [DiffFile]) { self.files = files }

    public static let empty = GitDiff(files: [])
}

public struct DiffFile: Equatable, Sendable, Identifiable {
    public var id: String { newPath.isEmpty ? oldPath : newPath }
    public var oldPath: String
    public var newPath: String
    public var hunks: [DiffHunk]
    /// Display name, preferring the new path.
    public var displayName: String { newPath.isEmpty ? oldPath : newPath }

    public var addedCount: Int { hunks.flatMap(\.lines).filter { $0.kind == .add }.count }
    public var removedCount: Int { hunks.flatMap(\.lines).filter { $0.kind == .remove }.count }
}

public struct DiffHunk: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public var header: String
    public var lines: [DiffLine]

    private enum CodingKeys: String, CodingKey { case header, lines }
    public static func == (lhs: DiffHunk, rhs: DiffHunk) -> Bool {
        lhs.header == rhs.header && lhs.lines == rhs.lines
    }
}

public struct DiffLine: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable { case add, remove, context }
    public let id = UUID()
    public var kind: Kind
    public var text: String
    public var oldLineNumber: Int?
    public var newLineNumber: Int?

    public static func == (lhs: DiffLine, rhs: DiffLine) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text &&
            lhs.oldLineNumber == rhs.oldLineNumber && lhs.newLineNumber == rhs.newLineNumber
    }
}

// MARK: - Provider

/// Runs `git diff` in a lane's working directory and parses the unified output
/// into a `GitDiff` model. Read-only: notchide shows the diff, never edits it.
public struct GitDiffProvider: Sendable {
    public init() {}

    /// The current branch name, or `nil` if not a repo / detached.
    public func currentBranch(cwd: String) async -> String? {
        let output = await Self.run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)
        guard let name = output?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != "HEAD" else {
            return nil
        }
        return name
    }

    /// Combined unstaged + staged diff for the working tree at `cwd`.
    ///
    /// The `cwd` is agent/attacker-controlled, so this path is deliberately
    /// hardened (see `run`): the environment neutralizes user/system/repo git
    /// config, and the diff itself disables ext-diff / textconv drivers. Callers
    /// invoke this only when the review console is actually being shown — never
    /// as an automatic side effect of merely receiving a gate.
    public func loadDiff(cwd: String) async -> GitDiff {
        guard !cwd.isEmpty else { return .empty }
        // Confirm this is a real work tree first, under the same hardened env, so
        // we never run diff machinery outside a checkout.
        guard await Self.isInsideWorkTree(cwd: cwd) else { return .empty }
        let diffArgs = ["diff", "--no-color", "--no-textconv", "--no-ext-diff"]
        let unstaged = await Self.run(diffArgs, cwd: cwd) ?? ""
        let staged = await Self.run(diffArgs + ["--staged"], cwd: cwd) ?? ""
        let combined = [unstaged, staged].filter { !$0.isEmpty }.joined(separator: "\n")
        return DiffParser.parse(combined)
    }

    /// Whether `cwd` is inside a git work tree, checked under the hardened env.
    private static func isInsideWorkTree(cwd: String) async -> Bool {
        let out = await run(["rev-parse", "--is-inside-work-tree"], cwd: cwd)
        return out?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Runs `git -C <cwd> <args>` off the main thread and returns stdout.
    ///
    /// SECURITY: auto-running `git` in an agent/attacker-controlled `cwd` would
    /// otherwise execute repo-configured code — `core.pager`, `core.fsmonitor`,
    /// and ext-diff / textconv drivers all run arbitrary programs with no user
    /// interaction, defeating the permission gate. We defang that here:
    ///   • the environment points `GIT_CONFIG_SYSTEM` / `GIT_CONFIG_GLOBAL` at
    ///     `/dev/null`, sets `GIT_OPTIONAL_LOCKS=0` and `GIT_TERMINAL_PROMPT=0`,
    ///   • the invocation forces `--no-optional-locks -c core.fsmonitor=` and the
    ///     diff callers additionally pass `--no-textconv --no-ext-diff`.
    private static func run(_ args: [String], cwd: String) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", cwd, "--no-optional-locks", "-c", "core.fsmonitor="] + args
            process.environment = hardenedGitEnvironment()
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// The current environment with git config sources neutralized, so no
    /// user/system/repo config can inject a pager, fsmonitor, or diff driver.
    private static func hardenedGitEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }
}

// MARK: - Unified diff parser

/// A small, dependency-free unified-diff parser. It understands `diff --git`,
/// `---`/`+++` file headers, `@@ … @@` hunk headers, and `+`/`-`/` ` line
/// prefixes, tracking old/new line numbers as it goes.
public enum DiffParser {
    public static func parse(_ text: String) -> GitDiff {
        var files: [DiffFile] = []
        var currentFile: DiffFile?
        var currentHunk: DiffHunk?
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            if let hunk = currentHunk { currentFile?.hunks.append(hunk); currentHunk = nil }
        }
        func flushFile() {
            flushHunk()
            if let file = currentFile { files.append(file); currentFile = nil }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.hasPrefix("diff --git") {
                flushFile()
                currentFile = DiffFile(oldPath: "", newPath: "", hunks: [])
            } else if rawLine.hasPrefix("--- ") {
                currentFile?.oldPath = stripPathPrefix(String(rawLine.dropFirst(4)))
            } else if rawLine.hasPrefix("+++ ") {
                currentFile?.newPath = stripPathPrefix(String(rawLine.dropFirst(4)))
            } else if rawLine.hasPrefix("@@") {
                flushHunk()
                if currentFile == nil { currentFile = DiffFile(oldPath: "", newPath: "", hunks: []) }
                let (o, n) = parseHunkStarts(rawLine)
                oldLine = o
                newLine = n
                currentHunk = DiffHunk(header: rawLine, lines: [])
            } else if currentHunk != nil {
                if rawLine.hasPrefix("+") {
                    currentHunk?.lines.append(DiffLine(kind: .add, text: String(rawLine.dropFirst()), oldLineNumber: nil, newLineNumber: newLine))
                    newLine += 1
                } else if rawLine.hasPrefix("-") {
                    currentHunk?.lines.append(DiffLine(kind: .remove, text: String(rawLine.dropFirst()), oldLineNumber: oldLine, newLineNumber: nil))
                    oldLine += 1
                } else if rawLine.hasPrefix(" ") || rawLine.isEmpty {
                    currentHunk?.lines.append(DiffLine(kind: .context, text: rawLine.isEmpty ? "" : String(rawLine.dropFirst()), oldLineNumber: oldLine, newLineNumber: newLine))
                    oldLine += 1
                    newLine += 1
                }
                // "\ No newline at end of file" and other metadata lines are ignored.
            }
        }
        flushFile()
        return GitDiff(files: files)
    }

    /// Drops the `a/` or `b/` prefix git puts on header paths.
    private static func stripPathPrefix(_ path: String) -> String {
        var p = path
        if let tab = p.firstIndex(of: "\t") { p = String(p[..<tab]) }
        if p.hasPrefix("a/") || p.hasPrefix("b/") { p = String(p.dropFirst(2)) }
        return p == "/dev/null" ? "" : p
    }

    /// Parses the starting old/new line numbers from a `@@ -o,c +n,c @@` header.
    private static func parseHunkStarts(_ header: String) -> (old: Int, new: Int) {
        // Example: "@@ -12,7 +12,9 @@ func foo()"
        let parts = header.split(separator: " ")
        var old = 0
        var new = 0
        for part in parts {
            if part.hasPrefix("-") {
                old = Int(part.dropFirst().split(separator: ",").first.map(String.init) ?? "0") ?? 0
            } else if part.hasPrefix("+") {
                new = Int(part.dropFirst().split(separator: ",").first.map(String.init) ?? "0") ?? 0
            }
        }
        return (old, new)
    }
}
