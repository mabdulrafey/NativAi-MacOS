/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Specific task capability reported by the server or detected by probes.
public enum ModelCapability: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case image
    case vision
    case embedding
    case tools
    case thinking
    case insert
    case completion

    public var id: String { rawValue }

    public init?(serverString: String) {
        let lower = serverString.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = ModelCapability(rawValue: lower) {
            self = match
        } else {
            switch lower {
            case "chat", "generate", "text":
                self = .completion
            case "embed", "embeddings":
                self = .embedding
            case "tool_use", "function", "tool":
                self = .tools
            case "reasoning", "thought":
                self = .thinking
            default:
                return nil
            }
        }
    }

    public var displayName: String {
        switch self {
        case .image: return "Image Generation"
        case .vision: return "Vision"
        case .embedding: return "Embedding"
        case .tools: return "Tool Calling"
        case .thinking: return "Reasoning"
        case .insert: return "Insert"
        case .completion: return "Chat"
        }
    }
}

/// Capability and metadata descriptor for an installed model.
public struct ModelCapabilities: Codable, Equatable, Sendable {
    public static let fallbackContextLength: Int = 4096

    public let modelName: String
    public var capabilities: Set<ModelCapability>
    public let contextLength: Int
    public let family: String?
    public let parameterSize: String?

    public init(
        modelName: String,
        capabilities: Set<ModelCapability>,
        contextLength: Int = 4096,
        family: String? = nil,
        parameterSize: String? = nil
    ) {
        self.modelName = modelName
        self.capabilities = capabilities
        self.contextLength = contextLength
        self.family = family
        self.parameterSize = parameterSize
    }

    public var supportsVision: Bool {
        capabilities.contains(.vision)
    }

    public func supports(_ capability: ModelCapability) -> Bool {
        capabilities.contains(capability)
    }

    public static func unknown(modelName: String) -> ModelCapabilities {
        ModelCapabilities(
            modelName: modelName,
            capabilities: [.completion],
            contextLength: fallbackContextLength,
            family: nil,
            parameterSize: nil
        )
    }
}
