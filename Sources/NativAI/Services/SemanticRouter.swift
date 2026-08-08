/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

enum RouterIntent: String, Codable {
    case image
    case coding
    case general
}

struct RoutingDecision {
    let intent: RouterIntent
    let needsVision: Bool
    let imagePrompt: String
    let usedLLM: Bool
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

    private static let __nativai_router_sig = "NativAI_Original_Architecture_AbdulRafey_2026_C3D4"

    // MARK: - Router model selection

    private static let preferredRouterModels = [
        "llama3.1:8b",
        "qwen2.5:7b",
        "qwen2.5:3b",
        "phi3:mini",
        "qwen2.5:1.5b"
    ]

    static let bundledRouterModel = "qwen2.5:1.5b"

    static func resolveRouterModel(installedModelNames: [String]) -> String? {
        for candidate in preferredRouterModels {
            if let hit = installedModelNames.first(where: { $0 == candidate || $0.hasPrefix(candidate) }) {
                return hit
            }
        }
        let nonVisionModels = installedModelNames.filter { name in
            let lower = name.lowercased()
            return !lower.contains("moondream") && !lower.contains("llava") && !lower.contains("bakllava")
        }
        let pool = nonVisionModels.isEmpty ? installedModelNames : nonVisionModels
        return pool.min(by: { estimatedSizeGB($0) < estimatedSizeGB($1) })
    }

    private static func estimatedSizeGB(_ name: String) -> Double {
        let lower = name.lowercased()
        if lower.contains("0.5b") { return 0.5 }
        if lower.contains("1.5b") || lower.contains("1.8b") { return 1.5 }
        if lower.contains("3b") { return 2.0 }
        if lower.contains("7b") || lower.contains("8b") { return 4.5 }
        if lower.contains("14b") { return 9.0 }
        if lower.contains("32b") || lower.contains("34b") { return 20.0 }
        if lower.contains("70b") { return 40.0 }
        return Double(name.count) * 0.1
    }

    // MARK: - Public entry point

