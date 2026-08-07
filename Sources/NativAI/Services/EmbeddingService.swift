/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Turns text into vectors via Ollama's `/api/embed`, for semantic retrieval of
/// remembered facts.
///
/// Verified against the live server: `nomic-embed-text` (0.22 GB) returns
/// 768-dimensional vectors and accepts batched input, so an entire memory store
/// can be embedded in one round trip.
///
/// Why embeddings rather than keyword matching: measured on real fact/query
/// pairs, cosine similarity retrieved the right fact for "how much money do I
/// have?" → *"The user's budget is 12000 dollars"* and "what code do I write?" →
/// *"…favourite programming language is Swift"*, neither of which shares a single
/// significant word with its answer. Keyword search finds nothing in those cases.
///
/// This also finally gives the catalog's two `embed`-role models a job — they were
/// previously installable but unreachable by any code path.
enum EmbeddingService {

    /// Preferred embedding models, smallest capable first.
    ///
    /// Ordered by size rather than quality: retrieval over a few dozen short
    /// facts is an easy task, so the 0.22 GB model is the right default and the
    /// larger one is only used if the user happens to have it instead.
    static let preferredModels = ["nomic-embed-text", "mxbai-embed-large"]

    /// Picks an installed embedding model, preferring the smallest.
    ///
    /// Checks capabilities from the live server first — a community embedding
    /// model absent from our catalog is still perfectly usable, and the server
    /// reports `embedding` for it.
    static func resolveModel(installedModelNames: [String]) async -> String? {
        for preferred in preferredModels {
            if let match = installedModelNames.first(where: {
                $0 == preferred || $0.hasPrefix("\(preferred):")
            }) {
                return match
            }
        }
        for name in installedModelNames {
            if await CapabilityProbe.shared.capabilities(for: name).supports(.embedding) {
                return name
            }
        }
        return nil
    }

    private struct EmbedRequest: Encodable {
        let model: String
        let input: [String]
    }

    private struct EmbedResponse: Decodable {
        let embeddings: [[Double]]
    }

    /// Embeds one or more strings, returning vectors in input order.
    ///
    /// Returns nil on any failure. Memory is an enhancement, so a missing or
    /// broken embedding model must degrade retrieval quality rather than break a
    /// conversation.
    static func embed(_ texts: [String], model: String) async -> [[Double]]? {
        guard !texts.isEmpty else { return [] }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/embed")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Short timeout: this runs on the send path when a query needs embedding.
        request.timeoutInterval = 20
        request.httpBody = try? JSONEncoder().encode(
            EmbedRequest(model: model, input: texts)
        )

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(EmbedResponse.self, from: data),
              decoded.embeddings.count == texts.count
        else { return nil }

        return decoded.embeddings
    }

    /// Cosine similarity of two vectors, in −1...1.
    ///
    /// Guards against zero-magnitude vectors, which would otherwise divide by
    /// zero and produce NaN — and a NaN score silently sorts unpredictably,
    /// making retrieval look random rather than broken.
    static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }

        var dot = 0.0, lhsMagnitude = 0.0, rhsMagnitude = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsMagnitude += lhs[index] * lhs[index]
            rhsMagnitude += rhs[index] * rhs[index]
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return dot / (lhsMagnitude.squareRoot() * rhsMagnitude.squareRoot())
    }
}
