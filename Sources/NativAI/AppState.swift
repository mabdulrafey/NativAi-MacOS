/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation
import SwiftUI
import Combine
import AppKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil   // nil = follow system, per SwiftUI convention
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The AppKit-level appearance to apply directly to NSApp. This is the
    /// part that actually makes the toggle work: `.preferredColorScheme()`
    /// only affects SwiftUI's own environment and asset-catalog colors — it
    /// does NOT affect AppKit dynamic system colors/materials like
    /// `Color(nsColor: .controlBackgroundColor)`, `.bar`, or `.regularMaterial`,
    /// all of which we use throughout the app. Those resolve from the actual
    /// window's NSAppearance, so without setting this too, toggling the mode
    /// changed nothing visible even though the SwiftUI-side value was updating.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil   // nil = clear override, let system decide
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Central app state: onboarding progress, device specs, installed models,
/// and navigation. Injected as an environment object at the app root.
@MainActor
final class AppState: ObservableObject {

    enum OnboardingStage {
        case scanningSpecs
        case installingOllama
        case installingRouter
        case selectUseCases
        case reviewRecommendations
        case done
    }

    // Onboarding
    @Published var onboardingStage: OnboardingStage = .scanningSpecs
    @Published var deviceSpecs: DeviceSpecs = .unknown {
        // Mirrored into the chat view model so capability-gap suggestions can be
        // filtered by what this machine can run. Pushed on assignment rather
        // than read on demand because ChatViewModel is deliberately independent
        // of AppState (it's owned by it, not the reverse), and a one-way copy
        // keeps that direction intact.
        didSet { chatViewModel.deviceSpecs = deviceSpecs }
    }
    @Published var selectedUseCases: Set<String> = []
    @Published var installLogLines: [String] = []
    /// Live progress while downloading the small routing model during
    /// onboarding. Separate from `activePulls` so the router's own download
    /// never appears in the user's model-management UI as if they'd requested
    /// it — it's infrastructure, not a model they chose.
    @Published var routerPullProgress: PullProgress? = nil
    /// Set when the router download fails. Non-fatal — routing falls back to
    /// keyword heuristics — but worth telling the user, since chat titles and
    /// intent detection will be noticeably worse.
    @Published var routerInstallError: String? = nil
    /// True once a usable routing model is confirmed present.
    @Published var routerReady: Bool = false
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    // Models
    @Published var installedModels: [OllamaManager.InstalledModel] = []
    @Published var activePulls: [String: PullProgress] = [:]   // modelName -> progress
    @Published var installErrors: [String: String] = [:]       // modelName -> last error message
    @Published var deleteErrors: [String: String] = [:]        // modelName -> last delete error message
    @Published var pullSpeeds: [String: Double] = [:]           // modelName -> bytes/sec (smoothed)
    @Published var isOllamaServerReachable: Bool = true
    @Published var lastServerError: String? = nil

    /// Tracks the previous progress sample per in-flight pull, so we can
    /// compute a live download speed from the delta between two updates
    /// rather than needing Ollama to report speed itself (it doesn't).
    private var lastPullSample: [String: (bytes: Int64, time: Date)] = [:]

    /// The in-flight Task for each active pull, tracked so it can be
    /// cancelled from the UI ("Pause"). Ollama stores downloaded blobs by
    /// content hash server-side, so cancelling and later re-pulling the same
    /// model name automatically RESUMES from whatever was already
    /// downloaded — we don't need to implement our own resume/range-request
    /// logic, just cancel and re-call install() later.
    private var pullTasks: [String: Task<Void, Never>] = [:]
    /// Tracks which models were explicitly paused (vs. actively downloading
    /// or genuinely not-yet-started), so the UI can show "Resume" instead of
    /// "Install" for a paused-but-not-finished download.
    @Published var pausedPulls: Set<String> = []

    // Chat
    @Published var selectedModelName: String? = nil
    /// Owned here (app-session-scoped) rather than as a view's @StateObject,
    /// so switching sidebar tabs never destroys/cancels an in-flight chat or
    /// image generation. Previously ChatView owned this as @StateObject,
    /// which meant navigating away and back recreated it from scratch.
    let chatViewModel = ChatViewModel()

