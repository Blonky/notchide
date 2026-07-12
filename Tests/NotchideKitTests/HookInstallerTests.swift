import Testing
import Foundation
@testable import NotchideKit

@Suite("HookInstaller merge/unmerge")
struct HookInstallerTests {

    let binary = "/usr/local/bin/notchide-hook"

    /// Deep, order-independent structural equality for two JSON-shaped dicts.
    private func deepEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        NSDictionary(dictionary: a).isEqual(NSDictionary(dictionary: b))
    }

    /// A settings dict that already has another tool's PreToolUse hook plus an
    /// unrelated top-level key, to prove notchide coexists with them.
    private func settingsWithOtherTool() -> [String: Any] {
        [
            "model": "opus",
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Bash",
                        "hooks": [
                            ["type": "command", "command": "/opt/other-tool guard"]
                        ]
                    ]
                ]
            ]
        ]
    }

    /// The single handler command in the first matcher group of an event.
    private func firstCommand(_ settings: [String: Any], event: String) throws -> String {
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let groups = try #require(hooks[event] as? [Any])
        let group = try #require(groups.first as? [String: Any])
        let handlers = try #require(group["hooks"] as? [Any])
        let handler = try #require(handlers.first as? [String: Any])
        return try #require(handler["command"] as? String)
    }

    // MARK: - Install into empty

    @Test("install into an empty settings dict wires all four events with the correct shape")
    func installIntoEmpty() throws {
        let result = HookInstaller.install(into: [:], binaryPath: binary)

        let hooks = try #require(result["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["PreToolUse", "Notification", "Stop", "SubagentStop"])

        // PreToolUse carries matcher "*" and the right command.
        let preGroups = try #require(hooks["PreToolUse"] as? [Any])
        #expect(preGroups.count == 1)
        let preGroup = try #require(preGroups.first as? [String: Any])
        #expect(preGroup["matcher"] as? String == "*")
        let preHandlers = try #require(preGroup["hooks"] as? [Any])
        let preHandler = try #require(preHandlers.first as? [String: Any])
        #expect(preHandler["type"] as? String == "command")
        #expect(preHandler["command"] as? String == HookInstaller.command(for: "PreToolUse", binaryPath: binary))
        // The path is single-quoted so a spaced/odd path stays one shell word.
        #expect(preHandler["command"] as? String == "'\(binary)' handle PreToolUse")

        // Notification / Stop / SubagentStop omit the matcher.
        for event in ["Notification", "Stop", "SubagentStop"] {
            let groups = try #require(hooks[event] as? [Any])
            let group = try #require(groups.first as? [String: Any])
            #expect(group["matcher"] == nil, "\(event) must omit matcher")
            #expect(try firstCommand(result, event: event) == HookInstaller.command(for: event, binaryPath: binary))
        }

        // doctor sees all four wired.
        #expect(HookInstaller.wiredEvents(in: result) == Set(HookInstaller.managedEvents))
    }

    // MARK: - Preserve existing settings & other tools

    @Test("install preserves unrelated keys and appends to (never replaces) another tool's hooks")
    func installPreservesExisting() throws {
        let existing = settingsWithOtherTool()
        let result = HookInstaller.install(into: existing, binaryPath: binary)

        // Unrelated top-level key survives.
        #expect(result["model"] as? String == "opus")

        // PreToolUse now has BOTH groups: the other tool first, notchide appended.
        let hooks = try #require(result["hooks"] as? [String: Any])
        let preGroups = try #require(hooks["PreToolUse"] as? [Any])
        #expect(preGroups.count == 2)

        let otherGroup = try #require(preGroups[0] as? [String: Any])
        let otherHandler = try #require((otherGroup["hooks"] as? [Any])?.first as? [String: Any])
        #expect(otherHandler["command"] as? String == "/opt/other-tool guard")

        let notchideGroup = try #require(preGroups[1] as? [String: Any])
        #expect(notchideGroup["matcher"] as? String == "*")
        let notchideHandler = try #require((notchideGroup["hooks"] as? [Any])?.first as? [String: Any])
        #expect(notchideHandler["command"] as? String == HookInstaller.command(for: "PreToolUse", binaryPath: binary))

        // The other three events are added fresh.
        #expect(HookInstaller.wiredEvents(in: result) == Set(HookInstaller.managedEvents))
    }

    // MARK: - Idempotency

    @Test("install is idempotent: applying it twice equals applying it once")
    func installIsIdempotent() throws {
        // From empty.
        let once = HookInstaller.install(into: [:], binaryPath: binary)
        let twice = HookInstaller.install(into: once, binaryPath: binary)
        #expect(deepEqual(once, twice))

        // From a dict that already contains another tool's hooks.
        let existing = settingsWithOtherTool()
        let onceMixed = HookInstaller.install(into: existing, binaryPath: binary)
        let twiceMixed = HookInstaller.install(into: onceMixed, binaryPath: binary)
        #expect(deepEqual(onceMixed, twiceMixed))

        // No duplicate notchide entries under PreToolUse (other tool + notchide only).
        let hooks = try #require(twiceMixed["hooks"] as? [String: Any])
        let preGroups = try #require(hooks["PreToolUse"] as? [Any])
        #expect(preGroups.count == 2)
    }

    // MARK: - Uninstall restores pre-install state

    @Test("uninstall restores the exact pre-install dict (empty start)")
    func uninstallRestoresEmpty() {
        let installed = HookInstaller.install(into: [:], binaryPath: binary)
        let removed = HookInstaller.uninstall(from: installed)
        #expect(deepEqual(removed, [:]))
    }

    @Test("uninstall removes only notchide, restoring the dict when other tools were present")
    func uninstallRestoresWithOtherTool() throws {
        let existing = settingsWithOtherTool()
        let installed = HookInstaller.install(into: existing, binaryPath: binary)
        let removed = HookInstaller.uninstall(from: installed)

        // Deep-equal to the pre-install state.
        #expect(deepEqual(removed, existing))

        // Concretely: the other tool's PreToolUse hook survives, alone again.
        let hooks = try #require(removed["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["PreToolUse"])
        let preGroups = try #require(hooks["PreToolUse"] as? [Any])
        #expect(preGroups.count == 1)
        #expect(try firstCommand(removed, event: "PreToolUse") == "/opt/other-tool guard")
    }

    @Test("uninstall on a dict without notchide is a no-op")
    func uninstallNoNotchideIsNoOp() {
        let existing = settingsWithOtherTool()
        let removed = HookInstaller.uninstall(from: existing)
        #expect(deepEqual(removed, existing))
    }

    // MARK: - doctor inspection

    @Test("wiredEvents reports the correct set before, after install, and after uninstall")
    func doctorInspection() throws {
        // Before: nothing wired.
        #expect(HookInstaller.wiredEvents(in: [:]).isEmpty)

        // After install: all four.
        let installed = HookInstaller.install(into: [:], binaryPath: binary)
        #expect(HookInstaller.wiredEvents(in: installed) == Set(HookInstaller.managedEvents))

        // After uninstall: none.
        let removed = HookInstaller.uninstall(from: installed)
        #expect(HookInstaller.wiredEvents(in: removed).isEmpty)

        // Partial wiring: drop one event and confirm it is reported missing.
        var partial = installed
        var hooks = try #require(partial["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "Stop")
        partial["hooks"] = hooks
        #expect(HookInstaller.wiredEvents(in: partial) == ["PreToolUse", "Notification", "SubagentStop"])
    }

    // MARK: - Quoting / spaced binary paths (item 1) + precise detection (item 3)

    @Test("install single-quotes a binary path with spaces; the command round-trips and uninstall removes it")
    func spacedBinaryPathRoundTrips() throws {
        let spaced = "/Users/My Apps/notchide-hook"
        let installed = HookInstaller.install(into: [:], binaryPath: spaced)

        // The generated command quotes the path as one shell word.
        let cmd = try firstCommand(installed, event: "PreToolUse")
        #expect(cmd == "'/Users/My Apps/notchide-hook' handle PreToolUse")

        // The first shell token parses back to the exact (spaced) path.
        #expect(HookInstaller.firstShellToken(cmd) == spaced)

        // Still detected as notchide's on all four events…
        #expect(HookInstaller.wiredEvents(in: installed) == Set(HookInstaller.managedEvents))
        // …and uninstall removes it cleanly, back to empty.
        #expect(deepEqual(HookInstaller.uninstall(from: installed), [:]))
    }

    @Test("install escapes an embedded single quote in the path and still round-trips")
    func quotedBinaryPathRoundTrips() throws {
        let weird = "/Users/O'Brien/notchide-hook"
        let installed = HookInstaller.install(into: [:], binaryPath: weird)

        let cmd = try firstCommand(installed, event: "PreToolUse")
        #expect(cmd == "'/Users/O'\\''Brien/notchide-hook' handle PreToolUse")
        #expect(HookInstaller.firstShellToken(cmd) == weird)

        #expect(HookInstaller.wiredEvents(in: installed) == Set(HookInstaller.managedEvents))
        #expect(deepEqual(HookInstaller.uninstall(from: installed), [:]))
    }

    @Test("detection is a precise basename match, not a loose substring")
    func detectionIsPreciseBasenameMatch() {
        // An unrelated tool whose command merely contains "notchide-hook" must
        // NOT be treated as notchide's (basename here is `run`, not
        // `notchide-hook`), so uninstall leaves it untouched.
        let lookalike: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "*", "hooks": [
                        ["type": "command", "command": "/opt/notchide-hook-wrapper/run --pre"]
                    ]]
                ]
            ]
        ]
        #expect(HookInstaller.wiredEvents(in: lookalike).isEmpty)
        #expect(deepEqual(HookInstaller.uninstall(from: lookalike), lookalike))
    }

    // MARK: - installChecked aborts on malformed config (item 5)

    @Test("installChecked aborts when `hooks` is present but not an object")
    func installCheckedRejectsMalformedHooks() {
        let bad: [String: Any] = ["hooks": "not-an-object", "model": "opus"]
        #expect(throws: HookInstaller.HookInstallError.self) {
            _ = try HookInstaller.installChecked(into: bad, binaryPath: binary)
        }
    }

    @Test("installChecked aborts when a managed event value is not an array")
    func installCheckedRejectsMalformedEvent() {
        let bad: [String: Any] = ["hooks": ["PreToolUse": "oops"]]
        #expect(throws: HookInstaller.HookInstallError.self) {
            _ = try HookInstaller.installChecked(into: bad, binaryPath: binary)
        }
    }

    @Test("installChecked equals install on well-formed input")
    func installCheckedMatchesInstallOnValidInput() throws {
        let existing = settingsWithOtherTool()
        let checked = try HookInstaller.installChecked(into: existing, binaryPath: binary)
        let plain = HookInstaller.install(into: existing, binaryPath: binary)
        #expect(deepEqual(checked, plain))

        // And from empty.
        let checkedEmpty = try HookInstaller.installChecked(into: [:], binaryPath: binary)
        #expect(deepEqual(checkedEmpty, HookInstaller.install(into: [:], binaryPath: binary)))
    }
}
