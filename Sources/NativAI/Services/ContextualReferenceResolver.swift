/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Resolves ordinal/positional references ("the number 10 one", "the first
/// name you suggested", "the 3rd option") against a numbered list that
/// appeared in a PRIOR assistant message, substituting the actual referenced
/// text into the current prompt before it's sent to an image model.
///
/// Why this exists: pure keyword-based intent classification correctly
/// detects "create a logo for X" as an image request, but has no way to know
/// what "the number 10 one you suggested" actually refers to — that requires
/// looking back at conversation history, extracting a numbered list item,
/// and splicing its real content into the current prompt. True general
/// pronoun/reference resolution needs an LLM's own reasoning; this instead
/// covers the common, high-value case of numbered-list callbacks with a
/// simple, fully offline pattern match.
enum ContextualReferenceResolver {

    /// Attempts to resolve an ordinal reference in `prompt` against the most
    /// recent prior assistant message containing a numbered list. Returns the
    /// prompt with the reference replaced by the actual list item text, or
    /// the original prompt unchanged if no reference/matching list is found.
    static func resolve(prompt: String, priorAssistantMessages: [String]) -> String {
        guard let ordinal = extractOrdinal(from: prompt) else { return prompt }

        // Search prior assistant messages most-recent-first for a numbered
        // list that actually has an item at this position.
        for message in priorAssistantMessages.reversed() {
            if let itemText = numberedListItem(at: ordinal, in: message) {
                return substitute(itemText, into: prompt)
            }
        }
        return prompt
    }

    /// Returns JUST the resolved subject (e.g. "Kairos") for an ordinal
    /// reference in `prompt`, or nil when there's no reference or no matching
    /// list item.
    ///
    /// This is the entry point SemanticRouter uses. Returning the bare subject
    /// instead of a rewritten prompt is the crux of the fix for the "drew a
    /// giant number 2" bug: the caller can then BUILD a clean standalone image
    /// prompt from the subject, rather than trying to surgically splice a name
    /// into the user's conversational phrasing with regexes — which failed
    /// whenever the ordinal and the referring word sat in different sentences
    /// ("I like number 2. Create a logo based on that") and fell through to
    /// appending "(referring to: Kairos)", leaving the literal numeral 2 in
    /// the text for the diffusion model to draw.
    static func resolvedSubject(prompt: String, priorAssistantMessages: [String]) -> String? {
        guard let ordinal = extractOrdinal(from: prompt) else { return nil }
        for message in priorAssistantMessages.reversed() {
            if let itemText = numberedListItem(at: ordinal, in: message) {
                let cleaned = itemText.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? nil : cleaned
            }
        }
        return nil
    }

    /// Clarifies an ordinal reference for a *text* turn by appending the resolved
    /// item, without disturbing the user's own wording.
    ///
    /// Ordinal resolution was previously applied only when building image
    /// prompts, which left a reported failure: in a chat where the assistant had
    /// listed ten brand names, "I like the no.8 name that you gave me" reached
    /// llama3:8b unmodified. The model then had to re-read a long transcript,
    /// mis-counted the list, and confidently answered about a different name
    /// entirely — and once that wrong name was in the transcript it kept being
    /// reinforced on later turns.
    ///
    /// Resolving the index in Swift removes the model's need to count at all.
    /// The original phrasing is preserved and the resolution appended, rather
    /// than substituted, because a text conversation should still read naturally
    /// in the transcript — unlike an image prompt, where only the subject matters.
    ///
    /// Returns nil when there is no ordinal, or no list to resolve it against.
    static func clarification(prompt: String, priorAssistantMessages: [String]) -> String? {
        guard let ordinal = extractOrdinal(from: prompt) else { return nil }
        for message in priorAssistantMessages.reversed() {
            if let itemText = numberedListItem(at: ordinal, in: message) {
                let cleaned = itemText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return nil }
                // Only worth appending when the user didn't already name it —
                // "I like no.8, Chic Boutique" needs no help.
                guard !prompt.lowercased().contains(cleaned.lowercased()) else { return nil }
                return "\(prompt)\n\n(For clarity, item \(ordinal) in your earlier list was: \(cleaned))"
            }
        }
        return nil
    }

    // MARK: - Ordinal extraction

    private static let wordNumbers: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10
    ]

    /// Finds patterns like "number 10", "no.8", "10th", "#10", or word-forms
    /// like "the first", "the third" anywhere in the prompt.
    private static func extractOrdinal(from prompt: String) -> Int? {
        let lower = prompt.lowercased()

        // "number 10" / "no. 8" / "no8" / "#10" / "num 3"
        //
        // The "no." abbreviation was a real reported miss: a user wrote "I like
        // the no.8 name that you gave me" and nothing matched, so the reference
        // was never resolved and the answering model invented a different name
        // from the list. Abbreviations are how people actually write ordinals, so
        // they belong here rather than being treated as an edge case.
        if let range = lower.range(
            of: #"(number\s*|no\.?\s*|num\.?\s*|#)(\d+)"#,
            options: .regularExpression
        ) {
            let digits = lower[range].filter(\.isNumber)
            if let n = Int(digits) { return n }
        }
        // "10th" / "3rd" / "1st" / "2nd"
        if let range = lower.range(of: #"\b(\d+)(st|nd|rd|th)\b"#, options: .regularExpression) {
            let digits = lower[range].filter(\.isNumber)
            if let n = Int(digits) { return n }
        }
        // Word forms: "the first", "the third one", etc.
        //
        // Scanned in ascending numeric order rather than dictionary order, which
        // is non-deterministic in Swift: with "first" and "second" both present,
        // the earlier ordinal is the more likely referent, and an arbitrary pick
        // made this behave differently between runs.
        for (word, value) in wordNumbers.sorted(by: { $0.value < $1.value }) {
            if lower.contains(word) { return value }
        }
        return nil
    }

    // MARK: - Numbered list lookup

    /// Extracts the text of numbered list item `n` from `text`, matching
    /// lines like "10. SustainStitch - A play on words...". Only takes the
    /// portion before a " - " or ":" separator if present, since list items
    /// in model output are often "Name - description"; we want just the name
    /// for substitution, not the whole explanatory sentence.
    private static func numberedListItem(at n: Int, in text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let dotIndex = trimmed.firstIndex(of: ".") else { continue }
            let prefix = trimmed[trimmed.startIndex..<dotIndex]
            guard let number = Int(prefix), number == n else { continue }

            var rest = String(trimmed[trimmed.index(after: dotIndex)...]).trimmingCharacters(in: .whitespaces)
            // Strip markdown bold markers if present ("**SustainStitch**").
            rest = rest.replacingOccurrences(of: "**", with: "")
            // Prefer just the name/title portion before a description separator.
            if let dashRange = rest.range(of: " - ") {
                return String(rest[rest.startIndex..<dashRange.lowerBound])
            }
            if let colonRange = rest.range(of: ": ") {
                return String(rest[rest.startIndex..<colonRange.lowerBound])
            }
            return rest
        }
        return nil
    }

    // MARK: - Substitution

    /// Replaces the ordinal reference phrase in the prompt with the resolved
    /// item text, e.g. "create a logo for the number 10 brand name you
    /// suggested" -> "create a logo for SustainStitch".
    private static func substitute(_ resolvedText: String, into prompt: String) -> String {
        let patterns = [
            #"(the\s+)?number\s+\d+\s+(brand\s+name\s+|name\s+)?(you\s+suggested\s*)?"#,
            #"(the\s+)?#\d+\s+(brand\s+name\s+|name\s+)?(you\s+suggested\s*)?"#,
            #"(the\s+)?\d+(st|nd|rd|th)\s+(one\s+|option\s+|name\s+)?(you\s+suggested\s*)?"#,
            #"(the\s+)?(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\s+(one\s+|option\s+|name\s+)?(you\s+suggested\s*)?"#
        ]
        for pattern in patterns {
            if let range = prompt.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return prompt.replacingCharacters(in: range, with: resolvedText)
            }
        }
        // Fallback: couldn't cleanly substitute in place — just append clearly.
        return "\(prompt) (referring to: \(resolvedText))"
    }
}