    static func fastPathClassification(
        prompt: String,
        hasPriorImage: Bool,
        hasDirectImageAttachment: Bool = false
    ) -> (intent: RouterIntent, needsVision: Bool)? {
        // 0. Explicit image attachment on current turn is ALWAYS a vision request
        if hasDirectImageAttachment {
            return (.general, true)
        }

        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        func matches(_ pattern: String) -> Bool {
            return lower.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }

        // 1. Famous People & Celebrities without Drawing Verbs
        let creationVerbsCheck = #"\b(draw|generate|paint|create|make|render|produce|design)\b"#
        let famousPeoplePattern = #"\b(ronaldo|messi|cristiano|elon musk|steve jobs|taylor swift|barack obama|bill gates|jeff bezos|zuckerberg|kanye|drake|lebron|jordan|kobe|federer|nadal|djokovic|mbappe|haaland)\b"#
        if matches(famousPeoplePattern) && !matches(creationVerbsCheck) {
            let imageNounCheck = #"\b(logo|image|picture|photo|icon|illustration|artwork|poster|banner|avatar)\b"#
            if !matches(imageNounCheck) {
                return (.general, false)
            }
        }

        // 2. Sports Debates, Player Stats & Comparisons
        let sportsTermsPattern = #"\b(ballon d'?ors?|golden boot|mvp|goals|assists|trophies|championship|points per game|touchdowns|home runs|grand slam|world cup|super bowl|nba|nfl|premier league|la liga|champions league|striker|quarterback|pitcher|midfielder|winger)\b"#
        let sportsCompPattern = #"\b(messi vs ronaldo|ronaldo vs messi|who has more|who is better|scored as many|won more|hasn't scored|stats comparison|player comparison|stat comparison|career stats|head to head|vs\.?|versus)\b"#
        if matches(sportsTermsPattern) || matches(sportsCompPattern) {
            if !matches(creationVerbsCheck) {
                return (.general, false)
            }
        }

        // 3. Counter-arguments & Opinion Statements / Rebuttals
        let counterArgPhrases = [
            "but he hasn't", "but she hasn't", "but they haven't", "that's not true",
            "that is not true", "i disagree", "what about", "you're wrong", "you are wrong",
            "on the contrary", "i don't think so", "no way", "actually no", "however,",
            "that makes no sense", "on the other hand"
        ]
        if counterArgPhrases.contains(where: { lower.contains($0) }) {
            return (.general, false)
        }

        // 4. Historical, Factual, Text History & Conversational Elaboration Follow-ups
        let factAndElaborationPhrases = [
            "history about", "history of", "tell me history", "tell history",
            "explain the history", "background of", "background on", "historical context",
            "tell me more about the history", "more details about", "more detail about",
            "elaborate on", "write an essay", "write an article", "write a summary",
            "when was it built", "when were they built", "who built", "where is it located",
            "how old is", "how old are", "significance of", "historical background",
            "tell me about their history", "history behind",
            "explain that further", "explain this further", "explain it further",
            "can you elaborate", "give me more details on", "more details on option",
            "more details on point", "expand on point", "expand on option",
            "why did you pick", "why did you choose", "why did you select", "why did you use",
            "tell me more about step", "tell me more about option", "tell me more about point",
            "clarify what you meant"
        ]
        if factAndElaborationPhrases.contains(where: { lower.contains($0) }) {
            return (.general, false)
        }

        // 5. Recall Questions ("what did I say", "remind me")
        let recallPhrases = [
            "what was my", "what did i", "what was the", "what were the",
            "remind me", "did i say", "which one did i", "initial selection",
            "what name did", "what did you suggest", "what were my"
        ]
        if recallPhrases.contains(where: { lower.contains($0) }) {
            return (.general, false)
        }

        // 6. Mathematical & Scientific Quantitative Reasoning -> Route to .general
        let mathTermsPattern = #"\b(solve|calculate|compute|derivative|integral|equation|formula|theorem|pythagorean|calculus|algebra|trigonometry|arithmetic|square root|variance|standard deviation|matrix multiplication|eigenvalue)\b"#
        let unitConvertPattern = #"\bconvert\s+\d+(\.\d+)?\s*(miles|km|kilometers|meters|feet|inches|pounds|kg|kilograms|celsius|fahrenheit|gallons|liters)\s+to\s+[a-z]+\b"#
        if matches(unitConvertPattern) || matches(mathTermsPattern) {
            let codeImplCheck = #"\b(script|code|python|swift|javascript|java|c\+\+|function|program|app|algorithm code)\b"#
            if !matches(codeImplCheck) {
                return (.general, false)
            }
        }

        // 7. Business Strategy & Comparisons -> Route to .general
        let businessCompPattern = #"\b(swot|swot analysis|pestel|pricing strategy|go to market|gtm|market research|business model|value proposition|competitive analysis|cost-benefit|return on investment|roi|market entry|unit economics)\b"#
        let comparisonPattern = #"\b(compare\s+.+\s+(to|with|and|vs\.?|versus)|alternatives?\s+to\b|which\s+(one\s+)?is\s+better\b|pros\s+and\s+cons\s+of\b|tradeoffs?\s+between\b)\b"#
        if matches(businessCompPattern) || matches(comparisonPattern) {
            return (.general, false)
        }

        // 8. Storywriting & Creative Writing -> Route to .general
        let verbalImageryPattern = #"\b(with words|in words|using words|verbally|prose|narrative|scene description)\b"#
        let storyPattern = #"\b(write|tell|create|compose)\s+(a\s+)?(story|tale|poem|essay|narrative|novel|script|dialogue)\b"#
        if matches(verbalImageryPattern) || matches(storyPattern) {
            return (.general, false)
        }

        // 9. Logo & Design Text Brainstorming / Concepts -> Route to .general
        let designConceptPattern = #"\b(logo|icon|banner|poster)\s+(ideas?|concepts?|briefs?|names?|suggestions?|taglines?|slogans?|palettes?|color schemes?|themes?|guidelines?|descriptions?)\b"#
        let conceptForDesignPattern = #"\b(ideas?|concepts?|briefs?|taglines?|slogans?|color palette|hex codes?|names?)\s+for\s+(a|the|my)?\s*(logo|brand|design|icon|company|business)\b"#
        if matches(designConceptPattern) || matches(conceptForDesignPattern) {
            return (.general, false)
        }

        // 10. Vision Q&A / Inspection / Opinion & Critique on Existing Image
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
            "this photo", "the photo", "this photograph", "the photograph", "this snapshot",
            "critique", "feedback on", "thoughts on", "changes would you recommend", "changes do you recommend",
            "recommend changes", "what changes", "how to improve", "how would you improve", "suggestions for changes",
            "what would you change", "any changes", "improvements", "recommendation"
        ]
        let opinionPhrases = [
            "do you think", "what do you think", "your opinion", "opinion about",
            "opinion on", "how does it look", "how does this look", "how does that look",
            "do you like", "is it good", "is this good", "is that good",
            "good logo", "rate this", "rate it", "would you say", "does it look"
        ]
        if aboutImagePhrases.contains(where: { lower.contains($0) }) || opinionPhrases.contains(where: { lower.contains($0) }) {
            return (.general, hasPriorImage)
        }

