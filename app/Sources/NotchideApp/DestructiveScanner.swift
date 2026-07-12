import Foundation

/// A best-effort heuristic that flags likely-destructive tokens in a pending
/// command so the review console can highlight them and show an advisory tag.
///
/// IMPORTANT: this is advisory UI only. It is a shallow, best-effort signal —
/// NOT a safety guarantee. It never changes the decision itself (the write path
/// defaults to caution and requires an explicit human click regardless), and it
/// can both miss destructive commands and over-flag harmless ones. Treat a clean
/// result as "nothing obvious spotted", never as "proven safe".
///
/// Rather than substring matching (which fires on `confirm-rm-later` and misses
/// `rm  -rf`), it lexes the command into words + shell operators — respecting
/// quotes — and reasons about actual argv tokens per command segment.
public enum DestructiveScanner {

    /// Returns the destructive markers found in `command` (empty when none).
    public static func scan(_ command: String?) -> [String] {
        guard let command else { return [] }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var found: [String] = []
        func add(_ marker: String) {
            if !found.contains(marker) { found.append(marker) }
        }

        let tokens = Lexer.tokenize(trimmed)

        // Walk command segments split on shell control operators.
        for segment in Self.segments(tokens) {
            scanSegment(segment, add: add)
        }

        // Fork bomb: `:(){ :|:& };:` — detect the classic definition regardless
        // of segmentation.
        if trimmed.replacingOccurrences(of: " ", with: "").contains(":(){") {
            add("fork bomb")
        }

        return found
    }

    // MARK: - Per-segment analysis

    private static func scanSegment(_ segment: [Token], add: (String) -> Void) {
        let words = segment.compactMap { token -> String? in
            if case let .word(value) = token { return value }
            return nil
        }
        let lower = words.map { $0.lowercased() }
        guard let firstWordIndex = lower.firstIndex(where: { !$0.isEmpty }) else {
            // No command word (e.g. a bare redirection). Still check redirects.
            checkRedirections(segment, add: add)
            return
        }

        // Skip a leading `sudo`; note elevated privilege when combined with a
        // destructive command.
        var commandIndex = firstWordIndex
        let elevated = lower[commandIndex] == "sudo"
        if elevated {
            commandIndex = lower[(commandIndex + 1)...].firstIndex(where: { !$0.isEmpty }) ?? commandIndex
        }
        let command = lower[safe: commandIndex] ?? ""
        let args = Array(lower[(commandIndex + 1)...])

        switch command {
        case "rm":
            if hasFlag(args, short: "rf", long: ["--recursive", "--force", "--dir"]) {
                add(elevated ? "sudo rm -rf" : "rm -rf")
            }
        case "dd":
            add("dd")
        case "shred":
            add("shred")
        case "mkfs":
            add("mkfs")
        case "chmod" where hasFlag(args, short: "r", long: ["--recursive"]):
            add("chmod -R")
        case "chown" where hasFlag(args, short: "r", long: ["--recursive"]):
            add("chown -R")
        case "git":
            scanGit(args, add: add)
        case "diskutil" where args.contains("erasedisk") || args.contains("erasevolume") || args.contains("reformat"):
            add("diskutil erase")
        case "shutdown", "reboot", "halt", "poweroff":
            add(command)
        case "killall":
            add("killall")
        case "kill" where args.contains("-9") || args.contains("-kill"):
            add("kill -9")
        default:
            // `mkfs.ext4`, `mkfs.hfs`, … as a single token.
            if command.hasPrefix("mkfs") { add("mkfs") }
        }

        // `sudo` on its own is worth surfacing (elevated privilege).
        if elevated { add("sudo") }

        checkRedirections(segment, add: add)
    }

    private static func scanGit(_ args: [String], add: (String) -> Void) {
        guard let sub = args.first(where: { !$0.hasPrefix("-") }) else { return }
        switch sub {
        case "clean":
            // `git clean -fd`, `-fdx`, `-xdf`, … : force + directories.
            if hasFlag(args, short: "f", long: ["--force"]),
               hasFlag(args, short: "dx", long: []) {
                add("git clean -fdx")
            } else if hasFlag(args, short: "f", long: ["--force"]) {
                add("git clean -f")
            }
        case "reset":
            if args.contains("--hard") { add("git reset --hard") }
        case "push":
            if args.contains("--force") || args.contains("-f") || args.contains("--force-with-lease") {
                add("git push --force")
            }
        case "checkout":
            if args.contains("--force") || args.contains("-f") { add("git checkout --force") }
        default:
            break
        }
    }

