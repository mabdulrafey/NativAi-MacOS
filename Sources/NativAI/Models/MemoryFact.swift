/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// A durable fact the user has stated about themselves, their work, or their
/// preferences — remembered across conversations.
struct MemoryFact: Identifiable, Codable, Equatable, Sendable {

    enum Kind: String, Codable, Sendable, CaseIterable {
        /// A stable preference ("prefers concise answers", "writes Swift").
        case preference
        /// Who the user is or works with ("co-founder is Priya").
        case identity
        /// A project, goal, or ongoing piece of work.
        case project

        var displayName: String {
            switch self {
            case .preference: return "Preference"
            case .identity: return "About you"
            case .project: return "Project"
            }
        }

        var symbolName: String {
            switch self {
            case .preference: return "slider.horizontal.3"
            case .identity: return "person.crop.circle"
            case .project: return "folder"
            }
        }
    }

    let id: UUID
    /// The fact in one short sentence, third person ("The user's budget is $12,000").
    var text: String
    let kind: Kind
    /// Session this was learned from, so the user can see where a fact came from.
    let sourceSessionId: UUID?
    let createdAt: Date

    /// Cached embedding for semantic retrieval.
    ///
    /// Stored rather than recomputed because embedding is a model call: with 50
    /// facts, re-embedding the whole store on every message would add a
    /// noticeable stall to each turn. Optional so a store written before an
    /// embedding model was installed still loads, and can be embedded later.
    var embedding: [Double]?

    init(
        id: UUID = UUID(),
        text: String,
        kind: Kind,
        sourceSessionId: UUID? = nil,
        createdAt: Date = Date(),
        embedding: [Double]? = nil
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.sourceSessionId = sourceSessionId
        self.createdAt = createdAt
        self.embedding = embedding
    }

    /// Normalised form used for duplicate detection.
    ///
    /// Small models restate the same fact with trivial variation across turns
    /// ("The user's budget is 12000 dollars." vs "the users budget is $12,000"),
    /// so exact string comparison would let the store fill with near-copies that
    /// then crowd out genuinely distinct facts in the retrieval window.
    ///
    /// Apostrophes are stripped rather than treated as separators, so possessives
    /// collapse onto their plural spelling ("user's" and "users" both become
    /// "users"). Splitting on them instead produced "user s", which failed to
    /// match the most common phrasing the extractor emits — the exact case that
    /// let duplicates through.
    var normalized: String {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