        // 11. Web & UI Code Design -> Route to .coding
        let webUiTechPattern = #"\b(html|css|tailwind|bootstrap|sass|scss|less|react|vue|angular|svelte|next\.?js|nuxt|jsx|tsx|flexbox|grid|stylesheet)\b"#
        let uiElementPattern = #"\b(landing page|navbar|navigation bar|modal|dropdown|button|ui button|ui component|header|footer|sidebar|card component|form layout)\b"#
        let uiCodeActionPattern = #"\b(design|write|create|build|make|code|implement|generate|style|layout)\b"#
        if (matches(webUiTechPattern) || matches(uiElementPattern)) && matches(uiCodeActionPattern) {
            return (.coding, false)
        }

        // 12. Shell & Terminal Automation Scripts -> Route to .coding
        let shellScriptPattern = #"\b(bash|zsh|sh|shell|powershell|cmd|terminal|command line|git|docker|docker-compose|dockerfile|container|kubernetes|k8s|kubectl|helm|cron|cronjob|makefile|awk|sed|grep)\b"#
        let shellActionPattern = #"\b(script|command|compose|dockerfile|makefile|workflow|pipeline|deployment|cronjob|cron job|automation)\b"#
        let directShellPhrases = [
            "bash script", "python script", "shell script", "zsh script", "powershell script",
            "docker compose", "dockerfile", "git command", "cron job", "makefile", "k8s deployment"
        ]
        if (matches(shellScriptPattern) && matches(shellActionPattern)) || directShellPhrases.contains(where: { lower.contains($0) }) {
            return (.coding, false)
        }

        // 13. Software Architecture & System Design Prompts -> Route to .coding
        let techDesignNouns = #"\b(schema|database|db|rest\s*api|graphql|endpoint|microservice|architecture|system design|wireframe|markdown table|state machine)\b"#
        if matches(techDesignNouns) {
            let techActions = #"\b(design|create|build|write|implement|architecture|structure|generate)\b"#
            if matches(techActions) {
                return (.coding, false)
            }
        }

        // 14. SVG Code & Vector Markup Requests -> Route to .coding
        let svgPattern = #"\b(svg|vector code|xml markup)\b"#
        if matches(svgPattern) {
            return (.coding, false)
        }

        // 15. Art Styles & Artistic Image Generation -> Route to .image
        let artStylePattern = #"\b(anime style|manga style|realistic portrait|photorealistic|watercolor painting|oil painting|charcoal sketch|pencil drawing|3d isometric|isometric room|isometric render|cyberpunk|steampunk|concept art|pixel art|digital art|pop art|impressionist|surrealist|cinematic lighting|octane render|unreal engine render|chibi style)\b"#
        let artNounPattern = #"\b(portrait|painting|sketch|drawing|render|cityscape|landscape|artwork|illustration|wallpaper|picture)\b"#
        if matches(artStylePattern) || (matches(artNounPattern) && matches(#"\b(cyberpunk|steampunk|anime|watercolor|oil|isometric|pixel art|3d)\b"#)) {
            return (.image, false)
        }

        // 16. True Image Creation Requests vs Questions about existing images
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
            return (.image, false)
        }

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

        if priorImagePrompt?.isEmpty == false, isIterationRequest(prompt) {
            intent = .image
            needsVision = false
        }

        if intent == .image || !hasPriorImage {
            needsVision = false
        }

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

    private static let iterationPhrases = [
        "another one", "another version", "another option", "another logo",
        "another", "different version", "different one", "different option",
        "try again", "one more", "variation", "variant", "alternative",
        "something else", "redo", "again"
    ]

    static func isIterationRequest(_ prompt: String) -> Bool {
        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.split(separator: " ").count <= 8 else { return false }
        return iterationPhrases.contains { lower.contains($0) }
    }

