import XCTest

/// Covers capability-based model selection.
///
/// The central guarantee is that a model is chosen by what the *server* says it
/// can do, never by name or by the hand-maintained catalog. Capability lists come
/// from `/api/show`; the values used here are the real ones observed on the
/// development machine (Flux reports `["image"]` with no `"completion"`,
/// moondream reports `["completion","vision"]`).
final class ModelScorerTests: XCTestCase {

    private func selected(
        _ required: Set<ModelCapability>,
        _ candidates: [ModelScorer.Candidate],
        current: String? = nil,
        resident: Set<String> = []
    ) -> String? {
        guard case .selected(let name) = ModelScorer.select(
            required: required,
            candidates: candidates,
            currentModel: current,
            residentModels: resident
        ) else { return nil }
        return name
    }

    private func gap(
        _ required: Set<ModelCapability>,
        _ candidates: [ModelScorer.Candidate],
        task: String = "answer this"
    ) -> ModelScorer.CapabilityGap? {
        guard case .gap(let gap) = ModelScorer.select(
            required: required,
            candidates: candidates,
            currentModel: nil,
            taskDescription: task
        ) else { return nil }
        return gap
    }

    // MARK: - Capability filtering

    func testImageRequestSelectsTheImageModel() {
        XCTAssertEqual(selected([.image], Fixture.Installed.all), "x/flux2-klein:4b")
    }

    func testVisionRequestSelectsTheVisionModel() {
        XCTAssertEqual(selected([.vision], Fixture.Installed.all), "moondream:1.8b")
    }

    /// The regression that motivated capability filtering.
    ///
    /// The previous role-based lookup fell back to `installedModelNames.first`,
    /// which could hand a text prompt to an image-only model. Flux advertises
    /// `["image"]` and no `"completion"`, so requiring `.completion` must exclude
    /// it — even when it is first in the list.
    func testImageOnlyModelIsNeverChosenForText() {
        let fluxFirst = [Fixture.Installed.flux, Fixture.Installed.llama]
        XCTAssertEqual(selected([.completion], fluxFirst), "llama3:8b")
    }

    // MARK: - Gap detection

    func testMissingVisionIsReportedAsVisionNotCompletion() {
        let textOnly = [Fixture.Installed.llama, Fixture.Installed.qwen]
        let gap = self.gap([.completion, .vision], textOnly, task: "read that image")

        XCTAssertEqual(gap?.missing, .vision, "The specialised capability decides which models to suggest.")
        XCTAssertEqual(gap?.taskDescription, "read that image")
    }

    func testMissingImageModelIsReported() {
        let textOnly = [Fixture.Installed.llama, Fixture.Installed.qwen]
        XCTAssertEqual(self.gap([.image], textOnly)?.missing, .image)
    }

    func testNoInstalledModelsProducesGap() {
        XCTAssertNotNil(self.gap([.completion], []))
    }

    // MARK: - Stickiness

    func testStaysOnResidentAdequateModel() {
        let rival = Fixture.candidate("mistral-nemo:12b", [.completion], sizeGB: 8.0)
        XCTAssertEqual(
            selected([.completion], [Fixture.Installed.llama, rival],
                     current: "llama3:8b", resident: ["llama3:8b"]),
            "llama3:8b",
            "Switching costs a multi-second load and changes the assistant's voice mid-chat."
        )
    }

    func testStaysOnAdequateColdModelAgainstMarginalRival() {
        let rival = Fixture.candidate("mistral-nemo:12b", [.completion], sizeGB: 8.0)
        XCTAssertEqual(
            selected([.completion], [Fixture.Installed.llama, rival], current: "llama3:8b"),
            "llama3:8b"
        )
    }

    func testSwitchesWhenCurrentModelLacksTheCapability() {
        XCTAssertEqual(
            selected([.vision], Fixture.Installed.all, current: "llama3:8b"),
            "moondream:1.8b"
        )
    }

    func testSwitchesWhenRivalIsVastlyBetter() {
        let big = Fixture.candidate("llama3.3:70b", [.completion], sizeGB: 40.0)
        XCTAssertEqual(
            selected([.completion], [Fixture.Installed.qwen, big], current: "qwen2.5:1.5b"),
            "llama3.3:70b"
        )
    }

    // MARK: - Ranking signals

    func testResidentModelWinsOverMarginallyLargerColdModel() {
        let a = Fixture.candidate("a:7b", [.completion], sizeGB: 4.0)
        let b = Fixture.candidate("b:7b", [.completion], sizeGB: 4.2)
        XCTAssertEqual(selected([.completion], [a, b], resident: ["a:7b"]), "a:7b")
    }

    func testResidentBonusDoesNotOutweighAVastlyBetterModel() {
        let a = Fixture.candidate("a:7b", [.completion], sizeGB: 4.0)
        let big = Fixture.candidate("llama3.3:70b", [.completion], sizeGB: 40.0)
        XCTAssertEqual(selected([.completion], [a, big], resident: ["a:7b"]), "llama3.3:70b")
    }

