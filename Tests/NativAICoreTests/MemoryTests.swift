import XCTest

/// Covers the retrieval maths and fact normalisation behind cross-session memory.
///
/// `MemoryStore` itself is `@MainActor` and writes to Application Support, so it's
/// exercised by hand; what's unit-tested here is the part where a subtle error
/// would be invisible rather than loud — a NaN similarity score sorts
/// unpredictably and makes recall look random instead of broken, and weak
/// normalisation lets near-duplicate facts accumulate until they crowd genuinely
/// distinct ones out of the small retrieval window.
final class MemoryTests: XCTestCase {

    // MARK: - Cosine similarity

    func testIdenticalVectorsScoreOne() {
        let vector = [0.1, 0.5, -0.3, 0.9]
        XCTAssertEqual(EmbeddingService.cosineSimilarity(vector, vector), 1.0, accuracy: 1e-9)
    }

    func testOrthogonalVectorsScoreZero() {
        XCTAssertEqual(EmbeddingService.cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 1e-9)
    }

    func testOppositeVectorsScoreMinusOne() {
        XCTAssertEqual(EmbeddingService.cosineSimilarity([1, 2], [-1, -2]), -1.0, accuracy: 1e-9)
    }

    func testMagnitudeDoesNotAffectSimilarity() {
        // Cosine measures direction only: an embedding scaled by 10 must rank
        // identically, or longer source text would score higher merely for length.
        let base = [0.3, 0.4, 0.5]
        let scaled = base.map { $0 * 10 }
        XCTAssertEqual(EmbeddingService.cosineSimilarity(base, scaled), 1.0, accuracy: 1e-9)
    }

    /// A zero vector would divide by zero and yield NaN, which sorts
    /// unpredictably — making retrieval appear random rather than failing loudly.
    func testZeroVectorScoresZeroRatherThanNaN() {
        let score = EmbeddingService.cosineSimilarity([0, 0, 0], [1, 2, 3])
        XCTAssertFalse(score.isNaN)
        XCTAssertEqual(score, 0.0)
    }

    func testMismatchedDimensionsScoreZero() {
        // Different embedding models produce different dimensionalities (768 vs
        // 1024). Comparing across them is meaningless, not an error to crash on.
        XCTAssertEqual(EmbeddingService.cosineSimilarity([1, 2, 3], [1, 2]), 0.0)
    }

    func testEmptyVectorsScoreZero() {
        XCTAssertEqual(EmbeddingService.cosineSimilarity([], []), 0.0)
    }

    /// Realistic check: the correct fact must outrank an unrelated one, and by
    /// enough to clear the injection threshold.
    func testRelatedVectorRanksAboveUnrelatedOne() {
        let query = [0.9, 0.1, 0.0]
        let related = [0.8, 0.2, 0.1]
        let unrelated = [-0.5, 0.3, 0.9]

        let relatedScore = EmbeddingService.cosineSimilarity(query, related)
        let unrelatedScore = EmbeddingService.cosineSimilarity(query, unrelated)

        XCTAssertGreaterThan(relatedScore, unrelatedScore)
        XCTAssertGreaterThan(relatedScore, MemoryStore.similarityThreshold)
        XCTAssertLessThan(unrelatedScore, MemoryStore.similarityThreshold)
    }

    // MARK: - Model resolution

    func testSmallestPreferredEmbeddingModelWins() async {
        // Retrieval over a few dozen short facts is easy, so the 0.22 GB model is
        // the right default even when a larger one is also installed.
        let resolved = await EmbeddingService.resolveModel(
            installedModelNames: ["mxbai-embed-large", "nomic-embed-text", "llama3:8b"]
        )
        XCTAssertEqual(resolved, "nomic-embed-text")
    }

    func testTaggedVariantOfPreferredModelIsRecognised() async {
        let resolved = await EmbeddingService.resolveModel(
            installedModelNames: ["nomic-embed-text:v1.5", "llama3:8b"]
        )
        XCTAssertEqual(resolved, "nomic-embed-text:v1.5")
    }

    /// A community embedding model absent from our catalog is still usable,
    /// because the server reports its capability.
    func testUncatalogedEmbeddingModelIsFoundByCapability() async {
        let resolved = await EmbeddingService.resolveModel(
            installedModelNames: ["llama3:8b", "some-community-embedder"]
        )
        XCTAssertEqual(resolved, "some-community-embedder")
    }

    func testNoEmbeddingModelResolvesToNil() async {
        let resolved = await EmbeddingService.resolveModel(
            installedModelNames: ["llama3:8b", "moondream:1.8b", "x/flux2-klein:4b"]
        )
        XCTAssertNil(resolved, "Retrieval must fall back to keywords, not fail.")
    }

    func testEmptyInstallListResolvesToNil() async {
        let resolved = await EmbeddingService.resolveModel(installedModelNames: [])
        XCTAssertNil(resolved)
    }

    // MARK: - Fact normalisation

    func testNormalisationIgnoresPunctuationAndCase() {
        let a = MemoryFact(text: "The user's budget is $12,000.", kind: .project)
        let b = MemoryFact(text: "the users budget is 12 000", kind: .project)
        XCTAssertEqual(a.normalized, b.normalized)
    }

