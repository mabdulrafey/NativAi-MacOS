import Foundation

// Minimal stand-ins for the networking types the logic under test references.
//
// `ConversationDigest` and `TokenBudget` both take `OllamaManager.ChatMessage`
// as their data type, and `ConversationDigest.fold` calls the live server. The
// real `OllamaManager` opens sockets and the real `CapabilityProbe` hits
// `/api/show`, neither of which belongs in a unit test — a test suite that needs
// Ollama running is a test suite that gets skipped.
//
// Only the *planning* half of compaction is covered here, which is the half
// where a mistake is dangerous: an off-by-one in `plan` would silently
// re-summarize or skip turns. `fold`'s behaviour is inherently a property of the
// model, so it's verified by hand against the live server instead.

struct OllamaManager {
    struct ChatMessage {
        let role: String
        let content: String
        let images: [String]?

        init(role: String, content: String, images: [String]? = nil) {
            self.role = role
            self.content = content
            self.images = (images?.isEmpty ?? true) ? nil : images
        }
    }

    static let shared = OllamaManager()

    func chat(
        model: String,
        messages: [ChatMessage],
        contextLength: Int,
        onToken: @escaping (String) -> Void
    ) async throws {
        // Never invoked: tests only exercise `plan`, not `fold`.
    }

    /// Never invoked either — `MemoryExtractor.extract` returns early in tests
    /// because no model is supplied. Present only so the extractor's file
    /// compiles in this target, letting its pure `sanitize` filter be tested.
    func structuredChat(
        model: String,
        messages: [ChatMessage],
        schema: [String: Any],
        maxTokens: Int = 100,
        contextLength: Int? = nil
    ) async throws -> Data {
        Data()
    }
}

actor CapabilityProbe {
    static let shared = CapabilityProbe()
    func contextLength(for model: String) async -> Int { 8192 }

    /// Reports capabilities from a table the tests control, so
    /// `EmbeddingService.resolveModel` can be exercised without a live server.
    func capabilities(for model: String) async -> ModelCapabilities {
        ModelCapabilities(
            modelName: model,
            capabilities: Self.stubbed[model] ?? [.completion],
            contextLength: 8192,
            family: nil,
            parameterSize: nil
        )
    }

    /// Capabilities the fake server reports. Mirrors what the real
    /// `/api/show` returns for these models on the development machine.
    static let stubbed: [String: Set<ModelCapability>] = [
        "nomic-embed-text": [.embedding],
        "mxbai-embed-large": [.embedding],
        "some-community-embedder": [.embedding],
        "llama3:8b": [.completion],
        "moondream:1.8b": [.completion, .vision],
        "x/flux2-klein:4b": [.image]
    ]
}

// MARK: - Fixtures

enum Fixture {

    static func message(_ role: String, _ content: String) -> OllamaManager.ChatMessage {
        OllamaManager.ChatMessage(role: role, content: content)
    }

    /// Messages labelled `MSG<n>` with globally unique indices.
    ///
    /// Uniqueness matters: an earlier version of these tests rebuilt a
    /// conversation with restarting labels, and the duplicate names looked
    /// exactly like a monotonicity violation in `plan`. The bug was in the test.
    static func run(from: Int, to: Int, padding: Int = 400) -> [OllamaManager.ChatMessage] {
        (from..<to).map { index in
            message(
                index % 2 == 0 ? "user" : "assistant",
                "MSG\(index) " + String(repeating: "z", count: padding)
            )
        }
    }

    /// Extracts the numeric label from a fixture message.
    static func label(_ message: OllamaManager.ChatMessage) -> Int {
        Int(message.content.split(separator: " ")[0].dropFirst(3))!
    }

    static func capabilities(
        _ name: String,
        _ capabilities: Set<ModelCapability>,
        contextLength: Int = 32768
    ) -> ModelCapabilities {
        ModelCapabilities(
            modelName: name,
            capabilities: capabilities,
            contextLength: contextLength,
            family: nil,
            parameterSize: nil
        )
    }

    static func entry(
        _ name: String,
        role: String,
        sizeGB: Double,
        vision: Bool = false
    ) -> ModelEntry {
        ModelEntry(
            name: name,
            displayName: name,
            category: [],
            role: role,
            useCases: [],
            description: "",
            sizeGB: sizeGB,
            minRAMGB: sizeGB * 2,
            minVRAMGB: sizeGB * 1.2,
            license: "",
            commercialUse: true,
            speedTier: nil,
            supportsVision: vision
        )
    }

    static func candidate(
        _ name: String,
        _ caps: Set<ModelCapability>,
        sizeGB: Double,
        role: String = "chat",
        contextLength: Int = 32768,
        vision: Bool = false
    ) -> ModelScorer.Candidate {
        ModelScorer.Candidate(
            name: name,
            capabilities: capabilities(name, caps, contextLength: contextLength),
            realSizeBytes: Int64(sizeGB * 1_000_000_000),
            entry: entry(name, role: role, sizeGB: sizeGB, vision: vision)
        )
    }

    /// The models actually installed on the development machine, with the exact
    /// capabilities the live server reports for them.
    enum Installed {
        static let llama = candidate("llama3:8b", [.completion], sizeGB: 4.7)
        static let qwen = candidate("qwen2.5:1.5b", [.completion, .tools], sizeGB: 1.0)
        static let flux = candidate("x/flux2-klein:4b", [.image], sizeGB: 5.7, role: "image")
        static let moondream = candidate(
            "moondream:1.8b", [.completion, .vision],
            sizeGB: 1.7, contextLength: 2048, vision: true
        )
        static let all = [llama, qwen, flux, moondream]
    }

    static let mac16GB = DeviceSpecs(
        totalRAMGB: 16, cpuCores: 8, isAppleSilicon: true,
        chipName: "M2", gpuName: "M2", vramGB: 16
    )

    static let mac8GB = DeviceSpecs(
        totalRAMGB: 8, cpuCores: 8, isAppleSilicon: true,
        chipName: "M1", gpuName: "M1", vramGB: 8
    )
}
