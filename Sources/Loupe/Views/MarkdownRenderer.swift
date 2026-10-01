import SwiftUI

/// A minimal block-level Markdown model. `Text(AttributedString(markdown:))`
/// only styles inline spans — it collapses headings, lists, code blocks, and
/// paragraph breaks into run-together text, which looked broken. So we parse
/// the document into blocks ourselves and render each with the right structure,
/// using `AttributedString` only for inline emphasis/links within a line.
enum MarkdownBlock: Identifiable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(items: [String])
    case ordered(items: [String])
    case codeBlock(String)
    case quote([String])
    case rule

    var id: String {
        switch self {
        case .heading(let l, let t): return "h\(l):\(t)"
        case .paragraph(let t): return "p:\(t)"
        case .bullet(let items): return "ul:\(items.joined(separator: "|"))"
        case .ordered(let items): return "ol:\(items.joined(separator: "|"))"
        case .codeBlock(let c): return "code:\(c.prefix(40))\(c.count)"
        case .quote(let lines): return "q:\(lines.joined(separator: "|"))"
        case .rule: return "hr:\(UUID().uuidString)"
        }
    }
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1 // consume closing fence
                blocks.append(.codeBlock(code.joined(separator: "\n")))
                continue
            }

            // Blank line ends a paragraph.
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // ATX heading.
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                i += 1
                continue
            }

            // Blockquote (consecutive `>` lines).
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces)
                    q.removeFirst()
                    quote.append(q.trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote))
                continue
            }

            // Unordered list.
            if isBullet(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripBullet(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.bullet(items: items))
                continue
            }

            // Ordered list.
            if isOrdered(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isOrdered(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripOrdered(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.ordered(items: items))
                continue
            }

            // Otherwise accumulate into a paragraph.
            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " || rest.isEmpty else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func stripBullet(_ line: String) -> String {
        String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func isOrdered(_ line: String) -> Bool {
        // e.g. "1. " / "12) "
        guard let dotRange = line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) else {
            return false
        }
        return dotRange.lowerBound == line.startIndex
    }

    private static func stripOrdered(_ line: String) -> String {
        guard let r = line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) else { return line }
        return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}

/// Renders parsed Markdown blocks as native SwiftUI views with proper hierarchy.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .fontWeight(.bold)
                .foregroundStyle(.black)
                .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let text):
            inlineText(text)
                .font(.body)
                .foregroundStyle(.black)
                .lineSpacing(3)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inlineText(item).foregroundStyle(.black)
                    }
                }
            }

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        inlineText(item).foregroundStyle(.black)
                    }
                }
            }

        case .codeBlock(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.black)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 8))

        case .quote(let lines):
            HStack(spacing: 10) {
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        inlineText(l).foregroundStyle(.secondary)
                    }
                }
            }

        case .rule:
            Divider()
        }
    }

    /// Renders a single line with inline Markdown (bold/italic/code/links).
    private func inlineText(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            return Text(attributed)
        }
        return Text(string)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 30)
        case 2: return .system(size: 24)
        case 3: return .system(size: 20)
        case 4: return .system(size: 17)
        default: return .system(size: 15)
        }
    }
}
