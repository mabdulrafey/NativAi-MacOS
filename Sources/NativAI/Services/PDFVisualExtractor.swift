/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation
import AppKit
import PDFKit

/// Converts PDF document pages into high-resolution visual PNG images
/// for Vision models (`granite3.2-vision` / `qwen2.5-vl`) to perform visual OCR,
/// chart reading, and complex table extraction.
enum PDFVisualExtractor {

    struct PDFPageVisual {
        let pageIndex: Int
        let image: NSImage
        let pngData: Data
    }

    /// Extracts up to `maxPages` rendered images from a PDF file URL.
    static func extractPages(from url: URL, maxPages: Int = 10) -> [PDFPageVisual] {
        guard let doc = PDFDocument(url: url) else { return [] }
        return extractPages(from: doc, maxPages: maxPages)
    }

    /// Extracts up to `maxPages` rendered images from PDF data.
    static func extractPages(from data: Data, maxPages: Int = 10) -> [PDFPageVisual] {
        guard let doc = PDFDocument(data: data) else { return [] }
        return extractPages(from: doc, maxPages: maxPages)
    }

    private static func extractPages(from doc: PDFDocument, maxPages: Int) -> [PDFPageVisual] {
        var results: [PDFPageVisual] = []
        let pageCount = min(doc.pageCount, maxPages)

        for i in 0..<pageCount {
            guard let page = doc.page(at: i) else { continue }
            let pageRect = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0 // 2x high-res rendering

            let imageSize = NSSize(width: pageRect.width * scale, height: pageRect.height * scale)
            let image = NSImage(size: imageSize, flipped: false) { dstRect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.setFillColor(NSColor.white.cgColor)
                context.fill(dstRect)
                context.saveGState()
                context.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: context)
                context.restoreGState()
                return true
            }

            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                results.append(PDFPageVisual(pageIndex: i + 1, image: image, pngData: pngData))
            }
        }
        return results
    }
}
