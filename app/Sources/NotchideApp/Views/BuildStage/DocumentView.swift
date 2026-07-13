import SwiftUI

/// Renders a `.document(markdown:)` artifact (DESIGN §14) as **readable text** — a
/// written answer, plan, or report.
///
/// A deliberately small block parser handles the shapes that show up in agent
/// output — headings, bullets, ordered items, block quotes, fenced code, rules —
/// and renders inline emphasis/code via `AttributedString(markdown:)`. It is a
/// readability pass, not a spec-complete CommonMark renderer.
public struct DocumentView: View {
    let markdown: String

    public init(markdown: String) {
        self.markdown = markdown
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.md)
        }
        .frame(maxHeight: 300)
        .buildCard()
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, level <= 2 ? Theme.Spacing.xs : 0)

        case .paragraph(let text):
            Text(inline(text))
                .font(Typo.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let text):
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Text("•")
                    .font(Typo.body)
                    .foregroundStyle(Theme.flowing)
                Text(inline(text))
                    .font(Typo.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, Theme.Spacing.sm)

        case .ordered(let number, let text):
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Text("\(number).")
                    .font(Typo.monoSmall)
                    .foregroundStyle(Theme.flowing)
                Text(inline(text))
                    .font(Typo.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, Theme.Spacing.sm)

        case .quote(let text):
            HStack(spacing: Theme.Spacing.sm) {
                Rectangle()
                    .fill(Theme.hairlineStrong)
                    .frame(width: 2)
                Text(inline(text))
                    .font(Typo.body)
                    .foregroundStyle(Theme.textTertiary)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let code):
            Text(code)
                .font(Typo.monoSmall)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(Theme.Spacing.sm)
                .background(Theme.sunkenSurface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )

        case .rule:
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, Theme.Spacing.xs)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 16
        case 2: return 14
        default: return 13
        }
    }

    /// Inline emphasis/code via the system markdown parser; falls back to plain.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// A block-level element of a lightweight markdown document.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case ordered(number: Int, text: String)
    case quote(String)
    case code(String)
    case rule

    /// Splits `source` into blocks. Line-oriented: fenced ``` blocks are captured
    /// verbatim; consecutive plain lines coalesce into one paragraph.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        let rawLines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < rawLines.count {
            let line = rawLines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block: gather until the closing fence.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < rawLines.count && !rawLines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(rawLines[index])
                    index += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                index += 1 // consume the closing fence
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
            } else if let heading = headingBlock(trimmed) {
                flushParagraph()
                blocks.append(heading)
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else if let ordered = orderedBlock(trimmed) {
                flushParagraph()
                blocks.append(ordered)
            } else {
                paragraph.append(trimmed)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func headingBlock(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var rest = Substring(line)
        while rest.first == "#" && level < 6 {
            level += 1
            rest = rest.dropFirst()
        }
        guard rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func orderedBlock(_ line: String) -> MarkdownBlock? {
        // "1. text" / "12. text"
        let parts = line.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let number = Int(parts[0]),
              parts[1].hasPrefix(" ") else { return nil }
        return .ordered(number: number, text: parts[1].trimmingCharacters(in: .whitespaces))
    }
}
