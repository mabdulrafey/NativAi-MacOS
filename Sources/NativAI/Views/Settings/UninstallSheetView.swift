/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI
import AppKit

/// Native SwiftUI dialog for completely uninstalling NativAI, its data,
/// downloaded models, and the local Ollama server without requiring Terminal.
struct UninstallSheetView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var removeAppAndPreferences: Bool = true
    @State private var removeModels: Bool = true
    @State private var removeOllamaServer: Bool = true

    @State private var isUninstalling: Bool = false
    @State private var statusMessage: String = ""
    @State private var isFinished: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isUninstalling {
                progressContent
            } else if isFinished {
                finishedContent
            } else {
                mainContent
            }
        }
        .frame(width: 480, height: 500)
    }

    private var header: some View {
        HStack {
            Image(systemName: "trash.circle.fill")
                .font(.title)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Uninstall NativAI")
                    .font(.headline)
                Text("Completely remove NativAI and leave zero trace on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isUninstalling && !isFinished {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
            }
        }
        .padding(16)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Footprint Summary Box
            VStack(alignment: .leading, spacing: 8) {
                Text("Space to be reclaimed:")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                HStack {
                    Image(systemName: "app.badge.checkmark")
                    Text("NativAI App & Chat History:")
                    Spacer()
                    Text("\(chatSizeString)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                HStack {
                    Image(systemName: "cpu")
                    Text("Downloaded AI Models:")
                    Spacer()
                    Text("\(String(format: "%.1f GB", appState.totalDiskUsageGB))")
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                }
                .font(.caption)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 12) {
                Text("Cleanup Options:")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Toggle(isOn: $removeAppAndPreferences) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remove NativAI App, Chats, Memory & Preferences")
                            .fontWeight(.medium)
                        Text("Deletes Application Support files, stored facts, and preferences.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $removeModels) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete all downloaded AI models (\(String(format: "%.1f GB", appState.totalDiskUsageGB)))")
                            .fontWeight(.medium)
                        Text("Deletes downloaded model weights from ~/.ollama/models.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $removeOllamaServer) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remove Ollama engine & background service")
                            .fontWeight(.medium)
                        Text("Stops and deletes the local Ollama binary, service, and cache.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button(role: .destructive) {
                    executeUninstall()
                } label: {
                    Text("Uninstall Everything & Quit")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(16)
    }

    private var progressContent: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(statusMessage)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }

    private var finishedContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Uninstallation Complete")
                .font(.title2)
                .fontWeight(.bold)
            Text("All selected items and preferences have been wiped. NativAI will now close.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    private var chatSizeString: String {
        let mb = Double(appState.chatViewModel.totalDiskUsageBytes) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }

    private func executeUninstall() {
        isUninstalling = true
        statusMessage = "Stopping background server & processes…"

        let shouldRemoveModels = self.removeModels
        let shouldRemoveOllama = self.removeOllamaServer
        let shouldRemoveApp = self.removeAppAndPreferences

        Task.detached {
            // 1. Stop Ollama server
            await OllamaManager.shared.stopServer()
            
            // Helper shell executor
            let runShell: (String) -> Void = { cmd in
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                proc.arguments = ["-c", cmd]
                try? proc.run()
                proc.waitUntilExit()
            }

            runShell("pkill -u $(id -u) -x ollama 2>/dev/null || true")
            runShell("pkill -u $(id -u) -f 'ollama runner' 2>/dev/null || true")

            // 2. Remove models if selected
            if shouldRemoveModels {
                await MainActor.run { statusMessage = "Deleting downloaded LLM & CoreML Stable Diffusion weights…" }
                // Remove Ollama model weights
                runShell("rm -rf ~/.ollama/models 2>/dev/null || true")
                let customModelsDir = ProcessInfo.processInfo.environment["OLLAMA_MODELS"]
                if let custom = customModelsDir, !custom.isEmpty {
                    runShell("rm -rf '\(custom)' 2>/dev/null || true")
                }
                // Remove CoreML Stable Diffusion weights & CoreML metal caches
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                runShell("rm -rf '\(home)/Library/Application Support/NativAI/CoreMLModels' 2>/dev/null || true")
                runShell("rm -rf '\(home)/Library/Caches/CoreML' 2>/dev/null || true")
                runShell("rm -rf '\(home)/Library/Caches/com.apple.metal' 2>/dev/null || true")
            }

            // 3. Remove Ollama runtime if selected
            if shouldRemoveOllama {
                await MainActor.run { statusMessage = "Removing Ollama server & runtime…" }
                runShell("rm -rf ~/.ollama 2>/dev/null || true")
                runShell("rm -f /opt/homebrew/bin/ollama /usr/local/bin/ollama 2>/dev/null || true")
                runShell("rm -rf /Applications/Ollama.app 2>/dev/null || true")
                runShell("rm -f ~/Library/LaunchAgents/homebrew.mxcl.ollama.plist 2>/dev/null || true")
                runShell("rm -rf '~/Library/Application Support/Ollama' 2>/dev/null || true")
                runShell("rm -rf ~/Library/Caches/ollama 2>/dev/null || true")
            }

            // 4. Remove NativAI app data, chats, memory & preferences
            if shouldRemoveApp {
                await MainActor.run { statusMessage = "Wiping chats, memory, preferences & receipts…" }
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                runShell("rm -rf '\(home)/Library/Application Support/NativAI' 2>/dev/null || true")
                runShell("rm -rf '\(home)/Library/Caches/com.nativai.app' '\(home)/Library/Caches/mar.NativAI' '\(home)/Library/Caches/NativAI' 2>/dev/null || true")
                runShell("rm -rf '\(home)/Library/Preferences/com.nativai.app.plist' '\(home)/Library/Preferences/mar.NativAI.plist' '\(home)/Library/Preferences/NativAI.plist' 2>/dev/null || true")
                runShell("rm -rf '\(home)/Library/Saved Application State/com.nativai.app.savedState' '\(home)/Library/Saved Application State/mar.NativAI.savedState' '\(home)/Library/Saved Application State/NativAI.savedState' 2>/dev/null || true")
                
                runShell("defaults delete com.nativai.app 2>/dev/null || true")
                runShell("defaults delete mar.NativAI 2>/dev/null || true")
                runShell("defaults delete NativAI 2>/dev/null || true")
                runShell("killall cfprefsd 2>/dev/null || true")

                runShell("pkgutil --pkgs 2>/dev/null | grep -iE 'nativai|com.nativai' | xargs -I {} pkgutil --forget {} 2>/dev/null || true")
            }

            // 5. Schedule self-deletion of /Applications/NativAI.app after exit
            runShell("nohup sh -c 'sleep 1 && rm -rf /Applications/NativAI.app' >/dev/null 2>&1 &")

            await MainActor.run {
                statusMessage = "Complete!"
                isUninstalling = false
                isFinished = true
                
                // Quit immediately after brief display
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    exit(0)
                }
            }
        }
    }
}
