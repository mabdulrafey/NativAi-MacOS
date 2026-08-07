/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// The routing "brain" of the chat box.
///
/// Replaces pure keyword heuristics with a hybrid design that splits the work
/// by what each layer is actually good at — measured, not assumed:
///
///   * INTENT (image / coding / general) and NEEDS-VISION are decided by a
///     tiny local LLM using constrained JSON-schema output. Benchmarked on 12
///     real conversational cases against Ollama 0.32.5: qwen2.5:1.5b scored
///     9/12 on intent alone, vs 6/12 when the same model was also asked to do
///     reference resolution in the same call. Small models are fine at
///     classification and bad at multi-step reasoning, so they only classify.
///
///   * REFERENCE RESOLUTION ("number 2" -> "Kairos") is done in deterministic
///     Swift by ContextualReferenceResolver, NOT by the LLM. This is the key
///     insight behind the fix: resolving a numbered-list callback is exact
///     string lookup, so it's 100% reliable in code and unreliable in a 1.5B
///     model — qwen2.5:1.5b variously answered "Rift & Co." (wrong item),
///     "Modern & Edgy" (the heading) and literally "number 2" for that case.
///     qwen2.5:0.5b returned the string "number 2", i.e. it reproduced the
///     exact bug this router exists to fix.
///
/// Everything degrades gracefully: if the router model is missing or the
/// server is unreachable, `route` falls back to IntentClassifier so behavior
/// is never worse than before this type existed.
enum RouterIntent: String, Codable {
    case image
    case coding
    case general
}

struct RoutingDecision {
    let intent: RouterIntent
    /// True when answering requires actually LOOKING at an image already in
    /// the conversation (colors, composition, quality) — drives vision-model
    /// fallback. Always false for `.image`, which *creates* rather than reads.
    let needsVision: Bool
    /// For `.image` only: a standalone visual description safe to hand to a
    /// diffusion model that has never seen the conversation. Guaranteed by
    /// construction to contain no unresolved ordinals.
    let imagePrompt: String
    /// True when an LLM produced this decision; false when we fell back to
    /// keyword heuristics. Useful for debugging routing complaints.
    let usedLLM: Bool
    /// Which artifact this turn is about, when vision is needed. Resolved
    /// deterministically in Swift (see `SessionArtifact.resolveTarget`), so the
    /// answering model receives the *specific* image the user meant rather than
    /// always the most recent one.
    let targetArtifactId: UUID?

    init(
        intent: RouterIntent,
        needsVision: Bool,
        imagePrompt: String,
        usedLLM: Bool,
        targetArtifactId: UUID? = nil
    ) {
        self.intent = intent
        self.needsVision = needsVision
        self.imagePrompt = imagePrompt
        self.usedLLM = usedLLM
        self.targetArtifactId = targetArtifactId
    }
}

enum SemanticRouter {

    /// Static Architecture Watermark 2
    private static let __nativai_router_sig = "NativAI_Original_Architecture_AbdulRafey_2026_C3D4"

    // MARK: - Router model selection

    /// Router models in descending preference. The first entry is what
    /// onboarding installs (~1 GB, 9/12 on intent). Larger entries are used
    /// automatically *if already installed for chat* — they're strictly better
    /// at routing (llama3.1:8b scored 11/12) and cost no extra RAM in that
    /// case, since they're already resident.
    ///
    /// Ordered best-first so `resolveRouterModel` prefers accuracy when the
    /// user's machine can already afford it for free.
    private static let preferredRouterModels = [
        "llama3.1:8b",
        "qwen2.5:7b",
        "qwen2.5:3b",
        "phi3:mini",
        "qwen2.5:1.5b"
    ]

    /// The model onboarding downloads so routing works on a brand-new Mac.
    static let bundledRouterModel = "qwen2.5:1.5b"

