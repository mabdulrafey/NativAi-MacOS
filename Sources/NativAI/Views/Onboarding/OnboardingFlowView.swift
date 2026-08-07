/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI

/// Container that walks the user through: spec scan → install Ollama (if needed)
/// → pick use cases → review recommendations → land in the main app.
struct OnboardingFlowView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if appState.onboardingStage == .scanningSpecs {
                await appState.runInitialScan()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.onboardingStage {
        case .scanningSpecs:
            ScanningSpecsView()
        case .installingOllama:
            InstallingOllamaView()
        case .installingRouter:
            InstallingRouterView()
        case .selectUseCases:
            SelectUseCasesView()
        case .reviewRecommendations:
            RecommendationsView()
        case .done:
            Color.clear
        }
    }
}
