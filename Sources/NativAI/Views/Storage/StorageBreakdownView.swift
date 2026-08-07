/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI

/// Tapping the sidebar's storage total opens this — a combined breakdown of
/// installed models and saved chat history, each individually deletable, plus
/// a bulk "Delete All Chats" action for reclaiming space quickly.
struct StorageBreakdownView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showUninstallSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List {
                Section("Models (\(String(format: "%.1f GB", appState.totalDiskUsageGB)))") {
                    if appState.installedModels.isEmpty {
                        Text("No models installed")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(appState.installedModels) { model in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.name)
                                        .font(.body)
                                    if let error = appState.deleteErrors[model.name] {
                                        Text("⚠️ \(error)")
                                            .font(.caption2)
                                            .foregroundStyle(.red)
                                    }
                                }
                                Spacer()
                                Text(sizeString(model.size))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button(role: .destructive) {
                                    appState.delete(modelName: model.name)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Chats (\(chatSizeString))")
                        Spacer()
                        if !appState.chatViewModel.sessions.isEmpty {
                            Button("Delete All", role: .destructive) {
                                deleteAllChats()
                            }
                            .font(.caption)
                        }
                    }
                } footer: {
                    if appState.chatViewModel.sessions.isEmpty {
                        Text("No saved chats")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(appState.chatViewModel.sessions) { session in
                                HStack {
                                    Text(session.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Button(role: .destructive) {
                                        appState.chatViewModel.deleteSession(session.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                Section("Ollama") {
                    Toggle("Stop Ollama when NativAI quits", isOn: Binding(
                        get: { appState.stopOllamaOnQuit },
                        set: { appState.stopOllamaOnQuit = $0 }
                    ))
                    .font(.body)

                    Text("On by default — Ollama and any loaded model are shut down when you quit NativAI, so nothing keeps using memory in the background. Turn this off to leave Ollama running for other apps or terminal use.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button("Free Model Memory Now") {
                        appState.freeModelMemoryNow()
                    }
                    .font(.body)
                }

                Section("Uninstall") {
                    Text("Completely removes NativAI, model weights, and Ollama server so zero trace remains on this Mac.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button("Uninstall NativAI…", role: .destructive) {
                        showUninstallSheet = true
                    }
                    .font(.body)
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 460, height: 560)
        .sheet(isPresented: $showUninstallSheet) {
            UninstallSheetView()
                .environmentObject(appState)
        }
    }

    private var header: some View {
        HStack {
            Text("Storage")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
        }
        .padding(16)
    }

    private var chatSizeString: String {
        let mb = Double(appState.chatViewModel.totalDiskUsageBytes) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }

    private func sizeString(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
    }

    private func deleteAllChats() {
        for session in appState.chatViewModel.sessions {
            appState.chatViewModel.deleteSession(session.id)
        }
    }
}
