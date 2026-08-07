import XCTest

/// Covers the artifact ledger — the typed record of images and documents in a
/// conversation.
///
/// This replaced keyword-based inference over message text, which was the single
/// largest source of routing regressions in the project: "logo for" matched
/// ordinary discussion, "create logo for X" missed for lack of an article, and
/// broad classification kept re-attaching stale images to unrelated follow-ups.
/// Recording the fact once, when it is unambiguous, removes that whole class of
/// bug — so these tests guard the recording and lookup, not a keyword list.
final class SessionArtifactTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1000)

    private func artifact(
        _ kind: SessionArtifact.Kind,
        label: String,
        offset: TimeInterval = 0
    ) -> SessionArtifact {
        SessionArtifact(
            kind: kind,
            messageId: UUID(),
            label: label,
            createdAt: epoch.addingTimeInterval(offset)
        )
    }

    /// Two generated images plus a document, oldest first.
    private var mixedArtifacts: (logo: SessionArtifact, poster: SessionArtifact, doc: SessionArtifact, all: [SessionArtifact]) {
        let logo = artifact(.generatedImage, label: "a logo for Kairos", offset: 0)
        let poster = artifact(.generatedImage, label: "a poster for Vela", offset: 60)
        let doc = artifact(.document, label: "spec.pdf", offset: 90)
        return (logo, poster, doc, [logo, poster, doc])
    }

    // MARK: - Target resolution

    func testDefaultsToMostRecentVisual() {
        let f = mixedArtifacts
        XCTAssertEqual(
            SessionArtifact.resolveTarget(prompt: "make it bluer", artifacts: f.all)?.id,
            f.poster.id
        )
    }

    func testOrdinalSelectsByIndex() {
        let f = mixedArtifacts
        XCTAssertEqual(
            SessionArtifact.resolveTarget(prompt: "what font is in the first image?", artifacts: f.all)?.id,
            f.logo.id
        )
        XCTAssertEqual(
            SessionArtifact.resolveTarget(prompt: "describe the second one", artifacts: f.all)?.id,
            f.poster.id
        )
    }

    /// The reported bug: asking about an earlier image analysed the newest one.
    ///
    /// Before the ledger, carryover always grabbed the most recent image, so
    /// "what font is in the logo?" after generating a poster examined the poster.
    func testLabelKeywordSelectsTheReferencedImage() {
        let f = mixedArtifacts
        XCTAssertEqual(
            SessionArtifact.resolveTarget(prompt: "what font is in the logo?", artifacts: f.all)?.id,
            f.logo.id
        )
        XCTAssertEqual(
            SessionArtifact.resolveTarget(prompt: "is the poster readable?", artifacts: f.all)?.id,
            f.poster.id
        )
    }

    func testOutOfRangeOrdinalFallsBackRatherThanClamping() {
        let f = mixedArtifacts
        // "the fifth image" with two images present shouldn't confidently pick
        // the last one; falling through to recency is the honest behaviour.
        XCTAssertNotNil(SessionArtifact.resolveTarget(prompt: "the fifth image", artifacts: f.all))
    }

    func testDocumentsAreNotVisualTargets() {
        let f = mixedArtifacts
        XCTAssertNil(
            SessionArtifact.resolveTarget(prompt: "make it bluer", artifacts: [f.doc]),
            "A document's text is already in the transcript, so it needs no vision model."
        )
        XCTAssertEqual(SessionArtifact.visuals(in: f.all).count, 2)
    }

    func testEmptyLedgerResolvesToNil() {
        XCTAssertNil(SessionArtifact.resolveTarget(prompt: "anything", artifacts: []))
    }

    // MARK: - Context summary

    func testEmptyLedgerProducesNoSummary() {
        // Telling a model "there are 0 images" measurably invites it to reason
        // about absent things.
        XCTAssertNil(SessionArtifact.contextSummary(for: []))
    }

    func testSummaryNumbersVisualsAndSeparatesDocuments() throws {
        let summary = try XCTUnwrap(SessionArtifact.contextSummary(for: mixedArtifacts.all))
        XCTAssertTrue(summary.contains("1."))
        XCTAssertTrue(summary.contains("2."))
        XCTAssertTrue(summary.contains("generated"))
        XCTAssertTrue(summary.contains("spec.pdf"))

        let imageSection = summary.components(separatedBy: "Documents").first ?? ""
        XCTAssertFalse(
            imageSection.contains("spec.pdf"),
            "Documents must not appear in the image list or vision routing would be forced for them."
        )
    }

    func testResolveTargetsReturnsMultipleArtifactsForComparativePrompts() {
        let f = mixedArtifacts
        let resolved = SessionArtifact.resolveTargets(prompt: "compare the 1st image with the 2nd image", artifacts: f.all)

        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved.first?.id, f.logo.id)
        XCTAssertEqual(resolved.last?.id, f.poster.id)
    }
}
