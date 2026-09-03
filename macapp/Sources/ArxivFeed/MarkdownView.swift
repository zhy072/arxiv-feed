import SwiftUI

/// Minimal block-level Markdown renderer: headings, lists, quotes, code fences,
/// paragraphs with inline styling. Enough for LLM-generated interpretations.
struct MarkdownView: View {
    let text: String

    private enum Block {
        case heading(String, Int)
        case list([(marker: String, text: String)])
        case quote(String)
        case code(String)
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parse().enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let s, let level):
                    if level <= 2 {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3, height: 15)
                            Text(inline(s)).font(.system(size: 15, weight: .bold))
                        }
                        .padding(.top, 8)
                    } else {
                        Text(inline(s))
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.top, 4)
                    }
                case .list(let items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.marker)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(minWidth: 12, alignment: .trailing)
                                Text(inline(item.text))
                                    .font(.system(size: 14))
                                    .lineSpacing(4)
                            }
                        }
                    }
                case .quote(let s):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.4)).frame(width: 3)
                        Text(inline(s))
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .code(let s):
                    Text(s)
                        .font(.system(size: 12.5, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceSecondary))
                case .paragraph(let s):
                    Text(inline(s))
                        .font(.system(size: 14))
                        .lineSpacing(5)
                }
            }
        }
        .foregroundStyle(Theme.ink)
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    private func parse() -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var items: [(marker: String, text: String)] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushList() {
            if !items.isEmpty {
                blocks.append(.list(items))
                items = []
            }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                }
                inCode.toggle()
                continue
            }
            if inCode {
                codeLines.append(rawLine)
                continue
            }
            if line.isEmpty {
                flushParagraph()
                flushList()
            } else if line.hasPrefix("#") {
                flushParagraph()
                flushList()
                let level = line.prefix(while: { $0 == "#" }).count
                blocks.append(.heading(line.drop(while: { $0 == "#" || $0 == " " }).description, level))
            } else if line.hasPrefix("> ") {
                flushParagraph()
                flushList()
                blocks.append(.quote(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph()
                items.append((marker: "•", text: String(line.dropFirst(2))))
            } else if let (marker, rest) = numberedItem(line) {
                flushParagraph()
                items.append((marker: marker, text: rest))
            } else {
                flushList()
                paragraph.append(line)
            }
        }
        if inCode, !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        flushParagraph()
        flushList()
        return blocks
    }

    /// "1. text" / "2) text" → ("1.", "text")
    private func numberedItem(_ line: String) -> (String, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let punct = rest.first, punct == "." || punct == ")" else { return nil }
        let body = rest.dropFirst()
        guard body.first == " " else { return nil }
        return (String(digits) + ".", body.trimmingCharacters(in: .whitespaces))
    }
}
