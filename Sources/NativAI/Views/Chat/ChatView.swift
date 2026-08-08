/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit

/// Thin wrapper that pulls the app-session-scoped ChatViewModel out of
/// AppState and observes it directly via @ObservedObject. This is necessary
/// because nested ObservableObjects held as a plain `let` on another
/// ObservableObject do NOT automatically propagate change notifications up —
/// without this explicit @ObservedObject, the view would silently stop
/// updating on new messages/streamed tokens after the first render.
///
/// `sessionId` is passed in explicitly by MainShellView (rather than read
/// from viewModel.activeSessionId) so this view never depends on ambient
/// state + onAppear timing to know which conversation to show — sidesteps a
/// real SwiftUI race that could show stale/empty content when switching
/// directly between two existing chats.
struct ChatView: View {
    @EnvironmentObject var appState: AppState
    let sessionId: UUID?
    /// Called with the newly-created session's id the moment a message is
    /// sent from the "New Chat" (sessionId == nil) placeholder state.
    /// MainShellView uses this to update its own sidebar selection
    /// immediately — without it, this view kept rendering the stale "New
    /// Chat" empty state after sending, since it was instantiated with a
    /// fixed sessionId: nil and had no way to know a real session now
    /// existed until something unrelated (like switching tabs) forced a
    /// fresh render that happened to pick up the new session.
    var onSessionCreated: ((UUID) -> Void)? = nil

    var body: some View {
        ChatContentView(viewModel: appState.chatViewModel, sessionId: sessionId, onSessionCreated: onSessionCreated)
    }
}

