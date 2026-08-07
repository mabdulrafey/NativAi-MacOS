/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation

/// Represents streamed progress from an `ollama pull`/API pull operation.
struct PullProgress: Equatable {
    let status: String       // e.g. "downloading", "verifying sha256 digest", "success"
    let completedBytes: Int64
    let totalBytes: Int64

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(completedBytes) / Double(totalBytes)
    }

    var percentageText: String {
        guard totalBytes > 0 else { return "" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// Ollama's raw status strings are things like "pulling 5ff0abeeac1d" —
    /// meaningful to Ollama internally (a layer digest) but meaningless to a
    /// user. Map the common ones to plain language; fall back to the raw
    /// status for anything unrecognized rather than hiding it.
    var friendlyStatus: String {
        if status.hasPrefix("pulling ") { return "Downloading" }
        if status.contains("verifying") { return "Verifying" }
        if status.contains("writing") { return "Writing to disk" }
        if status.contains("manifest") { return "Preparing" }
        if status == "success" { return "Done" }
        return status
    }

    var isComplete: Bool {
        status == "success"
    }
}

enum OllamaError: LocalizedError {
    case binaryNotFound
    case installFailed(String)
    case serverUnreachable
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "Ollama is not installed."
        case .installFailed(let msg): return "Failed to install Ollama: \(msg)"
        case .serverUnreachable: return "Could not reach the local Ollama server."
        case .requestFailed(let msg): return "Ollama request failed: \(msg)"
        }
    }
}

/// Manages detection, installation, and API communication with the local
/// Ollama server (default: http://127.0.0.1:11434).
final class OllamaManager {

    static let shared = OllamaManager()
    private let baseURL = URL(string: "http://127.0.0.1:11434")!

