/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation
// Required for @Published / ObservableObject. SPM resolves Combine transitively
// through SwiftUI elsewhere in the target, so omitting it still built there —
// but the Xcode target compiles this file without that transitive import and
// fails outright. Worth stating explicitly rather than depending on which build
// system happens to compile it.
import Combine

/// Cross-session memory: durable facts the user has stated, retrieved by meaning
/// and injected into later conversations.
///
/// This is the piece that makes the app feel like it knows the user rather than
/// starting fresh every time. It is also the piece with the most potential to
/// feel invasive, so three constraints are structural rather than optional:
///
/// 1. **Off by default.** `isEnabled` starts false. Silent memory in an
///    offline-first, privacy-forward app would betray the app's whole premise —
///    the user has to ask for it.
///
/// 2. **Never learns from attachments.** Only text the user typed is eligible.
///    Documents get dropped into chats casually and can contain material the user
///    would never choose to store permanently; given this project also handles
///    disclosure-controlled files, that's a hard line, not a preference.
///
/// 3. **Fully visible and deletable.** Every fact is listed in Settings with a
///    delete button. The most common complaint about ChatGPT's memory is not
///    knowing what it kept.
@MainActor
final class MemoryStore: ObservableObject {

    static let shared = MemoryStore()

    /// Remembered facts, newest first.
    @Published private(set) var facts: [MemoryFact] = []

    /// Whether memory is active. Persisted; defaults to off.
    ///
    /// The `UserDefaults` write is deliberately **not** in a `didSet`. A
    /// `Toggle` bound directly to a `@Published` property whose observer performs
    /// synchronous work mutates observable state *during* SwiftUI's view-update
    /// pass, and SwiftUI resolves that by discarding the enclosing body — which
    /// took down the whole `NavigationSplitView`, blanking the sidebar as well as
    /// the pane, with no way back. Persistence now happens in `setEnabled(_:)`,
    /// called from an explicit action rather than as a side effect of rendering.
    @Published private(set) var isEnabled: Bool

    /// Turns memory on or off and persists the choice.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        // Disabling stops extraction and injection but deliberately keeps stored
        // facts: a user switching memory off to ask something private shouldn't
        // silently destroy everything they'd asked it to remember. Clearing is a
        // separate, explicit action.
    }

    /// How many facts are injected into a conversation at most.
    ///
    /// Small on purpose: every injected fact spends context the conversation
    /// itself needs, and irrelevant facts measurably distract smaller models.
    nonisolated static let retrievalLimit = 5

    /// Similarity floor for injection.
    ///
    /// Calibrated from measured scores on real fact/query pairs: correct matches
    /// scored 0.51–0.68 while unrelated pairs sat below ~0.45. 0.45 admits weak
    /// but plausible matches without injecting noise on every unrelated question.
    nonisolated static let similarityThreshold = 0.45

    /// Upper bound on stored facts, oldest evicted first.
    nonisolated static let maximumFacts = 200

    private static let enabledKey = "memoryEnabled"

    /// Where facts are persisted.
    ///
    /// `urls(for:in:)` returns an array that is *documented* as possibly empty,
    /// so subscripting `[0]` is a latent trap — and because this runs inside a
    /// `static let` initialiser reached during SwiftUI view construction, that
    /// trap would surface as the entire window going blank rather than as a
    /// recognisable crash. Falling back to a temporary directory keeps the app
    /// usable (memory just doesn't survive a restart) instead of taking the
    /// whole UI down.
    private let fileURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = base.appendingPathComponent("NativAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("memory.json")
    }()

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MemoryFact].self, from: data)
        else { return }
        facts = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(facts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Mutation

    /// Adds a fact unless an equivalent one is already stored.
    ///
    /// Returns false when rejected as a duplicate, so callers can avoid paying
    /// for an embedding on text that won't be kept.
    @discardableResult
    func add(_ fact: MemoryFact) -> Bool {
        let incoming = fact.normalized
        guard !incoming.isEmpty else { return false }

        // Substring containment either way, not just equality: models restate
        // facts at varying length ("budget is 12000" vs "the user's budget is
        // 12000 dollars"), and treating those as distinct fills the store with
        // near-copies that crowd out genuinely different facts at retrieval time.
        let isDuplicate = facts.contains { existing in
            let stored = existing.normalized
            return stored == incoming || stored.contains(incoming) || incoming.contains(stored)
        }
        guard !isDuplicate else { return false }

        facts.insert(fact, at: 0)
        if facts.count > Self.maximumFacts {
            facts.removeLast(facts.count - Self.maximumFacts)
        }
        persist()
        return true
    }

    func delete(id: UUID) {
        facts.removeAll { $0.id == id }
        persist()
    }

    func deleteAll() {
        facts.removeAll()
        persist()
    }

    /// Attaches an embedding to a stored fact.
    func setEmbedding(_ embedding: [Double], for id: UUID) {
        guard let index = facts.firstIndex(where: { $0.id == id }) else { return }
        facts[index].embedding = embedding
        persist()
    }

    /// Facts still lacking an embedding, for backfilling once a model is available.
    var factsNeedingEmbedding: [MemoryFact] {
        facts.filter { $0.embedding == nil }
    }

    // MARK: - Retrieval

    /// The most relevant facts for a prompt.
    ///
    /// Falls back to keyword overlap when no embedding model is installed, so
    /// memory works — less precisely — without requiring a 0.22 GB download.
    func relevantFacts(
        for queryEmbedding: [Double]?,
        prompt: String,
        limit: Int = MemoryStore.retrievalLimit
    ) -> [MemoryFact] {
        guard isEnabled, !facts.isEmpty else { return [] }

        if let queryEmbedding {
            let scored = facts.compactMap { fact -> (MemoryFact, Double)? in
                guard let embedding = fact.embedding else { return nil }
                let score = EmbeddingService.cosineSimilarity(queryEmbedding, embedding)
                return score >= Self.similarityThreshold ? (fact, score) : nil
            }
            if !scored.isEmpty {
                return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
            }
        }

        return keywordMatches(prompt: prompt, limit: limit)
    }

    /// Keyword fallback: counts shared significant words.
    private func keywordMatches(prompt: String, limit: Int) -> [MemoryFact] {
        let queryWords = Set(
            prompt.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 }
        )
        guard !queryWords.isEmpty else { return [] }

        let scored = facts.compactMap { fact -> (MemoryFact, Int)? in
            let factWords = Set(fact.normalized.split(separator: " ").map(String.init))
            let overlap = queryWords.intersection(factWords).count
            return overlap > 0 ? (fact, overlap) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Wraps facts as a system message for injection.
    ///
    /// Framed as background the model may use, with an explicit instruction not
    /// to volunteer it: without that, small models open replies with "As I recall,
    /// your budget is $12,000…" even when the question had nothing to do with it,
    /// which reads as unsettling rather than helpful.
    ///
    /// `nonisolated` because it's a pure transformation of its argument that
    /// touches no store state — requiring a MainActor hop to format a string
    /// would be misleading about what it does.
    nonisolated static func systemMessage(for facts: [MemoryFact]) -> OllamaManager.ChatMessage? {
        guard !facts.isEmpty else { return nil }
        let lines = facts.map { "- \($0.text)" }.joined(separator: "\n")
        return OllamaManager.ChatMessage(
            role: "system",
            content: """
            What you know about this user from previous conversations:
            \(lines)

            Use these only when relevant. Do not mention them otherwise.
            """
        )
    }
}