    static func buildImagePrompt(
        prompt: String,
        history: [(role: String, content: String)],
        priorImagePrompt: String? = nil
    ) -> String {
        let priorAssistantTexts = history
            .filter { $0.role == "assistant" && !$0.content.isEmpty }
            .map { $0.content }

        if let priorImagePrompt, !priorImagePrompt.isEmpty, isIterationRequest(prompt) {
            let newDescriptors = styleDescriptors(in: prompt)
                .filter { !priorImagePrompt.lowercased().contains($0) }
            if newDescriptors.isEmpty {
                return priorImagePrompt
            }
            return priorImagePrompt + ". Style: " + newDescriptors.joined(separator: ", ")
        }

        guard let subject = ContextualReferenceResolver.resolvedSubject(
            prompt: prompt,
            priorAssistantMessages: priorAssistantTexts
        ) else {
            return prompt
        }

        let descriptors = styleDescriptors(in: prompt)
        let subjectKind = imageSubjectKind(in: prompt)

        var parts: [String] = []
        if descriptors.isEmpty {
            parts.append("\(article(for: subjectKind)) \(subjectKind) for \"\(subject)\"")
        } else {
            let descriptorPhrase = descriptors.joined(separator: ", ")
            parts.append("\(article(for: descriptorPhrase)) \(descriptorPhrase) \(subjectKind) for \"\(subject)\"")
        }
        if let meaning = meaningClause(for: subject, in: priorAssistantTexts) {
            parts.append(meaning)
        }
        return parts.joined(separator: ". ")
    }

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

    private static func imageSubjectKind(in prompt: String) -> String {
        let lower = prompt.lowercased()
        return subjectKinds.first(where: { lower.contains($0) }) ?? "image"
    }

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

        enum CodingKeys: String, CodingKey {
            case intent
            case needsVision = "needs_vision"
        }
    }

    private static let systemPrompt = """
    You classify the user's last message in a chat app. Reply with JSON only.

    "intent" must be exactly one of:
    - "image": the user is explicitly asking for a NEW picture, logo, icon, poster, wallpaper, or artwork to be CREATED, DRAWN, or GENERATED.
    - "coding": the user wants source code written, fixed, debugged, refactored, or explained. HTML/CSS/React web design code, shell scripts, bash commands, dockerfiles, SQL queries, or algorithms are all "coding".
    - "general": everything else. This includes general questions, advice, sports debates, player stats ("messi vs ronaldo", "who has more ballon d'ors"), counter-arguments ("but he hasn't", "I disagree"), famous people/celebrities ("Ronaldo", "Elon Musk", "Steve Jobs"), math, science, business strategy, creative writing, and any discussion ABOUT an existing picture. Simply mentioning a celebrity name or the word "logo" is NOT an image request — the user must explicitly ask for a new image to be drawn/created.

    "needs_vision" is true ONLY if answering requires inspecting pixel visual details of an image in conversation (e.g. "what colors does it have", "what font is that", "is it readable"). Questions about text, sports stats, code, or historical facts NEVER need vision, so needs_vision is false.

    CRITICAL GUARDRAILS:
    - Mentions of famous people, celebrities, or athletes ("Ronaldo", "Messi", "Elon Musk", "Steve Jobs") WITHOUT explicit visual creation verbs ("draw", "generate an image of", "paint") MUST be classified as "general".
    - Sports comparisons ("messi vs ronaldo", "who has more ballon d'ors") and debate rebuttals ("but he hasn't", "I disagree") MUST be classified as "general".

    Examples:
    "Ronaldo" -> {"intent":"general","needs_vision":false}
    "messi vs ronaldo who has more ballon d'ors" -> {"intent":"general","needs_vision":false}
    "he hasn't scored as many goals as ronaldo" -> {"intent":"general","needs_vision":false}
    "but he hasn't" -> {"intent":"general","needs_vision":false}
    "I like number 2, create a logo based on that" -> {"intent":"image","needs_vision":false}
    "which of those names would work best for a logo?" -> {"intent":"general","needs_vision":false}
    "what colors does it have?" -> {"intent":"general","needs_vision":true}
    "write a python function to reverse a list" -> {"intent":"coding","needs_vision":false}
    "write bash script to backup database" -> {"intent":"coding","needs_vision":false}
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

        let recent = history.suffix(4)

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
