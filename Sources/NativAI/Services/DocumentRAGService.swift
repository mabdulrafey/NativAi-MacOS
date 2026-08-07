/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Handles offline document Q&A and semantic search over attached text files, PDFs,
/// and code files using local vector embeddings (via EmbeddingService).
enum DocumentRAGService {

    /// A single text chunk extracted from an attached document.
    struct Chunk: Identifiable, Codable, Equatable {
        let id: UUID
        let sourceFileName: String
        let chunkIndex: Int
        let text: String
        var vector: [Double]?

        init(id: UUID = UUID(), sourceFileName: String, chunkIndex: Int, text: String, vector: [Double]? = nil) {
            self.id = id
            self.sourceFileName = sourceFileName
            self.chunkIndex = chunkIndex
            self.text = text
            self.vector = vector
        }
    }

    /// Result of semantic document retrieval.
    struct SearchResult: Equatable {
        let chunk: Chunk
        let similarity: Double
    }

    /// Splits a large document text into overlapping chunks of ~300 words.
    static func splitIntoChunks(text: String, fileName: String, chunkSizeWords: Int = 300, overlapWords: Int = 50) -> [Chunk] {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }

        var chunks: [Chunk] = []
        var startIndex = 0
        var chunkIndex = 0

        while startIndex < words.count {
            let endIndex = min(startIndex + chunkSizeWords, words.count)
            let chunkText = words[startIndex..<endIndex].joined(separator: " ")
            if !chunkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(Chunk(sourceFileName: fileName, chunkIndex: chunkIndex, text: chunkText))
                chunkIndex += 1
            }
            if endIndex >= words.count { break }
            startIndex += (chunkSizeWords - overlapWords)
        }

        return chunks
    }

    /// Generates vector embeddings for document chunks using an installed embedding model.
    static func indexChunks(_ chunks: [Chunk], embeddingModel: String) async -> [Chunk] {
        let texts = chunks.map(\.text)
        guard let vectors = await EmbeddingService.embed(texts, model: embeddingModel),
              vectors.count == chunks.count else {
            return chunks
        }

        var indexed: [Chunk] = []
        for (index, chunk) in chunks.enumerated() {
            var updated = chunk
            updated.vector = vectors[index]
            indexed.append(updated)
        }
        return indexed
    }

    /// Retrieves the top matching chunks for a user query using cosine similarity.
    static func retrieveTopChunks(
        query: String,
        chunks: [Chunk],
        embeddingModel: String,
        limit: Int = 3,
        minSimilarity: Double = 0.35
    ) async -> [SearchResult] {
        guard !chunks.isEmpty else { return [] }
        guard let queryVectors = await EmbeddingService.embed([query], model: embeddingModel),
              let queryVector = queryVectors.first else {
            return []
        }

        var results: [SearchResult] = []
        for chunk in chunks {
            guard let vector = chunk.vector else { continue }
            let sim = EmbeddingService.cosineSimilarity(queryVector, vector)
            if sim >= minSimilarity {
                results.append(SearchResult(chunk: chunk, similarity: sim))
            }
        }

        return Array(results.sorted(by: { $0.similarity > $1.similarity }).prefix(limit))
    }

    /// Formats top search results into prompt context for chat completion.
    static func formatContextExcerpts(_ results: [SearchResult]) -> String {
        guard !results.isEmpty else { return "" }
        var output = "\n\n--- [Relevant Document Excerpts] ---\n"
        for (idx, result) in results.enumerated() {
            output += "Excerpt \(idx + 1) (File: \(result.chunk.sourceFileName)):\n\"\(result.chunk.text)\"\n\n"
        }
        output += "--- [End of Excerpts] ---\n"
        return output
    }
}
