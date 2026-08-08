import XCTest

/// Covers the deterministic routing fast path.
///
/// Every case here is a prompt that both installed router models classified
/// *wrongly* when measured against the live server, taken from a real bug report:
/// a chat where the user generated a logo and then asked about it.
///
///   "Do you think its a good logo for my company?"
///       qwen2.5:1.5b -> intent=coding      llama3:8b -> intent=image
///   "What was my initial selection for the brand name?"
///       llama3:8b    -> intent=image
///
/// qwen scored 1/4 and llama 2/4. The user-visible consequence of `intent=image`
/// on an opinion question is severe: the app generates a *second* picture instead
/// of answering, and the conversation degrades from there.
///
/// These prompt shapes aren't genuinely ambiguous, so they're resolved in Swift.
/// The final group asserts the fast path stays *out* of the way for prompts that
/// really do need a model's judgement — a fast path that over-fires would be a
/// regression to the keyword-matching era this project deliberately moved away
/// from.
final class RoutingFastPathTests: XCTestCase {

    private func classify(
        _ prompt: String,
        hasPriorImage: Bool = true
    ) -> (intent: RouterIntent, needsVision: Bool)? {
        SemanticRouter.fastPathClassification(prompt: prompt, hasPriorImage: hasPriorImage)
    }

    private func assertClassified(
        _ prompt: String,
        intent expectedIntent: RouterIntent,
        needsVision expectedVision: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let result = classify(prompt) else {
            return XCTFail("Fast path did not fire for: \(prompt)", file: file, line: line)
        }
        XCTAssertEqual(result.intent, expectedIntent, "intent for: \(prompt)", file: file, line: line)
        XCTAssertEqual(result.needsVision, expectedVision, "needsVision for: \(prompt)", file: file, line: line)
    }

    // MARK: - Opinion about an existing image

    /// The headline bug: this produced a second logo instead of an answer.
    func testOpinionQuestionsAreAnsweredNotRegenerated() {
        assertClassified("Do you think its a good logo for my company?", intent: .general, needsVision: true)
        assertClassified("Whats your opinion about the logo above", intent: .general, needsVision: true)
        assertClassified("Do you like it?", intent: .general, needsVision: true)
        assertClassified("how does this look", intent: .general, needsVision: true)
        assertClassified("rate it", intent: .general, needsVision: true)
        assertClassified("is this good enough", intent: .general, needsVision: true)
    }

    /// Vision is only claimed when there is actually something to look at.
    func testOpinionWithoutAnImageDoesNotRequestVision() throws {
        let result = try XCTUnwrap(classify("do you think its good", hasPriorImage: false))
        XCTAssertEqual(result.intent, .general)
        XCTAssertFalse(result.needsVision)
    }

    // MARK: - Recall

    /// Mentioning a brand or logo doesn't make a recall question an image request.
    func testRecallQuestionsAreNeverImageRequests() {
        assertClassified("What was my initial selection for the brand name?", intent: .general, needsVision: false)
        assertClassified("what did you suggest earlier?", intent: .general, needsVision: false)
        assertClassified("remind me what I picked", intent: .general, needsVision: false)
        assertClassified("what was the third name", intent: .general, needsVision: false)
    }

    // MARK: - Create versus describe

    func testCreationRequestsRouteToImageGeneration() {
        assertClassified("Create a logo on it", intent: .image, needsVision: false)
        assertClassified("create another one", intent: .image, needsVision: false)
        assertClassified("make me a poster", intent: .image, needsVision: false)
        assertClassified("generate an icon", intent: .image, needsVision: false)
    }

    /// Both of these contain "logo"; only one is a request to draw.
    func testDescribeQuestionsAreDistinguishedFromCreateRequests() {
        assertClassified("What colors are in the image above", intent: .general, needsVision: true)
        assertClassified("what font is in the logo", intent: .general, needsVision: true)
        assertClassified("describe the logo above", intent: .general, needsVision: true)
    }

    // MARK: - Vision Synonyms (picture, pic, photo, photograph, snapshot)

    /// Asserts that phrasing using synonyms ("picture", "pic", "photo", "photograph")
    /// is reliably classified as general vision Q&A instead of image generation.
    func testVisionPhrasesWithSynonyms() {
        assertClassified("Can you tell me about this image", intent: .general, needsVision: true)
        assertClassified("tell me about this picture", intent: .general, needsVision: true)
        assertClassified("tell me about this pic", intent: .general, needsVision: true)
        assertClassified("tell me about this photo", intent: .general, needsVision: true)
        assertClassified("tell me about this photograph", intent: .general, needsVision: true)
        
        assertClassified("analyze this picture", intent: .general, needsVision: true)
        assertClassified("analyze this pic", intent: .general, needsVision: true)
        assertClassified("analyze this photo", intent: .general, needsVision: true)

        assertClassified("explain this picture", intent: .general, needsVision: true)
        assertClassified("explain this photo", intent: .general, needsVision: true)

        assertClassified("what is in this pic?", intent: .general, needsVision: true)
        assertClassified("what's in this picture?", intent: .general, needsVision: true)
    }

