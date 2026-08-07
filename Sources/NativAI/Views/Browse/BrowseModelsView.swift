/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI

struct BrowseModelsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedCategory: String = "all"
    @State private var onlyCompatible: Bool = true
    @State private var searchText: String = ""
    @State private var manualModelName: String = ""
    @State private var showManualPull: Bool = false
    @State private var sortOrder: SortOrder = .smallestFirst

    enum SortOrder: String, CaseIterable, Identifiable {
        case smallestFirst = "Smallest First"
        case largestFirst = "Largest First"
        var id: String { rawValue }
    }

    private let categories: [(id: String, label: String)] = [
        ("all", "All"),
        ("coding", "Coding"),
        ("research", "Research"),
        ("qa", "Q&A"),
        ("image_gen", "Image Gen"),
        ("embedding", "Embedding")
    ]

    private var filteredModels: [ModelEntry] {
        var models = appState.catalog.models(inCategory: selectedCategory)
        if onlyCompatible {
            models = models.filter { $0.compatibility(for: appState.deviceSpecs) != .unsupported }
        }
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let query = searchText.lowercased()
            models = models.filter {
                $0.displayName.lowercased().contains(query) || $0.name.lowercased().contains(query)
            }
        }
        switch sortOrder {
        case .smallestFirst:
            return models.sorted { $0.sizeGB < $1.sizeGB }
        case .largestFirst:
            return models.sorted { $0.sizeGB > $1.sizeGB }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if filteredModels.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 360), spacing: 14)], spacing: 14) {
                        ForEach(filteredModels) { model in
                            BrowseModelCard(model: model)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .task {
            await appState.refreshInstalledModels()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No models match your filters")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Browse Models")
                    .font(.headline)
                Spacer()
                Toggle("Compatible with my device", isOn: $onlyCompatible)
                    .toggleStyle(.switch)
                    .font(.caption)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search models…", text: $searchText)
                    .textFieldStyle(.plain)
                Spacer()
                Picker("", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
                .controlSize(.small)

                // "Pull by name" as a popover rather than an inline expanding
                // DisclosureGroup — expanding content inline here was
                // changing this header's height, which triggered
                // NavigationSplitView to visibly reflow the sidebar on
                // macOS (the "sidebar goes messed up" glitch). A popover
                // overlays instead of resizing its parent, so it can't
                // trigger that layout recalculation at all.
                Button {
                    showManualPull = true
                } label: {
                    Image(systemName: "terminal")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showManualPull, arrowEdge: .bottom) {
                    manualPullPopoverContent
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Scrollable category tabs — a fixed segmented picker stopped
            // fitting cleanly once we added the Embedding category alongside
            // the others at this window width.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.id) { category in
                        categoryTab(category)
                    }
                }
            }
        }
        .padding(16)
    }

    /// Fallback for the thousands of community models on ollama.com/library
    /// that aren't in our curated catalog — Ollama doesn't publish a public
    /// API for that registry, so rather than scrape their website (fragile,
    /// breaks silently on redesigns) we let power users pull any exact model
    /// name directly, using the same /api/pull plumbing as catalog installs.
    private var manualPullPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pull a model by name")
                .font(.headline)
            Text("Know the exact name of a model from ollama.com/library that isn't listed below? Pull it directly.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("e.g. phi3.5:latest", text: $manualModelName)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onSubmit(pullManualModel)

                Button("Pull") {
                    pullManualModel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(manualModelName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let progress = appState.activePulls[manualModelName.trimmingCharacters(in: .whitespaces)] {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                    Text(progress.totalBytes > 0 ? "\(progress.friendlyStatus) · \(progress.percentageText)" : progress.friendlyStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = appState.installErrors[manualModelName.trimmingCharacters(in: .whitespaces)] {
                Text("⚠️ \(error)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func pullManualModel() {
        let trimmed = manualModelName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        appState.install(modelName: trimmed)
    }

    private func categoryTab(_ category: (id: String, label: String)) -> some View {
        let isSelected = selectedCategory == category.id
        return Button {
            selectedCategory = category.id
        } label: {
            Text(category.label)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct BrowseModelCard: View {
    @EnvironmentObject var appState: AppState
    let model: ModelEntry
    @State private var showInstallAnywayConfirm = false

    private var compatibility: CompatibilityLevel {
        model.compatibility(for: appState.deviceSpecs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.role.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.blue)
                Spacer()
                Text(compatibility.badge)
                    .font(.caption2)
                    .foregroundStyle(compatibility == .unsupported ? .red : .secondary)
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

            actionArea
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .opacity(compatibility == .unsupported ? 0.6 : 1.0)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .confirmationDialog(
            "This model may exceed your device's memory and could run very slowly or fail to load. Install anyway?",
            isPresented: $showInstallAnywayConfirm
        ) {
            Button("Install Anyway", role: .destructive) {
                appState.install(model: model)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        if appState.isInstalled(model.name) {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)
        } else if appState.pausedPulls.contains(model.name) {
            HStack(spacing: 8) {
                Button {
                    appState.resumePull(modelName: model.name)
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if let progress = appState.activePulls[model.name] {
                    Text("Paused at \(progress.percentageText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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
                    Spacer()
                    // Ollama resumes from the same point later (blobs are
                    // stored by content hash server-side), so "Pause" here
                    // never loses download progress — it just stops for now.
                    Button {
                        appState.pausePull(modelName: model.name)
                    } label: {
                        Image(systemName: "pause.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Pause download")

                    Button {
                        appState.cancelPull(modelName: model.name)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button(compatibility == .unsupported ? "Install Anyway…" : "Install") {
                    if compatibility == .unsupported {
                        showInstallAnywayConfirm = true
                    } else {
                        appState.install(model: model)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let errorMessage = appState.installErrors[model.name] {
                    Text("⚠️ \(errorMessage)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    // A failed pull (timeout, network hiccup, etc.) otherwise
                    // has no easy recovery action beyond re-clicking "Install"
                    // above — this makes retrying one tap away right next to
                    // the error, and reads more clearly as "try again" than
                    // reusing the generic Install button for that purpose.
                    Button("Retry") {
                        appState.install(model: model)
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.blue)
                }
            }
        }
    }
}