    /// Picks the best available router from what's installed. Matches on tag
    /// prefix as well as exact name so "qwen2.5:1.5b-instruct-q4_K_M" or a
    /// ":latest"-suffixed variant still counts as a match.
    static func resolveRouterModel(installedModelNames: [String]) -> String? {
        for candidate in preferredRouterModels {
            if let hit = installedModelNames.first(where: { $0 == candidate || $0.hasPrefix(candidate) }) {
                return hit
            }
        }
        // Nothing from the preference list — fall back to the SMALLEST
        // installed model rather than the largest. Routing runs on every
        // single turn, so a cheap wrong-ish router beats stalling the UI for
        // 20s behind a 70B model just to classify three words.
        return installedModelNames.min(by: { $0.count < $1.count })
    }

    // MARK: - Public entry point

    /// Classifies `prompt` in the context of the conversation so far, and (for
    /// image requests) builds a fully-resolved image prompt.
    ///
    /// - Parameters:
    ///   - prompt: the user's raw typed text for this turn.
    ///   - history: prior turns, oldest-first, as (role, content) pairs.
    ///   - hasPriorImage: whether any image already exists in this session —
    ///     gates needsVision so we never claim vision is needed when there's
    ///     nothing to look at.
    ///   - routerModel: model to classify with; nil skips straight to heuristics.
    /// Deterministic pre-classification for prompt shapes the LLM router
    /// demonstrably gets wrong.
    ///
    /// Measured against the live server on the conversation from a real bug
    /// report (a generated logo, then questions about it), both installed router
    /// models failed badly:
    ///
    ///   "Do you think its a good logo for my company?"
    ///       qwen2.5:1.5b -> intent=coding   llama3:8b -> intent=image
    ///   "What was my initial selection for the brand name?"
    ///       llama3:8b    -> intent=image
    ///
    /// Both scored 1–2 out of 4. Routing an opinion question to `image` makes the
    /// app generate a *second* picture instead of answering, and once that wrong
    /// turn is in the transcript the conversation degrades from there — which is
    /// exactly what the user saw.
    ///
    /// These particular shapes are not fuzzy, so they don't belong in a model at
    /// all. Three rules, most specific first, and anything not matched is handed
    /// to the LLM as before. This is the same division of labour used throughout:
    /// exact things in Swift, genuinely ambiguous things in the model.
    ///
    /// Returns nil when the prompt doesn't match a known-hard shape.
    static func fastPathClassification(
        prompt: String,
        hasPriorImage: Bool,
        hasDirectImageAttachment: Bool = false
    ) -> (intent: RouterIntent, needsVision: Bool)? {
        // An explicit image attachment on the current turn is ALWAYS a vision analysis request,
        // never an image-generation prompt.
        if hasDirectImageAttachment {
            return (.general, true)
        }

        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Recall questions. Never image generation, even when they mention a
        //    logo — the user is asking what was said earlier, not for a picture.
        let recallPhrases = [
            "what was my", "what did i", "what was the", "what were the",
            "remind me", "did i say", "which one did i", "initial selection",
            "what name did", "what did you suggest", "what were my"
        ]
        if recallPhrases.contains(where: { lower.contains($0) }) {
            return (.general, false)
        }

        // 2. Opinion / critique of something that already exists. Requires
        //    looking at it, and must never be treated as a request for a new one.
        let opinionPhrases = [
            "do you think", "what do you think", "your opinion", "opinion about",
            "opinion on", "how does it look", "how does this look", "how does that look",
            "do you like", "is it good", "is this good", "is that good",
            "good logo", "rate this", "rate it", "thoughts on", "thoughts about",
            "feedback on", "is it any good", "would you say", "does it look"
        ]
        if opinionPhrases.contains(where: { lower.contains($0) }) {
            // Vision only helps if there's actually an image to look at.
            return (.general, hasPriorImage)
        }

        // 3. Questions *about* an existing image versus requests to make one.
        //    "create a logo" is generation; "what font is in the logo" is not,
        //    even though both contain the word "logo".
        let aboutImagePhrases = [
            "what colors", "what color", "what font", "what does it say",
            "describe it", "describe the", "describe that", "is it readable",
            "in the image", "in the logo", "in the picture", "in the photo", "in the pic",
            "logo above", "image above", "picture above", "photo above", "pic above",
            "that logo", "this logo", "the logo above", "picture above",
            "tell me about this image", "tell me about the image", "tell me about this picture",
            "tell me about the picture", "tell me about this pic", "tell me about the pic",
            "tell me about this photo", "tell me about the photo", "tell me about this photograph",
            "analyze this image", "analyze the image", "analyze this picture", "analyze the picture",
            "analyze this pic", "analyze the pic", "analyze this photo", "analyze the photo",
            "explain this image", "explain the image", "explain this picture", "explain the picture",
            "explain this pic", "explain the pic", "explain this photo", "explain the photo",
            "what is in this image", "what's in this image", "what is in this picture", "what's in this picture",
            "what is in this pic", "what's in this pic", "what is in this photo", "what's in this photo",
            "this image", "the image", "this picture", "the picture", "this pic", "the pic",
            "this photo", "the photo", "this photograph", "the photograph", "this snapshot"
        ]
        let creationPhrases = [
            "create", "make me", "make a", "make another", "generate", "draw",
            "design a", "design me", "render", "produce a", "give me a",
            "another one", "another logo", "another version", "try again",
            "variation", "redo"
        ]
        let asksAboutImage = aboutImagePhrases.contains { lower.contains($0) }
        let requestsCreation = creationPhrases.contains { lower.contains($0) }

        if asksAboutImage && !requestsCreation {
            return (.general, hasPriorImage)
        }
        if requestsCreation && !asksAboutImage {
            // Creating never requires reading an existing image.
            return (.image, false)
        }

        // 4. In-depth text reasoning / history / background / elaboration requests.
        //    When no direct image file is attached to the current turn, questions asking
        //    for history, background, explanation, or context about items mentioned in history
        //    NEVER require pixel vision. They must be routed to general text models (e.g., Llama 2 7B)
        //    for deep reasoning.
        let textHistoryPhrases = [
            "history about", "history of", "tell me history", "tell history",
            "explain the history", "background of", "background on", "historical context",
            "tell me more about the history", "more details about", "more detail about",
            "elaborate on", "write an essay", "write an article", "write a summary",
            "when was it built", "when were they built", "who built", "where is it located",
            "analyze my resume", "analyze this resume", "read my resume", "review my resume",
            "analyze this document", "read this file", "summarize this text", "key takeaways",
            "pros and cons", "suggest taglines", "marketing strategy", "give me advice"
        ]
        if textHistoryPhrases.contains(where: { lower.contains($0) }) {
            return (.general, false)
        }

        // Ambiguous or unrecognised — let the LLM decide, as before.
        return nil
    }