    /// Asserts that an attached image file payload on the current turn ALWAYS forces vision analysis
    /// regardless of the text prompt.
    func testDirectImageAttachmentOverrideWithSynonyms() {
        let result1 = SemanticRouter.fastPathClassification(prompt: "Can you tell me about this picture", hasPriorImage: true, hasDirectImageAttachment: true)
        XCTAssertEqual(result1?.intent, .general)
        XCTAssertEqual(result1?.needsVision, true)

        let result2 = SemanticRouter.fastPathClassification(prompt: "Look at this photo", hasPriorImage: true, hasDirectImageAttachment: true)
        XCTAssertEqual(result2?.intent, .general)
        XCTAssertEqual(result2?.needsVision, true)

        let result3 = SemanticRouter.fastPathClassification(prompt: "", hasPriorImage: true, hasDirectImageAttachment: true)
        XCTAssertEqual(result3?.intent, .general)
        XCTAssertEqual(result3?.needsVision, true)
    }

    // MARK: - Text History / Elaboration Follow-ups

    /// Asserts that questions asking for history, background, or text elaboration
    /// on previously described visual items do NOT request vision, allowing the router
    /// to pick superior general LLMs (e.g. Llama 2 / Llama 3) for text reasoning.
    func testTextHistoryFollowupsDoNotRequestVision() {
        assertClassified("tell me history about these", intent: .general, needsVision: false)
        assertClassified("tell me more about the history", intent: .general, needsVision: false)
        assertClassified("explain the history of these landmarks", intent: .general, needsVision: false)
        assertClassified("give me historical context", intent: .general, needsVision: false)
        assertClassified("tell me background on this", intent: .general, needsVision: false)
        assertClassified("explain that further", intent: .general, needsVision: false)
        assertClassified("why did you pick that color", intent: .general, needsVision: false)
        assertClassified("can you elaborate on point 2", intent: .general, needsVision: false)
    }

    // MARK: - Expanded Domain Precision Tests

    func testWebAndUICodeDesignRoutesToCoding() {
        assertClassified("design a landing page in html", intent: .coding, needsVision: false)
        assertClassified("write css layout for navbar", intent: .coding, needsVision: false)
        assertClassified("create a tailwind UI button", intent: .coding, needsVision: false)
    }

    func testShellAndTerminalScriptsRouteToCoding() {
        assertClassified("write a bash script to backup my directory", intent: .coding, needsVision: false)
        assertClassified("python script for file conversion", intent: .coding, needsVision: false)
        assertClassified("docker compose file for postgres", intent: .coding, needsVision: false)
        assertClassified("git command to undo commit", intent: .coding, needsVision: false)
    }

    func testMathAndQuantitativeReasoningRouteToGeneral() {
        assertClassified("solve this equation", intent: .general, needsVision: false)
        assertClassified("calculate derivative of sin(x)", intent: .general, needsVision: false)
        assertClassified("explain pythagorean theorem", intent: .general, needsVision: false)
        assertClassified("convert 50 miles to km", intent: .general, needsVision: false)
    }

    func testBusinessStrategyAndComparisonsRouteToGeneral() {
        assertClassified("compare React vs Vue", intent: .general, needsVision: false)
        assertClassified("what are alternatives to Docker", intent: .general, needsVision: false)
        assertClassified("swot analysis of Tesla", intent: .general, needsVision: false)
    }

    func testArtStylesAndAestheticGenerationRouteToImage() {
        assertClassified("draw a photo in anime style", intent: .image, needsVision: false)
        assertClassified("generate a realistic portrait of a knight", intent: .image, needsVision: false)
        assertClassified("make a watercolor painting of a sunset", intent: .image, needsVision: false)
        assertClassified("render a 3d isometric room", intent: .image, needsVision: false)
        assertClassified("cyberpunk cityscape picture", intent: .image, needsVision: false)
    }

    // MARK: - Deferral

    /// The fast path must handle only the shapes it is certain about.
    ///
    /// Over-firing would reintroduce exactly the brittle keyword classification
    /// this project moved away from, so anything genuinely ambiguous has to reach
    /// the LLM router untouched.
    func testAmbiguousPromptsAreLeftToTheModel() {
        XCTAssertNil(classify("write a python function to reverse a list"))
        XCTAssertNil(classify("what is the biggest clothing brand in the world"))
        XCTAssertNil(classify("explain quantum computing"))
        XCTAssertNil(classify("hi"))
        XCTAssertNil(classify("tell me about sustainable fabrics"))
    }
}
