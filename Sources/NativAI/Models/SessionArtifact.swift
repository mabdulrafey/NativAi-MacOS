/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// A typed record of an image or document artifact present in a conversation.
public struct SessionArtifact: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case generatedImage
        case attachedImage
        case document
    }

    public var id: UUID
    public var kind: Kind
    public var messageId: UUID
    public var label: String
    public var sourcePrompt: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        messageId: UUID,
        label: String,
        sourcePrompt: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.messageId = messageId
        self.label = label
        self.sourcePrompt = sourcePrompt
        self.createdAt = createdAt
    }

    /// Filters artifacts down to visual items (generated or attached images).
    public static func visuals(in artifacts: [SessionArtifact]) -> [SessionArtifact] {
        artifacts.filter { $0.kind == .generatedImage || $0.kind == .attachedImage }
    }

    /// Resolves the intended visual target for a follow-up prompt.
    public static func resolveTarget(prompt: String, artifacts: [SessionArtifact]) -> SessionArtifact? {
        let visualList = visuals(in: artifacts)
        guard !visualList.isEmpty else { return nil }

        let lower = prompt.lowercased()

        // 1. Ordinal resolution
        let ordinalMap: [(patterns: [String], index: Int)] = [
            (["first", "1st"], 0),
            (["second", "2nd"], 1),
            (["third", "3rd"], 2),
            (["fourth", "4th"], 3),
            (["fifth", "5th"], 4)
        ]

        for entry in ordinalMap {
            if entry.patterns.contains(where: { lower.contains($0) }) {
                if entry.index < visualList.count {
                    return visualList[entry.index]
                } else {
                    // Out of range ordinal falls back to recency rather than clamping
                    return visualList.last
                }
            }
        }

        // 2. Keyword matching on artifact label
        for visual in visualList.reversed() {
            let labelWords = visual.label.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 && !["the", "for", "and", "image", "with"].contains($0) }

            if labelWords.contains(where: { lower.contains($0) }) {
                return visual
            }
        }

        // 3. Default to most recent visual
        return visualList.last
    }

    /// Resolves multiple visual targets for comparative prompts.
    public static func resolveTargets(prompt: String, artifacts: [SessionArtifact]) -> [SessionArtifact] {
        let visualList = visuals(in: artifacts)
        guard !visualList.isEmpty else { return [] }

        let lower = prompt.lowercased()
        let ordinalMap: [(patterns: [String], index: Int)] = [
            (["first", "1st"], 0),
            (["second", "2nd"], 1),
            (["third", "3rd"], 2),
            (["fourth", "4th"], 3),
            (["fifth", "5th"], 4)
        ]

        var matchedIndices: [Int] = []
        for entry in ordinalMap {
            if entry.patterns.contains(where: { lower.contains($0) }) && entry.index < visualList.count {
                matchedIndices.append(entry.index)
            }
        }

        if matchedIndices.count >= 2 {
            matchedIndices.sort()
            return matchedIndices.map { visualList[$0] }
        }

        if let single = resolveTarget(prompt: prompt, artifacts: artifacts) {
            return [single]
        }
        return []
    }

    /// Formats an artifact ledger summary for context injection.
    public static func contextSummary(for artifacts: [SessionArtifact]) -> String? {
        guard !artifacts.isEmpty else { return nil }

        var sections: [String] = []
        let visualList = visuals(in: artifacts)
        if !visualList.isEmpty {
            var lines = ["Visual artifacts:"]
            for (index, visual) in visualList.enumerated() {
                let tag = visual.kind == .generatedImage ? "generated" : "attached"
                lines.append("\(index + 1). [\(tag)]: \(visual.label)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        let documents = artifacts.filter { $0.kind == .document }
        if !documents.isEmpty {
            var lines = ["Documents:"]
            for doc in documents {
                lines.append("- \(doc.label)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }
}
