/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI

/// A lightweight block-level markdown renderer for chat messages.
///
/// Why this exists: SwiftUI's `Text(AttributedString(markdown:))` can only
/// render *inline* attributes (bold/italic/code span) within one continuous
/// text flow — it cannot render block-level structure (separate paragraphs,
/// headers, bullet lists) as visually distinct elements, even when parsed
/// with `.full` syntax. Parsing with `.full` correctly identifies "this is a
/// heading" / "this is a new paragraph" / "this is a list item" as separate
/// blocks, but `Text` then silently collapses them all into one unbroken run
/// with no spacing — which is exactly the squished, no-paragraph-breaks
/// output this was built to fix. This renderer manually splits the raw
/// markdown into blocks (by blank lines / heading markers / list markers)
/// and renders each block as its own SwiftUI view with real vertical spacing,
/// indentation, and bullet glyphs.
struct MarkdownBlockView: View {
    let raw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks(raw).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - Block model

    private enum Block {
        case heading(text: String, level: Int)
        case bulletList(items: [String])
        case numberedList(items: [(number: Int, text: String)])
        case codeBlock(text: String)
        case paragraph(text: String)
    }

    // MARK: - Parsing

    private func parseBlocks(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var currentParagraphLines: [String] = []
        var currentBulletItems: [String] = []
        var currentNumberedItems: [(number: Int, text: String)] = []
        var inCodeBlock = false
        var codeBlockLines: [String] = []

        func flushParagraph() {
            if !currentParagraphLines.isEmpty {
                let joined = currentParagraphLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !joined.isEmpty { blocks.append(.paragraph(text: joined)) }
                currentParagraphLines = []
            }
        }
        func flushBullets() {
            if !currentBulletItems.isEmpty {
                blocks.append(.bulletList(items: currentBulletItems))
                currentBulletItems = []
            }
        }
        // Deliberately NOT flushed when a bullet sub-list interrupts a
        // numbered sequence (e.g. "1. Heading" followed by "- sub bullet"
        // followed by "2. Next heading") — model output commonly nests
        // bullets under numbered steps. Flushing on every interruption is
        // what caused every numbered item to become an isolated single-item
        // list that always rendered as "1." regardless of its real position.
        func flushNumbered() {
            if !currentNumberedItems.isEmpty {
                blocks.append(.numberedList(items: currentNumberedItems))
                currentNumberedItems = []
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks (```...```)
            if line.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(.codeBlock(text: codeBlockLines.joined(separator: "\n")))
                    codeBlockLines = []
                    inCodeBlock = false
                } else {
                    flushParagraph(); flushBullets(); flushNumbered()
                    inCodeBlock = true
                }
                continue
            }
            if inCodeBlock {
                codeBlockLines.append(rawLine)
                continue
            }

            if line.isEmpty {
                flushParagraph(); flushBullets(); flushNumbered()
                continue
            }

            // Headings: # / ## / ###
            if let headingMatch = matchHeading(line) {
                flushParagraph(); flushBullets(); flushNumbered()
                blocks.append(.heading(text: headingMatch.text, level: headingMatch.level))
                continue
            }

            // Bullet list items: -, *, •
            // Note: does NOT flush an in-progress numbered list — model
            // output frequently nests bullets under a numbered step, and
            // flushing here was the root cause of every numbered item
            // rendering as "1." (each one became an isolated single-item list).
            if let bulletText = matchBullet(line) {
                flushParagraph()
                currentBulletItems.append(bulletText)
                continue
            }

            // Numbered list items: "1. ", "2. ", etc. Preserves the actual
            // number the model wrote, rather than re-deriving it from array
            // position — needed because bullets interrupting the sequence
            // mean "array position" no longer matches the model's intended
            // step number once nesting is involved.
            if let numberedMatch = matchNumbered(line) {
                flushParagraph(); flushBullets()
                currentNumberedItems.append(numberedMatch)
                continue
            }

            // Otherwise: accumulate into the current paragraph. This DOES
            // flush both lists, since plain prose genuinely ends any list.
            flushBullets(); flushNumbered()
            currentParagraphLines.append(line)
        }

        flushParagraph(); flushBullets(); flushNumbered()
        if inCodeBlock, !codeBlockLines.isEmpty {
            blocks.append(.codeBlock(text: codeBlockLines.joined(separator: "\n")))
        }
        return blocks
    }

    private func matchHeading(_ line: String) -> (text: String, level: Int)? {
        var level = 0
        var rest = Substring(line)
        while rest.first == "#" {
            level += 1
            rest = rest.dropFirst()
        }
        guard level > 0, level <= 6, rest.first == " " else { return nil }
        return (String(rest.dropFirst()).trimmingCharacters(in: .whitespaces), level)
    }

    private func matchBullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] {
            if line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count))
            }
        }
        return nil
    }

    private func matchNumbered(_ line: String) -> (number: Int, text: String)? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let prefix = line[line.startIndex..<dotIndex]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }), let number = Int(prefix) else { return nil }
        let afterDot = line.index(after: dotIndex)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return (number, String(line[line.index(after: afterDot)...]))
    }

    // MARK: - Rendering

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let text, let level):
            inlineText(text)
                .font(headingFont(for: level))
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let text):
            inlineText(text)
                .fixedSize(horizontal: false, vertical: true)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        inlineText(item)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(item.number).")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        inlineText(item.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .codeBlock(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .system(size: 17, weight: .bold)
        case 2: return .system(size: 15.5, weight: .bold)
        default: return .system(size: 14, weight: .semibold)
        }
    }

    /// Renders inline markdown (bold/italic/code span) within a single block
    /// of text — this is the one place AttributedString's markdown parsing
    /// is actually the right tool, since we've already split out block
    /// structure ourselves above.
    private func inlineText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }
}
