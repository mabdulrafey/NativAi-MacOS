/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// A durable record of something *visual or documentary* that exists in a
/// conversation: an image the app generated, an image the user attached, or a
/// document whose text was injected.
///
/// Why this type exists — the recurring-bug story:
///
/// Routing used to re-derive "is there an image in this chat, and is the user
/// talking about it?" from raw message text on every single turn, via keyword
/// heuristics. That is the single largest source of routing regressions in this
/// project's history: "logo for" matched ordinary discussion, "create logo for
/// X" missed for lack of an article, "build logo" missed because only "build
/// me" was listed, and broad `.general` classification kept re-attaching stale
/// images to unrelated follow-ups. Each fix was another keyword, and each new
/// keyword created a new false positive somewhere else.
///
/// The ledger replaces that guessing with **typed state**. When an image is
/// produced or attached, we record that fact once, at the moment it happens,
/// when it is unambiguous. Later turns then *look it up* instead of trying to
/// infer it from prose. "Make the logo bigger" or "what font is that?" resolve
/// against a concrete entry rather than a regex — which is exactly the same
/// insight that made `ContextualReferenceResolver` reliable: do the exact part
/// in Swift, and leave only the genuinely fuzzy part to the model.
struct SessionArtifact: Identifiable, Codable, Equatable, Sendable {

    enum Kind: String, Codable, Sendable {
        /// An image this app generated via a diffusion model.
        case generatedImage
        /// An image the user attached to one of their messages.
        case attachedImage
        /// A text/PDF/code file whose extracted contents were injected.
        case document

        /// True for artifacts a vision model could actually look at. Documents
        /// are excluded: their text is already in the transcript, so answering
        /// about them needs no vision capability at all — conflating the two
        /// would wrongly force vision routing (and a vision-model swap) for a
        /// plain question about an attached .txt file.
        var isVisual: Bool {
            switch self {
            case .generatedImage, .attachedImage: return true
            case .document: return false
            }
        }
    }

    let id: UUID
    let kind: Kind
    /// The message this artifact lives in, so the actual bytes can be found
    /// again without duplicating image data into the ledger (sessions are
    /// persisted as JSON — copying image bytes would double file size).
    let messageId: UUID
    /// Short human-readable description, used both for the router's context
    /// facts and for disambiguating between multiple artifacts.
    let label: String
    /// For `.generatedImage`: the prompt that produced it. Lets a follow-up
    /// like "make it bluer" be rebuilt from the original intent rather than
    /// from the user's elliptical phrasing.
    let sourcePrompt: String?
    let createdAt: Date

    var isVisual: Bool { kind.isVisual }

    init(
        id: UUID = UUID(),
        kind: Kind,
        messageId: UUID,
        label: String,
        sourcePrompt: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.messageId = messageId
        self.label = label
        self.sourcePrompt = sourcePrompt
        self.createdAt = createdAt
    }
}

// MARK: - Context summary

extension SessionArtifact {

    /// A compact, factual description of a session's artifacts for the router's
    /// system prompt.
    ///
    /// Deliberately phrased as *facts*, not as text to interpret. The router is
    /// told "this conversation contains 1 generated image (a logo …)" rather
    /// than being handed the transcript and asked to work it out. Small models
    /// are markedly better at answering a question about stated facts than at
    /// extracting those facts first — the same reason the benchmark in
    /// `SemanticRouter` showed accuracy collapsing when one call was asked to
    /// do two jobs.
    ///
    /// Returns nil when there is nothing to report, so callers can omit the
    /// section entirely rather than telling the model "there are 0 images",
    /// which measurably invites it to reason about absent things.
    static func contextSummary(for artifacts: [SessionArtifact]) -> String? {
        guard !artifacts.isEmpty else { return nil }

        // Newest last so ordinal language ("the second image") lines up with
        // the order a user reads the conversation in.
        let sorted = artifacts.sorted { $0.createdAt < $1.createdAt }
        let visuals = sorted.filter { $0.kind.isVisual }
        let documents = sorted.filter { $0.kind == .document }

        var lines: [String] = []

        if !visuals.isEmpty {
            let described = visuals.enumerated().map { index, artifact -> String in
                let origin = artifact.kind == .generatedImage ? "generated" : "attached by the user"
                return "  \(index + 1). \(artifact.label) (\(origin))"
            }
            lines.append("Images already present in this conversation:")
            lines.append(contentsOf: described)
        }

        if !documents.isEmpty {
            let names = documents.map { $0.label }.joined(separator: ", ")
            lines.append("Documents already provided as text: \(names)")
        }

        return lines.joined(separator: "\n")
    }

