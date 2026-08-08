/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI

struct InstalledModelsView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""

    private var filteredModels: [OllamaManager.InstalledModel] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return appState.installedModels }
        return appState.installedModels.filter { $0.name.lowercased().contains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if appState.installedModels.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filteredModels) { model in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.name)
                                        .font(.body.bold())
                                    Text(sizeString(model.size))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    appState.delete(modelName: model.name)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }
                            if let error = appState.deleteErrors[model.name] {
                                Text("⚠️ \(error)")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
                .searchable(text: $searchText, prompt: "Filter installed models...")
            }
        }
        .task {
            await appState.refreshInstalledModels()
        }
    }

    private var header: some View {
        HStack {
            Text("Installed Models")
                .font(.headline)
            Spacer()
            Text("\(appState.installedModels.count) models (\(String(format: "%.1f GB", appState.totalDiskUsageGB)))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Models Installed")
                .font(.headline)
            Text("Browse the catalog to download local AI models.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    private func sizeString(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000.0
        return String(format: "%.2f GB", gb)
    }
}
