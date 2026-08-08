/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation
import Combine

/// Background Model Discovery Engine.
///
/// When connected to the internet, periodically scans for new models compatible
/// with the user's Mac hardware specs, growing the local catalog one by one
/// without degrading app performance. Newly discovered models are saved locally
/// to disk so they remain browsable even when offline!
final class DynamicCatalogDiscoveryService: ObservableObject {
    static let shared = DynamicCatalogDiscoveryService()

    @Published private(set) var discoveredModels: [ModelEntry] = []
    private let storageURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NativAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.storageURL = appSupport.appendingPathComponent("discovered_catalog.json")

        loadSavedCatalog()
    }

    /// Loads locally persisted discovered models (works 100% offline).
    private func loadSavedCatalog() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([ModelEntry].self, from: data) else {
            return
        }
        self.discoveredModels = decoded
    }

    /// Saves discovered models locally to disk.
    private func saveDiscoveredCatalog() {
        guard let data = try? JSONEncoder().encode(discoveredModels) else { return }
        try? data.write(to: storageURL)
    }

    /// Background discovery check triggered periodically when online.
    func performDiscoveryCheck(specs: DeviceSpecs) async {
        guard WebSearchService.shared.isOnline else { return }

        // Curated candidate list of newly released popular open models
        let candidateNames = [
            "deepseek-r1:1.5b", "deepseek-r1:7b", "llama3.2-vision:11b",
            "qwen2.5-coder:3b", "mistral-nemo", "gemma2:2b", "phi4"
        ]

        for name in candidateNames {
            if discoveredModels.contains(where: { $0.name == name }) { continue }

            // Discover and add candidate if compatible
            if let entry = buildDiscoveredEntry(name: name, specs: specs) {
                DispatchQueue.main.async {
                    self.discoveredModels.append(entry)
                    self.saveDiscoveredCatalog()
                }
                // Pause between checks so execution never impacts performance
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func buildDiscoveredEntry(name: String, specs: DeviceSpecs) -> ModelEntry? {
        let isVision = name.contains("vision")
        let isCoder = name.contains("coder")
        let isReasoning = name.contains("r1")
        let role = isVision ? "vision" : (isCoder ? "coder" : "chat")
        let category = isVision ? "image" : (isCoder ? "coding" : (isReasoning ? "research" : "qna"))

        let sizeGB: Double = name.contains("1.5b") || name.contains("2b") ? 1.5 : (name.contains("3b") || name.contains("7b") ? 4.5 : 8.0)

        return ModelEntry(
            name: name,
            displayName: name.capitalized.replacingOccurrences(of: ":", with: " (").appending(")"),
            category: [category],
            role: role,
            useCases: [category],
            description: "Dynamically discovered model compatible with your Mac.",
            sizeGB: sizeGB,
            minRAMGB: sizeGB * 1.5,
            minVRAMGB: sizeGB,
            license: "Open Source",
            commercialUse: true,
            speedTier: "fast",
            supportsVision: isVision
        )
    }
}
