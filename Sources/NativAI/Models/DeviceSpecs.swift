/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Capability tier derived from usable memory, driving recommendation and context scaling.
public enum HardwareTier: String, Codable, CaseIterable, Comparable, Sendable {
    case essential = "Essential"
    case performance = "Performance"
    case workstation = "Workstation"

    public static func < (lhs: HardwareTier, rhs: HardwareTier) -> Bool {
        let order: [HardwareTier] = [.essential, .performance, .workstation]
        guard let lIndex = order.firstIndex(of: lhs),
              let rIndex = order.firstIndex(of: rhs) else { return false }
        return lIndex < rIndex
    }

    public var label: String { rawValue }
    public var displayName: String { rawValue }

    public var summary: String {
        switch self {
        case .essential:
            return "Fast, lightweight models tuned for 8–12 GB machines."
        case .performance:
            return "Mid-size models with strong reasoning headroom for 16–24 GB machines."
        case .workstation:
            return "Large frontier-class local models for 24+ GB machines."
        }
    }
}

/// Hardware profile snapshot of the host machine.
public struct DeviceSpecs: Codable, Equatable, Sendable {
    public let totalRAMGB: Double
    public let cpuCores: Int
    public let isAppleSilicon: Bool
    public let chipName: String
    public let gpuName: String
    public let vramGB: Double

    public init(
        totalRAMGB: Double,
        cpuCores: Int,
        isAppleSilicon: Bool,
        chipName: String,
        gpuName: String,
        vramGB: Double
    ) {
        self.totalRAMGB = totalRAMGB
        self.cpuCores = cpuCores
        self.isAppleSilicon = isAppleSilicon
        self.chipName = chipName
        self.gpuName = gpuName
        self.vramGB = vramGB
    }

    public static let unknown = DeviceSpecs(
        totalRAMGB: 0,
        cpuCores: 0,
        isAppleSilicon: false,
        chipName: "Unknown",
        gpuName: "Unknown",
        vramGB: 0
    )

    public var tier: HardwareTier {
        if totalRAMGB >= 24 {
            return .workstation
        } else if totalRAMGB >= 16 {
            return .performance
        } else {
            return .essential
        }
    }

    /// Dynamically scales context windows based on RAM and model size to prevent thrashing and swap.
    public func effectiveContextLength(rawContextLength: Int, modelSizeGB: Double) -> Int {
        if totalRAMGB <= 8.5 {
            if modelSizeGB > 2.0 {
                return min(rawContextLength, 4096)
            } else {
                return min(rawContextLength, 8192)
            }
        } else if totalRAMGB <= 16.5 {
            return min(rawContextLength, 16384)
        } else {
            return rawContextLength
        }
    }
}
