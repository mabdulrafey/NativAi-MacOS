/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Generates short, human-readable chat titles with the local router model.
///
/// Previously titles were the first 40 characters of the first substantive
/// message, which produced truncated fragments like "I am planning on building
/// a clothing bra…". A 1.5B model is more than capable of the summarisation
/// needed here — it's a much easier task than intent classification, since
/// there's no reasoning involved, just compression.
///
/// Stays fully offline (same local Ollama server) and always has a
/// deterministic fallback, so a missing/failed router never leaves a chat
/// untitled.
enum ChatTitleGenerator {

    private static let systemPrompt = """
    You write very short titles for chat conversations. Reply with JSON only.

    Rules for "title":
    - 2 to 5 words.
    - Title Case.
    - Describe the TOPIC, not the request. "Clothing Brand Names", not "User Asks For Names".
    - No quotes, no trailing punctuation, no emoji.
    - Never start with "Chat About" or "Conversation On".

    Examples:
    User asked for clothing brand name ideas -> {"title":"Clothing Brand Names"}
    User needs help fixing a Swift compiler error -> {"title":"Swift Build Error"}
    User wants a logo generated for a brand -> {"title":"Brand Logo Design"}
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": ["title": ["type": "string"]],
        "required": ["title"]
    ]

    private struct TitleResult: Codable {
        let title: String
    }

    /// Produces a title from the opening exchange. `assistantReply` is
    /// optional but improves quality — the reply usually states the topic more
    /// explicitly than a terse opening question does.
    ///
    /// Returns nil if the router is unavailable or the model returns something
    /// unusable, letting the caller keep its existing truncated title.
    static func generateTitle(
        userMessage: String,
        assistantReply: String?,
        routerModel: String?
    ) async -> String? {
        guard let routerModel, !routerModel.isEmpty else { return nil }

        let trimmedUser = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedUser.count >= 3 else { return nil }

        // Cap both sides: a title only needs the gist, and long input slows a
        // small model down for no gain.
        var conversation = "User: \(String(trimmedUser.prefix(500)))"
        if let assistantReply, !assistantReply.isEmpty {
            conversation += "\n\nAssistant: \(String(assistantReply.prefix(500)))"
        }

        let messages = [
            OllamaManager.ChatMessage(role: "system", content: systemPrompt),
            OllamaManager.ChatMessage(role: "user", content: conversation)
        ]

        guard let data = try? await OllamaManager.shared.structuredChat(
            model: routerModel,
            messages: messages,
            schema: schema,
            maxTokens: 24
        ),
        let result = try? JSONDecoder().decode(TitleResult.self, from: data) else {
            return nil
        }

        return sanitize(result.title)
    }

    /// Asks whether an existing title still fits a conversation that has moved
    /// on, returning a replacement only when it genuinely doesn't.
    ///
    /// This is what stops a chat being permanently named after its opening
    /// question. A conversation that starts "I want to build a clothing brand"
    /// and becomes mostly logo design is mis-titled by turn 6 — but titles that
    /// churn on every message are worse than slightly stale ones, since the
    /// sidebar becomes unrecognisable. Hence: few revisions, high bar to change.
    ///
    /// **Requires a mid-sized model.** Measured against the live server, this
    /// task is beyond the tiny router used for intent classification:
    /// qwen2.5:1.5b answered `keep:true` even for a title of "French Capital
    /// Question" on a conversation entirely about Swift debugging, while
    /// llama3:8b correctly returned `keep:false, "Swift Debugging and Testing"`.
    /// Judging *semantic drift* needs more capacity than picking one of three
    /// intent labels, so passing the router model here would silently disable
    /// the feature rather than make it cheap. Callers should supply the best
    /// available chat model; nil skips revision entirely, which is a perfectly
    /// acceptable outcome — a slightly stale title is a cosmetic issue.
    static func reviseTitle(
        currentTitle: String,
        digest: String,
        model: String?
    ) async -> String? {
        guard let model, !model.isEmpty else { return nil }
        guard digest.count >= 20 else { return nil }

        let system = """
        You check whether a chat title still describes the conversation. Reply with JSON only.

        Set "keep" to true if the existing title is still reasonable — this is the common case.
        Set "keep" to false ONLY if the conversation has clearly moved to a different topic,
        and then supply a better "title" of 2 to 5 words in Title Case.

        Examples:
        Title "Clothing Brand Names", conversation is about picking brand names -> {"keep":true}
        Title "Clothing Brand Names", conversation is now entirely about logo design -> {"keep":false,"title":"Brand Logo Design"}
        Title "Python Help", conversation is about debugging a Python script -> {"keep":true}
        """

        let reviseSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "keep": ["type": "boolean"],
                "title": ["type": "string"]
            ],
            "required": ["keep"]
        ]

        let messages = [
            OllamaManager.ChatMessage(role: "system", content: system),
            OllamaManager.ChatMessage(
                role: "user",
                content: "Current title: \(currentTitle)\n\nConversation so far:\n\(String(digest.prefix(1200)))"
            )
        ]

        guard let data = try? await OllamaManager.shared.structuredChat(
            model: model,
            messages: messages,
            schema: reviseSchema,
            maxTokens: 32,
            contextLength: await CapabilityProbe.shared.contextLength(for: model)
        ),
        let result = try? JSONDecoder().decode(ReviseResult.self, from: data),
        result.keep == false,
        let proposed = result.title,
        let cleaned = sanitize(proposed)
        else { return nil }

        // Ignore a "new" title that's effectively the same, which small models
        // return often enough to matter — rewriting the sidebar for a
        // capitalisation change would be pure noise.
        guard cleaned.lowercased() != currentTitle.lowercased() else { return nil }
        return cleaned
    }

    private struct ReviseResult: Codable {
        let keep: Bool
        let title: String?
    }

    /// Guards against the small-model failure modes actually seen in testing:
    /// wrapping the title in quotes, appending a period, returning an empty
    /// string, or ignoring the word limit and emitting a whole sentence.
    private static func sanitize(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(of: "\"", with: "")
        title = title.replacingOccurrences(of: "\n", with: " ")
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: "))

        guard !title.isEmpty else { return nil }

        // Hard-cap runaway output at 6 words rather than rejecting it, so a
        // slightly-too-long title still beats no title.
        let words = title.split(separator: " ").map(String.init)
        if words.count > 6 {
            title = words.prefix(6).joined(separator: " ")
        }
        // Anything this long means the model ignored the instruction entirely.
        guard title.count <= 60 else { return nil }
        return title
    }
}
