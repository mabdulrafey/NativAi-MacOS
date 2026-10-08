/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation
import AppKit
import PDFKit
import CoreText
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
                exportToPDF(session: session, to: url)
            }
        }
    }

    /// Exports a chat session to a multi-page paginated PDF with full typography and no message truncation.
    static func exportToPDF(session: ChatSession, to url: URL) {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // Standard US Letter (8.5 x 11 in)
        var mediaBox = pageRect

        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return
        }

        let attrString = buildAttributedTranscript(session: session)
        let framesetter = CTFramesetterCreateWithAttributedString(attrString as CFAttributedString)

        let margin: CGFloat = 44
        let footerHeight: CGFloat = 28
        let textRect = CGRect(
            x: margin,
            y: margin,
            width: pageRect.width - (margin * 2),
            height: pageRect.height - (margin * 2) - footerHeight
        )

        var textRange = CFRange(location: 0, length: 0)
        var pageIndex = 1

        while textRange.location < attrString.length {
            context.beginPage(mediaBox: &mediaBox)

            // 1. Draw text frame using CoreText in flipped coordinate space
            context.saveGState()
            context.translateBy(x: 0, y: pageRect.height)
            context.scaleBy(x: 1.0, y: -1.0)

            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, textRange, path, nil)
            CTFrameDraw(frame, context)

            let frameRange = CTFrameGetVisibleStringRange(frame)
            if frameRange.length == 0 {
                context.restoreGState()
                context.endPage()
                break
            }
            textRange.location += frameRange.length
            context.restoreGState()

            // 2. Draw running footer in bottom coordinate space
            drawFooter(context: context, pageNumber: pageIndex, pageRect: pageRect, margin: margin)

            context.endPage()
            pageIndex += 1
        }

        context.closePDF()
    }

    private static func buildAttributedTranscript(session: ChatSession) -> NSAttributedString {
        let full = NSMutableAttributedString()

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = 4
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 20),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: titleStyle
        ]
        full.append(NSAttributedString(string: "\(session.title)\n", attributes: titleAttrs))

        let metaStyle = NSMutableParagraphStyle()
        metaStyle.paragraphSpacing = 18
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: metaStyle
        ]
        full.append(NSAttributedString(string: "Exported from NativAI on \(dateStr) · Model: \(session.modelName)\n\n", attributes: metaAttrs))

        for msg in session.messages {
            let isUser = msg.role == "user"
            let badgeText = isUser ? "👤 User\n" : "🤖 NativAI (\(msg.modelUsed ?? session.modelName))\n"
            let badgeColor = isUser ? NSColor.systemBlue : NSColor.systemPurple
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: badgeColor
            ]
            full.append(NSAttributedString(string: badgeText, attributes: badgeAttrs))

            let contentStyle = NSMutableParagraphStyle()
            contentStyle.lineSpacing = 3
            contentStyle.paragraphSpacing = 16
            let contentAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: contentStyle
            ]

            let contentText = msg.content.isEmpty ? "(Visual Content / Image Attachment)" : msg.content
            full.append(NSAttributedString(string: "\(contentText)\n", attributes: contentAttrs))

            if let imgData = msg.imageData, let img = NSImage(data: imgData) {
                let attachment = NSTextAttachment()
                attachment.image = img
                let maxW: CGFloat = 380
                let scale = min(maxW / max(img.size.width, 1), 1.0)
                attachment.bounds = CGRect(x: 0, y: 0, width: img.size.width * scale, height: img.size.height * scale)
                full.append(NSAttributedString(attachment: attachment))
                full.append(NSAttributedString(string: "\n\n"))
            } else {
                full.append(NSAttributedString(string: "\n"))
            }
        }

        return full
    }

    private static func drawFooter(context: CGContext, pageNumber: Int, pageRect: CGRect, margin: CGFloat) {
        let footerStr = NSAttributedString(
            string: "Page \(pageNumber) · NativAI Local AI Manager",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        let line = CTLineCreateWithAttributedString(footerStr as CFAttributedString)
        context.saveGState()
        context.textPosition = CGPoint(x: margin, y: 22)
        CTLineDraw(line, context)
        context.restoreGState()
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
