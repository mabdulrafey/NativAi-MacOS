/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Classifies what kind of model a prompt likely needs, using lightweight
/// offline keyword heuristics — deliberately NOT an LLM call, since spinning
/// up a whole model just to decide which model to use would be slow and
/// defeats the point of staying fully offline/fast. This is the same kind of
/// simple intent-routing real multi-model products do under the hood.
enum PromptIntent {
    case image
    case coding
    case general
}

enum IntentClassifier {

    // Verbs that indicate a request to PRODUCE something (as opposed to
    // discussing/evaluating something that already exists). "build" alone
    // was missing here (only the phrase "build me" was present) — since
    // "build" as a bare word never matched any entry, "can you build logo
    // based on my resume" fell through to .general instead of being detected
    // as an image-creation request.
    private static let creationVerbs = [
        "generate", "create", "make", "draw", "design", "render", "produce", "build"
    ]

    // Nouns that indicate the thing being requested is a visual asset.
    // Matched near a creation verb rather than as a single fixed phrase, so
    // natural phrasing variation ("create logo for X" vs "create a logo for
    // X" vs "can you create the logo") is all caught by the same rule instead
    // of needing every exact wording enumerated ahead of time.
    private static let imageNouns = [
        "logo", "image", "picture", "icon", "illustration", "artwork", "graphic", "poster", "banner", "avatar"
    ]

    // Phrases that mean the user is talking ABOUT an image that already
    // exists (feedback, opinions, follow-up discussion) rather than asking
    // for a new one. These override an image match, since without this check
    // something like "do you like this logo for my brand" was matching on
    // "logo" near no creation verb... but phrases like "how does this logo
    // look" still contain no creation verb either, so this list exists as an
    // extra explicit safety net for the most common feedback-phrasing patterns.
    private static let discussionOverrideKeywords = [
        "do you like", "what do you think", "is this good", "how does this look",
        "how does this logo", "considering the fact", "considering that", "does this work",
        "is it good", "what do you think about", "your thoughts", "your opinion",
        "does it look", "how do you like", "rate this", "feedback on"
    ]

    private static let codingKeywords = [
        "write code", "write a function", "fix this bug", "debug", "refactor", "swift code",
        "python code", "javascript", "typescript", "write a script", "code snippet",
        "implement a", "class ", "function that", "algorithm for", "regex for", "sql query",
        "write a program", "compile error", "stack trace", "add error handling",
        "optimize this", "make it faster", "add unit tests", "fix the error", "rewrite in",
        "convert to python", "convert to swift", "convert to javascript", "explain line"
    ]

    // Phrases/words that indicate the user is actually referring to a visual
    // thing already on screen — distinct from the broad "general" bucket,
    // which is the classify() default fallback for essentially anything that
    // isn't image-creation or coding. Without this dedicated check, a
    // completely unrelated follow-up question (e.g. "what's the biggest
    // clothing brand?") was matching the old ".general" condition just as
    // much as an actual "is this good?" follow-up, so the previous image
    // kept getting reattached and forced vision routing forever, regardless
    // of topic.
    private static let visualReferenceKeywords = [
        "this logo", "the logo", "this image", "the image", "this picture", "the picture",
        "this design", "the design", "this icon", "the icon", "above", "you generated",
        "you made", "you created", "you drew", "does this", "is this good", "is it good",
        "how does this", "how does it", "what do you think of this", "what do you think about this",
        "rate this", "feedback on this", "improve this", "change this", "edit this", "colors does",
        "colors it has", "what colors"
    ]

    /// True if the prompt is asking about a specific visual thing already in
    /// the conversation, as opposed to a general/unrelated question that
    /// merely happens to follow an image message chronologically.
    static func isReferringToVisualContent(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return visualReferenceKeywords.contains(where: lower.contains)
    }

    static func classify(_ prompt: String) -> PromptIntent {
        let lower = prompt.lowercased()

        if discussionOverrideKeywords.contains(where: lower.contains) {
            return .general
        }
        if isImageCreationRequest(lower) {
            return .image
        }
        if codingKeywords.contains(where: lower.contains) {
            return .coding
        }
        return .general
    }

    /// True if the prompt contains a creation verb reasonably close to an
    /// image-related noun — e.g. "create logo for X", "generate a picture of
    /// Y", "can you draw an icon". Checking proximity (same sentence, verb
    /// appearing before the noun within a short word window) rather than
    /// just "does the prompt contain both words anywhere" avoids false
    /// positives on unrelated sentences that happen to mention both an action
    /// verb and an image noun far apart with unrelated meaning in between.
    private static func isImageCreationRequest(_ lower: String) -> Bool {
        let words = lower.split(separator: " ").map(String.init)
        for (index, word) in words.enumerated() {
            let cleanedWord = word.trimmingCharacters(in: .punctuationCharacters)
            guard creationVerbs.contains(where: { cleanedWord == $0 || cleanedWord.hasPrefix($0) }) else { continue }
            // Look ahead up to 5 words for an image-related noun.
            let windowEnd = min(index + 6, words.count)
            for lookahead in (index + 1)..<windowEnd {
                let candidate = words[lookahead].trimmingCharacters(in: .punctuationCharacters)
                if imageNouns.contains(where: { candidate == $0 || candidate.hasPrefix($0) }) {
                    return true
                }
            }
        }
        return false
    }
}
