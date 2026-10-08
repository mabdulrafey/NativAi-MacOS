/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// A single message bubble in the chat transcript.
struct DisplayMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: String        // "user" | "assistant"
    var content: String
    var isImage: Bool       // true if this bubble should render image data instead of text
    var imageData: Data?    // populated when isImage == true
    /// Which real installed model actually generated this message. Only set
    /// on assistant messages when Auto mode routed the request — lets each
    /// response show exactly which model answered, rather than relying on a
    /// single session-wide "last routed model" value that can't reflect a
    /// conversation where different messages were routed to different models.
    var modelUsed: String?
    /// Files the user attached to this message (images for vision models,
    /// text/code files whose content gets injected into the prompt).
    var attachments: [MessageAttachment]

    init(id: UUID = UUID(), role: String, content: String, isImage: Bool, imageData: Data? = nil, modelUsed: String? = nil, attachments: [MessageAttachment] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.isImage = isImage
        self.imageData = imageData
        self.modelUsed = modelUsed
        self.attachments = attachments
    }
}

