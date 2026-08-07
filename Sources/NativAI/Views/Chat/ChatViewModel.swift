/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI
import AppKit
import Combine

/// A capability the user's request needed but no installed model provides,
/// paired with models that would fix it.
///
/// Surfaced as an inline card in the chat rather than an alert, because it isn't
/// an error — it's a missing-prerequisite state with an obvious next action.
/// Suggestions are precomputed against the machine's specs so the card can
/// never offer a model this Mac cannot run.
struct CapabilityGapPrompt: Identifiable, Equatable {
    let id = UUID()
    let gap: ModelScorer.CapabilityGap
    let suggestions: [ModelEntry]

    /// One-line explanation of what's missing.
    var headline: String {
        switch gap.missing {
        case .image: return "I need an image-generation model to \(gap.taskDescription)."
        case .vision: return "I need a vision model to \(gap.taskDescription)."
        case .embedding: return "I need an embedding model for that."
        default: return "I need a chat model to \(gap.taskDescription)."
        }
    }

    var symbolName: String {
        switch gap.missing {
        case .image: return "photo.on.rectangle.angled"
        case .vision: return "eye"
        case .embedding: return "point.3.filled.connected.trianglepath.dotted"
        default: return "bubble.left.and.bubble.right"
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    /// Static Architecture Watermark 3
    private static let __nativai_vm_sig = "NativAI_Original_Architecture_AbdulRafey_2026_E5F6"

    /// Sentinel model "name" shown in the picker as "Auto" — when selected,
    /// send(using:) classifies each prompt's intent and routes to the best
    /// installed model for that specific task instead of a fixed model.
    static let autoRouteSentinel = "__auto__"

    @Published var sessions: [ChatSession] = []
    @Published var activeSessionId: UUID?
    @Published var draftText: String = ""
    @Published var isStreaming: Bool = false
    /// Which real model Auto mode most recently routed to — surfaced in the
    /// UI so the user can see which underlying model actually answered.
    @Published var lastAutoRoutedModel: String?
    /// Set when a turn needed a capability nothing installed provides, so the
    /// chat can offer the fix inline. Cleared on the next successful turn.
    @Published var pendingCapabilityGap: CapabilityGapPrompt?

    /// Active streaming task for current token generation.
    private var activeStreamTask: Task<Void, Never>?

    /// Stops active LLM token streaming immediately when the user clicks Stop.
    func stopStreaming() {
        activeStreamTask?.cancel()
        activeStreamTask = nil
        isStreaming = false
    }

    /// Host hardware, injected by AppState so capability-gap suggestions can be
    /// filtered to models this machine can actually run. Recommending a 40 GB
    /// model to an 8 GB Mac is worse than recommending nothing, since it invites
    /// a long download that ends in an unusable model.
    var deviceSpecs: DeviceSpecs = .unknown

    private let ollama = OllamaManager.shared
    private let catalog = CatalogService.shared
    private let history = ChatHistoryStore.shared

    init() {
        sessions = history.loadAll()
    }

    // MARK: - Session management

    var activeSession: ChatSession? {
        guard let id = activeSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    var activeMessages: [DisplayMessage] {
        activeSession?.messages ?? []
    }

    /// Explicit, non-ambient lookup — used by ChatView so it never depends on
    /// activeSessionId/onAppear timing to know which messages to show. This
    /// sidesteps a real SwiftUI race where switching directly between two
    /// existing chats could momentarily render stale state (the .id() +
    /// onAppear approach coalesced with List's selection update in some
    /// transition paths, e.g. chat→chat, but not others, e.g. browse→chat).
    func messages(for sessionId: UUID?) -> [DisplayMessage] {
        guard let sessionId else { return [] }
        return sessions.first { $0.id == sessionId }?.messages ?? []
    }

    func session(for sessionId: UUID?) -> ChatSession? {
        guard let sessionId else { return nil }
        return sessions.first { $0.id == sessionId }
    }

    func startNewSession(modelName: String) {
        let session = ChatSession(modelName: modelName)
        sessions.insert(session, at: 0)
        activeSessionId = session.id
        history.save(session)
    }

    func selectSession(_ id: UUID) {
        activeSessionId = id
    }

    /// Deletes the session both from memory and from the local JSON file on
    /// disk — freeing the storage it was using, not just hiding it from the UI.
    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        history.delete(sessionId: id)
        if activeSessionId == id {
            activeSessionId = sessions.first?.id
        }
    }

    var totalDiskUsageBytes: Int64 {
        history.totalDiskUsageBytes()
    }

    // MARK: - Sending

    /// Routes to image generation or text chat, using SemanticRouter to decide
    /// intent from the actual conversation rather than keyword matching alone.
    ///
    /// `targetSessionId` is passed explicitly by the view (rather than reading
    /// activeSessionId) so a message always lands in the session the user was
    /// actually looking at, with no dependency on ambient state timing.
    ///
    /// Stays SYNCHRONOUS and returns the session id immediately so the view's
    /// existing call site and scroll/focus behavior are unchanged; the routing
    /// LLM call happens inside a detached Task afterwards. The user message is
    /// appended before routing begins, so the UI shows it instantly even though
    /// the routing decision takes ~1-2s.
    func send(using modelName: String, targetSessionId: UUID?, installedModelNames: [String] = [], realSizesBytes: [String: Int64] = [:], attachments: [MessageAttachment] = []) -> UUID? {
        let rawText = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty || !attachments.isEmpty, !isStreaming else { return targetSessionId }

        var sessionId = targetSessionId
        if sessionId == nil {
            let placeholderModel = (modelName == Self.autoRouteSentinel) ? (installedModelNames.first ?? "") : modelName
            let session = ChatSession(modelName: placeholderModel)
            sessions.insert(session, at: 0)
            activeSessionId = session.id
            history.save(session)
            sessionId = session.id
        }
        guard let sessionId, let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else { return sessionId }

        // Text-file attachments: read content is injected directly into the
        // prompt text, since any chat model can read plain text.
        var text = rawText
        for attachment in attachments where attachment.kind == .textFile {
            if let fileText = attachment.extractedText, !fileText.isEmpty, fileText.count <= 4000 {
                text += "\n\n--- \(attachment.fileName) ---\n\(fileText)"
            }
        }
        let imageAttachments = attachments.filter { $0.kind == .image }
        let attachedImageData: [Data] = imageAttachments.compactMap { $0.imageData }

        // Append the user's message and show a provisional title right away,
        // before the async routing work starts.
        let userMessage = DisplayMessage(role: "user", content: rawText, isImage: false, imageData: nil, attachments: attachments)
        sessions[sessionIndex].messages.append(userMessage)

        // Record attachments in the ledger at the moment they arrive, while
        // their nature is unambiguous. Doing it here rather than inferring it
        // later from message text is the whole point of the ledger.
        for attachment in attachments {
            sessions[sessionIndex].recordArtifact(SessionArtifact(
                kind: attachment.kind == .image ? .attachedImage : .document,
                messageId: userMessage.id,
                label: attachment.fileName
            ))
        }

        sessions[sessionIndex].refreshAutoTitle()
        sessions[sessionIndex].updatedAt = Date()
        draftText = ""
        persistSession(id: sessionId)

        // Mark streaming immediately so the input disables and the user can't
        // fire a second send during the routing window.
        isStreaming = true

        let conversationHistory = routingHistory(sessionId: sessionId)
        let sessionArtifacts = sessions[sessionIndex].artifacts
        let hasPriorImage = !SessionArtifact.visuals(in: sessionArtifacts).isEmpty
        let priorImagePrompt = sessionArtifacts
            .filter { $0.kind == .generatedImage && $0.sourcePrompt?.isEmpty == false }
            .max { $0.createdAt < $1.createdAt }?
            .sourcePrompt
        let routerModel = SemanticRouter.resolveRouterModel(installedModelNames: installedModelNames)
        let wasAutoRouted = (modelName == Self.autoRouteSentinel)

        Task { [weak self] in
            guard let self else { return }

            // Async Document RAG for large files (>4,000 chars)
            var enrichedText = text
            let embeddingModel = await EmbeddingService.resolveModel(installedModelNames: installedModelNames)
            for attachment in attachments where attachment.kind == .textFile {
                if let fileText = attachment.extractedText, fileText.count > 4000 {
                    if let embeddingModel {
                        let chunks = DocumentRAGService.splitIntoChunks(text: fileText, fileName: attachment.fileName)
                        let indexedChunks = await DocumentRAGService.indexChunks(chunks, embeddingModel: embeddingModel)
                        let topResults = await DocumentRAGService.retrieveTopChunks(query: rawText, chunks: indexedChunks, embeddingModel: embeddingModel, limit: 4)
                        if !topResults.isEmpty {
                            enrichedText += DocumentRAGService.formatContextExcerpts(topResults)
                        } else {
                            enrichedText += "\n\n--- \(attachment.fileName) ---\n\(fileText)"
                        }
                    } else {
                        enrichedText += "\n\n--- \(attachment.fileName) ---\n\(fileText)"
                    }
                }
            }

            let hasDirectImageAttachment = !attachedImageData.isEmpty
            var decision: RoutingDecision
            if wasAutoRouted {
                decision = await SemanticRouter.route(
                    prompt: rawText,
                    history: conversationHistory,
                    hasPriorImage: hasPriorImage || hasDirectImageAttachment,
                    hasDirectImageAttachment: hasDirectImageAttachment,
                    routerModel: routerModel,
                    artifacts: sessionArtifacts,
                    priorImagePrompt: priorImagePrompt
                )
            } else {
                // A manually-picked model dictates its own behavior — respect
                // the user's explicit choice instead of overriding it with a
                // classification. Still ask the router whether vision is
                // needed so image carryover works with fixed models too.
                let isImageModel = self.catalog.entry(named: modelName)?.role == "image"
                let needsVision = hasPriorImage && !isImageModel
                    ? IntentClassifier.isReferringToVisualContent(rawText)
                    : false
                decision = RoutingDecision(
                    intent: isImageModel ? .image : .general,
                    needsVision: needsVision,
                    imagePrompt: isImageModel
                        ? SemanticRouter.buildImagePrompt(
                            prompt: text,
                            history: conversationHistory,
                            priorImagePrompt: priorImagePrompt
                          )
                        : "",
                    usedLLM: false,
                    // Even on the manual path, resolve *which* image is meant
                    // deterministically, so carryover picks the referenced one
                    // rather than always the newest.
                    targetArtifactId: needsVision
                        ? SessionArtifact.resolveTarget(prompt: rawText, artifacts: sessionArtifacts)?.id
                        : nil
                )
            }

            await self.dispatch(
                decision: decision,
                enrichedText: enrichedText,
                rawText: rawText,
                explicitModel: wasAutoRouted ? nil : modelName,
                sessionId: sessionId,
                installedModelNames: installedModelNames,
                realSizesBytes: realSizesBytes,
                attachedImageData: attachedImageData,
                routerModel: routerModel
            )
        }

        return sessionId
    }

    /// Applies a routing decision: resolves the concrete model, handles vision
    /// fallback, then hands off to the streaming chat or image generation path.
    private func dispatch(
        decision: RoutingDecision,
        enrichedText: String,
        rawText: String,
        explicitModel: String?,
        sessionId: UUID,
        installedModelNames: [String],
        realSizesBytes: [String: Int64],
        attachedImageData: [Data],
        routerModel: String?
    ) async {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else {
            isStreaming = false
            return
        }

        // Carry a previously produced image forward only when the router says
        // this turn actually requires looking at one — this is what stops an
        // unrelated follow-up ("what's the biggest clothing brand?") from
        // silently reattaching the last image and forcing vision routing.
        //
        // Which image is used now comes from the ledger's deterministic
        // resolution rather than "whatever was most recent", so "what font is
        // in the first logo?" reaches the first logo. Falls back to recency
        // when no specific target was identified.
        var effectiveImageData = attachedImageData
        if effectiveImageData.isEmpty, decision.needsVision {
            if let targetId = decision.targetArtifactId,
               let artifact = sessions[sessionIndex].artifacts.first(where: { $0.id == targetId }),
               let message = sessions[sessionIndex].messages.first(where: { $0.id == artifact.messageId }),
               let data = Self.imageData(in: message) {
                effectiveImageData = [data]
            } else if let lastImageMessage = sessions[sessionIndex].messages.last(where: { $0.isImage && $0.imageData != nil }) {
                effectiveImageData = [lastImageMessage.imageData!]
            }
        }

        // Capability-based selection. Intent decides *what abilities* are
        // needed; ModelScorer decides *which installed model* provides them.
        // Vision is now part of that single decision rather than a post-hoc
        // swap, which removes a whole class of mismatch: previously a model was
        // chosen by role, then patched if it turned out it couldn't see.
        let candidates = await makeCandidates(
            installedModelNames: installedModelNames,
            realSizesBytes: realSizesBytes
        )
        let needsVisionNow = !effectiveImageData.isEmpty
        // Keeping the session's current model when it still qualifies avoids a
        // multi-second cold load and a mid-conversation change of voice.
        let residentModels = await OllamaManager.shared.residentModelNames()

        var resolvedModel: String
        var capabilityGap: ModelScorer.CapabilityGap? = nil

        if let explicitModel {
            resolvedModel = explicitModel
        } else {
            switch resolveModel(
                for: decision.intent,
                needsVision: needsVisionNow,
                candidates: candidates,
                currentModel: currentSessionModel(sessionId: sessionId),
                residentModels: residentModels
            ) {
            case .selected(let name):
                resolvedModel = name
            case .gap(let gap):
                capabilityGap = gap
                // Fall back to the best chat-capable model so the user still
                // gets a reply alongside the install suggestion, rather than a
                // dead end. An image request with no image model becomes a
                // text answer plus a card offering to fix that.
                let textOnly = ModelScorer.select(
                    required: [.completion],
                    candidates: candidates,
                    currentModel: currentSessionModel(sessionId: sessionId),
                    residentModels: residentModels
                )
                if case .selected(let fallback) = textOnly {
                    resolvedModel = fallback
                } else {
                    resolvedModel = ""
                }
            }
        }

        // A model that can't accept images must not be handed image bytes — it
        // would confidently describe something it never received.
        var visionFallbackNote: String? = nil
        if !effectiveImageData.isEmpty, !resolvedModel.isEmpty {
            let probed = await CapabilityProbe.shared.capabilities(for: resolvedModel)
            if !probed.supportsVision {
                effectiveImageData = []
                if capabilityGap == nil {
                    visionFallbackNote = "⚠️ \(resolvedModel) can't read images, so this answer is based on text only."
                }
            }
        }

        let wasAutoRouted = (explicitModel == nil)
        lastAutoRoutedModel = wasAutoRouted ? resolvedModel : nil
        let modelUsedTag = wasAutoRouted ? resolvedModel : nil

        // Publish the gap so the chat can render install suggestions inline.
        // Computed here (not in the view) because it needs device specs and the
        // installed set to avoid recommending models this Mac can't run.
        if let gap = capabilityGap {
            pendingCapabilityGap = CapabilityGapPrompt(
                gap: gap,
                suggestions: ModelScorer.suggestions(
                    for: gap,
                    catalog: catalog.allModels,
                    specs: deviceSpecs,
                    installedNames: Set(installedModelNames)
                )
            )
        } else {
            pendingCapabilityGap = nil
        }

        guard !resolvedModel.isEmpty else {
            // Nothing installed at all — surface the gap instead of silently
            // doing nothing.
            isStreaming = false
            return
        }

        let canGenerateImages = await CapabilityProbe.shared
            .capabilities(for: resolvedModel).supportsImageGeneration

        if decision.intent == .image && canGenerateImages {
            // decision.imagePrompt is already standalone with all ordinal
            // references resolved into real names by SemanticRouter, so the
            // diffusion model never sees "number 2" and can't draw a numeral.
            let prompt = decision.imagePrompt.isEmpty ? enrichedText : decision.imagePrompt
            sendImageGeneration(prompt: prompt, model: resolvedModel, sessionId: sessionId, modelUsedTag: modelUsedTag, routerModel: routerModel)
        } else {
            // Resolve ordinal back-references ("the no.8 name you gave me")
            // before the model sees the turn. Counting list positions across a
            // long transcript is something small models get wrong confidently —
            // and once a wrong name enters the transcript it gets reinforced on
            // every later turn. Doing the lookup in Swift removes the need to
            // count at all.
            var textForModel = enrichedText
            let priorAssistantTexts = sessions[sessionIndex].messages
                .filter { $0.role == "assistant" && !$0.content.isEmpty }
                .map { $0.content }
            if let clarified = ContextualReferenceResolver.clarification(
                prompt: enrichedText,
                priorAssistantMessages: priorAssistantTexts
            ) {
                textForModel = clarified
            }

            sendChat(prompt: textForModel, model: resolvedModel, sessionId: sessionId, modelUsedTag: modelUsedTag, imageData: effectiveImageData, prependNote: visionFallbackNote, routerModel: routerModel, rawUserText: rawText, installedModelNames: installedModelNames)
        }
    }

    /// Conversation so far as (role, content) pairs for the router, with image
    /// messages represented by a text placeholder.
    ///
    /// Generated-image messages store content "" once the image arrives, so
    /// passing them through raw produced EMPTY assistant turns — which both
    /// wasted a turn slot and destroyed the alternating structure the chat
    /// model relies on. The placeholder keeps the turn meaningful ("an image
    /// was produced here") for both routing and chat history.
    private func routingHistory(sessionId: UUID) -> [(role: String, content: String)] {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return [] }
        return sessions[index].messages.dropLast().map { message in
            (role: message.role, content: Self.historyContent(for: message))
        }
    }

    /// Text stand-in for a message when building model-facing history.
    static func historyContent(for message: DisplayMessage) -> String {
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isImage && trimmed.isEmpty {
            return "[Generated an image as requested.]"
        }
        return message.content
    }

    /// Image bytes belonging to a message, whether it's a generated image
    /// bubble or a user message with an image attachment. Both forms are
    /// ledger-tracked, so both must be retrievable.
    static func imageData(in message: DisplayMessage) -> Data? {
        if message.isImage, let data = message.imageData { return data }
        return message.attachments.first { $0.kind == .image }?.imageData
    }

    /// Real-time machine date, time, timezone, and OS context injected as a system prompt.
    static var systemEnvironmentMessage: OllamaManager.ChatMessage {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        let dateString = formatter.string(from: Date())
        let timezone = TimeZone.current.identifier
        let sysContent = """
        System Environment Context:
        Current Date and Time: \(dateString) (\(timezone))
        Operating System: macOS
        Always use this real-time system clock information to accurately answer user questions about the current date, time, day of the week, or year.
        """
        return OllamaManager.ChatMessage(role: "system", content: sysContent)
    }


    /// Maps a routing intent to the best installed model for that task. Falls
    /// back through: matching role → any installed chat model → literally any
    /// installed model, so routing always resolves to *something* runnable
    /// rather than silently failing.
    /// Builds scoring candidates from the installed models, pairing each with
    /// its live capabilities.
    ///
    /// Models the server can't describe are still included (via `.unknown`), so
    /// a probe failure degrades to conservative assumptions rather than making a
    /// model vanish from selection entirely.
    private func makeCandidates(
        installedModelNames: [String],
        realSizesBytes: [String: Int64]
    ) async -> [ModelScorer.Candidate] {
        var candidates: [ModelScorer.Candidate] = []
        for name in installedModelNames {
            let capabilities = await CapabilityProbe.shared.capabilities(for: name)
            candidates.append(ModelScorer.Candidate(
                name: name,
                capabilities: capabilities,
                realSizeBytes: realSizesBytes[name],
                entry: catalog.entry(named: name)
            ))
        }
        return candidates
    }

    /// Translates a routing intent into the capabilities a model must have.
    ///
    /// This is the indirection that removes hardcoded model names from routing:
    /// intent → capabilities → whatever installed model provides them. Adding a
    /// new vision or image model requires no code change, and the catalog can be
    /// wrong without breaking selection, because the server is the authority.
    private static func requiredCapabilities(
        for intent: RouterIntent,
        needsVision: Bool
    ) -> Set<ModelCapability> {
        var required: Set<ModelCapability> = []
        switch intent {
        case .image:
            // Image generation only — Flux reports ["image"] with no
            // "completion", so requiring completion here would exclude it.
            required.insert(.image)
        case .coding, .general:
            required.insert(.completion)
            if needsVision { required.insert(.vision) }
        }
        return required
    }

    /// Human-readable description of the task, for the capability-gap card.
    private static func taskDescription(for intent: RouterIntent, needsVision: Bool) -> String {
        switch intent {
        case .image: return "generate an image"
        case .coding: return needsVision ? "read that image" : "write code"
        case .general: return needsVision ? "read that image" : "answer this"
        }
    }

    /// The model that actually answered most recently in this session.
    ///
    /// Needed because `session.modelName` holds the sentinel `"__auto__"` while
    /// Auto routing is active, which matches no candidate — so passing it as
    /// `currentModel` silently disabled stickiness on exactly the path that
    /// needs it most. The last `modelUsed` tag is the real answer: it records
    /// the concrete model each assistant turn was produced by.
    private func currentSessionModel(sessionId: UUID) -> String? {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return nil }
        if let used = session.messages.last(where: { $0.role == "assistant" && $0.modelUsed != nil })?.modelUsed {
            return used
        }
        // Manual mode: the session's model is already concrete.
        return session.modelName == Self.autoRouteSentinel ? nil : session.modelName
    }

