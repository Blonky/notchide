import Foundation

/// A tiny heuristic that flags destructive tokens in a pending command so the
/// review console can highlight them in red and show a "destructive" tag.
///
/// This is intentionally conservative pattern-matching (the write path defaults
/// to caution, never auto-approval). It is advisory UI only — it never changes
/// the decision itself.
public enum DestructiveScanner {

    /// Substrings whose presence marks a command destructive. Case-insensitive.
    private static let patterns: [String] = [
        "rm -rf", "rm -fr", "rm -r", "rm -f",
        "sudo ", "mkfs", "dd if=", "dd of=",
        "git push --force", "git push -f", "git reset --hard", "git clean -fd",
        ":(){", "chmod -R", "chown -R", "> /dev/", "truncate -s 0",
        "shutdown", "reboot", "killall", "diskutil erase", "kill -9",
        "curl | sh", "curl | bash", "wget | sh", "npm publish", "drop table", "DROP TABLE",
    ]

    /// Returns the destructive tokens found in `command` (empty when none).
    public static func scan(_ command: String?) -> [String] {
        guard let command else { return [] }
        let haystack = command.lowercased()
        var found: [String] = []
        for pattern in patterns {
            if haystack.contains(pattern.lowercased()) {
                found.append(pattern.trimmingCharacters(in: .whitespaces))
            }
        }
        return found
    }
}
