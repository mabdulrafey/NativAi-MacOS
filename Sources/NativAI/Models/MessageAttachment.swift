/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// A file the user attached to a message — either an image (sent to a
/// vision-capable model as base64) or a text/code file (its contents are
/// read and injected directly into the prompt, since any chat model can
/// read plain text — no special vision capability needed for that case).
struct MessageAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    let fileName: String
    let kind: Kind
    /// For .image: raw image bytes (base64-encoded when sent to Ollama).
    /// For .textFile: not used — see `extractedText` instead.
    var imageData: Data?
    /// For .textFile: the file's decoded text content, injected into the
    /// prompt as context. For .image: not used.
    var extractedText: String?

    enum Kind: String, Codable {
        case image
        case textFile
    }

    init(id: UUID = UUID(), fileName: String, kind: Kind, imageData: Data? = nil, extractedText: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
        self.imageData = imageData
        self.extractedText = extractedText
    }
}

