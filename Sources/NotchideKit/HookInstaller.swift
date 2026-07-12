import Foundation

/// Pure, I/O-free logic for merging notchide's hook handlers into (and removing
/// them from) a Claude Code `settings.json` structure.
///
/// Everything here operates on an in-memory `[String: Any]` — the shape you get
/// from `JSONSerialization.jsonObject(with:)` on a `settings.json` file — so the
/// merge/unmerge is fully unit-testable without touching the real `~/.claude`.
/// The `notchide-hook` CLI is the only thing that does the actual file I/O; it
/// reads the file, calls these functions, and writes the result back.
///
/// ## settings.json shape (verified against https://code.claude.com/docs/en/hooks)
///
/// ```json
/// {
///   "hooks": {
///     "PreToolUse": [
///       {
///         "matcher": "*",
///         "hooks": [ { "type": "command", "command": "…" } ]
///       }
///     ]
///   }
/// }
/// ```
///
/// Three nesting levels: the top-level `hooks` object maps each **event name**
/// to an **array of matcher groups**; each group has an optional `matcher` and a
/// `hooks` array of command **handlers**. `PreToolUse` carries `matcher: "*"`;
/// `Notification` / `Stop` / `SubagentStop` omit the matcher (per the docs, the
/// matcher is optional/ignored for these), so notchide writes them without one.
public enum HookInstaller {

    /// The four hook events notchide wires, in the order it presents them.
    public static let managedEvents = ["PreToolUse", "Notification", "Stop", "SubagentStop"]

    /// The executable basename that uniquely identifies a hook handler as
    /// notchide's own. A handler is treated as belonging to notchide iff the
    /// basename of its command's first (executable) shell token equals this —
    /// a precise match, not a loose substring, so an unrelated tool whose
    /// command merely mentions "notchide-hook" is never touched.
    static let marker = "notchide-hook"

    /// The `matcher` value for an event, or `nil` when the event omits it.
    static func matcher(for event: String) -> String? {
        event == "PreToolUse" ? "*" : nil
    }

    /// The exact `command` string notchide writes for an event:
    /// `"'<abs-path-to-binary>' handle <EventName>"`.
    ///
    /// The binary path is single-quoted (with any embedded single quote escaped
    /// as `'\''`) so a path containing spaces or shell metacharacters is passed
    /// to the shell as a single argument and the gate actually fires. Detection
    /// and uninstall parse this quoting back out (see `firstShellToken`).
    public static func command(for event: String, binaryPath: String) -> String {
        "\(shellSingleQuote(binaryPath)) handle \(event)"
    }

    /// Wraps a string in single quotes for safe use as one shell word, escaping
    /// any embedded single quote using the standard `'\''` idiom.
    static func shellSingleQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Extracts the first shell token (the executable word) from a command
    /// string, honoring single-quote quoting and backslash escaping the way a
    /// POSIX shell would. Returns `nil` for an empty/blank command.
    ///
    /// This is what makes detection robust to quoted, spaced paths: for
    /// `'/Users/My Apps/notchide-hook' handle PreToolUse` it returns
    /// `/Users/My Apps/notchide-hook`, and for the legacy unquoted
    /// `/usr/local/bin/notchide-hook handle PreToolUse` it returns
    /// `/usr/local/bin/notchide-hook`.
    static func firstShellToken(_ command: String) -> String? {
        var result = ""
        var inSingleQuote = false
        var started = false
        let chars = Array(command)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inSingleQuote {
                if c == "'" {
                    inSingleQuote = false
                } else {
                    result.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case "'":
                inSingleQuote = true
                started = true
                i += 1
            case "\\":
                // Backslash escapes the next character (POSIX, outside quotes).
                if i + 1 < chars.count {
                    result.append(chars[i + 1])
                    i += 2
                } else {
                    i += 1
                }
                started = true
            case " ", "\t":
                if started { return result } // end of the first token
                i += 1 // skip leading whitespace
            default:
                result.append(c)
                started = true
                i += 1
            }
        }
        return started ? result : nil
    }

    // MARK: - Install (merge)

    /// Returns a NEW settings dictionary with notchide's hooks merged in for all
    /// four managed events, pointing each handler at `binaryPath`.
    ///
    /// Guarantees:
    /// - All existing, unrelated settings are preserved.
    /// - Existing hooks from other tools are preserved; notchide's group is
    ///   **appended** to each event's array, never replacing anything.
    /// - Idempotent: re-running never duplicates notchide's entries (and updates
    ///   the command if `binaryPath` changed), because it first strips any
    ///   existing notchide entries and then re-adds fresh ones.
    ///
    /// The input dictionary is not mutated.
    public static func install(into settings: [String: Any], binaryPath: String) -> [String: Any] {
        // Strip any prior notchide entries first so the result is identical
        // whether or not notchide was already installed (idempotency) and so a
        // changed binary path takes effect.
        var result = uninstall(from: settings)
        var hooks = (result["hooks"] as? [String: Any]) ?? [:]

        for event in managedEvents {
            var groups = (hooks[event] as? [Any]) ?? []
            let handler: [String: Any] = ["type": "command", "command": command(for: event, binaryPath: binaryPath)]
            var group: [String: Any] = ["hooks": [handler]]
            if let matcher = matcher(for: event) {
                group["matcher"] = matcher
            }
            groups.append(group)
            hooks[event] = groups
        }

        result["hooks"] = hooks
        return result
    }

