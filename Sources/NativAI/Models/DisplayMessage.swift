/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// A single message displayed within a chat transcript.
public struct DisplayMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var role: String
    public var content: String
    public var isImage: Bool
    public var imageData: Data?
    public var modelUsed: String?
    public var attachments: [MessageAttachment]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: String,
        content: String,
        isImage: Bool = false,
        imageData: Data? = nil,
        modelUsed: String? = nil,
        attachments: [MessageAttachment] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.isImage = isImage
        self.imageData = imageData
        self.modelUsed = modelUsed
        self.attachments = attachments
        self.createdAt = createdAt
    }

    public enum CodingKeys: String, CodingKey {
        case id, role, content, isImage, imageData, modelUsed, attachments, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.role = try container.decode(String.self, forKey: .role)
        self.content = try container.decode(String.self, forKey: .content)
        self.isImage = try container.decodeIfPresent(Bool.self, forKey: .isImage) ?? false
        self.imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
        self.modelUsed = try container.decodeIfPresent(String.self, forKey: .modelUsed)
        self.attachments = try container.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