    /// In-app appearance override (Light / Dark / System). Persisted so it
    /// survives relaunches. Defaults to following the system setting.
    @Published var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
            applyAppearance()
        }
    }

    /// Actually applies the appearance at the AppKit level. `.preferredColorScheme()`
    /// alone (set at the WindowGroup root) only affects SwiftUI's own
    /// environment and asset-catalog colors — it does NOT affect AppKit
    /// dynamic system colors/materials like `Color(nsColor: .controlBackgroundColor)`,
    /// `.bar`, or `.regularMaterial`, which this app uses extensively. Those
    /// resolve from the actual window's NSAppearance, so without this call,
    /// toggling the mode updated SwiftUI's value but changed nothing visible.
    private func applyAppearance() {
        NSApp.appearance = appearanceMode.nsAppearance
    }

    /// When true, quitting NativAI also stops the Ollama server process (and
    /// unloads any model from memory with it). Off by default since some
    /// users deliberately want Ollama to keep running in the background
    /// (e.g. to use it from the terminal or another app) even after closing
    /// this one — this makes that a conscious choice rather than a surprise
    /// either way.
    @Published var stopOllamaOnQuit: Bool {
        didSet { UserDefaults.standard.set(stopOllamaOnQuit, forKey: "stopOllamaOnQuit") }
    }

    /// Unloads the currently-loaded model from RAM without stopping the
    /// server itself — the multi-GB "ollama" process visible in Activity
    /// Monitor is a loaded model kept warm for fast responses, distinct from
    /// the lightweight server process that's always running.
    func freeModelMemoryNow() {
        Task { await ollama.unloadAllModels() }
    }

    private let ollama = OllamaManager.shared
    let catalog = CatalogService.shared

    /// Static Architecture Watermark 1
    private static let __nativai_arch_sig = "NativAI_Original_Architecture_AbdulRafey_2026_A1B2"

    /// Dynamic Verification Trigger
    @discardableResult
    static func nativai_author_check() -> String {
        let signature = "NativAI - Designed & Developed by Muhammad Abdul Rafey"
        print(signature)
        return signature
    }

    init() {
        Self.nativai_author_check()
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        let savedAppearance = UserDefaults.standard.string(forKey: "appearanceMode").flatMap { AppearanceMode(rawValue: $0) }
        self.appearanceMode = savedAppearance ?? .system
        // Defaults to ON. Leaving a server plus a multi-gigabyte loaded model
        
        if UserDefaults.standard.object(forKey: "stopOllamaOnQuit") == nil {
            self.stopOllamaOnQuit = true
            UserDefaults.standard.set(true, forKey: "stopOllamaOnQuit")
        } else {
            self.stopOllamaOnQuit = UserDefaults.standard.bool(forKey: "stopOllamaOnQuit")
        }

        // If Ollama binary is not installed on disk, onboarding cannot be considered complete.
        if !ollama.isInstalled() {
            self.hasCompletedOnboarding = false
            UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        }

        if hasCompletedOnboarding {
            onboardingStage = .done
        } else {
            onboardingStage = .scanningSpecs
        }
        
        applyAppearance()
        
        // Always scan specs & check server/dependencies on launch.
        Task { await performLaunchHealthCheck() }
    }

    /// System startup health & dependency validation.
    /// Ensures device specs are fresh, Ollama server is started, and router model is ready.
    /// If Ollama is missing or no router model is present, triggers setup flow.
    private func performLaunchHealthCheck() async {
        deviceSpecs = SpecScanner.scan()

        // If Ollama is not installed, force onboarding setup
        if !ollama.isInstalled() {
            hasCompletedOnboarding = false
            onboardingStage = .scanningSpecs
            return
        }

        // Start server if needed & list installed models
        await refreshInstalledModels()

        // Check if a qualified router model is installed
        let installedNames = installedModels.map { $0.name }
        if SemanticRouter.resolveRouterModel(installedModelNames: installedNames) == nil {
            if hasCompletedOnboarding {
                // User completed onboarding previously, but router model is missing — pull it now
                await installRouterModelIfNeeded()
            } else {
                hasCompletedOnboarding = false
                onboardingStage = .scanningSpecs
            }
        } else {
            routerReady = true
        }
    }

    /// Lightweight spec refresh used on demand to keep deviceSpecs current.
    private func refreshDeviceSpecsOnly() async {
        deviceSpecs = SpecScanner.scan()
    }

    // MARK: - Onboarding flow

    func runInitialScan() async {
        onboardingStage = .scanningSpecs
        let specs = SpecScanner.scan()
        self.deviceSpecs = specs

        if !ollama.isInstalled() {
            onboardingStage = .installingOllama
            do {
                try await ollama.install { [weak self] line in
                    self?.installLogLines.append(line)
                }
            } catch {
                if ollama.isInstalled() {
                    installLogLines.append("✔ Ollama installed successfully.")
                } else {
                    installLogLines.append("❌ \(error.localizedDescription)")
                }
            }
        }
        await ollama.startServerIfNeeded()

        // rather than in the .pkg's postinstall script: postinstall runs as
        // root, so `ollama pull` there would write the weights into
        // /var/root/.ollama/models, where the user's own Ollama server can
        // never find them. Downloading ~1 GB into an unreachable directory
        // would look like a successful install and then silently not work.
        await installRouterModelIfNeeded()

        onboardingStage = .selectUseCases
    }

    /// Downloads the bundled router model if it isn't already present.
    ///
    /// Skipped entirely when a better router is already installed (see
    /// SemanticRouter.resolveRouterModel) — no reason to spend a gigabyte on
    /// qwen2.5:1.5b when the user already has llama3.1:8b, which measured
    /// 11/12 vs 9/12 on the same routing benchmark.
    func installRouterModelIfNeeded() async {
        await refreshInstalledModels()
        let installedNames = installedModels.map { $0.name }

        if SemanticRouter.resolveRouterModel(installedModelNames: installedNames) != nil {
            routerReady = true
            return
        }

        onboardingStage = .installingRouter
        routerInstallError = nil
        let target = SemanticRouter.bundledRouterModel

        do {
            try await ollama.pullModel(named: target) { [weak self] progress in
                self?.routerPullProgress = progress
            }
            routerPullProgress = nil
            routerReady = true
            await refreshInstalledModels()
        } catch {
            // Non-fatal: routing degrades to keyword heuristics, so the app is
            // still usable. Surface it rather than failing onboarding outright.
            routerInstallError = error.localizedDescription
            routerPullProgress = nil
        }
    }

    /// The model currently acting as the routing/titling brain, or nil when
    /// nothing suitable is installed. Exposed for the storage screen so users
    /// can see what's doing the routing.
    var activeRouterModel: String? {
        SemanticRouter.resolveRouterModel(installedModelNames: installedModels.map { $0.name })
    }

    func toggleUseCase(_ useCase: String) {
        if selectedUseCases.contains(useCase) {
            selectedUseCases.remove(useCase)
        } else {
            selectedUseCases.insert(useCase)
        }
    }

    var currentRecommendations: [CatalogService.Recommendation] {
        catalog.recommendations(for: Array(selectedUseCases), specs: deviceSpecs)
    }

    func finishOnboarding() {
        hasCompletedOnboarding = true
        onboardingStage = .done
        Task { await refreshInstalledModels() }
    }

    // MARK: - Model management

    /// Refreshes the installed-model list, starting the server first if needed.
    ///
    /// The start attempt matters because the app *stops* the server on quit (to
    /// avoid leaving multi-gigabyte models resident in RAM). Nothing restarted it
    /// on a normal launch — `startServerIfNeeded` was only wired into onboarding —
    /// so for anyone who had already onboarded, quitting once left the app stuck
    /// on "Can't reach the local Ollama server" every subsequent launch, with only
    /// the Retry button as a way out.
    func refreshInstalledModels() async {
        // Cheap when the server is already up: returns immediately if the port
        // is live, so this costs nothing on the common path.
        if !(await ollama.isServerRunning()) {
            await ollama.startServerIfNeeded()
        }

        do {
            installedModels = try await ollama.listInstalledModels()
            isOllamaServerReachable = true
            lastServerError = nil
            // Probe capabilities/context lengths in the background so the first
            // message of a session doesn't pay that latency on the send path.
            // Fire-and-forget: it's a pure cache warm, and failures fall back
            // to conservative defaults at point of use.
            let names = installedModels.map { $0.name }
            Task.detached { await CapabilityProbe.shared.prewarm(modelNames: names) }
            if selectedModelName == nil {
                // Default to Auto whenever there's a real choice to route
                // between — previously this picked installedModels.first,
                // which is just whatever order Ollama happens to list models
                // in (not remotely tied to which is "best"). With only one
                // model installed, Auto has nothing to route between, so we
                // select that single model directly instead.
                selectedModelName = installedModels.count > 1
                    ? ChatViewModel.autoRouteSentinel
                    : installedModels.first?.name
            }
        } catch {
            // Previously this only printed to the console, which meant a
            // dead/unreachable Ollama server looked identical in the UI to
            // "genuinely zero models installed" — impossible to tell apart
            // without checking Xcode's console. Now we surface it directly.
            isOllamaServerReachable = false
            lastServerError = error.localizedDescription
            print("Failed to refresh installed models: \(error)")
        }
    }

    func install(model: ModelEntry) {
        install(modelName: model.name)
    }

    /// Pulls a model by raw name string, bypassing the catalog entirely. Used
    /// both for catalog-driven installs and for the manual "pull by name"
    /// field, so users aren't limited to only the models we've curated
    /// metadata for — Ollama's registry has thousands of community models
    /// we'll never have size/RAM/license data for, but should still be
    /// installable if the user knows the exact name.
    func install(modelName: String) {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        installErrors.removeValue(forKey: trimmed)
        lastPullSample.removeValue(forKey: trimmed)
        pausedPulls.remove(trimmed)
        activePulls[trimmed] = PullProgress(status: "starting…", completedBytes: 0, totalBytes: 0)

        let task = Task {
            do {
                try await ollama.pullModel(named: trimmed) { [weak self] progress in
                    guard let self else { return }
                    // Carry the last known byte counts through post-download
                    // phases. Verified against the live stream: lines such as
                    // "verifying sha256 digest", "writing manifest" and
                    // "success" carry no completed/total fields, so taking them
                    // at face value made `fraction` snap from ~1.0 back to 0 and
                    // the bar visibly collapse right at the finish line. The
                    // status text still updates, so the user sees "Verifying"
                    // against a full bar instead of an empty one.
                    let merged: PullProgress
                    if progress.totalBytes == 0, let previous = self.activePulls[trimmed], previous.totalBytes > 0 {
                        merged = PullProgress(
                            status: progress.status,
                            completedBytes: previous.completedBytes,
                            totalBytes: previous.totalBytes
                        )
                    } else {
                        merged = progress
                    }
                    self.activePulls[trimmed] = merged
                    self.updatePullSpeed(for: trimmed, progress: merged)
                    if progress.isComplete {
                        self.activePulls.removeValue(forKey: trimmed)
                        self.pullSpeeds.removeValue(forKey: trimmed)
                        self.lastPullSample.removeValue(forKey: trimmed)
                        self.pullTasks.removeValue(forKey: trimmed)
                        Task { await self.refreshInstalledModels() }
                    }
                }
            } catch is CancellationError {
                // Deliberate pause, not a real error — leave activePulls'
                // last-known progress in place so the UI can show "X% done,
                // paused" rather than clearing it like a genuine failure would.
            } catch {
                installErrors[trimmed] = error.localizedDescription
                activePulls.removeValue(forKey: trimmed)
                pullSpeeds.removeValue(forKey: trimmed)
                lastPullSample.removeValue(forKey: trimmed)
            }
            pullTasks.removeValue(forKey: trimmed)
        }
        pullTasks[trimmed] = task
    }

    /// Cancels the in-flight download. Ollama resumes from the same point
    /// later (it stores blobs by content hash server-side) when install() is
    /// called again for the same model name — this is why "pause" doesn't
    /// need any custom resume/range-request logic of our own.
    func pausePull(modelName: String) {
        pullTasks[modelName]?.cancel()
        pullTasks.removeValue(forKey: modelName)
        pausedPulls.insert(modelName)
    }

    /// Re-calls install() for the same model name — Ollama's own content-hash
    /// blob storage means this picks up from wherever the paused download
    /// left off rather than starting over from zero.
    func resumePull(modelName: String) {
        pausedPulls.remove(modelName)
        install(modelName: modelName)
    }

    /// Fully cancels and discards progress — unlike pause, the caller should
    /// treat this as "give up on this download entirely" (used by a
    /// "Cancel" action distinct from "Pause").
    func cancelPull(modelName: String) {
        pullTasks[modelName]?.cancel()
        pullTasks.removeValue(forKey: modelName)
        pausedPulls.remove(modelName)
        activePulls.removeValue(forKey: modelName)
        pullSpeeds.removeValue(forKey: modelName)
        lastPullSample.removeValue(forKey: modelName)
    }

    /// Computes a smoothed download speed (bytes/sec) from the delta between
    /// this progress update and the last *sampled* one for the same model.
    ///
    /// Uses a 1-second sampling window rather than the previous 0.15s. With
    /// Ollama's fine-grained progress reporting (measured: ~670 lines/sec in
    /// 8–16 KB steps for a large single-blob model), a short window measures
    /// mostly scheduling jitter rather than throughput — replaying the real
    /// captured cadence, a 0.15s window showed 1.6% median error and swung
    /// between 7.7 and 8.5 MB/s, while a 1.0s window held 0.6% error and
    /// 8.0–8.2 MB/s. A full second of bytes is also a more honest thing to
    /// label "per second".
    ///
    /// A non-monotonic `completedBytes` (which Ollama can emit when it moves
    /// between layers, or on resume after a pause) resets the baseline instead
    /// of being discarded. Previously it returned early, which left the last
    /// sample permanently in the past and froze the displayed speed.
    private func updatePullSpeed(for modelName: String, progress: PullProgress) {
        let now = Date()
        guard let previous = lastPullSample[modelName] else {
            lastPullSample[modelName] = (progress.completedBytes, now)
            return
        }

        // Went backwards: re-baseline rather than freeze.
        guard progress.completedBytes >= previous.bytes else {
            lastPullSample[modelName] = (progress.completedBytes, now)
            return
        }

        let elapsed = now.timeIntervalSince(previous.time)
        guard elapsed >= 1.0 else { return }

        let instantaneousSpeed = Double(progress.completedBytes - previous.bytes) / elapsed
        let previousSpeed = pullSpeeds[modelName] ?? instantaneousSpeed
        // 60/40 rather than 70/30: with ~10x fewer samples arriving, heavy
        // smoothing would make the number lag visibly behind reality.
        pullSpeeds[modelName] = (previousSpeed * 0.6) + (instantaneousSpeed * 0.4)
        lastPullSample[modelName] = (progress.completedBytes, now)
    }

    func delete(modelName: String) {
        deleteErrors.removeValue(forKey: modelName)
        Task {
            do {
                try await ollama.deleteModel(named: modelName)
                // Drop cached capabilities so a later re-pull is re-probed
                // rather than reusing stale data for different weights.
                await CapabilityProbe.shared.invalidate(modelName: modelName)
                await refreshInstalledModels()
            } catch {
                deleteErrors[modelName] = error.localizedDescription
            }
        }
    }

    var totalDiskUsageGB: Double {
        Double(installedModels.reduce(0) { $0 + $1.size }) / 1_073_741_824.0
    }

    func isInstalled(_ modelName: String) -> Bool {
        installedModels.contains { installed in
            installed.name == modelName ||
            installed.name == "\(modelName):latest" ||
            installed.name.hasPrefix("\(modelName):") ||
            modelName == installed.name.components(separatedBy: ":").first
        }
    }
}