    func testNormalisationCollapsesWhitespace() {
        let fact = MemoryFact(text: "The   user\nwrites   Swift.", kind: .preference)
        XCTAssertEqual(fact.normalized, "the user writes swift")
    }

    /// Restatements at different lengths must be detectable as duplicates.
    ///
    /// The store treats containment either way as a duplicate, so this checks the
    /// substring relationship that logic depends on actually holds for the kind of
    /// variation models produce.
    func testShorterRestatementIsContainedInLongerOne() {
        let short = MemoryFact(text: "Budget is 12000 dollars", kind: .project)
        let long = MemoryFact(text: "The user's budget is 12000 dollars.", kind: .project)
        XCTAssertTrue(long.normalized.contains(short.normalized))
    }

    func testDistinctFactsDoNotAppearAsDuplicates() {
        let budget = MemoryFact(text: "The user's budget is 12000 dollars.", kind: .project)
        let cofounder = MemoryFact(text: "The user's co-founder is Priya.", kind: .identity)
        XCTAssertFalse(budget.normalized.contains(cofounder.normalized))
        XCTAssertFalse(cofounder.normalized.contains(budget.normalized))
    }

    // MARK: - Extraction filtering

    /// Genuine facts must survive the precision filter.
    func testRealFactsAreAccepted() {
        let facts = [
            "The user's co-founder is Priya, who handles supply chain.",
            "The user is building a clothing brand called FashionFrenzy.",
            "The user's budget for the project is 12000 dollars.",
            "The user prefers code without long explanations.",
            "The user's favourite programming language is Swift.",
            "The user targets sustainable streetwear for ages 18 to 25."
        ]
        for fact in facts {
            XCTAssertNotNil(
                MemoryExtractor.sanitizeForTesting(fact),
                "Rejected a genuine fact: \(fact)"
            )
        }
    }

    /// The outputs a 1.5B model actually produced for trivial messages.
    ///
    /// Measured live, qwen2.5:1.5b extracted a "fact" from **every** trivial
    /// message despite explicit prompt instructions not to — precision was 0/5.
    /// These exact strings are what it returned, so this test is a regression
    /// guard on real observed behaviour rather than on imagined failures.
    func testObservedModelNoiseIsRejected() {
        let noise = [
            // World trivia, not a fact about the user.
            "The capital of France is Paris.",
            // Restated requests from "make the logo bigger", "thanks that works",
            // "can you summarize this document", "what colors are in it".
            "The user wants the logo to be made larger.",
            "The user is grateful for the solution.",
            "The user wants a summary of the document.",
            "The user wants to know what colors are in it."
        ]
        for item in noise {
            XCTAssertNil(
                MemoryExtractor.sanitizeForTesting(item),
                "Leaked model noise into memory: \(item)"
            )
        }
    }

    func testQuestionsAreRejected() {
        XCTAssertNil(MemoryExtractor.sanitizeForTesting("The user's budget is what exactly?"))
    }

    func testFragmentsTooShortAreRejected() {
        XCTAssertNil(MemoryExtractor.sanitizeForTesting("The user."))
    }

    func testOverlongOutputIsRejected() {
        XCTAssertNil(
            MemoryExtractor.sanitizeForTesting("The user " + String(repeating: "x", count: 300))
        )
    }

    func testTerminalPunctuationIsNormalised() {
        XCTAssertEqual(
            MemoryExtractor.sanitizeForTesting("The user writes Swift"),
            "The user writes Swift."
        )
    }

    // MARK: - Injection framing

    func testNoFactsProducesNoSystemMessage() {
        XCTAssertNil(MemoryStore.systemMessage(for: []))
    }

    func testSystemMessageInstructsAgainstVolunteeringFacts() throws {
        let facts = [
            MemoryFact(text: "The user's co-founder is Priya.", kind: .identity),
            MemoryFact(text: "The user prefers concise answers.", kind: .preference)
        ]
        let message = try XCTUnwrap(MemoryStore.systemMessage(for: facts))

        XCTAssertEqual(message.role, "system")
        XCTAssertTrue(message.content.contains("Priya"))
        XCTAssertTrue(message.content.contains("concise"))
        // Without this instruction, small models open unrelated replies with
        // "As I recall, your co-founder is Priya…", which reads as unsettling.
        XCTAssertTrue(message.content.lowercased().contains("do not mention"))
    }

    // MARK: - Codable

    func testFactRoundTripsIncludingEmbedding() throws {
        let fact = MemoryFact(
            text: "The user writes Swift.", kind: .preference,
            sourceSessionId: UUID(), embedding: [0.1, 0.2, 0.3]
        )
        let restored = try JSONDecoder().decode(
            MemoryFact.self, from: JSONEncoder().encode(fact)
        )
        XCTAssertEqual(restored.text, fact.text)
        XCTAssertEqual(restored.kind, fact.kind)
        XCTAssertEqual(restored.embedding, fact.embedding)
    }

    /// A store written before an embedding model was installed must still load,
    /// then be embeddable later.
    func testFactWithoutEmbeddingDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","text":"The user writes Swift.","kind":"preference","createdAt":760000000}
        """
        let fact = try JSONDecoder().decode(MemoryFact.self, from: Data(json.utf8))
        XCTAssertNil(fact.embedding)
        XCTAssertEqual(fact.kind, .preference)
    }
}
