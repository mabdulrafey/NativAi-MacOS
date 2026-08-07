//
//  Models.swift
//  NativAI — Phase 1: shared domain types
//

import Foundation

// MARK: - Hardware Tiers

/// Capability tier derived from usable AI memory (unified memory on Apple
/// Silicon, system RAM on Intel). Drives the recommendation matrix.
enum HardwareTier: Int, Codable, CaseIterable, Comparable {
    case tier1 = 1   //  < 16 GB usable
    case tier2 = 2   // 16 ..< 24 GB usable
    case tier3 = 3   // >= 24 GB usable

    static func < (lhs: HardwareTier, rhs: HardwareTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .tier1: "Essential"
        case .tier2: "Performance"
        case .tier3: "Workstation"
        }
    }

    var summary: String {
        switch self {
        case .tier1: "Fast, lightweight models tuned for 8–12 GB machines."
        case .tier2: "Mid-size models with strong reasoning headroom."
        case .tier3: "Large frontier-class local models."
        }
    }
}

// MARK: - User Intent

/// What the user says they want to do — asked once during onboarding.
enum UserIntent: String, Codable, CaseIterable, Identifiable {
    case coding
    case general
    case research
    case multimodal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coding:     "Write & debug code"
        case .general:    "General questions & writing"
        case .research:   "Deep research & reasoning"
        case .multimodal: "Understand images & documents"
        }
    }

    var subtitle: String {
        switch self {
        case .coding:     "Code completion, refactors, test generation."
        case .general:    "Everyday Q&A, drafting, summarising."
        case .research:   "Long-form analysis and multi-step reasoning."
        case .multimodal: "Screenshots, diagrams, scanned pages."
        }
    }

    var symbolName: String {
        switch self {
        case .coding:     "chevron.left.forwardslash.chevron.right"
        case .general:    "bubble.left.and.bubble.right"
        case .research:   "book.closed"
        case .multimodal: "photo.on.rectangle.angled"
        }
    }
}

// MARK: - System Profile

/// Immutable snapshot of the host machine, produced by `HardwareScanner`.
struct SystemProfile: Codable, Equatable {
    /// Physical RAM installed, in bytes.
    let totalRAM: UInt64
    /// Memory the GPU will actually commit to a model, in bytes.
    /// Apple Silicon: `recommendedMaxWorkingSetSize`. Intel: discrete VRAM.
    let usableAIMemory: UInt64
    let isAppleSilicon: Bool
    let chipName: String
    let gpuCoreHint: Int?
    let tier: HardwareTier

    var totalRAMGB: Double { Double(totalRAM) / 1_073_741_824 }
    var usableAIMemoryGB: Double { Double(usableAIMemory) / 1_073_741_824 }

    var memoryDescription: String {
        String(format: "%.0f GB RAM · %.1f GB usable for AI",
               totalRAMGB.rounded(), usableAIMemoryGB)
    }
}

// MARK: - Model Recommendation

/// One suggested Ollama model, ready to hand to `/api/pull`.
struct ModelRecommendation: Codable, Identifiable, Equatable {
    /// Exact Ollama tag, e.g. `qwen3.5:4b`.
    let tag: String
    let displayName: String
    let intent: UserIntent
    let approxDownloadGB: Double
    let minMemoryGB: Double
    let blurb: String
    /// True when this is the headline pick for the user's stated intent.
    var isPrimary: Bool = false

    var id: String { tag }

    func fits(_ profile: SystemProfile) -> Bool {
        profile.usableAIMemoryGB >= minMemoryGB
    }
}

// MARK: - Engine Lifecycle

enum OllamaState: Equatable {
    case idle
    case launching
    case running(attachedToExisting: Bool)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - Errors

enum NativAIError: LocalizedError {
    case ollamaBinaryMissing
    case ollamaLaunchFailed(String)
    case ollamaUnreachable(TimeInterval)
    case metalDeviceUnavailable

    var errorDescription: String? {
        switch self {
        case .ollamaBinaryMissing:
            "The bundled AI engine is missing from this copy of NativAI. Please reinstall."
        case .ollamaLaunchFailed(let why):
            "The AI engine could not start: \(why)"
        case .ollamaUnreachable(let seconds):
            "The AI engine did not respond within \(Int(seconds)) seconds."
        case .metalDeviceUnavailable:
            "No Metal-capable GPU was found; falling back to system RAM for sizing."
        }
    }
}