    /// The visual artifacts, oldest-first.
    static func visuals(in artifacts: [SessionArtifact]) -> [SessionArtifact] {
        artifacts.filter { $0.kind.isVisual }.sorted { $0.createdAt < $1.createdAt }
    }
}

// MARK: - Deterministic target resolution

extension SessionArtifact {

    /// Ordinal words mapped to a zero-based index, for "the second image".
    private static let ordinals: [String: Int] = [
        "first": 0, "1st": 0,
        "second": 1, "2nd": 1,
        "third": 2, "3rd": 2,
        "fourth": 3, "4th": 3,
        "fifth": 4, "5th": 4
    ]

    /// Picks which visual artifact a prompt is talking about.
    ///
    /// Resolution order, most specific first:
    ///   1. An explicit ordinal ("the *first* logo") — exact index lookup.
    ///   2. A label keyword match ("the *logo*" when a logo artifact exists).
    ///   3. The most recent visual artifact.
    ///
    /// Entirely deterministic and done in Swift on purpose. Asking a 1.5B model
    /// to choose among several images was the exact failure mode measured in
    /// `SemanticRouter` (it returned wrong list items, headings, and even the
    /// literal string "number 2"), whereas index and substring lookup are
    /// exact. The LLM decides *whether* vision is needed; Swift decides *what*
    /// to look at.
    ///
    /// Returns nil only when there is nothing visual to point at.
    static func resolveTarget(prompt: String, artifacts: [SessionArtifact]) -> SessionArtifact? {
        let candidates = visuals(in: artifacts)
        guard !candidates.isEmpty else { return nil }

        let lower = prompt.lowercased()

        // 1. Explicit ordinal. Only trusted when it actually addresses an
        //    existing artifact — "the fifth image" with two images present
        //    falls through rather than silently clamping to the last one,
        //    since a wrong-but-confident pick is worse than a sensible default.
        for (word, index) in ordinals where lower.contains(word) {
            if candidates.indices.contains(index) {
                return candidates[index]
            }
        }

        // 2. Label keyword. Matches on the significant words of each label so
        //    "what font is in the logo?" finds the artifact labelled
        //    "logo for Kairos". Scanned newest-first so the most recent
        //    matching artifact wins when several share a word.
        for artifact in candidates.reversed() {
            let words = artifact.label
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 }
            if words.contains(where: { lower.contains($0) }) {
                return artifact
            }
        }

        // 3. Recency — the overwhelmingly common case ("make it bluer").
        return candidates.last
    }

    /// Resolves one or more visual artifacts referenced in a prompt (e.g. for comparative queries).
    static func resolveTargets(
        prompt: String,
        artifacts: [SessionArtifact]
    ) -> [SessionArtifact] {
        let visuals = artifacts.filter { $0.isVisual }
        guard !visuals.isEmpty else { return [] }

        let lower = prompt.lowercased()
        let isComparative = lower.contains("compare")
            || lower.contains("difference")
            || lower.contains("both")
            || lower.contains("between")

        if isComparative && visuals.count >= 2 {
            return Array(visuals.suffix(2))
        }

        if let single = resolveTarget(prompt: prompt, artifacts: artifacts) {
            return [single]
        }
        return []
    }
}

