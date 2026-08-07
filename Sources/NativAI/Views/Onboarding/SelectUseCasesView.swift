/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI

private struct UseCaseOption: Identifiable {
    let id: String
    let label: String
    let icon: String
    let description: String
}

private let useCaseOptions: [UseCaseOption] = [
    .init(id: "coding", label: "Coding", icon: "chevron.left.forwardslash.chevron.right", description: "Write, debug, and discuss code"),
    .init(id: "research", label: "Research", icon: "text.book.closed", description: "Summarize, analyze, dig into topics"),
    .init(id: "qa", label: "General Q&A", icon: "bubble.left.and.bubble.right", description: "Everyday questions and chat"),
    .init(id: "marketing", label: "Marketing / Content", icon: "megaphone", description: "Writing copy plus generating images"),
    .init(id: "design", label: "Design / UI Mockups", icon: "paintbrush", description: "Image generation, including text-in-image"),
]

struct SelectUseCasesView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("What will you use this for?")
                    .font(.title2.bold())
                Text("Select all that apply — we'll recommend models for each.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 12)], spacing: 12) {
                ForEach(useCaseOptions) { option in
                    useCaseCard(option)
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 720)

            Spacer()

            Button("Continue") {
                appState.onboardingStage = .reviewRecommendations
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.selectedUseCases.isEmpty)
            .padding(.bottom, 32)
        }
    }

    private func useCaseCard(_ option: UseCaseOption) -> some View {
        let isSelected = appState.selectedUseCases.contains(option.id)
        return Button {
            appState.toggleUseCase(option.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: option.icon)
                        .font(.title3)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
                Text(option.label)
                    .font(.headline)
                Text(option.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.blue.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
