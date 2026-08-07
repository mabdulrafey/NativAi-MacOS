/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Compresses the oldest turns of a long conversation into a running prose
/// summary, so context that no longer fits the model's window is *condensed*
/// rather than thrown away.
///
/// Why this exists: `TokenBudget.fit` keeps the newest turns that fit and drops
/// the rest. That was already a large improvement over letting Ollama silently
/// clip the prompt — at least the decision was ours — but it still means a long
/// conversation loses its own beginning. A user who establishes something in
/// turn 2 ("I'm building a clothing brand called FashionFrenzy") and refers back
/// to it in turn 40 would find the model had genuinely never seen it.
///
/// The design is deliberately conservative about *when* it summarizes:
///
/// - Compaction is **append-only and monotonic**. `digestedThroughIndex` only
///   ever moves forward, and already-digested turns are never re-read. This
///   matters because summarizing a summary degrades badly — each pass drops
///   detail, and after a few rounds the digest becomes vague and confidently
///   wrong. Instead, new material is folded into the existing digest once, and
///   the previous digest text is carried through verbatim as context.
///
/// - It runs **after** a reply is delivered, never before. Compaction costs a
///   model call, and making the user wait for it before their answer would trade
///   a real latency hit for an invisible benefit.
///
/// - It **never blocks or fails a turn**. Any error leaves the digest untouched,
///   which simply means the next send falls back to plain truncation.
enum ConversationDigest {

    /// Fraction of the input allowance that verbatim turns may occupy before
    /// compaction is worthwhile.
    ///
    /// Below this there's nothing to gain: the turns all still fit, so digesting
    /// them would spend a model call to summarize context the model was going to
    /// receive in full anyway — strictly worse, since a summary is lossier than
    /// the real text.
    static let compactionThreshold = 0.6

    /// Minimum number of messages to leave verbatim at the end of a conversation.
    ///
    /// Recent turns carry the conversational thread — pronouns, corrections, the
    /// thing being iterated on — and summarizing them would break exactly the
    /// short-range coherence the digest can't reproduce. Only genuinely old
    /// material is eligible.
    static let verbatimTailCount = 8

    /// Decides whether a session's history should be compacted, and which
    /// messages are eligible.
    ///
    /// Returns nil when compaction isn't warranted, which is the common case.
    struct Plan {
        /// Messages to fold into the digest (oldest first).
        let messages: [OllamaManager.ChatMessage]
        /// New value for `digestedThroughIndex` once folding succeeds.
        let newDigestedThroughIndex: Int
    }

    /// Builds a compaction plan, or returns nil if the conversation doesn't need
    /// one yet.
    ///
    /// - Parameters:
    ///   - history: full history in wire form, oldest first.
    ///   - alreadyDigestedThrough: how many leading messages are already
    ///     represented in the existing digest.
    ///   - contextLength: the answering model's real context window.
    static func plan(
        history: [OllamaManager.ChatMessage],
        alreadyDigestedThrough: Int,
        contextLength: Int
    ) -> Plan? {
        // Never re-read what's already summarized: that's what keeps compaction
        // monotonic and prevents summary-of-summary degradation.
        guard alreadyDigestedThrough < history.count else { return nil }
        let undigested = Array(history[alreadyDigestedThrough...])

        // Leave the recent tail verbatim.
        let eligibleCount = undigested.count - verbatimTailCount
        guard eligibleCount > 0 else { return nil }

        let allowance = Double(TokenBudget.inputAllowance(contextLength: contextLength))
        let undigestedCost = undigested.reduce(0) { $0 + TokenBudget.estimate($1) }
        guard Double(undigestedCost) > allowance * compactionThreshold else { return nil }

        let eligible = Array(undigested[..<eligibleCount])
        // A handful of trivial turns isn't worth a model call.
        guard eligible.count >= 2 else { return nil }

        return Plan(
            messages: eligible,
            newDigestedThroughIndex: alreadyDigestedThrough + eligibleCount
        )
    }

    private static let systemPrompt = """
    You compress a conversation into durable notes. Reply with prose only, no preamble.

    Write 3 to 6 short sentences capturing ONLY information that stays useful later:
    - concrete facts, names, numbers, decisions, and stated preferences
    - what the user is trying to accomplish
    - anything the user asked you to remember

    Omit pleasantries, restatements of the question, and your own explanations.
    Never invent detail that is not present. Write in third person about "the user".
    """

    /// Folds `messages` into `existingDigest`, returning the updated digest.
    ///
    /// The previous digest is supplied as context and the model is asked to
    /// produce a merged version, rather than being handed its own prior summary
    /// to re-summarize. That distinction is what stops the telephone-game
    /// degradation described above.
    ///
    /// Returns nil on any failure, leaving the caller's digest unchanged.
    static func fold(
        existingDigest: String,
        messages: [OllamaManager.ChatMessage],
        model: String?
    ) async -> String? {
        guard let model, !model.isEmpty, !messages.isEmpty else { return nil }

        var transcript = ""
        for message in messages {
            let role = message.role == "user" ? "User" : "Assistant"
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // Cap each turn: a single pasted document shouldn't crowd out the
            // rest of the window being summarized.
            transcript += "\(role): \(String(text.prefix(600)))\n"
        }
        guard !transcript.isEmpty else { return nil }

        var userContent = ""
        if !existingDigest.isEmpty {
            userContent += """
            Existing notes (keep everything still relevant, merge with the new material):
            \(existingDigest)

            """
        }
        userContent += "New conversation to fold in:\n\(transcript)"

        let request = [
            OllamaManager.ChatMessage(role: "system", content: systemPrompt),
            OllamaManager.ChatMessage(role: "user", content: userContent)
        ]

        let contextLength = await CapabilityProbe.shared.contextLength(for: model)
        var collected = ""
        do {
            try await OllamaManager.shared.chat(
                model: model,
                messages: TokenBudget.fit(messages: request, contextLength: contextLength).messages,
                contextLength: contextLength
            ) { token in
                collected += token
            }
        } catch {
            return nil
        }

        let cleaned = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject a degenerate result rather than overwriting good notes with it.
        guard cleaned.count >= 40 else { return nil }
        // Hard cap: the digest is prepended to every subsequent request, so an
        // unbounded one would itself become the thing crowding out the window.
        return cleaned.count > 2000 ? String(cleaned.prefix(2000)) : cleaned
    }

    /// Wraps a digest as a system message for injection into a request.
    ///
    /// Framed as notes about earlier conversation rather than as instructions,
    /// so the model treats it as background it may draw on instead of a task to
    /// perform.
    static func systemMessage(for digest: String) -> OllamaManager.ChatMessage? {
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return OllamaManager.ChatMessage(
            role: "system",
            content: "Notes from earlier in this conversation:\n\(trimmed)"
        )
    }
}
