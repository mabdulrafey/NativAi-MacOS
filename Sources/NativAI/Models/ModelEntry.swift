/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// A single model entry in the curated catalog (loaded from catalog.json).
struct ModelEntry: Identifiable, Codable, Equatable {
    var id: String { name }

    let name: String                 // e.g. "qwen2.5-coder:7b"
    let displayName: String          // e.g. "Qwen 2.5 Coder (7B)"
    let category: [String]           // "coding", "research", "qa", "image_gen"
    let role: String                 // "chat", "coder", "image"
    let useCases: [String]           // "marketing", "coding", "research", "design", ...
    let description: String
    let sizeGB: Double
    let minRAMGB: Double
    let minVRAMGB: Double
    let license: String
    let commercialUse: Bool?
    let speedTier: String?           // "fast", "medium", "slow" (mainly for image models)
    /// True for vision-language models (llava, llama3.2-vision, etc.) that
    /// can actually receive image bytes via Ollama's chat API and describe
    /// what's in them. Defaults to false for any catalog entry that predates
    /// this field, so existing entries decode fine without needing a
    /// migration. This is distinct from role=="image", which means the model
    /// GENERATES images — supportsVision means it can READ/understand them.
    let supportsVision: Bool

    enum CodingKeys: String, CodingKey {
        case name, displayName = "display_name", category, role
        case useCases = "use_cases", description
        case sizeGB = "size_gb", minRAMGB = "min_ram_gb", minVRAMGB = "min_vram_gb"
        case license, commercialUse = "commercial_use", speedTier = "speed_tier"
        case supportsVision = "supports_vision"
    }

    init(name: String, displayName: String, category: [String], role: String, useCases: [String], description: String, sizeGB: Double, minRAMGB: Double, minVRAMGB: Double, license: String, commercialUse: Bool?, speedTier: String?, supportsVision: Bool = false) {
        self.name = name
        self.displayName = displayName
        self.category = category
        self.role = role
        self.useCases = useCases
        self.description = description
        self.sizeGB = sizeGB
        self.minRAMGB = minRAMGB
        self.minVRAMGB = minVRAMGB
        self.license = license
        self.commercialUse = commercialUse
        self.speedTier = speedTier
        self.supportsVision = supportsVision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decode(String.self, forKey: .displayName)
        category = try container.decode([String].self, forKey: .category)
        role = try container.decode(String.self, forKey: .role)
        useCases = try container.decode([String].self, forKey: .useCases)
        description = try container.decode(String.self, forKey: .description)
        sizeGB = try container.decode(Double.self, forKey: .sizeGB)
        minRAMGB = try container.decode(Double.self, forKey: .minRAMGB)
        minVRAMGB = try container.decode(Double.self, forKey: .minVRAMGB)
        license = try container.decode(String.self, forKey: .license)
        commercialUse = try container.decodeIfPresent(Bool.self, forKey: .commercialUse)
        speedTier = try container.decodeIfPresent(String.self, forKey: .speedTier)
        // Explicitly defaulted via decodeIfPresent ?? false — existing
        // catalog.json entries have no "supports_vision" key at all, and
        // without this fallback every one of them would fail to decode.
        supportsVision = try container.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? false
    }
}

/// Compatibility verdict for a model against a given device, per the tiering
/// rules we defined: fits comfortably / works but slower / not recommended.
enum CompatibilityLevel: String {
    case fits           // model fits within VRAM/RAM comfortably
    case slow           // spills over, will run but slower
    case unsupported     // exceeds both VRAM and RAM meaningfully

    var badge: String {
        switch self {
        case .fits: return "✅ Fits comfortably"
        case .slow: return "⚠️ Will run, but slower"
        case .unsupported: return "🚫 Not recommended"
        }
    }
}

extension ModelEntry {
    /// Determines whether this model is a good, workable, or poor fit for the given specs.
    func compatibility(for specs: DeviceSpecs) -> CompatibilityLevel {
        let totalRAM = specs.totalRAMGB

        // On constrained 8GB machines (e.g. M1 MacBook Air 8GB), macOS system overhead
        // leaves only ~4GB free. Models > 3.5GB (like 7B/8B models) force NVMe disk swapping
        // and run noticeably slower. They are marked "Will run, but slower" (.slow).
        if totalRAM <= 8.5 {
            if sizeGB <= 3.5 {
                return .fits
            } else if sizeGB <= 5.5 {
                return .slow
            } else {
                return .unsupported
            }
        }

        // On 16GB machines, models up to ~6.5GB fit comfortably without swapping.
        if totalRAM <= 16.5 {
            if sizeGB <= 6.5 {
                return .fits
            } else if sizeGB <= 12.0 || minRAMGB <= 16.0 {
                return .slow
            } else {
                return .unsupported
            }
        }

        // On >16GB machines (32GB+), models up to 14GB fit comfortably.
        if sizeGB <= 14.0 || specs.vramGB >= minVRAMGB {
            return .fits
        }
        if specs.totalRAMGB >= minRAMGB {
            return .slow
        }
        return .unsupported
    }
}

