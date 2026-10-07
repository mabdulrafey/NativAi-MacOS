/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Machine compatibility level for a model given the host hardware profile.
public enum CompatibilityLevel: String, Codable, Equatable, Sendable {
    case fits
    case slow
    case unsupported

    public var badge: String {
        switch self {
        case .fits: return "Fits comfortably"
        case .slow: return "Will run, but slower"
        case .unsupported: return "Not recommended"
        }
    }
}

/// A catalog entry describing an available or installed model.
public struct ModelEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let displayName: String
    public let category: [String]
    public let role: String
    public let useCases: [String]
    public let description: String
    public let sizeGB: Double
    public let minRAMGB: Double
    public let minVRAMGB: Double
    public let license: String
    public let commercialUse: Bool
    public let speedTier: String?
    public let supportsVision: Bool

    public var id: String { name }

    public init(
        name: String,
        displayName: String,
        category: [String] = [],
        role: String,
        useCases: [String] = [],
        description: String = "",
        sizeGB: Double,
        minRAMGB: Double,
        minVRAMGB: Double = 0,
        license: String = "Open Source",
        commercialUse: Bool = true,
        speedTier: String? = nil,
        supportsVision: Bool = false
    ) {
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

    public enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case category
        case role
        case useCases = "use_cases"
        case description
        case sizeGB = "size_gb"
        case minRAMGB = "min_ram_gb"
        case minVRAMGB = "min_vram_gb"
        case license
        case commercialUse = "commercial_use"
        case speedTier = "speed_tier"
        case supportsVision = "supports_vision"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? name
        category = try container.decodeIfPresent([String].self, forKey: .category) ?? []
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "chat"
        useCases = try container.decodeIfPresent([String].self, forKey: .useCases) ?? []
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        sizeGB = try container.decodeIfPresent(Double.self, forKey: .sizeGB) ?? 0.0
        minRAMGB = try container.decodeIfPresent(Double.self, forKey: .minRAMGB) ?? (sizeGB * 1.5)
        minVRAMGB = try container.decodeIfPresent(Double.self, forKey: .minVRAMGB) ?? 0.0
        license = try container.decodeIfPresent(String.self, forKey: .license) ?? "Open Source"
        commercialUse = try container.decodeIfPresent(Bool.self, forKey: .commercialUse) ?? true
        speedTier = try container.decodeIfPresent(String.self, forKey: .speedTier)
        supportsVision = try container.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? false
    }

    /// Estimated parameter count in billions, parsed from model name or display name.
    public var parameterCountBillions: Double? {
        let patterns = [
            #"(?i)(?:^|[:\(\s_e])(\d+(?:\.\d+)?)\s*b(?:\b|[\):\s]|$)"#,
            #"(?i)(\d+(?:\.\d+)?)\s*b\b"#
        ]
        for text in [displayName, name] {
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                   match.numberOfRanges > 1,
                   let range = Range(match.range(at: 1), in: text),
                   let value = Double(text[range]) {
                    return value
                }
            }
        }
        return nil
    }

    /// Evaluates if and how well this model fits on the current device.
    public func compatibility(for specs: DeviceSpecs) -> CompatibilityLevel {
        if specs.totalRAMGB <= 0 {
            return .fits
        }
        // Tiered guardrail for 8GB Macs (≤ 8.5 GB RAM):
        // 4B and below: "Fits comfortably" (.fits)
        // Anything above 4B up to 7B: "Will run, but slower" (.slow)
        // 8B and up: "Not recommended" (.unsupported, won't run)
        if specs.totalRAMGB <= 8.5 {
            if let params = parameterCountBillions {
                if params >= 8.0 {
                    return .unsupported
                } else if params > 4.0 {
                    return .slow
                } else {
                    return .fits
                }
            } else {
                if sizeGB >= 4.8 {
                    return .unsupported
                } else if sizeGB > 2.8 {
                    return .slow
                } else {
                    return .fits
                }
            }
        }
        if specs.totalRAMGB >= minRAMGB {
            return .fits
        } else if specs.totalRAMGB >= sizeGB {
            return .slow
        } else {
            return .unsupported
        }
    }
}
