/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI

/// Inline card offering to install a model the user's request needed.
///
/// Presented in the chat transcript rather than as an alert, because a missing
/// model isn't an error — it's a prerequisite with an obvious next step, and
/// keeping it in the conversation preserves the context that prompted it. The
/// install runs through the same `AppState.install` path as Browse Models, so
/// progress, pause/resume and error surfacing all behave identically.
struct CapabilityGapCard: View {
    @EnvironmentObject private var appState: AppState
    let prompt: CapabilityGapPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: prompt.symbolName)
                    .foregroundStyle(.tint)
                Text(prompt.headline)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if prompt.suggestions.isEmpty {
                // Honest dead end: the catalog has nothing for this capability
                // that this machine can run. Saying so beats an empty card.
                Text("No compatible model is available for this machine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(prompt.suggestions) { entry in
                    SuggestionRow(entry: entry)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
    }

    /// One suggested model, with live install state.
    ///
    /// Nested so it can observe `appState` for this specific model's progress
    /// without the parent re-rendering every row on each progress tick.
    private struct SuggestionRow: View {
        @EnvironmentObject private var appState: AppState
        let entry: ModelEntry

        private var isInstalling: Bool { appState.activePulls[entry.name] != nil }
        private var isInstalled: Bool {
            appState.installedModels.contains { $0.name == entry.name }
        }

        var body: some View {
            // Wrapped in a VStack because the row and its error line are two
            // sibling views. A `some View` body returning two top-level views
            // relies on implicit TupleView layout, which lays them out
            // horizontally in some containers and produced a misaligned row.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayName)
                            .font(.callout.weight(.medium))
                        HStack(spacing: 6) {
                            Text(String(format: "%.1f GB", entry.sizeGB))
                            Text("·")
                            // Shows the honest fit for *this* Mac, so a "will run
                            // but slower" option isn't mistaken for a good one.
                            Text(entry.compatibility(for: appState.deviceSpecs).badge)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if isInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else if isInstalling, let progress = appState.activePulls[entry.name] {
                        VStack(alignment: .trailing, spacing: 2) {
                            ProgressView(value: progress.fraction)
                                .frame(width: 90)
                            Text(progress.status.capitalized)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Install") {
                            appState.install(modelName: entry.name)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                if let error = appState.installErrors[entry.name] {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.leading, 24)
        }
    }
}