    /// Selects a model by capability, or reports what's missing.
    ///
    /// Replaces the previous role-string lookup (`"chat"`/`"coder"`/`"image"`),
    /// which could only ever be as accurate as the hand-maintained catalog and
    /// silently fell back to `installedModelNames.first` — capable of handing a
    /// text prompt to an image-only model. Capability filtering makes that
    /// category of mistake unrepresentable.
    private func resolveModel(
        for intent: RouterIntent,
        needsVision: Bool,
        candidates: [ModelScorer.Candidate],
        currentModel: String?,
        residentModels: Set<String>
    ) -> ModelScorer.Outcome {
        guard !candidates.isEmpty else {
            return .gap(ModelScorer.CapabilityGap(
                missing: intent == .image ? .image : .completion,
                taskDescription: Self.taskDescription(for: intent, needsVision: needsVision)
            ))
        }

        return ModelScorer.select(
            required: Self.requiredCapabilities(for: intent, needsVision: needsVision),
            candidates: candidates,
            currentModel: currentModel,
            residentModels: residentModels,
            taskDescription: Self.taskDescription(for: intent, needsVision: needsVision),
            intent: intent
        )
    }

    private func sendChat(prompt: String, model: String, sessionId: UUID, modelUsedTag: String? = nil, imageData: [Data] = [], prependNote: String? = nil, routerModel: String? = nil, rawUserText: String = "", installedModelNames: [String] = []) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else {
            isStreaming = false
            return
        }
        let assistantIndex = sessions[sessionIndex].messages.count
        let initialContent = prependNote.map { $0 + "\n\n" } ?? ""
        sessions[sessionIndex].messages.append(DisplayMessage(role: "assistant", content: initialContent, isImage: false, imageData: nil, modelUsed: modelUsedTag))
        isStreaming = true

