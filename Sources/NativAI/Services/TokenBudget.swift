/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Fits conversation history into a model's real context window.
///
/// Why this exists: Ollama silently defaults `num_ctx` to a small value
/// (2048–4096) regardless of what the model actually supports, and silently
/// drops whatever doesn't fit. There is no error and no warning — the model
/// just stops seeing the oldest turns. Before this type existed, `sendChat`
/// sent the entire session history every turn and simply hoped, which meant a
/// long chat degraded invisibly and unpredictably.
///
/// Token counting is an estimate, not a tokenizer. ~4 characters per token is
/// the standard rule of thumb for English and runs roughly ±10% across the
/// Llama/Qwen/Gemma families. That inaccuracy is fine precisely because we
/// keep a large output reserve: overshooting the estimate eats into slack
/// rather than truncating the conversation.
enum TokenBudget {

    /// Characters per token, used for estimation.
    private static let charactersPerToken = 4.0

    /// Tokens held back for the model's own reply. Generous on purpose — a
    /// long answer that gets cut off mid-sentence is a far worse failure than
    /// dropping one extra old turn.
    static let outputReserveTokens = 1024

    /// Extra headroom for chat-template scaffolding (role markers, special
    /// tokens) that we don't model but the server still spends context on.
    private static let templateOverheadTokens = 256

    /// Rough token count for a string.
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(text.count) / charactersPerToken).rounded(.up))
    }

    /// Token cost of a message, including a small per-message allowance for
    /// the role wrapper the chat template adds.
    static func estimate(_ message: OllamaManager.ChatMessage) -> Int {
        // Base64 image payloads are NOT counted here: vision models process
        // images through a separate projector with its own fixed token cost,
        // not as characters in the text stream. Counting the base64 string
        // (often 100k+ characters for one photo) would blow the budget and
        // wrongly evict the entire text conversation.
        estimate(message.content) + 4
    }

    /// Tokens available for input, given a model's full context window.
    static func inputAllowance(contextLength: Int) -> Int {
        max(512, contextLength - outputReserveTokens - templateOverheadTokens)
    }

    /// Result of fitting messages to a budget.
    struct FitResult {
        let messages: [OllamaManager.ChatMessage]
        /// How many older messages were dropped. Surfaced so callers can
        /// decide to summarize instead of silently losing them (Phase 4).
        let droppedCount: Int
        let estimatedTokens: Int

        var didTruncate: Bool { droppedCount > 0 }
    }

    /// Selects the newest messages that fit within `contextLength`, always
    /// preserving any leading system message.
    ///
    /// Walks newest-first so the most relevant recent turns survive, then
    /// restores chronological order — models are heavily sensitive to
    /// ordering, and a reversed history produces confidently wrong answers.
    ///
    /// A system prompt is reserved up front rather than competing for space,
    /// since dropping it would change the model's behaviour entirely. Note a
    /// deliberate asymmetry: if the single newest message alone exceeds the
    /// whole budget (a giant pasted PDF), it is still included. Truncating it
    /// would mean answering a question the user never asked; letting the
    /// server clip the tail at least keeps the request intact and is the
    /// failure mode the user can actually see and react to.
    static func fit(
        messages: [OllamaManager.ChatMessage],
        contextLength: Int
    ) -> FitResult {
        let allowance = inputAllowance(contextLength: contextLength)

        var systemMessages: [OllamaManager.ChatMessage] = []
        var conversation = messages
        while let first = conversation.first, first.role == "system" {
            systemMessages.append(first)
            conversation.removeFirst()
        }

        let systemCost = systemMessages.reduce(0) { $0 + estimate($1) }
        var remaining = allowance - systemCost

        var kept: [OllamaManager.ChatMessage] = []
        var used = 0

        for message in conversation.reversed() {
            let cost = estimate(message)
            // Always keep the newest message, even if oversized (see above).
            if kept.isEmpty || cost <= remaining {
                kept.append(message)
                remaining -= cost
                used += cost
            } else {
                break
            }
        }

        let ordered = systemMessages + kept.reversed()
        return FitResult(
            messages: ordered,
            droppedCount: conversation.count - kept.count,
            estimatedTokens: systemCost + used
        )
    }
}
