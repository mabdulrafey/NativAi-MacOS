/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Snapshot of the host machine's relevant hardware capabilities.
struct DeviceSpecs: Equatable {
    let totalRAMGB: Double
    let cpuCores: Int
    let isAppleSilicon: Bool
    let chipName: String          // e.g. "Apple M2 Pro" or "Intel Core i7"
    let gpuName: String
    /// On Apple Silicon this equals totalRAMGB (unified memory).
    /// On Intel Macs with discrete GPU, this would be dedicated VRAM if detectable, else 0.
    let vramGB: Double

    /// Coarse capability tier used to gate model recommendations.
    enum Tier: String, CaseIterable {
        case constrained   // <= 8GB unified/RAM
        case standard       // 9-16GB
        case capable        // 17-32GB
        case highEnd        // > 32GB

        var label: String {
            switch self {
            case .constrained: return "Constrained"
            case .standard: return "Standard"
            case .capable: return "Capable"
            case .highEnd: return "High-End"
            }
        }
    }

    var tier: Tier {
        switch totalRAMGB {
        case ..<9: return .constrained
        case 9..<17: return .standard
        case 17..<33: return .capable
        default: return .highEnd
        }
    }

    /// Calculates the optimal context length for a model on this hardware.
    ///
    /// On constrained RAM machines (e.g. MacBook Air M1 8GB), running 32K context
    /// for a 7B model allocates ~1.5-2GB KV-cache in unified memory, forcing NVMe
    /// disk swapping. Dynamically capping the context window to 4,096 or 8,192 tokens
    /// on 8GB machines keeps response generation instant and buttery smooth.
    func optimalContextLength(forModelSizeGB sizeGB: Double, baseContext: Int) -> Int {
        if isAppleSilicon && totalRAMGB <= 8.5 {
            if sizeGB >= 3.5 {
                return min(baseContext, 4096)
            } else {
                return min(baseContext, 8192)
            }
        } else if totalRAMGB <= 16.5 {
            return min(baseContext, 16384)
        }
        return baseContext
    }

    /// Compatibility alias matching both naming conventions:
    func effectiveContextLength(rawContextLength: Int, modelSizeGB: Double) -> Int {
        optimalContextLength(forModelSizeGB: modelSizeGB, baseContext: rawContextLength)
    }

    static let unknown = DeviceSpecs(
        totalRAMGB: 0, cpuCores: 0, isAppleSilicon: false,
        chipName: "Unknown", gpuName: "Unknown", vramGB: 0
    )
}