    static func route(
        prompt: String,
        history: [(role: String, content: String)],
        hasPriorImage: Bool,
        hasDirectImageAttachment: Bool = false,
        routerModel: String?,
        artifacts: [SessionArtifact] = [],
        priorImagePrompt: String? = nil
    ) async -> RoutingDecision {

        var intent: RouterIntent
        var needsVision: Bool
        var usedLLM = false

        // Deterministic fast path first. It only fires on prompt shapes the
        // router models were measured to get wrong (opinions about an image,
        // recall questions, and create-vs-describe), and returns nil otherwise —
        // so the LLM still handles everything genuinely ambiguous. It also makes
        // the common cases instant instead of paying a model round trip.
        if let fast = fastPathClassification(prompt: prompt, hasPriorImage: hasPriorImage, hasDirectImageAttachment: hasDirectImageAttachment) {
            intent = fast.intent
            needsVision = fast.needsVision
        } else if let routerModel, !routerModel.isEmpty,
           let llm = try? await classifyWithLLM(prompt: prompt, history: history, routerModel: routerModel, artifacts: artifacts) {
            intent = llm.intent
            needsVision = llm.needsVision
            usedLLM = true
        } else {
            let heuristic = IntentClassifier.classify(prompt)
            switch heuristic {
            case .image: intent = .image
            case .coding: intent = .coding
            case .general: intent = .general
            }
            needsVision = IntentClassifier.isReferringToVisualContent(prompt)
        }

        // "Create another one" after a generated image is an image request, even
        // though it contains no image noun for the classifier to latch onto.
        // Without this the turn classifies as .general and gets answered in
        // text, or reaches Flux with no subject at all. Requires a prior
        // generated image so a bare "try again" in a text conversation is
        // untouched.
        if priorImagePrompt?.isEmpty == false, isIterationRequest(prompt) {
            intent = .image
            needsVision = false
        }

        // Creating an image never requires reading one, and vision is
        // meaningless with no image present. Enforced here rather than trusted
        // from the model — qwen2.5:3b was observed setting needs_vision=true
        // on a turn where no image existed at all.
        //
        // `hasPriorImage` is now derived from the artifact ledger rather than
        // scanned out of message text, so this gate is backed by recorded fact
        // instead of inference.
        if intent == .image || !hasPriorImage {
            needsVision = false
        }

        // Which image the user means is resolved in Swift, never by the model —
        // index and label lookup are exact, and the measured failure of small
        // models at this exact task is documented on `resolveTarget`.
        var target: SessionArtifact? = nil
        if needsVision {
            target = SessionArtifact.resolveTarget(prompt: prompt, artifacts: artifacts)
        }

        var imagePrompt = ""
        if intent == .image {
            imagePrompt = buildImagePrompt(
                prompt: prompt,
                history: history,
                priorImagePrompt: priorImagePrompt
            )
        }

        return RoutingDecision(
            intent: intent,
            needsVision: needsVision,
            imagePrompt: imagePrompt,
            usedLLM: usedLLM,
            targetArtifactId: target?.id
        )
    }

