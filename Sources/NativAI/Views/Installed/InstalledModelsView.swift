/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI

struct InstalledModelsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if appState.installedModels.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(appState.installedModels) { model in
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
            Text("\(appState.totalDiskUsageGB, specifier: "%.1f") GB used")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "internaldrive")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No models installed")
                .font(.headline)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sizeString(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        return String(format: "%.1f GB", gb)
    }
}