private struct ChatContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var viewModel: ChatViewModel
    let sessionId: UUID?
    var onSessionCreated: ((UUID) -> Void)?
    /// Owned by the view rather than AppState: dictation is transient composer
    /// state with no meaning outside this screen, and tying its lifetime to the
    /// view guarantees the audio engine is torn down when the chat closes.
    @StateObject private var dictation = DictationService()
    @State private var draftText: String = ""
    @State private var pendingAttachments: [MessageAttachment] = []
    @State private var attachmentError: String?
    @State private var inputHeight: CGFloat = 20

    private var messages: [DisplayMessage] {
        viewModel.messages(for: sessionId)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if appState.installedModels.isEmpty {
                emptyState
            } else {
                transcript
                inputBar
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NativAISystemNewChat"))) { _ in
            viewModel.startNewSession(modelName: appState.selectedModelName ?? ChatViewModel.autoRouteSentinel)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NativAISystemExportSession"))) { _ in
            if let currentSession = viewModel.session(for: sessionId) {
                SessionExportService.promptSaveSession(currentSession, format: .markdown, window: NSApp.keyWindow)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(viewModel.session(for: sessionId)?.title ?? "New Chat")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()



            // Session Export Menu
            if let currentSession = viewModel.session(for: sessionId) {
                Menu {
                    Button("Export as Markdown (.md)") {
                        SessionExportService.promptSaveSession(currentSession, format: .markdown, window: NSApp.keyWindow)
                    }
                    Button("Export as HTML (.html)") {
                        SessionExportService.promptSaveSession(currentSession, format: .html, window: NSApp.keyWindow)
                    }
                    Button("Export as PDF (.pdf)") {
                        SessionExportService.promptSaveSession(currentSession, format: .pdf, window: NSApp.keyWindow)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderlessButton)
            }

            modelPicker
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private var modelPicker: some View {
        Picker("", selection: Binding(
            get: { appState.selectedModelName ?? "" },
            set: { newValue in
                // Deferred to next runloop tick — same fix as the appearance
                // picker in MainShellView, avoids "Publishing changes from
                // within view updates" triggered by the Picker committing
                // this binding synchronously during its own update pass.
                DispatchQueue.main.async {
                    appState.selectedModelName = newValue
                }
            }
        )) {
            Text("✨ Auto").tag(ChatViewModel.autoRouteSentinel)
            ForEach(groupedModelNames(), id: \.self) { name in
                Text(displayLabel(for: name)).tag(name)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 240)
        .controlSize(.small)
    }

    private func groupedModelNames() -> [String] {
        appState.installedModels.map { $0.name }
    }

    private func displayLabel(for modelName: String) -> String {
        guard let entry = appState.catalog.entry(named: modelName) else { return modelName }
        let roleTag = entry.role == "image" ? " 🎨" : (entry.role == "coder" ? " 💻" : "")
        return entry.displayName + roleTag
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
            }
            Text("No models installed yet")
                .font(.system(size: 16, weight: .semibold))
            Text("Go to Browse Models to install one, or revisit your recommendations.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if messages.isEmpty {
                    startPrompt
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        // Pinned after the last message so the offer to install
                        // appears exactly where the unmet request happened,
                        // keeping the reason visible alongside the fix.
                        if let gap = viewModel.pendingCapabilityGap {
                            CapabilityGapCard(prompt: gap)
                                .id(gap.id)
                        }
                    }
                    .padding(20)
                }
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: messages.last?.content) { _, _ in
                if viewModel.isStreaming, let last = messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var startPrompt: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 120)
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("Ask anything, or generate an image")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // Professional, ChatGPT-style composer using a system material for the
    // fill — reads as a soft frosted "glass" surface today, and automatically
    // upgrades to true Liquid Glass rendering on macOS 26 with no code
    // changes, since materials are a system-provided, OS-version-aware effect.
    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 6) {
                if !pendingAttachments.isEmpty {
                    attachmentChips
                }
                if let attachmentError {
                    Text("⚠️ \(attachmentError)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                if case .unavailable(let message) = dictation.state {
                    // Shown inline rather than as an alert: the fix is usually in
                    // System Settings, and an alert would be dismissed before the
                    // user could read where to go.
                    HStack(spacing: 6) {
                        Image(systemName: "mic.slash")
                            .font(.caption2)
                        Text(message)
                            .font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Dismiss") { dictation.dismissError() }
                            .font(.caption2)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.orange)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Button(action: pickAttachment) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)

                    // Only offered when on-device recognition is actually
                    // available, so the button can't exist in a state where it
                    // always fails.
                    if DictationService.isSupported {
                        Button(action: toggleDictation) {
                            Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                                .font(.system(size: 13))
                                .foregroundStyle(dictation.isListening ? Color.red : .secondary)
                                .frame(width: 26, height: 26)
                                .background(
                                    Circle().fill(
                                        dictation.isListening
                                            ? Color.red.opacity(0.12)
                                            : Color.clear
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isStreaming)
                        .help(dictation.isListening
                              ? "Stop dictation"
                              : "Dictate — speech stays on this Mac")
                    }

                    ChatInputTextView(
                        text: $draftText,
                        measuredHeight: $inputHeight,
                        onSubmit: send
                    )
                    .frame(height: inputHeight)

                    if viewModel.isStreaming {
                        Button(action: { viewModel.stopStreaming() }) {
                            Image(systemName: "square.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.red))
                        }
                        .buttonStyle(.plain)
                        .help("Stop generating response")
                        .padding(.bottom, 2)
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(canSend ? Color.accentColor : Color.secondary.opacity(0.35))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .padding(.bottom, 2)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var attachmentChips: some View {
        HStack(spacing: 6) {
            ForEach(pendingAttachments) { attachment in
                HStack(spacing: 4) {
                    Image(systemName: attachment.kind == .image ? "photo" : "doc.text")
                        .font(.caption2)
                    Text(attachment.fileName)
                        .font(.caption2)
                        .lineLimit(1)
                    Button {
                        pendingAttachments.removeAll { $0.id == attachment.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
            }
            Spacer()
        }
    }

    /// Opens a file picker for images (routed to a vision-capable model
    /// automatically) or text/code/document files (content read and
    /// injected directly into the prompt — any chat model can read plain
    /// text, no special capability needed for that path). Explicitly lists
    /// every common code/text extension rather than relying solely on the
    /// broader .sourceCode/.plainText umbrella types, since those don't
    /// reliably cover every extension across UTType's built-in declarations
    /// (many languages/config formats aren't pre-registered as .sourceCode).
    private func pickAttachment() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        let codeExtensions = [
            "py", "js", "ts", "tsx", "jsx", "java", "c", "h", "cpp", "cc", "hpp", "cs",
            "go", "rs", "rb", "php", "swift", "kt", "kts", "m", "mm", "scala", "pl",
            "sh", "bash", "zsh", "sql", "r", "lua", "dart", "vue", "svelte", "html",
            "css", "scss", "less", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf",
            "json", "md", "markdown", "txt", "log", "csv", "tsv", "env", "gradle",
            "makefile", "dockerfile", "gitignore", "vb", "asm", "clj", "ex", "exs",
            "hs", "jl", "nim", "pas", "pyi", "pyx", "groovy", "tf", "proto"
        ]
        let codeTypes: [UTType] = codeExtensions.compactMap { UTType(filenameExtension: $0) }
        let documentTypes: [UTType] = [.pdf, .rtf]

        panel.allowedContentTypes = [.image, .plainText, .sourceCode] + codeTypes + documentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let utType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType

        if let utType, utType.conforms(to: .image) {
            guard let data = try? Data(contentsOf: url) else {
                attachmentError = "Couldn't read that image file."
                return
            }
            attachmentError = nil
            pendingAttachments.append(MessageAttachment(fileName: url.lastPathComponent, kind: .image, imageData: data))
        } else if let utType, utType.conforms(to: .pdf) {
            let text = extractPDFText(from: url) ?? ""
            let pages = PDFVisualExtractor.extractPages(from: url, maxPages: 1)
            let firstPageData = pages.first?.pngData
            attachmentError = nil
            pendingAttachments.append(MessageAttachment(
                fileName: url.lastPathComponent,
                kind: .textFile,
                imageData: firstPageData,
                extractedText: text.isEmpty ? "PDF Document: \(url.lastPathComponent)" : text
            ))
        } else if let text = try? String(contentsOf: url, encoding: .utf8) {
            attachmentError = nil
            pendingAttachments.append(MessageAttachment(fileName: url.lastPathComponent, kind: .textFile, extractedText: text))
        } else {
            attachmentError = "Couldn't read that file — only images, PDFs, and text/code files are supported."
        }
    }

    /// Extracts plain text from a PDF using PDFKit, so PDF content can be
    /// injected into the prompt the same way a .txt/.md file's content is —
    /// any chat model can then read/answer questions about it as text.
    private func extractPDFText(from url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        var fullText = ""
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            fullText += page.string ?? ""
            fullText += "\n"
        }
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var canSend: Bool {
        !viewModel.isStreaming
            && appState.selectedModelName != nil
            && (!draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
    }

    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
            return
        }
        dictation.start(existingText: draftText) { composed in
            draftText = composed
        }
    }

    private func send() {
        if dictation.isListening { dictation.stop() }
        guard let model = appState.selectedModelName else { return }
        let wasNewSession = (sessionId == nil)
        var realSizes: [String: Int64] = [:]
        for m in appState.installedModels { realSizes[m.name] = m.size }
        let textToSend = draftText
        draftText = ""
        let resultingSessionId = viewModel.send(
            promptText: textToSend,
            using: model,
            targetSessionId: sessionId,
            installedModelNames: appState.installedModels.map { $0.name },
            realSizesBytes: realSizes,
            attachments: pendingAttachments
        )
        pendingAttachments = []
        inputHeight = 20
        if wasNewSession, let resultingSessionId {
            onSessionCreated?(resultingSessionId)
        }
    }
}

private struct MessageBubble: View {
    @EnvironmentObject var appState: AppState
    let message: DisplayMessage
    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if message.role == "user" { Spacer(minLength: 60) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                if let modelUsed = message.modelUsed {
                    routedBadge(for: modelUsed)
                }
                if !message.attachments.isEmpty {
                    attachmentPreviewChips
                }
                bubbleContent
                if !message.isImage {
                    copyButton
                }
            }
            .frame(maxWidth: message.isImage ? 400 : 480, alignment: message.role == "user" ? .trailing : .leading)

            if message.role == "assistant" { Spacer(minLength: 60) }
        }
        .onHover { hovering in isHovering = hovering }
    }

    /// Shows exactly which real model answered THIS specific message —
    /// stamped per-message rather than tracked as one session-wide "last
    /// routed model" value, since Auto mode can legitimately route different
    /// messages in the same conversation to different models (e.g. a chat
    /// model for brand names, then an image model for a logo request).
    private func routedBadge(for modelName: String) -> some View {
        let label = appState.catalog.entry(named: modelName)?.displayName ?? modelName
        return Label(label, systemImage: "sparkles")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
    }

    private var attachmentPreviewChips: some View {
        HStack(spacing: 6) {
            ForEach(message.attachments) { attachment in
                Label(attachment.fileName, systemImage: attachment.kind == .image ? "photo" : "doc.text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private var copyButton: some View {
        // Deliberately always visible (not hover-gated) rather than
        // opacity(0)-until-hover — hover detection inside a ScrollView/
        // LazyVStack can be unreliable on macOS, and a copy button that
        // silently never appears is worse than one that's always present but
        // subtle. Low opacity keeps it unobtrusive without hiding it entirely.
        Button {
            copyText()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                if didCopy { Text("Copied").font(.caption2) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .opacity(didCopy ? 1 : 0.45)
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { didCopy = false }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isImage {
            if let data = message.imageData, let nsImage = NSImage(data: data) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    HStack(spacing: 10) {
                        Button {
                            saveImage(data: data)
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            copyImage(data: data)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                generatingIndicator(label: "Generating image…")
                    .padding(10)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        } else if message.role == "assistant" && message.content.isEmpty {
            generatingIndicator(label: nil)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            // .textSelection(.enabled) intentionally applied inside
            // MarkdownBlockView per-Text, not wrapped around the whole
            // composite from out here — wrapping the entire multi-view VStack
            // in one selection region was intercepting pointer events and
            // preventing the copy button below it from receiving hover/clicks.
            MarkdownBlockView(raw: message.content)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func generatingIndicator(label: String?) -> some View {
        HStack(spacing: 8) {
            if let label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TypingIndicatorView()
        }
    }

    /// Distinct card styling per role so bubbles read clearly against the
    /// window background in both light and dark mode. Assistant bubbles use
    /// a system material (frosted glass look today, automatically upgrades
    /// to true Liquid Glass on macOS 26) rather than a flat fill; user
    /// bubbles keep an accent tint since a colored material would clash with
    /// the tinted glass look Apple reserves for controls, not chat content.
    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(message.role == "user" ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(.regularMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(message.role == "user" ? Color.accentColor.opacity(0.25) : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )
    }

    private func saveImage(data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "generated-image.png"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func copyImage(data: Data) {
        guard let image = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}
