import XCTest

/// Covers the compaction *planner*, which decides which turns get folded into
/// the running digest.
///
/// Only planning is unit-tested: `fold` calls a live model, so its output is a
/// property of the model rather than of this code and is verified by hand against
/// the server. Planning, by contrast, is exact arithmetic — and an off-by-one
/// here would either re-summarize material (degrading it each pass) or skip turns
/// entirely (losing them silently). Those are the failures worth locking down.
final class ConversationDigestTests: XCTestCase {

    func testShortConversationIsNotCompacted() {
        // Compaction would be strictly worse here: the turns all still fit, so a
        // summary would replace real text with a lossier version of it.
        XCTAssertNil(
            ConversationDigest.plan(
                history: Fixture.run(from: 0, to: 10, padding: 50),
                alreadyDigestedThrough: 0,
                contextLength: 8192
            )
        )
    }

    func testLongConversationIsCompactedOldestFirst() throws {
        let history = Fixture.run(from: 0, to: 80)
        let plan = try XCTUnwrap(
            ConversationDigest.plan(history: history, alreadyDigestedThrough: 0, contextLength: 8192)
        )

        XCTAssertEqual(Fixture.label(plan.messages.first!), 0, "Oldest material is digested first.")
        XCTAssertEqual(
            history.count - plan.newDigestedThroughIndex,
            ConversationDigest.verbatimTailCount,
            "Recent turns carry the conversational thread and must stay verbatim."
        )
        XCTAssertLessThan(Fixture.label(plan.messages.last!), 79)
        XCTAssertEqual(plan.newDigestedThroughIndex, plan.messages.count)
    }

    /// Compaction must be append-only.
    ///
    /// Summarizing a summary degrades badly — each pass drops detail, and after a
    /// few rounds the digest becomes vague and confidently wrong. This is the
    /// property that prevents it.
    func testCompactionIsMonotonicAndNeverOverlaps() throws {
        let history = Fixture.run(from: 0, to: 80)
        let first = try XCTUnwrap(
            ConversationDigest.plan(history: history, alreadyDigestedThrough: 0, contextLength: 8192)
        )

        XCTAssertNil(
            ConversationDigest.plan(
                history: history,
                alreadyDigestedThrough: first.newDigestedThroughIndex,
                contextLength: 8192
            ),
            "Nothing new to digest means no model call."
        )

        let grown = history + Fixture.run(from: 80, to: 120)
        let second = try XCTUnwrap(
            ConversationDigest.plan(
                history: grown,
                alreadyDigestedThrough: first.newDigestedThroughIndex,
                contextLength: 8192
            )
        )

        let firstLabels = Set(first.messages.map(Fixture.label))
        let secondLabels = Set(second.messages.map(Fixture.label))
        XCTAssertTrue(firstLabels.intersection(secondLabels).isEmpty, "No turn is digested twice.")
        XCTAssertEqual(
            Fixture.label(second.messages.first!),
            Fixture.label(first.messages.last!) + 1,
            "The second pass resumes exactly where the first stopped."
        )
        XCTAssertGreaterThan(second.newDigestedThroughIndex, first.newDigestedThroughIndex)
    }

    func testEmptyHistoryIsNotCompacted() {
        XCTAssertNil(
            ConversationDigest.plan(history: [], alreadyDigestedThrough: 0, contextLength: 8192)
        )
    }

    func testFullyDigestedHistoryIsNotRecompacted() {
        let history = Fixture.run(from: 0, to: 80)
        XCTAssertNil(
            ConversationDigest.plan(
                history: history,
                alreadyDigestedThrough: history.count,
                contextLength: 8192
            )
        )
    }

    /// A stored index beyond the message count (hand-edited file, or messages
    /// deleted after digesting) must not slice out of bounds.
    func testOutOfRangeIndexIsHandledSafely() {
        let history = Fixture.run(from: 0, to: 80)
        XCTAssertNil(
            ConversationDigest.plan(
                history: history,
                alreadyDigestedThrough: history.count + 50,
                contextLength: 8192
            )
        )
    }

    func testConversationOfOnlyTailLengthIsNotCompacted() {
        XCTAssertNil(
            ConversationDigest.plan(
                history: Fixture.run(from: 0, to: 8, padding: 4000),
                alreadyDigestedThrough: 0,
                contextLength: 8192
            )
        )
    }

    func testLargerContextWindowDefersCompaction() {
        let history = Fixture.run(from: 0, to: 80)
        XCTAssertNotNil(
            ConversationDigest.plan(history: history, alreadyDigestedThrough: 0, contextLength: 8192)
        )
        XCTAssertNil(
            ConversationDigest.plan(history: history, alreadyDigestedThrough: 0, contextLength: 131_072),
            "A model with room to spare shouldn't pay for summarization."
        )
    }

    // MARK: - Injection

    func testEmptyDigestProducesNoSystemMessage() {
        XCTAssertNil(ConversationDigest.systemMessage(for: ""))
        XCTAssertNil(ConversationDigest.systemMessage(for: "   \n "))
    }

    func testSystemMessageIsFramedAsBackgroundNotes() throws {
        let message = try XCTUnwrap(
            ConversationDigest.systemMessage(for: "User builds FashionFrenzy.")
        )
        XCTAssertEqual(message.role, "system")
        XCTAssertTrue(message.content.contains("FashionFrenzy"))
        XCTAssertTrue(
            message.content.lowercased().contains("earlier"),
            "Framed as background the model may draw on, not as a task to perform."
        )
    }

    /// The property that makes the whole feature work.
    ///
    /// The digest is only useful if it survives the truncation that made it
    /// necessary. `TokenBudget` reserves leading system messages up front, so the
    /// digest is never the thing evicted.
    func testDigestSurvivesTruncationOfALongConversation() throws {
        let digest = try XCTUnwrap(
            ConversationDigest.systemMessage(for: "User builds a brand called FashionFrenzy.")
        )
        let fitted = TokenBudget.fit(
            messages: [digest] + Fixture.run(from: 0, to: 120),
            contextLength: 8192
        )

        XCTAssertTrue(fitted.didTruncate)
        XCTAssertEqual(
            fitted.messages.first?.content.contains("FashionFrenzy"), true,
            "A digest that gets evicted by the truncation it exists to mitigate would be useless."
        )
    }
}
