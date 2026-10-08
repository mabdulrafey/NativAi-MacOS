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

    // MARK: - Clean Text Extraction

    /// Sanitizes raw document text by stripping control characters and normalizing whitespace.
    static func cleanText(_ text: String) -> String {
        var sanitized = text.replacingOccurrences(of: "\r\n", with: "\n")
        sanitized = sanitized.replacingOccurrences(of: "\r", with: "\n")
        sanitized = sanitized.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        }.map(String.init).joined()

        while sanitized.contains("\n\n\n") {
            sanitized = sanitized.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sentence-Aware Chunking

    /// Splits a large document text into sentence-boundary aligned overlapping chunks of ~300 words.
    static func splitIntoChunks(text: String, fileName: String, chunkSizeWords: Int = 300, overlapWords: Int = 50) -> [Chunk] {
        let cleaned = cleanText(text)
        guard !cleaned.isEmpty else { return [] }

        let sentences = extractSentences(cleaned)
        guard !sentences.isEmpty else { return [] }

        var chunks: [Chunk] = []
        var currentSentences: [String] = []
        var currentWordCount = 0
        var chunkIndex = 0

        for sentence in sentences {
            let sentenceWords = sentence.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            if sentenceWords.isEmpty { continue }

            if currentWordCount + sentenceWords.count > chunkSizeWords, !currentSentences.isEmpty {
                let chunkText = currentSentences.joined(separator: " ")
                chunks.append(Chunk(sourceFileName: fileName, chunkIndex: chunkIndex, text: chunkText))
                chunkIndex += 1

                var overlapSentences: [String] = []
                var overlapCount = 0
                for prevSentence in currentSentences.reversed() {
                    let count = prevSentence.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
                    if overlapCount + count <= overlapWords {
                        overlapSentences.insert(prevSentence, at: 0)
                        overlapCount += count
                    } else {
                        break
                    }
                }
                currentSentences = overlapSentences
                currentWordCount = overlapCount
            }

            currentSentences.append(sentence)
            currentWordCount += sentenceWords.count
        }

        if !currentSentences.isEmpty {
            let chunkText = currentSentences.joined(separator: " ")
            if !chunkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(Chunk(sourceFileName: fileName, chunkIndex: chunkIndex, text: chunkText))
            }
        }

        return chunks
    }

    private static func extractSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        let rawParagraphs = text.components(separatedBy: "\n\n")

        for paragraph in rawParagraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let pattern = #"(?<=[.!?])\s+"#
            let parts = (try? NSRegularExpression(pattern: pattern))?.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))

            if let matches = parts, !matches.isEmpty {
                var lastIndex = trimmed.startIndex
                for match in matches {
                    if let range = Range(match.range, in: trimmed) {
                        let sentence = String(trimmed[lastIndex..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !sentence.isEmpty {
                            sentences.append(sentence)
                        }
                        lastIndex = range.upperBound
                    }
                }
                let remainder = String(trimmed[lastIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !remainder.isEmpty {
                    sentences.append(remainder)
                }
            } else {
                sentences.append(trimmed)
            }
        }
        return sentences.isEmpty ? [text] : sentences
    }

    // MARK: - Contextual Query Expansion

    /// Combines follow-up prompts with conversation history so search queries find exact facts/stats.
    static func buildContextualQuery(prompt: String, history: [(role: String, content: String)]) -> String {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorUserTurns = history
            .filter { $0.role == "user" }
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let lastUserTurn = priorUserTurns.last, lastUserTurn != trimmedPrompt else {
            return trimmedPrompt
        }

        let contextPrefix = lastUserTurn.count > 120 ? String(lastUserTurn.prefix(120)) : lastUserTurn
        return "\(contextPrefix) | \(trimmedPrompt)"
    }

    // MARK: - Vector Indexing & Retrieval

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
        limit: Int = 4,
        minSimilarity: Double = 0.30
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

    // MARK: - High-Density Prompt Grounding

    /// Formats top search results into prompt context with authoritative system grounding instructions.
    static func formatContextExcerpts(_ results: [SearchResult]) -> String {
        guard !results.isEmpty else { return "" }
        var output = "\n\nAUTHORITATIVE KNOWLEDGE GROUNDING DIRECTIVE:\n"
        output += "Speak with senior expert authority using the EXACT facts and technical details provided in the document excerpts below. "
        output += "Synthesize the information directly to answer the user's query with maximum precision and completeness. "
        output += "Cite specific file names and numerical data where applicable.\n\n"
        output += "--- [Relevant Document Excerpts] ---\n"
        for (idx, result) in results.enumerated() {
            let score = String(format: "%.1f%% relevance", result.similarity * 100)
            output += "Excerpt \(idx + 1) [Source: \(result.chunk.sourceFileName) | Chunk \(result.chunk.chunkIndex + 1) | \(score)]:\n"
            output += "\"\"\"\n\(result.chunk.text.trimmingCharacters(in: .whitespacesAndNewlines))\n\"\"\"\n\n"
        }
        output += "--- [End of Relevant Document Excerpts] ---\n"
        return output
    }

    /// Indexes and queries a local project workspace folder completely offline.
    static func queryWorkspace(prompt: String, workspaceURL: URL) async -> String {
        let fileManager = FileManager.default
        let allowedExtensions = ["swift", "py", "js", "ts", "json", "md", "cpp", "h", "c", "java", "kt", "go", "rs", "txt", "sh", "yml", "yaml"]

        var fileList: [String] = []
        var fullFileContext = ""
        var fileCount = 0

        if let enumerator = fileManager.enumerator(at: workspaceURL, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                let path = fileURL.path
                if path.contains("/.git/") || path.contains("/.build/") || path.contains("/node_modules/") {
                    continue
                }

                let ext = fileURL.pathExtension.lowercased()
                if allowedExtensions.contains(ext) {
                    let relativePath = fileURL.path.replacingOccurrences(of: workspaceURL.path + "/", with: "")
                    fileList.append(relativePath)
                    fileCount += 1

                    if fileCount <= 15, let content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty {
                        let truncatedContent = content.count > 3000 ? String(content.prefix(3000)) + "\n... (truncated)" : content
                        fullFileContext += "\n--- File: \(relativePath) ---\n\(truncatedContent)\n"
                    }
                }
            }
        }

        guard !fileList.isEmpty else { return "" }

        var context = "AUTHORITATIVE KNOWLEDGE GROUNDING DIRECTIVE: You have been granted full access to local workspace '\(workspaceURL.lastPathComponent)'. Speak with senior expert authority using the exact code and files below:\n\n"
        context += "📁 Workspace Directory: \(workspaceURL.lastPathComponent)\n"
        context += "Files in workspace (\(fileList.count)):\n"
        for file in fileList {
            context += "• \(file)\n"
        }
        context += "\n--- [Workspace Source Code & Documents] ---\n"
        context += fullFileContext
        context += "\n--- [End of Workspace Context] ---\n"

        return context
    }
}
