import XCTest

/// Covers the history-fitting logic that decides what a model actually sees.
///
/// This is worth pinning down because its failure mode is invisible: before
/// `num_ctx` was set explicitly, Ollama silently clamped the window to ~4096 and
/// discarded the oldest turns with no error at all. Measured on the development
/// machine, a prompt of ~7,247 tokens was truncated to 4,091 and the model
/// answered confidently from the remaining fragment. A regression here would
/// look like the model "forgetting" rather than like a bug.
final class TokenBudgetTests: XCTestCase {

    private func message(_ role: String, _ content: String) -> OllamaManager.ChatMessage {
        Fixture.message(role, content)
    }

    func testShortConversationIsNotTruncated() {
        let messages = [
            message("system", "You are helpful."),
            message("user", "hi"),
            message("assistant", "hello"),
            message("user", "bye")
        ]
        let result = TokenBudget.fit(messages: messages, contextLength: 32768)

        XCTAssertFalse(result.didTruncate)
        XCTAssertEqual(result.messages.count, 4)
        XCTAssertEqual(
            result.messages.map(\.content),
            ["You are helpful.", "hi", "hello", "bye"],
            "Chronological order must survive: models are highly sensitive to turn order, "
                + "and a reversed history produces confidently wrong answers."
        )
    }

    func testLongConversationDropsOldestAndKeepsNewest() {
        var messages = [message("system", "SYS")]
        messages += Fixture.run(from: 0, to: 200, padding: 200)

        let result = TokenBudget.fit(messages: messages, contextLength: 4096)

        XCTAssertTrue(result.didTruncate)
        XCTAssertEqual(result.messages.first?.content, "SYS", "System prompt must be reserved.")
        XCTAssertEqual(Fixture.label(result.messages.last!), 199, "Newest turn must survive.")
        XCTAssertLessThanOrEqual(
            result.estimatedTokens,
            TokenBudget.inputAllowance(contextLength: 4096)
        )

        let labels = result.messages.dropFirst().map(Fixture.label)
        XCTAssertEqual(labels, labels.sorted(), "Kept turns must stay in chronological order.")
        XCTAssertEqual(result.droppedCount, 200 - labels.count)
    }

    func testLargerWindowRetainsMoreHistory() {
        let messages = Fixture.run(from: 0, to: 200, padding: 200)
        let small = TokenBudget.fit(messages: messages, contextLength: 4096).messages.count
        let large = TokenBudget.fit(messages: messages, contextLength: 32768).messages.count

        // The concrete win from reading the real context length off the server:
        // qwen2.5:1.5b reports 32768 but was being run at roughly an eighth of it.
        XCTAssertGreaterThan(large, small)
    }

    func testOversizedNewestMessageIsStillIncluded() {
        let huge = String(repeating: "y", count: 500_000)
        let result = TokenBudget.fit(
            messages: [message("system", "SYS"), message("user", huge)],
            contextLength: 4096
        )

        // Truncating the current question would mean answering something the user
        // never asked. Letting the server clip the tail at least keeps the
        // request intact, and it's a failure the user can see and react to.
        XCTAssertTrue(result.messages.contains { $0.content.count == 500_000 })
    }

    func testImagePayloadsAreNotChargedAgainstTextBudget() {
        let imageMessage = OllamaManager.ChatMessage(
            role: "user",
            content: "what is this?",
            images: [String(repeating: "A", count: 400_000)]
        )

        // Vision models bill images through a separate projector with a fixed
        // cost, not as characters in the text stream. Counting the base64 string
        // would evict the entire conversation on every image message.
        XCTAssertLessThan(TokenBudget.estimate(imageMessage), 20)
    }

    func testAllLeadingSystemMessagesArePreserved() {
        let result = TokenBudget.fit(
            messages: [message("system", "A"), message("system", "B"), message("user", "q")],
            contextLength: 8192
        )
        XCTAssertEqual(result.messages.prefix(2).map(\.content), ["A", "B"])
    }

    func testEmptyInputIsSafe() {
        XCTAssertTrue(TokenBudget.fit(messages: [], contextLength: 4096).messages.isEmpty)
    }

    func testOutputReserveIsHeldBack() {
        XCTAssertLessThan(TokenBudget.inputAllowance(contextLength: 4096), 4096)
    }

    func testHardwareAdaptiveContextLengthScaling() {
        let mac8GB = DeviceSpecs(totalRAMGB: 8.0, cpuCores: 8, isAppleSilicon: true, chipName: "Apple M1", gpuName: "Apple M1", vramGB: 8.0)
        let mac16GB = DeviceSpecs(totalRAMGB: 16.0, cpuCores: 10, isAppleSilicon: true, chipName: "Apple M1 Pro", gpuName: "Apple M1 Pro", vramGB: 16.0)
        let mac64GB = DeviceSpecs(totalRAMGB: 64.0, cpuCores: 12, isAppleSilicon: true, chipName: "Apple M2 Max", gpuName: "Apple M2 Max", vramGB: 64.0)

        // 7B model (size 4.7GB) on 8GB Mac must cap context to 4096 to prevent memory swapping
        XCTAssertEqual(mac8GB.effectiveContextLength(rawContextLength: 32768, modelSizeGB: 4.7), 4096)

        // 1.5B model (size 1.0GB) on 8GB Mac caps context to 8192
        XCTAssertEqual(mac8GB.effectiveContextLength(rawContextLength: 32768, modelSizeGB: 1.0), 8192)

        // 16GB Mac caps at 16384
        XCTAssertEqual(mac16GB.effectiveContextLength(rawContextLength: 32768, modelSizeGB: 4.7), 16384)

        // 64GB Mac retains full 32768 raw context
        XCTAssertEqual(mac64GB.effectiveContextLength(rawContextLength: 32768, modelSizeGB: 4.7), 32768)
    }
}