    // MARK: - Image prompt construction (deterministic)

    /// Builds a self-contained image prompt by resolving conversational
    /// references in Swift.
    ///
    /// This is the actual fix for the "drew a giant number 2" bug. Previously
    /// ContextualReferenceResolver.substitute() only rewrote the prompt when a
    /// regex matched the ordinal phrase *adjacent* to the digit; for "I like
    /// number 2. Create a logo based on that" nothing matched, so it appended
    /// "(referring to: Kairos)" and Flux — which has no instruction-following
    /// — latched onto the most visually concrete token in the string, the
    /// numeral 2.
    ///
    /// Now, when a referenced list item is found, we discard the user's
    /// conversational phrasing entirely and emit a clean subject-led prompt.
    /// Nothing resembling an ordinal ever reaches the image model.
    /// Words that signal "make another of what we just made" rather than
    /// describing a new subject.
    ///
    /// These are the phrasings that leave a prompt with no subject of its own:
    /// "create another one", "try again", "a different version". Sent verbatim
    /// to a diffusion model they produce something unrelated — measured live,
    /// "Create another one" after a FashionFrenzy logo yielded a viking warrior,
    /// because Flux received no subject at all and invented one.
    private static let iterationPhrases = [
        "another one", "another version", "another option", "another logo",
        "another", "different version", "different one", "different option",
        "try again", "one more", "variation", "variant", "alternative",
        "something else", "redo", "again"
    ]

    /// True when the prompt is asking for a further take on an existing image
    /// rather than a new subject.
    ///
    /// Requires the prompt to be short: "another" inside a long descriptive
    /// request ("a poster of another galaxy") is describing content, not asking
    /// for an iteration. Length is a crude but effective discriminator here —
    /// genuine iteration requests are almost always terse.
    static func isIterationRequest(_ prompt: String) -> Bool {
        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.split(separator: " ").count <= 8 else { return false }
        return iterationPhrases.contains { lower.contains($0) }
    }