    func testRoomierContextWindowBeatsTinyOne() {
        let llava = Fixture.candidate(
            "llava:7b", [.completion, .vision],
            sizeGB: 4.7, contextLength: 32768, vision: true
        )
        // moondream reports only 2048 tokens, so it should lose when a roomier
        // vision model exists — while remaining fully usable on its own.
        XCTAssertEqual(selected([.vision], [Fixture.Installed.moondream, llava]), "llava:7b")
    }

    // MARK: - Suggestions

    private var visionCatalog: [ModelEntry] {
        [
            Fixture.entry("llava:7b", role: "chat", sizeGB: 4.7, vision: true),
            Fixture.entry("moondream:1.8b", role: "chat", sizeGB: 1.7, vision: true),
            Fixture.entry("llava:34b", role: "chat", sizeGB: 20.0, vision: true),
            Fixture.entry("flux", role: "image", sizeGB: 5.7)
        ]
    }

    private var visionGap: ModelScorer.CapabilityGap {
        ModelScorer.CapabilityGap(missing: .vision, taskDescription: "read that image")
    }

    func testSuggestionsMatchTheMissingCapabilityAndAreSmallestFirst() {
        let suggestions = ModelScorer.suggestions(
            for: visionGap, catalog: visionCatalog,
            specs: Fixture.mac16GB, installedNames: []
        )
        XCTAssertTrue(suggestions.allSatisfy(\.supportsVision))
        XCTAssertEqual(
            suggestions.first?.name, "moondream:1.8b",
            "The quickest route to a working feature is the smallest adequate model."
        )
    }

    func testSuggestionsExcludeModelsTheMachineCannotRun() {
        let suggestions = ModelScorer.suggestions(
            for: visionGap, catalog: visionCatalog,
            specs: Fixture.mac8GB, installedNames: []
        )
        XCTAssertFalse(
            suggestions.contains { $0.name == "llava:34b" },
            "Suggesting a 20 GB model to an 8 GB Mac invites a long download ending in an unusable model."
        )
    }

    func testSuggestionsExcludeAlreadyInstalledModels() {
        let suggestions = ModelScorer.suggestions(
            for: visionGap, catalog: visionCatalog,
            specs: Fixture.mac16GB, installedNames: ["moondream:1.8b"]
        )
        XCTAssertFalse(suggestions.contains { $0.name == "moondream:1.8b" })
    }

    func testImageGapSuggestsImageModels() {
        let gap = ModelScorer.CapabilityGap(missing: .image, taskDescription: "generate an image")
        let suggestions = ModelScorer.suggestions(
            for: gap, catalog: visionCatalog,
            specs: Fixture.mac16GB, installedNames: []
        )
        XCTAssertTrue(suggestions.allSatisfy { $0.role == "image" })
    }

    func testSuggestionLimitIsRespected() {
        XCTAssertEqual(
            ModelScorer.suggestions(
                for: visionGap, catalog: visionCatalog,
                specs: Fixture.mac16GB, installedNames: [], limit: 1
            ).count,
            1
        )
    }

    func testCoderModelIsNeverSelectedForGeneralChatGreetings() {
        let starCoder = ModelScorer.Candidate(
            name: "starcoder2:3b",
            capabilities: ModelCapabilities(modelName: "starcoder2:3b", capabilities: [.completion], contextLength: 4096, family: "starcoder2", parameterSize: "3b"),
            realSizeBytes: 1_700_000_000,
            entry: ModelEntry(name: "starcoder2:3b", displayName: "StarCoder2 (3B)", category: ["coding"], role: "coder", useCases: ["coding"], description: "", sizeGB: 1.7, minRAMGB: 4, minVRAMGB: 1, license: "Apache-2.0", commercialUse: true, speedTier: "fast")
        )
        let qwenChat = ModelScorer.Candidate(
            name: "qwen2.5:1.5b",
            capabilities: ModelCapabilities(modelName: "qwen2.5:1.5b", capabilities: [.completion], contextLength: 4096, family: "qwen2", parameterSize: "1.5b"),
            realSizeBytes: 1_000_000_000,
            entry: ModelEntry(name: "qwen2.5:1.5b", displayName: "Qwen 2.5 (1.5B)", category: ["qa"], role: "chat", useCases: ["qa"], description: "", sizeGB: 1.0, minRAMGB: 2.5, minVRAMGB: 0.5, license: "Apache-2.0", commercialUse: true, speedTier: "fast")
        )

        // For [.completion] (general chat), qwen2.5:1.5b (role: chat) MUST win over starcoder2:3b (role: coder)
        XCTAssertEqual(ModelScorer.select(required: [.completion], candidates: [starCoder, qwenChat], currentModel: nil, intent: .general), .selected("qwen2.5:1.5b"))

        // For coding task (intent: .coding), starcoder2:3b MUST win over qwen2.5:1.5b
        XCTAssertEqual(ModelScorer.select(required: [.completion], candidates: [starCoder, qwenChat], currentModel: nil, intent: .coding), .selected("starcoder2:3b"))
    }
}
