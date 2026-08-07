/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Picks the concrete model to answer a turn, given the capabilities that turn
/// requires.
///
/// The split this type enforces is the central idea of Phase 3: **the router
/// decides what is *needed*; this decides what is *used*.** The router is never
/// asked to name a model, because a small model asked for a model name invents
/// plausible-looking ones (`llava:34b-v1.7`) that don't exist — and a
/// nonexistent name reaches `/api/pull`, where Ollama answers with an error line
/// carrying HTTP 200, the exact shape that once made installs hang silently.
/// Capabilities, by contrast, come from a closed set the server itself reports,
/// so selection becomes a pure, testable function over live data.
///
/// Everything here is deterministic and synchronous — capabilities are resolved
/// up front by `CapabilityProbe`, so scoring never touches the network.
enum ModelScorer {

    /// A model considered for a turn, with its live capabilities and real size.
    struct Candidate {
        let name: String
        let capabilities: ModelCapabilities
        /// Actual on-disk bytes from `/api/tags`, reflecting the installed
        /// quantisation rather than the catalog's nominal figure.
        let realSizeBytes: Int64?
        /// Catalog metadata, when this is a model we curate. Absent for
        /// manually pulled community models, which must still be selectable.
        let entry: ModelEntry?

        var effectiveSizeBytes: Double {
            if let realSizeBytes { return Double(realSizeBytes) }
            return (entry?.sizeGB ?? 0) * 1_000_000_000
        }
    }

    /// Why a turn can't be served, so the UI can offer the right fix.
    struct CapabilityGap: Equatable {
        let missing: ModelCapability
        /// What the user was trying to do, in plain language.
        let taskDescription: String
    }

    enum Outcome: Equatable {
        case selected(String)
        case gap(CapabilityGap)
    }

    /// Chooses a model satisfying `required`, preferring to stay on
    /// `currentModel` when it already qualifies.
    ///
    /// - Parameter stickinessMargin: when the session's current model satisfies
    ///   the requirement, it wins unless a rival scores this many times higher.
    ///   Switching mid-conversation costs a full model load (seconds, and evicts
    ///   the previous model from RAM) and subtly changes the assistant's voice,
    ///   which reads to a user as flakiness. Demanding a *meaningful* rather
    ///   than marginal improvement is what makes a chat feel like one continuous
    ///   assistant instead of a pool of them.
    ///
    ///   Calibrated against the logarithmic size score: with a 4.7 GB model
    ///   resident, an 8 GB rival scores 1.26x, a 20 GB rival 1.75x and a 40 GB
    ///   rival 2.13x. 1.8 is therefore the point where a mid-conversation swap
    ///   requires roughly a 4x size jump — enough that the quality gain is real,
    ///   while ignoring the incremental upgrades that would otherwise cause
    ///   thrashing between two similar models on consecutive turns.
    static func select(
        required: Set<ModelCapability>,
        candidates: [Candidate],
        currentModel: String?,
        residentModels: Set<String> = [],
        taskDescription: String = "answer this",
        intent: RouterIntent = .general,
        stickinessMargin: Double = 1.8
    ) -> Outcome {

        // Hard filter, never a preference: a model lacking `.vision` that is
        // handed image bytes doesn't degrade gracefully, it confidently
        // describes an image it never received.
        let qualified = candidates.filter { required.isSubset(of: $0.capabilities.capabilities) }

        guard !qualified.isEmpty else {
            return .gap(CapabilityGap(
                missing: mostSpecificMissing(required: required, candidates: candidates),
                taskDescription: taskDescription
            ))
        }

        let scored = qualified.map {
            ($0, score($0, required: required, residentModels: residentModels, intent: intent))
        }

        guard let best = scored.max(by: { $0.1 < $1.1 }) else {
            return .gap(CapabilityGap(
                missing: required.first ?? .completion,
                taskDescription: taskDescription
            ))
        }

        // Stickiness: hold the current model unless the best rival clears the margin.
        // If currentModel is a specialized small vision model (e.g. moondream) and this turn does NOT need vision,
        // relax stickiness so the app seamlessly upgrades to a larger general LLM (e.g. Llama 3 8B).
        var effectiveMargin = stickinessMargin
        if let currentModel,
           let currentCandidate = candidates.first(where: { $0.name == currentModel }),
           currentCandidate.capabilities.supportsVision,
           (currentCandidate.entry?.sizeGB ?? 2.0) <= 3.5,
           !required.contains(.vision) && !required.contains(.image) {
            effectiveMargin = 1.05
        }

        if let currentModel,
           let current = scored.first(where: { $0.0.name == currentModel }),
           best.1 < current.1 * effectiveMargin {
            return .selected(currentModel)
        }

        return .selected(best.0.name)
    }