    /// Flags `>` truncation of a non-`/dev` path (`> file`, `:> file`). `>>`
    /// (append) is intentionally not flagged.
    private static func checkRedirections(_ segment: [Token], add: (String) -> Void) {
        for (i, token) in segment.enumerated() {
            guard case let .op(op) = token, op == ">" else { continue }
            // The redirect target is the next word token, if any.
            let target = segment[(i + 1)...].compactMap { t -> String? in
                if case let .word(value) = t { return value }
                return nil
            }.first
            if let target, target.hasPrefix("/dev/") { continue }
            add("> truncate")
            return
        }
        // `truncate -s 0 file`
        let words = segment.compactMap { t -> String? in
            if case let .word(value) = t { return value.lowercased() }
            return nil
        }
        if words.first == "truncate", words.contains("0") { add("truncate -s 0") }
    }

    // MARK: - Flag helpers

    /// Whether `args` contains any bundled short flag from `short` (e.g. `-rf`
    /// matches `short: "r"`) or any exact long flag from `long`. Case-insensitive,
    /// so it is robust to callers passing already-lowercased argv tokens (where
    /// `-R` has become `-r`).
    private static func hasFlag(_ args: [String], short: String, long: [String]) -> Bool {
        let shortSet = Set(short.lowercased())
        let longSet = Set(long.map { $0.lowercased() })
        for raw in args {
            let arg = raw.lowercased()
            if longSet.contains(arg) { return true }
            if arg.hasPrefix("--") { continue }
            if arg.hasPrefix("-"), arg.count > 1 {
                if arg.dropFirst().contains(where: { shortSet.contains($0) }) { return true }
            }
        }
        return false
    }

    // MARK: - Segmentation

    /// Splits a token stream into command segments on control operators
    /// (`|`, `||`, `&&`, `;`, `&`). Redirections stay within their segment.
    private static func segments(_ tokens: [Token]) -> [[Token]] {
        var result: [[Token]] = []
        var current: [Token] = []
        for token in tokens {
            if case let .op(op) = token, ["|", "||", "&&", ";", "&"].contains(op) {
                if !current.isEmpty { result.append(current) }
                current = []
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

// MARK: - Tiny shell lexer

/// One lexed shell token: a plain word or a control/redirection operator.
enum Token: Equatable {
    case word(String)
    case op(String)
}

/// A minimal, quote-aware lexer. It recognizes the shell operators notchide's
/// heuristic cares about and treats everything else as words, so operators
/// inside quotes are not mistaken for control characters.
enum Lexer {
    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var word = ""
        var quote: Character? = nil
        let chars = Array(input)
        var i = 0

        func flushWord() {
            if !word.isEmpty { tokens.append(.word(word)); word = "" }
        }

        while i < chars.count {
            let c = chars[i]

            if let q = quote {
                if c == q { quote = nil } else { word.append(c) }
                i += 1
                continue
            }

            switch c {
            case "'", "\"":
                quote = c
                i += 1
            case " ", "\t", "\n":
                flushWord()
                i += 1
            case "|", "&":
                flushWord()
                // Collapse doubled operators (`||`, `&&`).
                if i + 1 < chars.count, chars[i + 1] == c {
                    tokens.append(.op(String(c) + String(c)))
                    i += 2
                } else {
                    tokens.append(.op(String(c)))
                    i += 1
                }
            case ";":
                flushWord()
                tokens.append(.op(";"))
                i += 1
            case ">":
                flushWord()
                if i + 1 < chars.count, chars[i + 1] == ">" {
                    tokens.append(.op(">>"))
                    i += 2
                } else {
                    tokens.append(.op(">"))
                    i += 1
                }
            case "<":
                flushWord()
                tokens.append(.op("<"))
                i += 1
            default:
                word.append(c)
                i += 1
            }
        }
        flushWord()
        return tokens
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