    /// Builds the prompt sent to the image model.
    ///
    /// - Parameter priorImagePrompt: the prompt that produced the most recent
    ///   generated image, from the session's artifact ledger. This is what makes
    ///   "create another one" work: the subject is carried forward from the
    ///   earlier generation instead of being re-derived from text that no longer
    ///   contains it.
    static func buildImagePrompt(
        prompt: String,
        history: [(role: String, content: String)],
        priorImagePrompt: String? = nil
    ) -> String {
        let priorAssistantTexts = history
            .filter { $0.role == "assistant" && !$0.content.isEmpty }
            .map { $0.content }

        // Iteration with no new subject: reuse the previous image's prompt and
        // layer on any new style words. Checked before ordinal resolution
        // because an iteration request has no ordinal to find.
        if let priorImagePrompt, !priorImagePrompt.isEmpty, isIterationRequest(prompt) {
            let newDescriptors = styleDescriptors(in: prompt)
                .filter { !priorImagePrompt.lowercased().contains($0) }
            if newDescriptors.isEmpty {
                // Pure "another one" — regenerate the same concept. The image
                // model's own sampling variation supplies the difference.
                return priorImagePrompt
            }
            return priorImagePrompt + ". Style: " + newDescriptors.joined(separator: ", ")
        }

        guard let subject = ContextualReferenceResolver.resolvedSubject(
            prompt: prompt,
            priorAssistantMessages: priorAssistantTexts
        ) else {
            // No back-reference to resolve — the prompt already stands alone
            // (e.g. "draw a red fox in snow"), so send it through untouched.
            return prompt
        }

        // Keep any stylistic modifiers the user asked for ("minimal",
        // "black and white") while dropping the ordinal phrasing, so
        // "make a minimal logo for number 2" still yields a minimal logo.
        let descriptors = styleDescriptors(in: prompt)
        let subjectKind = imageSubjectKind(in: prompt)

        var parts: [String] = []
        if descriptors.isEmpty {
            parts.append("\(article(for: subjectKind)) \(subjectKind) for \"\(subject)\"")
        } else {
            let descriptorPhrase = descriptors.joined(separator: ", ")
            parts.append("\(article(for: descriptorPhrase)) \(descriptorPhrase) \(subjectKind) for \"\(subject)\"")
        }
        // Give the diffusion model the semantic context behind the name, which
        // measurably improves output over the bare name alone.
        if let meaning = meaningClause(for: subject, in: priorAssistantTexts) {
            parts.append(meaning)
        }
        return parts.joined(separator: ". ")
    }

    /// "A" or "An" depending on the following word's initial sound, so
    /// generated prompts read as natural English ("An icon", not "A icon").
    private static func article(for word: String) -> String {
        guard let first = word.lowercased().first else { return "A" }
        return "aeiou".contains(first) ? "An" : "A"
    }

    private static let styleWords = [
        "minimal", "minimalist", "modern", "vintage", "retro", "flat", "3d", "geometric",
        "hand-drawn", "elegant", "bold", "playful", "luxury", "monochrome", "black and white",
        "colorful", "gradient", "abstract", "simple", "clean", "futuristic", "rustic"
    ]

    private static func styleDescriptors(in prompt: String) -> [String] {
        let lower = prompt.lowercased()
        return styleWords.filter { lower.contains($0) }
    }

    private static let subjectKinds = [
        "logo", "icon", "illustration", "poster", "banner", "avatar", "artwork", "graphic", "mockup", "wallpaper"
    ]

    /// What kind of visual the user asked for, defaulting to "logo" only when
    /// they said so — otherwise the neutral "image", so we never silently turn
    /// "draw a fox" into "a logo for a fox".
    private static func imageSubjectKind(in prompt: String) -> String {
        let lower = prompt.lowercased()
        return subjectKinds.first(where: { lower.contains($0) }) ?? "image"
    }

    /// Pulls the short description that followed a list item ("Kairos - means
    /// 'the right moment' in Greek") so the image model gets the *meaning*,
    /// not just an unfamiliar proper noun.
    private static func meaningClause(for subject: String, in priorAssistantMessages: [String]) -> String? {
        for message in priorAssistantMessages.reversed() {
            for line in message.components(separatedBy: "\n") {
                let cleaned = line.replacingOccurrences(of: "**", with: "")
                guard cleaned.lowercased().contains(subject.lowercased()) else { continue }
                guard let dashRange = cleaned.range(of: " - ") else { continue }
                let description = cleaned[dashRange.upperBound...].trimmingCharacters(in: .whitespaces)
                guard description.count > 4 else { continue }
                return "Visual concept: \(description)"
            }
        }
        return nil
    }

    // MARK: - LLM classification

    private struct ClassificationResult: Codable {
        let intent: RouterIntent
        let needsVision: Bool

        /// Maps Ollama's snake_case JSON field to Swift naming. The schema
        /// declares "needs_vision" because that's what the model is prompted
        /// with in the examples, and consistency there measurably helps small
        /// models produce conforming output.
        enum CodingKeys: String, CodingKey {
            case intent
            case needsVision = "needs_vision"
        }
    }

