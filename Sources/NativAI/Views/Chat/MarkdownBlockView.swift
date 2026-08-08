/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI
import AppKit

/// A lightweight block-level markdown renderer for chat messages.
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
        case codeBlock(text: String, language: String?)
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
        var codeBlockLanguage: String? = nil
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
        func flushNumbered() {
            if !currentNumberedItems.isEmpty {
                blocks.append(.numberedList(items: currentNumberedItems))
                currentNumberedItems = []
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks (```swift ... ```)
            if line.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(.codeBlock(text: codeBlockLines.joined(separator: "\n"), language: codeBlockLanguage))
                    codeBlockLines = []
                    codeBlockLanguage = nil
                    inCodeBlock = false
                } else {
                    flushParagraph(); flushBullets(); flushNumbered()
                    inCodeBlock = true
                    let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    codeBlockLanguage = lang.isEmpty ? nil : lang
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
            if let bulletText = matchBullet(line) {
                flushParagraph()
                currentBulletItems.append(bulletText)
                continue
            }

            // Numbered list items: "1. ", "2. ", etc.
            if let numberedMatch = matchNumbered(line) {
                flushParagraph(); flushBullets()
                currentNumberedItems.append(numberedMatch)
                continue
            }

            flushBullets(); flushNumbered()
            currentParagraphLines.append(line)
        }

        flushParagraph(); flushBullets(); flushNumbered()
        if inCodeBlock, !codeBlockLines.isEmpty {
            blocks.append(.codeBlock(text: codeBlockLines.joined(separator: "\n"), language: codeBlockLanguage))
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

        case .codeBlock(let text, let language):
            CodeBlockContainerView(text: text, language: language)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .system(size: 17, weight: .bold)
        case 2: return .system(size: 15.5, weight: .bold)
        default: return .system(size: 14, weight: .semibold)
        }
    }

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

/// Rich Code Block container view with Copy Code button and language badge.
struct CodeBlockContainerView: View {
    let text: String
    let language: String?
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        didCopy = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        Text(didCopy ? "Copied" : "Copy Code")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(didCopy ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))

            Divider()

            ScrollView(.horizontal, showsIndicators: true) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
        )
    }
}
