/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Extracts durable facts from what the user actually typed.
///
/// Runs after a reply is delivered, never before — extraction costs a model call,
/// and making the user wait for it would trade real latency for a benefit they
/// can't see on this turn.
///
/// The prompt is built around one hard-won lesson from this project: small models
/// asked an open question invent plausible content. So the instructions define
/// eligibility narrowly, demand verbatim grounding, and state explicitly that
/// returning nothing is the normal outcome — most turns contain no durable fact at
/// all, and a model that feels obliged to produce one will fabricate.
enum MemoryExtractor {

    private struct ExtractionResult: Codable {
        struct Item: Codable {
            let text: String
            let kind: String
        }
        let facts: [Item]
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "facts": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "kind": ["type": "string", "enum": ["preference", "identity", "project"]]
                    ],
                    "required": ["text", "kind"]
                ]
            ]
        ],
        "required": ["facts"]
    ]

    private static let systemPrompt = """
    You extract durable facts about the user from their message. Reply with JSON only.

    Record a fact ONLY if it is:
    - stated by the user about themselves, their work, their people, or their preferences
    - still true and useful in a future, unrelated conversation
    - explicitly present in the message — never inferred or guessed

    Do NOT record:
    - questions, requests, or anything the assistant said
    - one-off task details ("summarize this", "make it blue")
    - transient state ("I'm tired today")

    "kind" is one of:
    - "identity": who the user or their people are
    - "project": what they are building or working toward
    - "preference": how they like things done

    Write each fact as one short third-person sentence about "the user".

    Most messages contain NO durable facts. Returning {"facts":[]} is the correct
    and common answer — never invent one to fill the list.

    Examples:
    "My co-founder is Priya and she handles supply chain" -> {"facts":[{"text":"The user's co-founder is Priya, who handles supply chain.","kind":"identity"}]}
    "I'm building a clothing brand called FashionFrenzy with a 12000 dollar budget" -> {"facts":[{"text":"The user is building a clothing brand called FashionFrenzy.","kind":"project"},{"text":"The user's budget is 12000 dollars.","kind":"project"}]}
    "Always give me code without explanations" -> {"facts":[{"text":"The user prefers code without explanations.","kind":"preference"}]}
    "What's the capital of France?" -> {"facts":[]}
    "Make the logo bigger" -> {"facts":[]}
    """

    /// Pulls candidate facts from a single user message.
    ///
    /// - Parameter userMessage: **only** text the user typed. Attachment contents
    ///   must never be passed here: documents are dropped into chats casually and
    ///   can hold material the user would not choose to store permanently.
    static func extract(
        userMessage: String,
        model: String?,
        sessionId: UUID?
    ) async -> [MemoryFact] {
        guard let model, !model.isEmpty else { return [] }

        let trimmed = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        // Very short messages ("ok", "thanks", "make it blue") never carry durable
        // facts, and skipping them avoids a model call on the majority of turns.
        guard trimmed.count >= 15 else { return [] }

        let messages = [
            OllamaManager.ChatMessage(role: "system", content: systemPrompt),
            OllamaManager.ChatMessage(role: "user", content: String(trimmed.prefix(2000)))
        ]

        guard let data = try? await OllamaManager.shared.structuredChat(
            model: model,
            messages: messages,
            schema: schema,
            maxTokens: 200,
            contextLength: await CapabilityProbe.shared.contextLength(for: model)
        ),
        let decoded = try? JSONDecoder().decode(ExtractionResult.self, from: data)
        else { return [] }

        return decoded.facts.compactMap { (item: ExtractionResult.Item) -> MemoryFact? in
            guard let sanitized = sanitize(item.text),
                  let kind = MemoryFact.Kind(rawValue: item.kind)
            else { return nil }
            return MemoryFact(text: sanitized, kind: kind, sourceSessionId: sessionId)
        }
    }

    /// Rejects the degenerate outputs small models produce.
    ///
    /// This filter does the heavy lifting for precision, because prompt
    /// instructions alone are not enough. Measured against the live server,
    /// qwen2.5:1.5b extracted a "fact" from **every single** trivial message it
    /// was shown — "thanks that works" became *"The user is grateful for the
    /// solution."*, "what colors are in it" became *"The user wants to know what
    /// colors are in it."*, and "What's the capital of France?" became *"The
    /// capital of France is Paris."* Precision on non-facts was 0/5 with the
    /// prompt guidance alone.
    ///
    /// Every rejected pattern below corresponds to one of those observed
    /// failures. They share a shape that is reliably detectable in Swift: the
    /// model emits either a restatement of the user's *request* ("the user wants
    /// …", "the user is asking …") or a fact about the *world* rather than about
    /// the user. Recall is unaffected — genuine facts say "the user's X is Y" or
    /// "the user prefers/is building …", none of which match these.
    ///
    /// Preferring a deterministic filter over more prompt engineering is the same
    /// lesson learned elsewhere in this project: do the exact part in Swift, and
    /// leave only the genuinely fuzzy part to the model.
    static func sanitizeForTesting(_ text: String) -> String? { sanitize(text) }

    private static func sanitize(_ text: String) -> String? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*-"))
        guard cleaned.count >= 12, cleaned.count <= 200 else { return nil }

        // A question is a request, not a fact about the user.
        guard !cleaned.hasSuffix("?") else { return nil }

        let lower = cleaned.lowercased()

        // Restated requests and transient state. A durable fact describes what is
        // true of the user, not what they asked for on this turn.
        let requestPhrases = [
            "wants", "would like", "is asking", "asks", "requests", "requested",
            "needs help", "is looking for", "is grateful", "is thankful",
            "thanks", "appreciates", "wants to know", "is curious"
        ]
        guard !requestPhrases.contains(where: { lower.contains($0) }) else { return nil }

        // Must actually be about the user. Facts about the world ("The capital of
        // France is Paris.") are not memory — they're trivia the model already has.
        guard lower.hasPrefix("the user") || lower.hasPrefix("user ") else { return nil }

        // Prompt echo / meta-commentary.
        let rejected = ["the user asks", "the user wants me to", "the assistant",
                        "no durable", "not applicable", "n/a", "none"]
        guard !rejected.contains(where: { lower.hasPrefix($0) || lower == $0 }) else { return nil }

        if !cleaned.hasSuffix(".") { cleaned += "." }
        return cleaned
    }
}