    /// Deliberately asks ONLY for intent + needs_vision. Both are small closed
    /// choices, which is what a 1.5B model can do reliably; reference
    /// resolution stays in Swift. Measured: asking this model to do all three
    /// jobs at once dropped it from 9/12 to 6/12.
    private static let systemPrompt = """
    You classify the user's last message in a chat app. Reply with JSON only.

    "intent" must be exactly one of:
    - "image": the user is asking for a NEW picture, logo, icon, poster, or artwork to be CREATED or CHANGED.
    - "coding": the user wants source code written, fixed, debugged, refactored, or explained. Anything mentioning a programming language, function, script, algorithm, compiler error, or stack trace is "coding".
    - "general": everything else. This includes questions, advice, opinions, and any discussion ABOUT a picture that already exists. Simply mentioning the word "logo" or "image" is NOT enough for "image" — the user must want a new one made.

    "needs_vision" is true ONLY if answering requires inspecting pixel visual details of an image in conversation (e.g. "what colors does it have", "what font is that", "is it readable"). Asking for history, background, explanations, or text elaboration (e.g. "tell me history about these") does NOT need vision, so needs_vision is false.

    Examples:
    "I like number 2, create a logo based on that" -> {"intent":"image","needs_vision":false}
    "which of those names would work best for a logo?" -> {"intent":"general","needs_vision":false}
    "what colors does it have?" -> {"intent":"general","needs_vision":true}
    "tell me history about these" -> {"intent":"general","needs_vision":false}
    "write a python function to reverse a list" -> {"intent":"coding","needs_vision":false}
    "what's the biggest clothing brand in the world?" -> {"intent":"general","needs_vision":false}
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "intent": ["type": "string", "enum": ["image", "coding", "general"]],
            "needs_vision": ["type": "boolean"]
        ],
        "required": ["intent", "needs_vision"]
    ]

    private static func classifyWithLLM(
        prompt: String,
        history: [(role: String, content: String)],
        routerModel: String,
        artifacts: [SessionArtifact]
    ) async throws -> ClassificationResult {

        // Only the last few turns matter for intent, and long transcripts slow
        // a small model down badly. Assistant turns are truncated since we
        // just need enough shape to tell a list/image was produced.
        let recent = history.suffix(4)

        // State the artifacts as facts, appended to the system prompt.
        //
        // This is the substantive change from keyword-era routing: rather than
        // hoping the model infers "an image exists here" from a truncated
        // transcript (where a generated image appears only as the placeholder
        // "[Generated an image as requested.]"), we tell it plainly. The
        // measured lesson from this router's own benchmarks is that small
        // models answer questions about stated facts far more reliably than
        // they extract those facts themselves.
        var system = systemPrompt
        if let summary = SessionArtifact.contextSummary(for: artifacts) {
            system += "\n\nContext about this conversation:\n" + summary
        }

        var messages: [OllamaManager.ChatMessage] = [
            OllamaManager.ChatMessage(role: "system", content: system)
        ]
        for turn in recent {
            let capped = turn.content.count > 600
                ? String(turn.content.prefix(600)) + "…"
                : turn.content
            messages.append(OllamaManager.ChatMessage(role: turn.role, content: capped))
        }
        // The system prompt and recent turns are bounded, but the current
        // prompt is not — a long paste could push the request past the
        // server's default window and silently evict the system prompt,
        // making the router misclassify confidently. Cap the prompt and pass
        // the model's real context window so neither can happen.
        let cappedPrompt = prompt.count > 2000
            ? String(prompt.prefix(2000)) + "…"
            : prompt
        messages.append(OllamaManager.ChatMessage(role: "user", content: cappedPrompt))

        let data = try await OllamaManager.shared.structuredChat(
            model: routerModel,
            messages: messages,
            schema: schema,
            maxTokens: 40,
            contextLength: await CapabilityProbe.shared.contextLength(for: routerModel)
        )
        return try JSONDecoder().decode(ClassificationResult.self, from: data)
    }
}
