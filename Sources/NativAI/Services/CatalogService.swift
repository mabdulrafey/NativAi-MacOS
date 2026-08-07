/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Loads the bundled model catalog and provides recommendation/browse queries
/// against it, driven by device specs and the user's selected use cases.
final class CatalogService {

    static let shared = CatalogService()

    private(set) var allModels: [ModelEntry] = []

    private init() {
        loadCatalog()
    }

    private func loadCatalog() {
        guard let url = Self.locateCatalogURL() else {
            print("⚠️ catalog.json not found in any known location")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            allModels = try JSONDecoder().decode([ModelEntry].self, from: data)
        } catch {
            print("⚠️ Failed to load catalog.json: \(error)")
        }
    }

    /// Resolves catalog.json across every way this app can be built/run:
    ///  1. Packaged .app bundle (Contents/Resources/catalog.json) — production .pkg installs
    ///  2. `swift run`/`swift build` dev flow — SPM copies resources into a
    ///     sibling "*_NativAI.bundle" next to the built executable
    ///  3. Direct source-tree fallback — useful when compiled via raw `swiftc`
    ///     (no SwiftPM resource bundling at all), as our build_pkg.sh fallback does
    private static func locateCatalogURL() -> URL? {
        // 1. Standard app bundle resource lookup.
        if let url = Bundle.main.url(forResource: "catalog", withExtension: "json") {
            return url
        }

        // 2. Look for an SPM-generated resource bundle next to the executable.
        let executableDir = Bundle.main.bundleURL.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: executableDir, includingPropertiesForKeys: nil
        ) {
            for entry in contents where entry.pathExtension == "bundle" {
                let candidate = entry.appendingPathComponent("catalog.json")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        // 3. Dev-time fallback: resolve relative to this source file's location
        // in the repo (Sources/NativAI/Services/CatalogService.swift -> ../Resources/catalog.json).
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let repoFallback = sourceFileURL
            .deletingLastPathComponent()          // Services/
            .deletingLastPathComponent()          // NativAI/
            .appendingPathComponent("Resources/catalog.json")
        if FileManager.default.fileExists(atPath: repoFallback.path) {
            return repoFallback
        }

        return nil
    }

    // MARK: - Browse (all models, optionally filtered by category)

    /// Looks up a catalog entry by exact model name (e.g. "x/flux2-klein:4b").
    /// Used to determine a currently-selected/installed model's role (chat/coder/image)
    /// since Ollama's own /api/tags response doesn't carry our catalog metadata.
    func entry(named name: String) -> ModelEntry? {
        allModels.first { entry in
            entry.name == name ||
            name == "\(entry.name):latest" ||
            name.hasPrefix("\(entry.name):") ||
            entry.name == name.components(separatedBy: ":").first
        }
    }

    func models(inCategory category: String?) -> [ModelEntry] {
        guard let category, category != "all" else { return allModels }
        return allModels.filter { $0.category.contains(category) }
    }

    // MARK: - Recommendations

    /// One recommendation "card" the onboarding/recommendation screen can render.
    struct Recommendation: Identifiable {
        var id: String { "\(useCase)-\(model.name)" }
        let useCase: String
        let roleLabel: String     // "Reasoning", "Coder", "Image Generation", etc.
        let model: ModelEntry
        let compatibility: CompatibilityLevel
    }

    /// Given the user's selected use cases and device specs, returns the best
    /// model recommendation(s). Coding gets two slots (chat + coder), per the
    /// two-job pattern; other use cases get one best-fit chat/image model.
    func recommendations(for useCases: [String], specs: DeviceSpecs) -> [Recommendation] {
        var results: [Recommendation] = []

        for useCase in useCases {
            if useCase == "coding" {
                if let coder = bestFit(role: "coder", useCase: useCase, specs: specs) {
                    results.append(Recommendation(useCase: useCase, roleLabel: "Coder", model: coder, compatibility: coder.compatibility(for: specs)))
                }
                if let chat = bestFit(role: "chat", useCase: useCase, specs: specs) {
                    results.append(Recommendation(useCase: useCase, roleLabel: "Reasoning / Chat", model: chat, compatibility: chat.compatibility(for: specs)))
                }
            } else if useCase == "design" || useCase == "marketing" {
                if let image = bestFit(role: "image", useCase: useCase, specs: specs) {
                    results.append(Recommendation(useCase: useCase, roleLabel: "Image Generation", model: image, compatibility: image.compatibility(for: specs)))
                }
                if let chat = bestFit(role: "chat", useCase: useCase, specs: specs) {
                    results.append(Recommendation(useCase: useCase, roleLabel: "Chat", model: chat, compatibility: chat.compatibility(for: specs)))
                }
            } else {
                if let chat = bestFit(role: "chat", useCase: useCase, specs: specs) {
                    results.append(Recommendation(useCase: useCase, roleLabel: "Chat", model: chat, compatibility: chat.compatibility(for: specs)))
                }
            }
        }
        return results
    }

    /// Picks the highest-quality model for a given role/use-case that the
    /// device can run at least at "slow" tier. Prefers largest size that still fits,
    /// since bigger generally = higher quality within a fitting tier.
    private func bestFit(role: String, useCase: String, specs: DeviceSpecs) -> ModelEntry? {
        let candidates = allModels.filter {
            $0.role == role && $0.useCases.contains(useCase)
        }

        let runnable = candidates.filter { $0.compatibility(for: specs) != .unsupported }
        guard !runnable.isEmpty else {
            // Nothing comfortably fits — fall back to the smallest candidate overall
            // so we always suggest *something*, clearly marked unsupported/slow.
            return candidates.sorted { $0.sizeGB < $1.sizeGB }.first
        }

        // Prefer "fits" over "slow", then prefer the largest (assumed higher quality) within that tier.
        let fitsFully = runnable.filter { $0.compatibility(for: specs) == .fits }
        if !fitsFully.isEmpty {
            return fitsFully.sorted { $0.sizeGB > $1.sizeGB }.first
        }
        return runnable.sorted { $0.sizeGB > $1.sizeGB }.first
    }

    // MARK: - Auto-routing (best installed model for a given role)

    /// Among the user's currently-INSTALLED models, picks the best match for
    /// a given role (chat/coder/image), preferring the largest parameter
    /// count (sizeGB as proxy) — used by "Auto" mode to route each message to
    /// whichever installed model is the strongest fit for that specific task,
    /// rather than always using whichever model happens to be selected.
    /// Falls back to any installed model not in our catalog if nothing
    /// matches (e.g. a manually-pulled model), assuming role "chat" as the
    /// safest default for unknown models.
    func bestInstalledModel(role: String, installedNames: [String], realSizesBytes: [String: Int64] = [:]) -> String? {
        let candidates = installedNames.compactMap { name -> ModelEntry? in
            entry(named: name)
        }.filter { $0.role == role }

        if let best = candidates.sorted(by: { $0.sizeGB > $1.sizeGB }).first {
            return best.name
        }

        // No catalog match for this role among installed models. If asking
        // for "chat" specifically, fall back to any installed model we don't
        // recognize — but pick the LARGEST by real on-disk byte size rather
        // than just the first in the list, since list order from Ollama's
        // /api/tags is arbitrary and has no relationship to model quality.
        // This was the root cause of Auto picking a small unrecognized model
        // (e.g. "phi3:mini") over a much larger correctly-catalogued one.
        if role == "chat" {
            let unrecognized = installedNames.filter { entry(named: $0) == nil }
            guard !unrecognized.isEmpty else { return nil }
            if !realSizesBytes.isEmpty {
                return unrecognized.sorted { (realSizesBytes[$0] ?? 0) > (realSizesBytes[$1] ?? 0) }.first
            }
            return unrecognized.first
        }
        return nil
    }
}
