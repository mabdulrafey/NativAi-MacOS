/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI
import AppKit

/// Floating Spotlight-style NSPanel for quick queries & offline workspace debugging.
final class QuickAskPanel: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.borderless, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.hasShadow = true
        self.contentView = contentView

        centerOnScreen()
    }

    func centerOnScreen() {
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let x = screenRect.midX - 340
            let y = screenRect.midY + 100
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

/// SwiftUI View for the Quick Ask floating Spotlight popover.
struct QuickAskView: View {
    @EnvironmentObject var appState: AppState
    @State private var promptText: String = ""
    @State private var responseText: String = ""
    @State private var isStreaming: Bool = false
    @State private var selectedWorkspaceURL: URL? = nil
    @State private var statusNote: String = "Offline Workspace Debugger Ready"
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Top Search / Input Bar
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.accentColor)

                TextField("Ask NativAI or debug your workspace offline…", text: $promptText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .regular))
                    .focused($isFocused)
                    .onSubmit { sendQuickAsk() }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isFocused = true
                        }
                    }

                if isStreaming {
                    ProgressView()
                        .controlSize(.small)
                } else if !promptText.isEmpty {
                    Button(action: sendQuickAsk) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))

            Divider()

            // Workspace Bar (VS Code / Xcode project selector)
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(selectedWorkspaceURL?.lastPathComponent ?? "No active workspace folder selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                Button("Select Workspace Folder") {
                    selectWorkspaceFolder()
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))

            Divider()

            // Response Area
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if responseText.isEmpty && !isStreaming {
                        Text("Type a question, paste code, or select a project workspace to debug offline without internet.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top, 20)
                    } else {
                        Text(responseText)
                            .font(.system(size: 14, weight: .regular, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 680, height: 420)
        .background(.regularMaterial)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window is QuickAskPanel {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isFocused = true
                }
            }
        }
    }

    private func selectWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Workspace"

        if panel.runModal() == .OK, let url = panel.url {
            selectedWorkspaceURL = url
            statusNote = "Workspace: \(url.lastPathComponent)"
        }
    }

    private func sendQuickAsk() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        isStreaming = true
        responseText = "Thinking..."

        Task {
            var contextStr = ""
            // Index workspace folder offline via DocumentRAGService if selected
            if let workspace = selectedWorkspaceURL {
                contextStr = await DocumentRAGService.queryWorkspace(prompt: text, workspaceURL: workspace)
            }

            let fullPrompt = contextStr.isEmpty ? text : "\(contextStr)\n\nUser Question: \(text)"
            let installedNames = appState.installedModels.map { $0.name }
            let model = SemanticRouter.resolveRouterModel(installedModelNames: installedNames) ?? installedNames.first ?? "qwen2.5:1.5b"

            responseText = ""
            try? await OllamaManager.shared.chat(
                model: model,
                messages: [OllamaManager.ChatMessage(role: "user", content: fullPrompt)],
                contextLength: 4096
            ) { token in
                DispatchQueue.main.async {
                    self.responseText += token
                }
            }
            DispatchQueue.main.async {
                self.isStreaming = false
            }
        }
    }
}
