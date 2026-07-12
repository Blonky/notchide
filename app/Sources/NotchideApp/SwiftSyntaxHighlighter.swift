import SwiftUI
import Foundation

/// A SMALL, dependency-free Swift keyword highlighter used to color diff text.
///
/// It runs a handful of regexes over one line and paints keywords, capitalized
/// types, numbers, string literals, and comments. It is deliberately shallow —
/// good enough to make a Swift diff readable at a glance.
///
/// SCOPE (v0.1): highlighting is **Swift-only**. Its rules (Swift keyword set,
/// `//` `/* */` comments, `"…"` strings) would mis-color other languages, so any
/// non-Swift file falls back to plain mono via ``highlight(_:language:)``. Real
/// multi-language tree-sitter highlighting (Neon + SwiftTreeSitter +
/// CodeEditLanguages, docs/DESIGN.md §5.4) is a later milestone; those deps are
/// intentionally NOT added here so the app resolves and compiles reliably.
public enum SwiftSyntaxHighlighter {

    /// The language a diff line belongs to, for highlighter scoping.
    public enum Language: Equatable {
        case swift
        /// Any other language — rendered as plain mono in v0.1.
        case other
    }

    /// Classifies a file path into a highlighter language by extension.
    public static func language(forPath path: String) -> Language {
        path.lowercased().hasSuffix(".swift") ? .swift : .other
    }

    /// Highlights a line only when it belongs to a Swift file; every other
    /// language renders as plain mono so we never mis-highlight it.
    public static func highlight(_ line: String, language: Language) -> AttributedString {
        guard language == .swift else { return AttributedString(line) }
        return highlight(line)
    }

    private static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
        "func", "import", "init", "inout", "internal", "let", "open", "operator",
        "private", "protocol", "public", "rethrows", "static", "struct", "subscript",
        "typealias", "var", "actor", "async", "await", "nonisolated", "some", "any",
        "break", "case", "continue", "default", "defer", "do", "else", "fallthrough",
        "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while",
        "as", "catch", "false", "is", "nil", "super", "self", "Self", "throw",
        "throws", "true", "try", "final", "lazy", "weak", "unowned", "mutating",
        "override", "convenience", "required", "indirect", "@escaping", "@MainActor",
        "@Sendable", "@Published", "@State", "@ObservedObject", "@StateObject",
    ]

    // Compiled once. Order matters at apply time (comments/strings win).
    private static let identifierRegex = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*")
    private static let typeRegex = try! NSRegularExpression(pattern: "\\b[A-Z][A-Za-z0-9_]*\\b")
    private static let numberRegex = try! NSRegularExpression(pattern: "\\b\\d[\\d_]*(\\.[\\d_]+)?\\b")
    private static let stringRegex = try! NSRegularExpression(pattern: "\"(\\\\.|[^\"\\\\])*\"")
    private static let commentRegex = try! NSRegularExpression(pattern: "//.*|/\\*.*?\\*/")

    /// Returns a colored `AttributedString` for a single line of code.
    public static func highlight(_ line: String) -> AttributedString {
        guard !line.isEmpty else { return AttributedString(line) }
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Per-character color, defaulting to plain text.
        var colors = [Color](repeating: Theme.synPlain, count: ns.length)
        func paint(_ range: NSRange, _ color: Color) {
            let upper = min(range.location + range.length, colors.count)
            guard range.location >= 0, range.location < colors.count else { return }
            for i in range.location..<upper { colors[i] = color }
        }

        // Apply in precedence order (later wins).
        numberRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            if let r = match?.range { paint(r, Theme.synNumber) }
        }
        typeRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            if let r = match?.range { paint(r, Theme.synType) }
        }
        identifierRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            guard let r = match?.range else { return }
            let word = ns.substring(with: r)
            if keywords.contains(word) { paint(r, Theme.synKeyword) }
        }
        stringRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            if let r = match?.range { paint(r, Theme.synString) }
        }
        commentRegex.enumerateMatches(in: line, range: full) { match, _, _ in
            if let r = match?.range { paint(r, Theme.synComment) }
        }

        // Group consecutive same-color characters into attributed runs.
        var result = AttributedString()
        var runStart = 0
        var index = 1
        func appendRun(_ start: Int, _ end: Int) {
            let substring = ns.substring(with: NSRange(location: start, length: end - start))
            var piece = AttributedString(substring)
            piece.foregroundColor = colors[start]
            result.append(piece)
        }
        while index < colors.count {
            if colors[index] != colors[runStart] {
                appendRun(runStart, index)
                runStart = index
            }
            index += 1
        }
        appendRun(runStart, colors.count)
        return result
    }
}