    /// Dedicated session for long-running/streaming calls (pulls, chat, image gen).
    /// URLSession.shared's default 60s idle timeout is far too short for
    /// multi-gigabyte model downloads — a quiet moment (checksum verification,
    /// a network hiccup) easily exceeds 60s with no bytes received, which is
    /// exactly what produced the "The request timed out." error.
    private let longRunningSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1800     // 30 min of silence before giving up — generous for slow/flaky connections on large multi-GB pulls
        config.timeoutIntervalForResource = 60 * 60 * 12   // 12 hour total ceiling
        return URLSession(configuration: config)
    }()

    // Common install locations for the `ollama` CLI on macOS.
    private let commonBinaryPaths = [
        "/usr/local/bin/ollama",
        "/opt/homebrew/bin/ollama",
        "/Applications/Ollama.app/Contents/Resources/ollama"
    ]

    // MARK: - Detection

    /// True if the `ollama` binary is present on disk.
    func isInstalled() -> Bool {
        commonBinaryPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// True if the local Ollama server is up and responding.
    func isServerRunning() async -> Bool {
        do {
            let (_, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/tags"))
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Installation

    /// Downloads and runs the official Ollama install script, streaming its
    /// output so the UI can show a live "Setting up…" log.
    ///
    /// Deliberately **not** `curl … | sh`. Piping a network stream straight into
    /// a shell means bytes execute as they arrive, so there is no point at which
    /// the content can be inspected, and a truncated or tampered response is
    /// executed anyway — a connection cut mid-download can leave a half-written
    /// command that still runs. It also spawns a shell that interprets its input,
    /// which is a needlessly large amount of trust for a fixed URL.
    ///
    /// Instead: download to a private temp file, verify it looks like a shell
    /// script and is a plausible size, then execute that file directly with no
    /// shell involved. The download is atomic from the executor's point of view —
    /// either the whole script is on disk and validated, or nothing runs.
    ///
    /// HTTPS to a pinned host provides transport integrity; this adds
    /// content-level sanity checks on top. A published checksum would be
    /// stronger, but Ollama doesn't publish a stable one for this script, and
    /// hardcoding a hash we can't update would break installs on every upstream
    /// change.
    func install(onOutputLine: @escaping (String) -> Void) async throws {
        let scriptURL = URL(string: "https://ollama.com/install.sh")!

        // Every progress line is delivered on the main actor.
        //
        // `install` is called from a detached Task, so its body runs on a
        // background cooperative thread. Callers append these lines to a
        // @Published property on an @MainActor object, and writing that from a
        // background thread makes SwiftUI rebuild the main menu off-thread —
        // AppKit's `-[NSMenu itemArray]` then asserts and calls abort().
        //
        // This crashed on first launch for anyone without Ollama already
        // installed (verified from a user crash report: SIGABRT on
        // com.apple.root.user-initiated-qos.cooperative, NSMenu assertion). The
        // streamed output below was already hopping to main via its
        // readabilityHandler; these direct status lines were not, so the hop is
        // centralised here where it can't be forgotten again.
        let emit: (String) -> Void = { line in
            Task { @MainActor in onOutputLine(line) }
        }

        emit("Downloading installer from ollama.com…\n")

        var request = URLRequest(url: scriptURL)
        request.timeoutInterval = 60
        // Never serve this from a cache: a poisoned cache entry would otherwise
        // be executed without any network round trip to validate it.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OllamaError.installFailed("Could not download installer: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OllamaError.installFailed("Installer download failed (HTTP \(code)).")
        }
        // Confirm HTTPS actually held for the *final* URL — a redirect to plain
        // HTTP would otherwise be followed silently.
        guard response.url?.scheme == "https" else {
            throw OllamaError.installFailed("Installer was not served over HTTPS — refusing to run it.")
        }

        guard let script = String(data: data, encoding: .utf8) else {
            throw OllamaError.installFailed("Installer was not valid text — refusing to run it.")
        }
        // Size bounds catch an error page or a truncated transfer being treated
        // as a script. The real installer is ~10–15 KB.
        guard data.count > 1_000, data.count < 1_000_000 else {
            throw OllamaError.installFailed("Installer had an unexpected size (\(data.count) bytes) — refusing to run it.")
        }
        guard script.hasPrefix("#!") else {
            throw OllamaError.installFailed("Downloaded file is not a shell script — refusing to run it.")
        }

        // Private per-run directory, owned by this user only, so nothing else can
        // swap the script between validation and execution.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("NativAI-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptPath = directory.appendingPathComponent("install.sh")
        try data.write(to: scriptPath, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptPath.path
        )

        emit("Verified installer (\(data.count) bytes). Running…\n")

        let process = Process()
        // Executed directly rather than through `sh -c`, so there is no shell
        // parsing step and nothing to inject into.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            // Uses the same main-actor hop as the status lines above, so there is
            // one path to the UI rather than two with different threading rules.
            emit(line)
        }

        try process.run()

        await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                handle.readabilityHandler = nil
                continuation.resume()
            }
        }

        if process.terminationStatus != 0 {
            // Ollama's official install script tries `sudo ln -sf ... /usr/local/bin/ollama` at the end,
            // which fails without a TTY terminal (exit status 1). However, the app bundle in
            // /Applications/Ollama.app was already fully extracted and installed!
            if isInstalled() {
                emit("✔ Ollama binary installed to /Applications/Ollama.app successfully.\n")
                return
            }
            throw OllamaError.installFailed("Install script exited with status \(process.terminationStatus)")
        }
    }

    /// Starts the Ollama background server (`ollama serve`) if it isn't already running.
    /// Ollama.app normally keeps this running itself; this is a fallback for CLI-only installs.
    /// Locations Ollama's binary may occupy, in probe order.
    ///
    /// `/opt/homebrew` is first because that's where Homebrew installs on Apple
    /// Silicon, which is the majority of target machines. The previous code
    /// hardcoded `/usr/local/bin/ollama` — the Intel Homebrew prefix — so on
    /// every Apple Silicon Mac the launch attempt silently failed (the error was
    /// swallowed by `try?`) and the app reported "Can't reach the local Ollama
    /// server" with no way to recover from inside the UI.
    private static let ollamaBinaryPaths = [
        "/opt/homebrew/bin/ollama",   // Homebrew, Apple Silicon
        "/usr/local/bin/ollama",      // Homebrew on Intel, and the official installer
        "/opt/local/bin/ollama",      // MacPorts
        "/Applications/Ollama.app/Contents/Resources/ollama"  // Ollama.app bundle
    ]

    /// First Ollama binary that actually exists on this machine.
    static func resolveBinaryPath() -> String? {
        ollamaBinaryPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Starts the server if it isn't already listening.
    ///
    /// Returns whether the server is reachable afterwards, so callers can report
    /// a real failure instead of assuming success.
    @discardableResult
    func startServerIfNeeded() async -> Bool {
        if await isServerRunning() { return true }

        // Launch the binary directly first, before trying the launchd service.
        //
        // Ordering matters: `brew services start` writes to
        // ~/Library/LaunchAgents, which fails outright under some sandbox and
        // permission configurations ("Operation not permitted @ apply2files"),
        // whereas spawning the binary needs no special access. Reversing this
        // meant the reliable path was gated behind the fragile one.
        if let binary = Self.resolveBinaryPath() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["serve"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()

            // Poll rather than sleeping a fixed interval: a cold start can take
            // several seconds, and the previous fixed 1.5s wait reported failure
            // while the server was still binding its port.
            for _ in 0..<15 {
                if await isServerRunning() { return true }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }

        // Fall back to the launchd service. Also re-enables it after
        // `stopServer` disabled it, so normal Homebrew-managed operation resumes.
        for brew in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: brew) {
            let service = Process()
            service.executableURL = URL(fileURLWithPath: brew)
            service.arguments = ["services", "start", "ollama"]
            service.standardOutput = FileHandle.nullDevice
            service.standardError = FileHandle.nullDevice
            try? service.run()
            service.waitUntilExit()
            break
        }

        for _ in 0..<10 {
            if await isServerRunning() { return true }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return await isServerRunning()
    }

    /// Unloads any currently-loaded model from memory (the multi-GB RAM
    /// footprint visible in Activity Monitor as a second "ollama" process)
    /// WITHOUT stopping the server itself. Ollama keeps a model loaded after
    /// a chat finishes so the next message answers instantly — calling
    /// generate with keep_alive:0 tells it to unload immediately instead of
    /// waiting for its normal idle timeout. Useful for reclaiming RAM
    /// between sessions without fully shutting Ollama down.
    func unloadAllModels() async {
        for model in (try? await listInstalledModels()) ?? [] {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body = ["model": model.name, "keep_alive": 0] as [String: Any]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// Fully stops the Ollama server process. If it was installed via
    /// Homebrew as a launchd service (`brew services start ollama`), that
    /// service definition is what makes it auto-restart on login/reboot —
    /// this only stops the currently-running process for THIS session, it
    /// does not unregister the launchd service. A user who wants Ollama to
    /// never auto-start again would need `brew services stop ollama`
    /// themselves; we intentionally don't do that automatically since it's a
    /// system-level change beyond just "this app is closing."
    /// Stops the Ollama server this app is responsible for.
    ///
    /// Only targets processes owned by the current user (`pkill -u`). The previous
    /// `pkill -x ollama` matched **every** user's processes, so on a shared or
    /// lab Mac quitting this app would kill a colleague's running Ollama — and on
    /// any machine it would also kill a server the user had deliberately started
    /// in their own Terminal.
    ///
    /// Also stops the Homebrew launchd service when one is managing Ollama.
    /// Without that, launchd immediately restarts the process we just killed,
    /// which looks like the setting silently not working.
    func stopServer() async {
        // Ask the launchd service to stop first, so it doesn't respawn the
        // process. Ignored when Homebrew isn't managing Ollama.
        for brew in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: brew) {
            let service = Process()
            service.executableURL = URL(fileURLWithPath: brew)
            service.arguments = ["services", "stop", "ollama"]
            service.standardOutput = FileHandle.nullDevice
            service.standardError = FileHandle.nullDevice
            try? service.run()
            service.waitUntilExit()
            break
        }

        // Then terminate any remaining server owned by this user. SIGTERM first
        // so it can flush and exit cleanly.
        let uid = String(getuid())
        let terminate = Process()
        terminate.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        terminate.arguments = ["-u", uid, "-x", "ollama"]
        terminate.standardOutput = FileHandle.nullDevice
        terminate.standardError = FileHandle.nullDevice
        try? terminate.run()
        terminate.waitUntilExit()

        // Ollama also spawns a helper ("ollama runner") that holds the model in
        // memory. Killing only the parent can leave that behind holding several
        // GB of RAM — the exact "eating the user's computer in the background"
        // problem this is meant to prevent.
        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        runner.arguments = ["-u", uid, "-f", "ollama runner"]
        runner.standardOutput = FileHandle.nullDevice
        runner.standardError = FileHandle.nullDevice
        try? runner.run()
        runner.waitUntilExit()
    }

    // MARK: - Model listing

    struct InstalledModel: Codable, Identifiable {
        var id: String { name }
        let name: String
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case name, size
        }
    }

    private struct TagsResponse: Codable {
        let models: [InstalledModel]
    }

    func listInstalledModels() async throws -> [InstalledModel] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return decoded.models
    }

    /// Names of models currently loaded in memory, from `/api/ps`.
    ///
    /// Used as a routing signal: a resident model answers immediately, while a
    /// cold one costs a multi-second load and evicts whatever was loaded before.
    /// That load time is the most visible latency in local inference, so
    /// preferring an already-warm model matters more to perceived speed than a
    /// small quality difference the user can't directly observe.
    ///
    /// Returns an empty set on any failure — this is an optimisation hint, and
    /// losing it should degrade ranking slightly, never block a message.
    func residentModelNames() async -> Set<String> {
        let url = baseURL.appendingPathComponent("api/ps")
        var request = URLRequest(url: url)
        // Deliberately short: this sits on the interactive send path, and a
        // slow answer is worth less than the latency it would add.
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data)
        else { return [] }
        return Set(decoded.models.map { $0.name })
    }

    // MARK: - Pull (download/install a model) with streamed progress

    private struct PullRequest: Codable {
        let model: String
        let stream: Bool
    }

    private struct PullStreamLine: Codable {
        let status: String?
        let completed: Int64?
        let total: Int64?
        let error: String?
    }

    /// Streams pull progress via NDJSON from POST /api/pull, calling `onProgress`
    /// for every line received. Throws on network/decode failure OR when
    /// Ollama reports an error line — which it does with HTTP 200 and a
    /// streamed `{"error": "..."}` body (e.g. "pull model manifest: file does
    /// not exist" for a bad/nonexistent model name), NOT a non-200 status
    /// code. Previously this went undetected: `PullStreamLine` required a
    /// `status` field the error line doesn't have, so `try?` decoding
    /// silently failed and the line was skipped via `continue` — meaning a
    /// bad model name just hung forever showing "starting…" instead of ever
    /// completing or erroring.
    func pullModel(named modelName: String, onProgress: @escaping (PullProgress) -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PullRequest(model: modelName, stream: true))

        let (bytes, response) = try await longRunningSession.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.requestFailed("Unexpected status pulling \(modelName)")
        }

        var buffer = Data()
        // Progress updates are coalesced to ~10/sec before touching the main
        // actor.
        //
        // Measured against the live server: pulling x/flux2-klein:4b emits
        // ~9,400 NDJSON lines in 14 seconds (~670/sec) in 8–16 KB increments,
        // because a single 5.7 GB blob is reported at HTTP-chunk granularity.
        // Forwarding every line meant ~670 `MainActor.run` hops per second,
        // each mutating a @Published dictionary and invalidating SwiftUI. That
        // saturates the main thread, so hops queue up and run late: by the time
        // one executes, `Date()` reads the current time while `completedBytes`
        // is already stale, which collapses the computed speed and makes the
        // progress bar stutter. Models like moondream:1.8b send far fewer,
        // larger chunks, which is why they always looked fine.
        //
        // Terminal lines (success/error) are never dropped — only intermediate
        // byte-progress ticks are, and those are pure redraw noise at this rate.
        var lastForwarded = Date.distantPast
        let minimumInterval: TimeInterval = 0.1

        for try await byte in bytes {
            buffer.append(byte)
            guard byte == UInt8(ascii: "\n") else { continue }
            defer { buffer.removeAll(keepingCapacity: true) }
            guard let line = try? JSONDecoder().decode(PullStreamLine.self, from: buffer) else { continue }
            if let error = line.error {
                throw OllamaError.requestFailed(error)
            }
            let progress = PullProgress(
                status: line.status ?? "",
                completedBytes: line.completed ?? 0,
                totalBytes: line.total ?? 0
            )

            // Always forward status changes and completion; throttle the rest.
            let now = Date()
            let isTerminal = progress.isComplete
            guard isTerminal || now.timeIntervalSince(lastForwarded) >= minimumInterval else { continue }
            lastForwarded = now

            await MainActor.run { onProgress(progress) }
        }
    }

    // MARK: - Delete a model

    private struct DeleteRequest: Codable {
        let model: String
    }

    func deleteModel(named modelName: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/delete"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DeleteRequest(model: modelName))

        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.requestFailed("Failed to delete \(modelName)")
        }
    }

    // MARK: - Image generation (POST /api/generate, non-streaming)

    private struct GenerateImageRequest: Codable {
        let model: String
        let prompt: String
        let stream: Bool
    }

    private struct GenerateImageResponse: Codable {
        let response: String?
        let image: String?     // base64-encoded PNG
        let done: Bool?
    }

    /// Generates an image from a text prompt using an image-capable model
    /// (e.g. x/flux2-klein:4b, x/z-image-turbo:fp8). Confirmed live against
    /// Ollama 0.32.5: the response comes back non-streamed with a top-level
    /// `image` field containing a single base64-encoded PNG.
    func generateImage(model: String, prompt: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            GenerateImageRequest(model: model, prompt: prompt, stream: false)
        )
        // Image generation can take a while (model load + inference), especially
        // on the first call, so use the long-running session rather than the
        // default 60s-idle-timeout shared session.
        let (data, response) = try await longRunningSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.requestFailed("Image generation failed for model \(model)")
        }

        let decoded = try JSONDecoder().decode(GenerateImageResponse.self, from: data)
        guard let base64 = decoded.image, let imageData = Data(base64Encoded: base64) else {
            throw OllamaError.requestFailed("No image data returned by \(model)")
        }
        return imageData
    }

    // MARK: - Chat (streamed token generation)

    /// A single chat turn on the wire.
    ///
    /// `nonisolated`/`Sendable` because it is pure data that crosses actor
    /// boundaries constantly — built off the main actor by ConversationDigest and
    /// MemoryStore, consumed by network code. Without this the Xcode target's
    /// default-MainActor-isolation setting infers @MainActor for the type, making
    /// even constructing one from a nonisolated context a Swift 6 error. SPM does
    /// not enable that inference, so it only surfaces in the Xcode build.
    nonisolated struct ChatMessage: Codable, Sendable {
        let role: String   // "user" | "assistant" | "system"
        let content: String
        /// Base64-encoded images attached to this message — Ollama's vision
        /// models (llava, llama3.2-vision, etc.) read these directly, letting
        /// the model actually see an image instead of only ever receiving
        /// text. Omitted from encoding when empty so non-vision requests keep
        /// their exact previous wire format.
        let images: [String]?

        init(role: String, content: String, images: [String]? = nil) {
            self.role = role
            self.content = content
            self.images = (images?.isEmpty ?? true) ? nil : images
        }
    }

    private struct ChatStreamLine: Codable {
        let message: ChatMessage?
        let done: Bool
    }

    // MARK: - Structured (JSON-schema constrained) chat

    /// Runs a NON-streaming chat completion constrained to a JSON Schema,
    /// returning the raw JSON body of the model's reply for the caller to
    /// decode.
    ///
    /// Ollama's `format` parameter accepts a full JSON Schema (verified live
    /// against 0.32.5) and constrains token sampling so the model *cannot*
    /// emit anything but conforming JSON. That's what makes it safe to rely on
    /// a 1.5B model for routing: it can be wrong about the classification, but
    /// it can't return malformed output and crash the parse.
    ///
    /// Uses a dedicated short-timeout session rather than `longRunningSession`
    /// — routing and titling run on the interactive path, so a stuck request
    /// must fail fast and let the caller fall back to heuristics instead of
    /// hanging the send for up to 30 minutes.
    private let structuredSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }()

    func structuredChat(
        model: String,
        messages: [ChatMessage],
        schema: [String: Any],
        maxTokens: Int = 100,
        contextLength: Int? = nil
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Built with JSONSerialization rather than Codable because `schema` is
        // a heterogeneous [String: Any] tree; encoding it through Codable would
        // require a wrapper type per schema shape.
        let encodedMessages: [[String: Any]] = messages.map { message in
            var dict: [String: Any] = ["role": message.role, "content": message.content]
            if let images = message.images { dict["images"] = images }
            return dict
        }
        let body: [String: Any] = [
            "model": model,
            "messages": encodedMessages,
            "stream": false,
            "format": schema,
            // Keep the router warm between turns so repeat classifications
            // don't pay model-load cost on every single message.
            "keep_alive": "10m",
            "options": {
                var options: [String: Any] = [
                    // Deterministic: routing must not vary run-to-run for identical input.
                    "temperature": 0,
                    "num_predict": maxTokens
                ]
                // Routing prompts include recent history, so the same silent
                // truncation that affects chat applies here too — with a worse
                // failure mode, since a router that can't see the turn it's
                // classifying misroutes confidently rather than erroring.
                if let contextLength { options["num_ctx"] = contextLength }
                return options
            }()
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await structuredSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.requestFailed("Structured chat failed for model \(model)")
        }

        struct StructuredResponse: Codable {
            let message: ChatMessage?
        }
        let decoded = try JSONDecoder().decode(StructuredResponse.self, from: data)
        guard let content = decoded.message?.content,
              let contentData = content.data(using: .utf8) else {
            throw OllamaError.requestFailed("Empty structured response from \(model)")
        }
        return contentData
    }

    /// Unloads all currently resident models from RAM except `currentModel`,
    /// preventing RAM over-allocation and macOS NVMe swap freezing on 8GB machines.
    func unloadInactiveModels(except currentModel: String? = nil) async {
        guard let resident = try? await residentModelNames() else { return }
        for name in resident {
            if let currentModel, name == currentModel || name.hasPrefix("\(currentModel):") {
                continue
            }
            var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "model": name,
                "keep_alive": 0
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// Streams a chat completion, calling `onToken` for each incremental chunk of content.
    ///
    /// `contextLength` must be the model's real context window (from
    /// `CapabilityProbe`). It is passed straight through as `num_ctx`, because
    /// Ollama otherwise defaults to a small window (2048–4096) no matter what
    /// the model actually supports, and then silently discards whatever
    /// doesn't fit — no error, no warning, the model simply stops seeing the
    /// oldest turns. That made long conversations degrade invisibly: measured
    /// live, qwen2.5:1.5b reports a 32768-token window but was being run at
    /// roughly an eighth of it.
    ///
    /// Built with JSONSerialization rather than the `ChatRequest` Codable type
    /// because `options` is a heterogeneous dictionary.
    func chat(
        model: String,
        messages: [ChatMessage],
        contextLength: Int,
        keepAliveSeconds: Int? = nil,
        onToken: @escaping (String) -> Void
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encodedMessages: [[String: Any]] = messages.map { message in
            var dict: [String: Any] = ["role": message.role, "content": message.content]
            if let images = message.images { dict["images"] = images }
            return dict
        }
        var body: [String: Any] = [
            "model": model,
            "messages": encodedMessages,
            "stream": true,
            "options": ["num_ctx": contextLength, "num_predict": 4096]
        ]
        if let keepAliveSeconds {
            body["keep_alive"] = keepAliveSeconds == 0 ? 0 : "\(keepAliveSeconds)s"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await longRunningSession.bytes(for: request)
        if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
            var errBuffer = Data()
            for try await byte in bytes { errBuffer.append(byte) }
            if let decoded = try? JSONDecoder().decode(PullStreamLine.self, from: errBuffer), let err = decoded.error {
                throw OllamaError.requestFailed(err)
            } else if let text = String(data: errBuffer, encoding: .utf8), !text.isEmpty {
                throw OllamaError.requestFailed(text)
            }
            throw OllamaError.requestFailed("Chat request failed for model \(model) (HTTP \(httpResp.statusCode))")
        }

        var buffer = Data()
        for try await byte in bytes {
            buffer.append(byte)
            guard byte == UInt8(ascii: "\n") else { continue }
            defer { buffer.removeAll(keepingCapacity: true) }
            guard let line = try? JSONDecoder().decode(ChatStreamLine.self, from: buffer) else { continue }
            if let content = line.message?.content, !content.isEmpty {
                await MainActor.run { onToken(content) }
            }
            if line.done { break }
        }
    }
}
