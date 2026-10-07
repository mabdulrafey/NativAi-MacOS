/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// A remembered fact extracted from conversations for cross-session personalization.
public struct MemoryFact: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case project
        case preference
        case identity
        case general

        public var displayName: String {
            switch self {
            case .project: return "Project"
            case .preference: return "Preference"
            case .identity: return "Identity"
            case .general: return "General"
            }
        }

        public var symbolName: String {
            switch self {
            case .project: return "folder.fill"
            case .preference: return "slider.horizontal.3"
            case .identity: return "person.fill"
            case .general: return "info.circle.fill"
            }
        }
    }

    public var id: UUID
    public var text: String
    public var kind: Kind
    public var sourceSessionId: UUID?
    public var embedding: [Double]?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        kind: Kind,
        sourceSessionId: UUID? = nil,
        embedding: [Double]? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.sourceSessionId = sourceSessionId
        self.embedding = embedding
        self.createdAt = createdAt
    }

    public enum CodingKeys: String, CodingKey {
        case id, text, kind, sourceSessionId, embedding, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try container.decode(String.self, forKey: .text)
        self.kind = try container.decode(Kind.self, forKey: .kind)
        self.sourceSessionId = try container.decodeIfPresent(UUID.self, forKey: .sourceSessionId)
        self.embedding = try container.decodeIfPresent([Double].self, forKey: .embedding)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// Normalized representation for robust deduplication and comparison.
    public var normalized: String {
        var filtered = ""
        for ch in text.lowercased() {
            if ch == "'" || ch == "’" {
                // Drop apostrophes so "user's" becomes "users"
                continue
            } else if ch.isLetter || ch.isNumber {
                filtered.append(ch)
            } else {
                // Treat all other punctuation and symbols as space
                filtered.append(" ")
            }
        }
        return filtered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