        // Build history from all messages except the just-appended assistant
        // placeholder. The final (current) user message uses `prompt` — NOT
        // msg.content — since `prompt` is the enriched version with any
        // attached text-file/PDF content appended, while msg.content stores
        // only the original typed text for display purposes. Using
        // msg.content here was the actual bug behind "the model says it
        // can't read the PDF" — the extracted PDF text was correctly
        // computed and passed into sendChat's `prompt` parameter, but this
        // history-building loop was silently ignoring it and sending the
        // model the bare typed message instead, so it genuinely never
        // received the PDF's content at all. It also gets the image data
        // attached via base64 — everything Ollama's vision models need to
        // actually see it, rather than only ever receiving text.
        //
        // Non-final messages route through historyContent(for:) so a
        // previously generated image becomes "[Generated an image as
        // requested.]" instead of an empty assistant turn — an empty turn
        // both wasted a slot and broke the alternating user/assistant
        // structure, which is why the model could lose track of what it had
        // already produced earlier in the conversation.
        let priorMessages = sessions[sessionIndex].messages.dropLast()
        var historyMessages: [OllamaManager.ChatMessage] = []
        for (index, msg) in priorMessages.enumerated() {
            let isLastUserMessage = (index == priorMessages.count - 1) && msg.role == "user"
            let images = (isLastUserMessage && !imageData.isEmpty)
                ? imageData.map { $0.base64EncodedString() }
                : nil
            let content = isLastUserMessage ? prompt : Self.historyContent(for: msg)
            historyMessages.append(OllamaManager.ChatMessage(role: msg.role, content: content, images: images))
        }

        activeStreamTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Ask the server for this model's real context window, then apply
                // hardware-adaptive context scaling (capping window on 8GB RAM machines to avoid disk swapping).
                let rawContext = await CapabilityProbe.shared.contextLength(for: model)
                let modelSizeGB = catalog.entry(named: model)?.sizeGB ?? 2.0
                let contextLength = deviceSpecs.effectiveContextLength(rawContextLength: rawContext, modelSizeGB: modelSizeGB)

                // Prepend the running digest so material already compacted out
                // of the verbatim window is still available.
                var request = historyMessages
                if let sessionIdx = sessions.firstIndex(where: { $0.id == sessionId }),
                   let digestMessage = ConversationDigest.systemMessage(for: sessions[sessionIdx].digest) {
                    request.insert(digestMessage, at: 0)
                }

                // Inject real-time system date & time so LLMs can answer machine-level date/time questions
                request.insert(Self.systemEnvironmentMessage, at: 0)

                // Inject remembered facts from *previous* conversations
                let memories = await retrieveMemories(
                    prompt: rawUserText.isEmpty ? prompt : rawUserText,
                    installedModelNames: installedModelNames
                )
                if let memoryMessage = MemoryStore.systemMessage(for: memories) {
                    request.insert(memoryMessage, at: 0)
                }

