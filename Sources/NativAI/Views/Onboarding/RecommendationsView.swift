/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI

struct RecommendationsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Recommended for you")
                    .font(.title2.bold())
                Text("Based on your \(appState.deviceSpecs.tier.label.lowercased())-tier Mac and selected use cases.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)
            .padding(.bottom, 16)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 360), spacing: 14)], spacing: 14) {
                    ForEach(appState.currentRecommendations) { rec in
                        RecommendationCard(recommendation: rec)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }

            HStack {
                Button("Back") {
                    appState.onboardingStage = .selectUseCases
                }
                Spacer()
                Button("Finish Setup") {
                    appState.finishOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
        }
        .task {
            await appState.refreshInstalledModels()
        }
    }
}

private struct RecommendationCard: View {
    @EnvironmentObject var appState: AppState
    let recommendation: CatalogService.Recommendation

    private var model: ModelEntry { recommendation.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(recommendation.roleLabel.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.blue)
                Spacer()
                Text(recommendation.compatibility.badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(model.displayName)
                .font(.headline)

            Text(model.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Label("\(model.sizeGB, specifier: "%.1f") GB", systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if model.commercialUse == false {
                    Label("Non-commercial", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            installButton
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var installButton: some View {
        if appState.isInstalled(model.name) {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)
        } else if let progress = appState.activePulls[model.name] {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress.fraction)
                HStack(spacing: 6) {
                    Text(progress.totalBytes > 0 ? "\(progress.friendlyStatus) · \(progress.percentageText)" : progress.friendlyStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let speed = appState.pullSpeeds[model.name], speed > 0 {
                        Text("· \(formatSpeed(bytesPerSecond: speed))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button("Install") {
                    appState.install(model: model)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let errorMessage = appState.installErrors[model.name] {
                    Text("⚠️ \(errorMessage)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
