/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Discovers what installed models can actually do, by asking the local
/// Ollama server instead of guessing from model names or trusting the static
/// catalog.
///
/// This is the structural fix for a bug class that has recurred repeatedly in
/// this project: `catalog.json` is a hand-maintained guess about 122 models,
/// and every time it drifts from reality something breaks (a missing tag alias
/// made Auto-routing pick the wrong size; `supportsVision` flags were set by
/// hand and can be wrong or missing). For an INSTALLED model there is no need
/// to guess — `POST /api/show` reports its capabilities and true context
/// length directly. The catalog remains the source of truth only for models
/// that aren't installed yet, where the server can't help.
///
/// All results are cached in memory: `/api/show` costs ~10-50ms and the answer
/// cannot change while a model stays installed, but routing may consult it
/// several times per turn.
actor CapabilityProbe {

    static let shared = CapabilityProbe()

    private let baseURL = URL(string: "http://127.0.0.1:11434")!
    private var cache: [String: ModelCapabilities] = [:]

    /// Short timeout: this runs on the interactive send path, and a stuck
    /// probe must degrade to catalog data rather than stall the user's message.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    private struct ShowResponse: Decodable {
        let capabilities: [String]?
        let model_info: [String: JSONValue]?
        let details: Details?

        struct Details: Decodable {
            let family: String?
            let parameter_size: String?
        }
    }

    /// `model_info` mixes strings, ints, and arrays under keys that vary by
    /// architecture (`llama.context_length`, `qwen2.context_length`, ...), so
    /// it can't decode into a homogeneous dictionary.
    private enum JSONValue: Decodable {
        case int(Int)
        case string(String)
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) { self = .int(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else { self = .other }
        }

        var intValue: Int? {
            switch self {
            case .int(let value): return value
            case .string(let value): return Int(value)
            case .other: return nil
            }
        }
    }

    /// Fetches capabilities for a model, using the cache when available.
    ///
    /// Never throws: on any failure it returns a conservative
    /// `.unknown` (completion-only, 4096 context) so callers always get a
    /// usable value. That means a server hiccup degrades routing quality
    /// slightly rather than failing the user's message outright.
    func capabilities(for modelName: String) async -> ModelCapabilities {
        if let cached = cache[modelName] { return cached }

        guard let resolved = await fetch(modelName: modelName) else {
            // Deliberately not cached — a failure here is usually transient
            // (server still starting up), and caching it would poison routing
            // for the rest of the app's lifetime.
            return .unknown(modelName: modelName)
        }
        cache[modelName] = resolved
        return resolved
    }

    private func fetch(modelName: String) async -> ModelCapabilities? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": modelName])

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ShowResponse.self, from: data)
        else { return nil }

        var capabilities = Set(
            (decoded.capabilities ?? []).compactMap(ModelCapability.init(serverString:))
        )

        // Enrich vision capability if the server didn't explicitly return it
        // but catalog metadata or model family/name confirms vision support.
        let lowerName = modelName.lowercased()
        let familyLower = (decoded.details?.family ?? "").lowercased()
        let hasVisionKey = decoded.model_info?.keys.contains(where: { $0.contains("projector") || $0.contains("vision") }) ?? false
        let catalogSupportsVision = CatalogService.shared.entry(named: modelName)?.supportsVision ?? false

        if catalogSupportsVision ||
           lowerName.contains("llava") || lowerName.contains("vision") || lowerName.contains("moondream") || lowerName.contains("bakllava") || lowerName.contains("qwen2-vl") || lowerName.contains("minicpm-v") ||
           familyLower.contains("llava") || familyLower.contains("mclip") || familyLower.contains("clip") ||
           hasVisionKey {
            capabilities.insert(.vision)
        }

        // Guarantee a baseline only when the server told us nothing at all.
        // Note this must NOT be applied to image-only models: Flux legitimately
        // reports ["image"] with no "completion", and forcing completion in
        // would make it look like a valid chat model.
        if capabilities.isEmpty { capabilities.insert(.completion) }

        let contextLength = decoded.model_info?
            .first { $0.key.hasSuffix(".context_length") }?
            .value.intValue ?? ModelCapabilities.fallbackContextLength

        return ModelCapabilities(
            modelName: modelName,
            capabilities: capabilities,
            contextLength: contextLength,
            family: decoded.details?.family,
            parameterSize: decoded.details?.parameter_size
        )
    }

    /// Context window for a model, for sizing history before a chat call.
    func contextLength(for modelName: String) async -> Int {
        await capabilities(for: modelName).contextLength
    }

    /// Warms the cache for several models at once, in parallel.
    /// Called after launch/model-list refresh so the first send doesn't pay
    /// probe latency.
    func prewarm(modelNames: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for name in modelNames where cache[name] == nil {
                group.addTask { _ = await self.capabilities(for: name) }
            }
        }
    }

    /// Drops a model's cached entry (call after delete, or after a re-pull
    /// that may have changed the underlying weights).
    func invalidate(modelName: String) {
        cache.removeValue(forKey: modelName)
    }

    func invalidateAll() {
        cache.removeAll()
    }
}