    /// Thrown by `installChecked` when the existing config cannot be safely
    /// merged into without risking data loss.
    public enum HookInstallError: Error, Equatable {
        /// The existing `hooks` value — or a managed event's value — is present
        /// but has an unexpected shape. The associated string explains which.
        case malformedHooks(String)
    }

    /// Shape-validating variant of `install`.
    ///
    /// `install` assumes a well-formed settings dict and, on a malformed
    /// `hooks` object (or a non-array event value), would silently discard it.
    /// `installChecked` instead ABORTS by throwing `HookInstallError` so the
    /// caller can refuse to clobber the user's config. On well-formed input it
    /// is identical to `install`. This is the entry point the `notchide-hook`
    /// CLI uses.
    public static func installChecked(into settings: [String: Any], binaryPath: String) throws -> [String: Any] {
        if let hooksAny = settings["hooks"] {
            guard let hooks = hooksAny as? [String: Any] else {
                throw HookInstallError.malformedHooks(
                    "`hooks` is present but is not a JSON object")
            }
            for event in managedEvents {
                if let eventValue = hooks[event], !(eventValue is [Any]) {
                    throw HookInstallError.malformedHooks(
                        "`hooks.\(event)` is present but is not an array")
                }
            }
        }
        return install(into: settings, binaryPath: binaryPath)
    }

    // MARK: - Uninstall (unmerge)

    /// Returns a NEW settings dictionary with ONLY notchide's hook handlers
    /// removed, leaving every other setting and every other tool's hooks intact.
    ///
    /// Cleans up containers that removing notchide leaves empty: a matcher group
    /// whose handler list becomes empty is dropped, an event whose group list
    /// becomes empty is removed, and the top-level `hooks` object is removed if
    /// it ends up empty. Containers that were already empty (and did not hold a
    /// notchide entry) are left untouched.
    ///
    /// The input dictionary is not mutated.
    public static func uninstall(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard let hooks = result["hooks"] as? [String: Any] else {
            return result
        }

        var newHooks: [String: Any] = [:]
        var anyChange = false

        for (event, value) in hooks {
            guard let groups = value as? [Any] else {
                newHooks[event] = value
                continue
            }

            var newGroups: [Any] = []
            var eventChanged = false

            for groupAny in groups {
                guard var group = groupAny as? [String: Any],
                      let handlers = group["hooks"] as? [Any] else {
                    newGroups.append(groupAny)
                    continue
                }

                let filtered = handlers.filter { !handlerIsNotchide($0) }
                if filtered.count == handlers.count {
                    // No notchide handler in this group; leave it exactly as-is.
                    newGroups.append(groupAny)
                    continue
                }

                eventChanged = true
                if filtered.isEmpty {
                    // We emptied this group by removing notchide; drop it.
                    continue
                }
                group["hooks"] = filtered
                newGroups.append(group)
            }

            if !eventChanged {
                newHooks[event] = value
                continue
            }

            anyChange = true
            // If newGroups is empty we omit the event key entirely (cleanup).
            if !newGroups.isEmpty {
                newHooks[event] = newGroups
            }
        }

        if newHooks.isEmpty && anyChange {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = newHooks
        }
        return result
    }

    // MARK: - Inspect (doctor)

    /// Returns the subset of the four managed events currently wired to notchide
    /// in the given settings dictionary.
    public static func wiredEvents(in settings: [String: Any]) -> Set<String> {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var wired: Set<String> = []
        for event in managedEvents {
            guard let groups = hooks[event] as? [Any] else { continue }
            let hasNotchide = groups.contains { groupAny in
                guard let group = groupAny as? [String: Any],
                      let handlers = group["hooks"] as? [Any] else { return false }
                return handlers.contains { handlerIsNotchide($0) }
            }
            if hasNotchide { wired.insert(event) }
        }
        return wired
    }

    // MARK: - Helpers

    /// True when a hook handler is one of notchide's: the basename of its
    /// command's first (executable) shell token equals `notchide-hook`.
    ///
    /// This is a precise match. An unrelated tool whose command merely contains
    /// the text "notchide-hook" (e.g. `/opt/notchide-hook-wrapper/run`, whose
    /// basename is `run`) is NOT matched, so uninstall never removes it. Quoted
    /// and spaced paths are handled via `firstShellToken`.
    private static func handlerIsNotchide(_ handler: Any) -> Bool {
        guard let dict = handler as? [String: Any],
              let command = dict["command"] as? String,
              let token = firstShellToken(command) else { return false }
        return (token as NSString).lastPathComponent == marker
    }
}
