/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Attachment associated with a message (image, text file, document).
public struct MessageAttachment: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case image
        case textFile
    }

    public var id: UUID
    public var fileName: String
    public var kind: Kind
    public var imageData: Data?
    public var extractedText: String?

    public init(
        id: UUID = UUID(),
        fileName: String,
        kind: Kind,
        imageData: Data? = nil,
        extractedText: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
        self.imageData = imageData
        self.extractedText = extractedText
    }

    public enum CodingKeys: String, CodingKey {
        case id, fileName, kind, imageData, extractedText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.fileName = try container.decode(String.self, forKey: .fileName)
        self.kind = try container.decode(Kind.self, forKey: .kind)
        self.imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
        self.extractedText = try container.decodeIfPresent(String.self, forKey: .extractedText)
    }
}
