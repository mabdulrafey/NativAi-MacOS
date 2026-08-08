/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Handles exporting chat sessions into Markdown (.md), HTML (.html), and PDF (.pdf).
enum SessionExportService {

    /// Exports a chat session to a Markdown file.
    static func exportToMarkdown(session: ChatSession) -> String {
        var result = "# \(session.title)\n\n"
        result += "_Exported from NativAI on \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))_\n\n---\n\n"

        for msg in session.messages {
            let roleLabel = msg.role == "user" ? "👤 **User**" : "🤖 **NativAI (\(msg.modelUsed ?? "Assistant"))**"
            result += "\(roleLabel):\n\n\(msg.content)\n\n---\n\n"
        }
        return result
    }

    /// Exports a chat session to a clean, styled HTML string.
    static func exportToHTML(session: ChatSession) -> String {
        let title = session.title.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")

        var messagesHTML = ""
        for msg in session.messages {
            let isUser = msg.role == "user"
            let badge = isUser ? "User" : (msg.modelUsed ?? "NativAI")
            let bgClass = isUser ? "user-msg" : "assistant-msg"
            let contentEscaped = msg.content
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>")

            messagesHTML += """
            <div class="message \(bgClass)">
                <div class="sender-badge">\(badge)</div>
                <div class="message-content">\(contentEscaped)</div>
            </div>
            """
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>\(title) - NativAI Export</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    background-color: #1e1e24;
                    color: #e0e0e6;
                    margin: 0;
                    padding: 30px;
                    line-height: 1.6;
                }
                .container {
                    max-width: 800px;
                    margin: 0 auto;
                }
                h1 {
                    color: #ffffff;
                    border-bottom: 2px solid #3a3a46;
                    padding-bottom: 10px;
                }
                .meta {
                    color: #8e8e93;
                    font-size: 0.9em;
                    margin-bottom: 30px;
                }
                .message {
                    border-radius: 12px;
                    padding: 16px 20px;
                    margin-bottom: 20px;
                }
                .user-msg {
                    background-color: #2c2c36;
                    border-left: 4px solid #007aff;
                }
                .assistant-msg {
                    background-color: #252530;
                    border-left: 4px solid #34c759;
                }
                .sender-badge {
                    font-weight: 600;
                    font-size: 0.85em;
                    text-transform: uppercase;
                    letter-spacing: 0.5px;
                    margin-bottom: 8px;
                    color: #a1a1aa;
                }
                .message-content {
                    font-size: 1.05em;
                    white-space: pre-wrap;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>\(title)</h1>
                <div class="meta">Exported from NativAI on \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))</div>
                \(messagesHTML)
            </div>
        </body>
        </html>
        """
    }

    /// Prompts the user to save the session in the chosen format (.md, .html, or .pdf).
    @MainActor
    static func promptSaveSession(_ session: ChatSession, format: ExportFormat, window: NSWindow?) {
        let savePanel = NSSavePanel()
        savePanel.title = "Export Chat Session"
        savePanel.nameFieldStringValue = "\(session.title.lowercased().replacingOccurrences(of: " ", with: "_")).\(format.fileExtension)"
        savePanel.allowedContentTypes = [format.contentType]

        savePanel.beginSheetModal(for: window ?? NSApp.keyWindow ?? NSWindow()) { response in
            guard response == .OK, let url = savePanel.url else { return }

            switch format {
            case .markdown:
                let content = exportToMarkdown(session: session)
                try? content.write(to: url, atomically: true, encoding: .utf8)
            case .html:
                let content = exportToHTML(session: session)
                try? content.write(to: url, atomically: true, encoding: .utf8)
            case .pdf:
                let printView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
                printView.string = exportToMarkdown(session: session)
                let pdfData = printView.dataWithPDF(inside: printView.bounds)
                try? pdfData.write(to: url)
            }
        }
    }

    enum ExportFormat {
        case markdown, html, pdf

        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .html: return "html"
            case .pdf: return "pdf"
            }
        }

        var contentType: UTType {
            switch self {
            case .markdown: return .plainText
            case .html: return .html
            case .pdf: return .pdf
            }
        }
    }
}
