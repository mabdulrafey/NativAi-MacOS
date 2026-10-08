/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// A capability a model can satisfy, as reported by the local Ollama server.
///
/// Deliberately mirrors Ollama's own `capabilities` strings from
/// `POST /api/show` (verified live against 0.32.5, which returns e.g.
/// `["completion"]` for llama3:8b and `["completion","tools"]` for
/// qwen2.5:1.5b). Using the server's vocabulary rather than inventing our own
/// means capability discovery needs no hardcoded model-name lists — the whole
/// point of routing on capabilities instead of names.
///
/// Verified live against Ollama 0.32.5: `x/flux2-klein:4b` reports
/// `["image"]`, `moondream:1.8b` reports `["completion","vision"]`, and
/// `llama3:8b` reports `["completion"]`. Image generation *is* reported by the
/// server after all, so no capability here needs to be inferred from the
/// catalog — which is what makes "don't hardcode model names" achievable.
enum ModelCapability: String, Codable, Hashable, CaseIterable, Sendable {
    case completion
    case vision
    case tools
    case embedding
    case thinking
    case insert
    /// Text-to-image generation. Reported by the server as "image".
    case image

    /// Maps an unrecognized server string to nil rather than throwing, so a
    /// future Ollama release adding a new capability can't break decoding.
    nonisolated init?(serverString: String) {
        guard let match = ModelCapability(rawValue: serverString) else { return nil }
        self = match
    }
}

/// Everything we know about an installed model's actual runtime abilities,
/// resolved from the live server rather than guessed from its name.
nonisolated struct ModelCapabilities: Codable, Equatable, Sendable {
    let modelName: String
    let capabilities: Set<ModelCapability>
    /// The model's true maximum context window in tokens, read from
    /// `model_info["<arch>.context_length"]`.
    let contextLength: Int
    let family: String?
    /// Parameter count string as reported by Ollama (e.g. "8.0B"), useful as a
    /// quality tie-breaker when ranking candidates.
    let parameterSize: String?

    func supports(_ capability: ModelCapability) -> Bool {
        capabilities.contains(capability)
    }

    var supportsVision: Bool { supports(.vision) }
    var supportsImageGeneration: Bool { supports(.image) }
    /// Can hold a normal text conversation. Image-only models cannot — Flux
    /// reports `["image"]` with no `completion`, so sending chat turns to it
    /// would fail or return nonsense.
    var supportsChat: Bool { supports(.completion) }

    /// Conservative default for when a probe fails entirely. 4096 matches
    /// Ollama's own fallback behaviour, so this degrades to today's status quo
    /// rather than to something broken.
    static let fallbackContextLength = 4096

    static func unknown(modelName: String) -> ModelCapabilities {
        let lower = modelName.lowercased()
        let isVision = lower.contains("llava") || lower.contains("vision") || lower.contains("moondream") || lower.contains("bakllava") || lower.contains("qwen2-vl") || lower.contains("minicpm-v")
        let caps: Set<ModelCapability> = isVision ? [.completion, .vision] : [.completion]
        return ModelCapabilities(
            modelName: modelName,
            capabilities: caps,
            contextLength: fallbackContextLength,
            family: nil,
            parameterSize: nil
        )
    }
}

