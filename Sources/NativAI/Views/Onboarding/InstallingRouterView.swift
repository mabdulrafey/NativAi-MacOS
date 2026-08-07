/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI

/// Onboarding step that downloads the small local model NativAI uses as its
/// routing brain — deciding whether each message wants an image, code, or
/// chat, and naming conversations.
///
/// Shown only when no suitable router is already installed, so users who
/// already have a capable model never see this screen at all.
struct InstallingRouterView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "brain")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: appState.routerInstallError == nil)

            VStack(spacing: 8) {
                Text("Setting up NativAI's engine")
                    .font(.title2.weight(.semibold))
                Text("Downloading a small model that understands what you're asking for and routes it to the right place. This happens once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if let error = appState.routerInstallError {
                errorSection(error)
            } else {
                progressSection
            }

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressSection: some View {
        VStack(spacing: 10) {
            if let progress = appState.routerPullProgress, progress.totalBytes > 0 {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 320)
                HStack(spacing: 6) {
                    Text(progress.friendlyStatus)
                    Text("·")
                    Text(progress.percentageText)
                    Text("·")
                    Text(formatBytes(progress.totalBytes))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 320)
                Text("Preparing download…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(SemanticRouter.bundledRouterModel)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
    }

    /// A failed router download is recoverable and non-blocking — the app
    /// still works with keyword-based routing — so offer both retry and skip
    /// rather than trapping the user on this screen.
    private func errorSection(_ error: String) -> some View {
        VStack(spacing: 14) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Text("NativAI will still work, but intent detection and chat names will be less accurate. You can install \(SemanticRouter.bundledRouterModel) later from Browse Models.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button("Try Again") {
                    Task { await appState.installRouterModelIfNeeded() }
                }
                .buttonStyle(.borderedProminent)

                Button("Skip for Now") {
                    appState.onboardingStage = .selectUseCases
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