    /// Of the required capabilities that nothing installed provides, the most
    /// distinctive one — that's what decides which models to suggest.
    ///
    /// Ordered by specificity: `.completion` is table stakes, so when several
    /// are missing the interesting one is the specialised capability. Telling a
    /// user "install a chat model" when the real problem is "no vision model"
    /// would send them after the wrong download entirely.
    private static func mostSpecificMissing(
        required: Set<ModelCapability>,
        candidates: [Candidate]
    ) -> ModelCapability {
        let bySpecificity: [ModelCapability] = [
            .image, .vision, .embedding, .tools, .thinking, .insert, .completion
        ]
        let missing = bySpecificity.first { capability in
            required.contains(capability)
                && !candidates.contains { $0.capabilities.supports(capability) }
        }
        return missing ?? required.first ?? .completion
    }

    /// Ranks a qualifying candidate. Higher is better.
    ///
    /// Size stands in for quality: among models that all satisfy the
    /// requirement, the larger is generally more capable. It contributes
    /// *logarithmically* on purpose — 1 GB → 8 GB is a far bigger real jump than
    /// 60 GB → 67 GB, and a linear term would let one huge model dominate every
    /// other signal, including whether it's even loaded.
    private static func score(
        _ candidate: Candidate,
        required: Set<ModelCapability>,
        residentModels: Set<String>,
        intent: RouterIntent = .general
    ) -> Double {
        var score = 0.0

        let gigabytes = candidate.effectiveSizeBytes / 1_000_000_000
        score += log2(max(gigabytes, 0.1) + 1) * 10

        // Already resident in memory. Weighted heavily because a cold model load
        // is the largest source of perceived latency in local inference.
        // However, on pure text turns (no vision), small vision models (<= 3.5GB)
        // shouldn't get a resident bonus over larger general text models.
        let isSpecializedSmallVisionModel = candidate.capabilities.supportsVision && (candidate.entry?.sizeGB ?? 2.0) <= 3.5
        let isPureTextTurn = !required.contains(.vision) && !required.contains(.image)

        if residentModels.contains(candidate.name) {
            if !(isPureTextTurn && isSpecializedSmallVisionModel) {
                score += 6
            }
        }

        // Role alignment: Boost purpose-built models when their specialized task is requested,
        // and prefer conversational chat models for general chat (avoiding coder models for casual greetings).
        if let role = candidate.entry?.role {
            if required.contains(.image) || intent == .image, role == "image" {
                score += 15
            } else if intent == .coding {
                if role == "coder" { score += 15 }
            } else if !required.contains(.vision) {
                // General chat turn (non-coding, non-image)
                if role == "chat" { score += 15 }
                else if role == "coder" { score -= 10 }
            }
        }

        // Mild penalty for very small context windows: such models can answer
        // but truncate long conversations badly. Measured live, moondream:1.8b
        // reports only 2048 tokens, so it should lose to a roomier vision model
        // when one is installed — while still remaining fully usable alone.
        if candidate.capabilities.contextLength < 4096 {
            score -= 6
        }

        return score
    }

    /// Catalog models that would close a capability gap, best fit first.
    ///
    /// Filtered by what this machine can actually run: suggesting a 40 GB model
    /// to someone with 8 GB of RAM is worse than suggesting nothing, because it
    /// invites a long download that ends in an unusable model.
    static func suggestions(
        for gap: CapabilityGap,
        catalog: [ModelEntry],
        specs: DeviceSpecs,
        installedNames: Set<String>,
        limit: Int = 3
    ) -> [ModelEntry] {
        let matching = catalog.filter { entry in
            guard !installedNames.contains(entry.name) else { return false }
            switch gap.missing {
            case .vision: return entry.supportsVision
            case .image: return entry.role == "image"
            case .embedding: return entry.role == "embed"
            default: return entry.role == "chat" || entry.role == "coder"
            }
        }

        // Prefer models that fit; fall back to `.slow` before giving up, since
        // "works but slower" still completes the user's task. `.unsupported` is
        // excluded unless nothing else exists at all — better to show a
        // stretch option than an empty card with no path forward.
        let comfortable = matching.filter { $0.compatibility(for: specs) == .fits }
        let workable = matching.filter { $0.compatibility(for: specs) != .unsupported }
        let pool = !comfortable.isEmpty ? comfortable : (!workable.isEmpty ? workable : matching)

        // Smallest-first: the quickest route to a working feature is the
        // smallest adequate model, not the best one available.
        return Array(pool.sorted { $0.sizeGB < $1.sizeGB }.prefix(limit))
    }
}
