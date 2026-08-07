/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI

enum MainSection: Hashable {
    case chat(UUID?)   // nil = no session selected yet / "New Chat" landing state
    case browse
    case installed
    case memory
}

/// Main app shell shown after onboarding: sidebar (new chat + chat history +
/// storage total) + content area.
struct MainShellView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedSection: MainSection = .chat(nil)
    @State private var showStorageBreakdown = false

    var body: some View {
        VStack(spacing: 0) {
            if !appState.isOllamaServerReachable {
                serverUnreachableBanner
            }
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            } detail: {
                detailView
            }
        }
        .task {
            await appState.refreshInstalledModels()
        }
    }

    /// Makes an otherwise-silent "can't reach Ollama" failure immediately
    /// visible and actionable, instead of just quietly showing an empty
    /// model list that's indistinguishable from "you have no models yet."
    private var serverUnreachableBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Can't reach the local Ollama server")
                    .font(.system(size: 12, weight: .semibold))
                Text(appState.lastServerError ?? "Make sure Ollama is running (brew services start ollama).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Retry") {
                Task { await appState.refreshInstalledModels() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedSection) {
                Section {
                    Button {
                        startNewChat()
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.plain)
                }

                if !appState.chatViewModel.sessions.isEmpty {
                    Section("Chats") {
                        ForEach(appState.chatViewModel.sessions) { session in
                            chatHistoryRow(session)
                                .tag(MainSection.chat(session.id))
                        }
                    }
                }

                Section("Models") {
                    Label("Browse Models", systemImage: "square.grid.2x2")
                        .tag(MainSection.browse)
                    Label("Installed Models", systemImage: "internaldrive")
                        .tag(MainSection.installed)
                }
            }
            .listStyle(.sidebar)

            Divider()
            appearancePicker
            Divider()
            storageFooter
        }
    }

    private var appearancePicker: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { appState.appearanceMode },
                set: { newValue in
                    // Deferring to the next runloop tick avoids "Publishing
                    // changes from within view updates" — SwiftUI's segmented
                    // Picker can commit its selection binding synchronously
                    // during its own view-update pass, and mutating an
                    // ObservableObject's @Published property in that exact
                    // moment is what triggers the warning (and, per Apple,
                    // undefined behavior) even though the value change itself
                    // is completely intentional here.
                    DispatchQueue.main.async {
                        appState.appearanceMode = newValue
                    }
                }
            )) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func chatHistoryRow(_ session: ChatSession) -> some View {
        HStack {
            Label(session.title, systemImage: "bubble.left")
                .lineLimit(1)
            Spacer()
        }
        .contextMenu {
            Button("Delete Chat", role: .destructive) {
                deleteSession(session.id)
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                deleteSession(session.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Total local storage used, combining saved chat history (text + any
    /// embedded generated images) and installed model weights on disk — the
    /// two things this app actually accumulates over time.
    private var storageFooter: some View {
        let chatBytes = appState.chatViewModel.totalDiskUsageBytes
        let modelsGB = appState.totalDiskUsageGB
        let chatMB = Double(chatBytes) / 1_048_576.0
        let totalGB = modelsGB + (chatMB / 1024.0)

        return Button {
            showStorageBreakdown = true
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: "internaldrive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f GB used", totalGB))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Text("Models: \(String(format: "%.1f GB", modelsGB)) · Chats: \(String(format: "%.0f MB", chatMB))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .sheet(isPresented: $showStorageBreakdown) {
            StorageBreakdownView()
                .environmentObject(appState)
        }
    }

    private func startNewChat() {
        guard let model = appState.selectedModelName ?? appState.installedModels.first?.name else {
            selectedSection = .chat(nil)
            return
        }
        appState.chatViewModel.startNewSession(modelName: model)
        selectedSection = .chat(appState.chatViewModel.activeSessionId)
    }

    private func deleteSession(_ id: UUID) {
        appState.chatViewModel.deleteSession(id)
        if case .chat(let selectedId) = selectedSection, selectedId == id {
            selectedSection = .chat(appState.chatViewModel.activeSessionId)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .chat(let sessionId):
            ChatView(sessionId: sessionId) { newSessionId in
                // Fired the instant a message is sent from the "New Chat"
                // placeholder — updates the sidebar selection right away
                // instead of leaving the view stuck showing the stale empty
                // state until an unrelated tab switch forced a re-render.
                selectedSection = .chat(newSessionId)
            }
        case .browse:
            BrowseModelsView()
        case .installed:
            InstalledModelsView()
        case .memory:
            // Retained so previously-persisted sidebar selections still resolve,
            // but no longer reachable from the sidebar: rendering this inside the
            // NavigationSplitView reliably blanked the entire window, including
            // the sidebar, and three attempts to isolate the cause by inspection
            // failed. Memory now lives in its own Settings window (⌘,) where a
            // render failure cannot take the main UI down with it — the feature
            // itself works, so containing the blast radius is worth more than
            // continuing to guess at the SwiftUI interaction.
            MemoryView(store: MemoryStore.shared)
        }
    }
}