                let fitted = TokenBudget.fit(messages: request, contextLength: contextLength)

                // On 8GB Macs, unload inactive models from RAM first to prevent NVMe disk swapping
                if deviceSpecs.totalRAMGB <= 8.5 {
                    await OllamaManager.shared.unloadInactiveModels(except: model)
                }
                let keepAliveSeconds = deviceSpecs.totalRAMGB <= 8.5 ? 15 : nil

                try await ollama.chat(
                    model: model,
                    messages: fitted.messages,
                    contextLength: contextLength,
                    keepAliveSeconds: keepAliveSeconds
                ) { [weak self] token in
                    guard let self,
                          let idx = self.sessions.firstIndex(where: { $0.id == sessionId }),
                          self.sessions[idx].messages.indices.contains(assistantIndex) else { return }
                    self.sessions[idx].messages[assistantIndex].content += token
                }
            } catch {
                if Task.isCancelled {
                    self.isStreaming = false
                    self.activeStreamTask = nil
                    return
                }
                if let idx = self.sessions.firstIndex(where: { $0.id == sessionId }),
                   self.sessions[idx].messages.indices.contains(assistantIndex) {
                    self.sessions[idx].messages[assistantIndex].content += "⚠️ Error: \(error.localizedDescription)"
                }
            }
            self.isStreaming = false
            self.activeStreamTask = nil
            self.persistSession(id: sessionId)
            await self.generateTitleIfNeeded(sessionId: sessionId, routerModel: routerModel)
            await self.compactIfNeeded(sessionId: sessionId, model: model)
            await self.learnFromTurn(
                rawUserText: rawUserText,
                sessionId: sessionId,
                routerModel: routerModel,
                installedModelNames: installedModelNames
            )
        }
    }

    /// Retrieves remembered facts relevant to this prompt.
    ///
    /// Embeds the query when an embedding model is installed, and falls back to
    /// keyword overlap otherwise — memory should work without requiring an extra
    /// download, just less precisely. Also opportunistically backfills embeddings
    /// for facts stored before a model was available.
    private func retrieveMemories(
        prompt: String,
        installedModelNames: [String]
    ) async -> [MemoryFact] {
        let store = MemoryStore.shared
        guard store.isEnabled, !store.facts.isEmpty else { return [] }

        var queryEmbedding: [Double]? = nil
        if let embedModel = await EmbeddingService.resolveModel(installedModelNames: installedModelNames) {
            // Backfill first so newly-stored facts are retrievable on this very
            // turn rather than only on the next one.
            let pending = store.factsNeedingEmbedding
            if !pending.isEmpty,
               let vectors = await EmbeddingService.embed(pending.map(\.text), model: embedModel) {
                for (fact, vector) in zip(pending, vectors) {
                    store.setEmbedding(vector, for: fact.id)
                }
            }
            queryEmbedding = await EmbeddingService.embed([prompt], model: embedModel)?.first
        }

        return store.relevantFacts(for: queryEmbedding, prompt: prompt)
    }

    /// Extracts and stores durable facts from the user's message.
    ///
    /// Runs after the reply so extraction latency never delays an answer. Uses the
    /// small router model: extraction is a narrow, schema-constrained task that
    /// 1.5B handles well, unlike the semantic-drift judgement that title revision
    /// needs.
    private func learnFromTurn(
        rawUserText: String,
        sessionId: UUID,
        routerModel: String?,
        installedModelNames: [String]
    ) async {
        let store = MemoryStore.shared
        guard store.isEnabled, !rawUserText.isEmpty else { return }

        let candidates = await MemoryExtractor.extract(
            userMessage: rawUserText,
            model: routerModel,
            sessionId: sessionId
        )
        guard !candidates.isEmpty else { return }

        // Embed only what actually survives deduplication — embedding a fact the
        // store rejects is a wasted model call.
        var stored: [MemoryFact] = []
        for candidate in candidates where store.add(candidate) {
            stored.append(candidate)
        }
        guard !stored.isEmpty else { return }

        if let embedModel = await EmbeddingService.resolveModel(installedModelNames: installedModelNames),
           let vectors = await EmbeddingService.embed(stored.map(\.text), model: embedModel) {
            for (fact, vector) in zip(stored, vectors) {
                store.setEmbedding(vector, for: fact.id)
            }
        }
    }

    /// Folds old turns into the session digest when the conversation has grown
    /// past what the model's window can hold verbatim.
    ///
    /// Runs on the model that just answered — it's already loaded, so this costs
    /// no additional model load. Any failure leaves the digest untouched, which
    /// simply means the next send falls back to plain truncation.
    private func compactIfNeeded(sessionId: UUID, model: String) async {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        let contextLength = await CapabilityProbe.shared.contextLength(for: model)
        let wireHistory = sessions[index].messages.map {
            OllamaManager.ChatMessage(role: $0.role, content: Self.historyContent(for: $0))
        }

        guard let plan = ConversationDigest.plan(
            history: wireHistory,
            alreadyDigestedThrough: sessions[index].digestedThroughIndex,
            contextLength: contextLength
        ) else { return }

        let existing = sessions[index].digest
        guard let updated = await ConversationDigest.fold(
            existingDigest: existing,
            messages: plan.messages,
            model: model
        ) else { return }

        // Re-locate after the async gap, and only advance if the digest hasn't
        // moved on in the meantime — two overlapping compactions would otherwise
        // double-count turns and skip material.
        guard let currentIndex = sessions.firstIndex(where: { $0.id == sessionId }),
              sessions[currentIndex].digestedThroughIndex < plan.newDigestedThroughIndex,
              plan.newDigestedThroughIndex <= sessions[currentIndex].messages.count else { return }

        sessions[currentIndex].digest = updated
        sessions[currentIndex].digestedThroughIndex = plan.newDigestedThroughIndex
        persistSession(id: sessionId)
    }

    private func sendImageGeneration(prompt: String, model: String, sessionId: UUID, modelUsedTag: String? = nil, routerModel: String? = nil) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else {
            isStreaming = false
            return
        }
        let assistantIndex = sessions[sessionIndex].messages.count
        sessions[sessionIndex].messages.append(DisplayMessage(role: "assistant", content: "Generating image…", isImage: true, imageData: nil, modelUsed: modelUsedTag))
        isStreaming = true

        // Deliberately not tied to any view's lifecycle — ChatViewModel lives
        // on AppState (app-session-scoped), so switching sidebar tabs never
        // cancels this in-flight generation.
        Task {
            do {
                let imageData = try await ollama.generateImage(model: model, prompt: prompt)
                if let idx = sessions.firstIndex(where: { $0.id == sessionId }),
                   sessions[idx].messages.indices.contains(assistantIndex) {
                    sessions[idx].messages[assistantIndex].imageData = imageData
                    sessions[idx].messages[assistantIndex].content = ""

                    // Record the generated image in the ledger now, while the
                    // prompt that produced it is still in hand. Recording it at
                    // the point of creation — rather than reconstructing it from
                    // message text later — is what lets a follow-up like "what
                    // font is in the logo?" resolve to this exact image.
                    let messageId = sessions[idx].messages[assistantIndex].id
                    sessions[idx].recordArtifact(SessionArtifact(
                        kind: .generatedImage,
                        messageId: messageId,
                        label: ChatSession.label(fromPrompt: prompt) ?? "a generated image",
                        sourcePrompt: prompt
                    ))
                }
            } catch {
                if let idx = sessions.firstIndex(where: { $0.id == sessionId }),
                   sessions[idx].messages.indices.contains(assistantIndex) {
                    sessions[idx].messages[assistantIndex].content = "⚠️ Error: \(error.localizedDescription)"
                }
            }
            isStreaming = false
            persistSession(id: sessionId)
            await generateTitleIfNeeded(sessionId: sessionId, routerModel: routerModel)
        }
    }

    /// Generates the chat's permanent title with the local router model once a
    /// real exchange exists, then locks it. Runs after the reply completes so
    /// the title reflects the whole topic, not just the opening question.
    ///
    /// Silently keeps the existing provisional title if the router is missing
    /// or returns something unusable — a chat with a truncated name is a much
    /// smaller problem than a failed send.
    private func generateTitleIfNeeded(sessionId: UUID, routerModel: String?) async {
        guard let routerModel,
              let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        // Two distinct jobs: name a new chat, or re-check an existing name once
        // the conversation has developed. Revision is what stops a chat being
        // permanently titled after its opening question — the reported case
        // being a chat that began "I want to build a clothing brand" and became
        // entirely about logo design.
        if sessions[index].needsGeneratedTitle {
            let session = sessions[index]
            guard let firstUser = session.messages.first(where: { $0.role == "user" }) else { return }
            let firstAssistant = session.messages.first {
                $0.role == "assistant" && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            guard let title = await ChatTitleGenerator.generateTitle(
                userMessage: firstUser.content,
                assistantReply: firstAssistant.map { Self.historyContent(for: $0) },
                routerModel: routerModel
            ) else { return }

            // Re-locate the session — an async gap means indices may have shifted
            // if the user created or deleted a chat while the title was generating.
            guard let currentIndex = sessions.firstIndex(where: { $0.id == sessionId }),
                  sessions[currentIndex].needsGeneratedTitle else { return }
            sessions[currentIndex].lockTitle(title)
            persistSession(id: sessionId)
            return
        }

        guard sessions[index].shouldReviseTitle else { return }
        let currentTitle = sessions[index].title
        let digest = sessions[index].titleDigest()

        // Revision needs a mid-sized model, not the tiny router: measured live,
        // qwen2.5:1.5b returned keep:true even when the title described a
        // completely different topic, while llama3:8b caught it. Reuse whatever
        // actually answered in this session — it's already loaded, so this costs
        // no extra model load. If that model is somehow unavailable, revision is
        // skipped rather than performed badly.
        let reviserModel = currentSessionModel(sessionId: sessionId)

        guard let revised = await ChatTitleGenerator.reviseTitle(
            currentTitle: currentTitle,
            digest: digest,
            model: reviserModel
        ) else { return }

        // Re-check after the async gap: the title may have been renamed by the
        // user, or the session deleted, while the model was thinking.
        guard let currentIndex = sessions.firstIndex(where: { $0.id == sessionId }),
              !sessions[currentIndex].titleIsUserSet,
              sessions[currentIndex].title == currentTitle else { return }
        sessions[currentIndex].applyRevisedTitle(revised)
        persistSession(id: sessionId)
    }

    private func persistSession(id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        history.save(session)
    }
}
