import XCTest

final class DocumentRAGServiceTests: XCTestCase {

    func testChunkingSplitsLargeTextWithOverlap() {
        let sampleText = (1...1000).map { "word\($0)" }.joined(separator: " ")
        let chunks = DocumentRAGService.splitIntoChunks(text: sampleText, fileName: "test_doc.txt", chunkSizeWords: 300, overlapWords: 50)

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertEqual(chunks.first?.sourceFileName, "test_doc.txt")
        XCTAssertEqual(chunks.first?.chunkIndex, 0)
    }

    func testFormatContextExcerptsProducesFormattedOutput() {
        let chunk1 = DocumentRAGService.Chunk(sourceFileName: "doc.txt", chunkIndex: 0, text: "Swift is a programming language.")
        let chunk2 = DocumentRAGService.Chunk(sourceFileName: "doc.txt", chunkIndex: 1, text: "Ollama runs models locally.")

        let results = [
            DocumentRAGService.SearchResult(chunk: chunk1, similarity: 0.85),
            DocumentRAGService.SearchResult(chunk: chunk2, similarity: 0.72)
        ]

        let formatted = DocumentRAGService.formatContextExcerpts(results)
        XCTAssertTrue(formatted.contains("Relevant Document Excerpts"))
        XCTAssertTrue(formatted.contains("doc.txt"))
        XCTAssertTrue(formatted.contains("Swift is a programming language"))
    }
}
