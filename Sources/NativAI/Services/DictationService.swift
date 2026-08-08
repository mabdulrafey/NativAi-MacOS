/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import Foundation
import AVFoundation
import Speech
import Combine

/// On-device speech-to-text for the chat composer.
///
/// This is dictation, not a voice assistant: audio becomes text in the input box,
/// the user reviews it, and sends when ready. The model never sees audio, so there
/// is no TTS, no interruption handling and no latency budget to meet — which is
/// what makes it a small, dependable feature rather than a speech-to-speech
/// pipeline that local models can't currently deliver convincingly.
///
/// **Privacy is enforced, not requested.** `SFSpeechRecognizer` will happily send
/// audio to Apple's servers when an on-device model isn't available for the user's
/// locale, and it does so silently. For an app whose entire premise is that
/// nothing leaves the machine, a silent network fallback would be a broken
/// promise the user can't detect. So this refuses to run unless
/// `supportsOnDeviceRecognition` is true, and says so plainly instead.
///
/// Uses Apple's built-in frameworks rather than Whisper + Piper deliberately:
/// zero extra download, no Python runtime, and the app keeps its property of
/// linking nothing but OS-provided libraries.
@MainActor
final class DictationService: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        /// Terminal, user-visible failure. The message is shown in the UI.
        case unavailable(String)
    }

    @Published private(set) var state: State = .idle
    /// Live transcript for the current utterance, updated as the user speaks.
    @Published private(set) var partialTranscript: String = ""

    var isListening: Bool { state == .listening }

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Text present in the composer when dictation started.
    ///
    /// Kept so the transcript is *appended* rather than replacing what the user
    /// already typed — silently destroying typed text would be a far worse
    /// outcome than a slightly awkward join.
    private var textAtStart: String = ""

    /// Utterances already finalised during this dictation session.
    ///
    /// On-device recognition finalises **per utterance**: a pause ends the
    /// current segment, and the next one arrives with a `formattedString` that
    /// starts over rather than continuing. Without accumulating here, each pause
    /// caused the previous sentence to be overwritten — the reported "if I take a
    /// gap between speaking it erases it".
    private var committedTranscript: String = ""

    /// Set while tearing down, so late callbacks can't clobber the draft.
    ///
    /// `task.cancel()` delivers one final callback whose result is empty. Emitting
    /// that produced `textAtStart` with no transcript, which wiped everything the
    /// user had just dictated — the reported "clicking the microphone erases what
    /// I said".
    private var isStopping = false

    /// Called with the full composed text (original + transcript) on each update.
    private var onUpdate: ((String) -> Void)?

    /// Whether dictation can be offered at all on this machine.
    ///
    /// Checked before showing the mic button, so an unsupported locale results in
    /// no button rather than a button that always errors.
    static var isSupported: Bool {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    /// Starts listening, appending recognised text to `existingText`.
    func start(existingText: String, onUpdate: @escaping (String) -> Void) {
        guard state == .idle || isFailed else { return }

        self.textAtStart = existingText
        self.onUpdate = onUpdate
        self.partialTranscript = ""
        self.committedTranscript = ""
        self.isStopping = false
        state = .requestingPermission

        Task { @MainActor in
            let speechGranted = await Self.requestSpeechAuthorization()
            guard speechGranted else {
                self.state = .unavailable(
                    "Speech recognition is turned off for NativAI. Enable it in System Settings › Privacy & Security › Speech Recognition."
                )
                return
            }

            let micGranted = await Self.requestMicrophoneAccess()
            guard micGranted else {
                self.state = .unavailable(
                    "Microphone access is off for NativAI. Enable it in System Settings › Privacy & Security › Microphone."
                )
                return
            }

            self.beginRecognition()
        }
    }

    private static func requestSpeechAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status == .denied || status == .restricted { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { newStatus in
                continuation.resume(returning: newStatus == .authorized)
            }
        }
    }

    /// Requests microphone access, checking status first to avoid repeated OS prompts.
    private static func requestMicrophoneAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return true }
        if status == .denied || status == .restricted { return false }
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
    }

    private func beginRecognition() {
        // Prefer the user's own locale, falling back to en-US so a machine set to
        // an unsupported language still works rather than silently offering
        // nothing.
        let candidate = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

        guard let recognizer = candidate, recognizer.isAvailable else {
            state = .unavailable("Speech recognition isn't available right now.")
            return
        }
        // The privacy gate. Without an on-device model, SFSpeechRecognizer streams
        // audio to Apple — so refuse rather than break the offline guarantee.
        guard recognizer.supportsOnDeviceRecognition else {
            state = .unavailable(
                "On-device dictation isn't available for \(Locale.current.identifier). "
                    + "NativAI won't send your voice to a server, so dictation is disabled."
            )
            return
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        // Belt and braces: even having checked support, this forbids the network
        // path outright so a framework change can't quietly re-enable it.
        request.requiresOnDeviceRecognition = true
        // Live partial results are what make this feel like system dictation
        // rather than a recorder that reveals its output at the end.
        request.shouldReportPartialResults = true
        // Punctuation from speech ("period", pauses) — otherwise transcripts
        // arrive as one long run-on sentence.
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        self.request = request

        setupAudioEngineObservers()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // A zero sample rate means no usable input device (no mic, or it was
        // unplugged). Installing a tap with that format throws an exception
        // rather than returning an error.
        guard format.sampleRate > 0 else {
            state = .unavailable("No microphone was found.")
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cleanUpAudio()
            state = .unavailable("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                // Ignore anything arriving after stop() began. cancel() delivers a
                // final empty callback, and acting on it would publish a transcript
                // of "" and erase the user's text.
                guard !self.isStopping else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                    self.partialTranscript = text
                    self.onUpdate?(self.composedText)

                    // A finalised segment ends this utterance. Fold it into the
                    // committed text and clear the live buffer, so the *next*
                    // utterance (after a pause) extends the transcript instead of
                    // replacing it.
                    if result.isFinal {
                        self.commitCurrentUtterance()
                        // Recognition of this segment is over, but the user may
                        // still be talking — restart to keep listening rather than
                        // ending the session at the first pause.
                        self.restartRecognitionSegment()
                        return
                    }
                }

                if let error {
                    if self.isBenignError(error) {
                        self.commitCurrentUtterance()
                        self.restartRecognitionSegment()
                    } else {
                        self.finish(commit: true)
                    }
                }
            }
        }

        state = .listening
    }

    /// Moves the live transcript into the committed buffer without mutating textAtStart.
    private func commitCurrentUtterance() {
        let spoken = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spoken.isEmpty {
            committedTranscript = committedTranscript.isEmpty
                ? spoken
                : committedTranscript + " " + spoken
            partialTranscript = ""
        }
    }

    private func isBenignError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let domain = nsError.domain
        let code = nsError.code
        let isAssistantSilence = (domain == "kAFAssistantErrorDomain" || domain == "kkAFAssistantErrorDomain") && [203, 209, 216, 1110].contains(code)
        let isSpeechSilence = (domain == "SFSpeechErrorDomain" || domain == "kSFSpeechErrorDomain") && [1, 203, 209, 216, 1700].contains(code)
        return isAssistantSilence || isSpeechSilence
    }

    /// Starts a fresh recognition request while keeping the audio engine running.
    private func restartRecognitionSegment() {
        guard state == .listening, !isStopping, let recognizer else { return }

        task?.cancel()
        task = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        guard format.sampleRate > 0 else {
            finish(commit: true)
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, !self.isStopping else { return }
                if let result {
                    self.partialTranscript = result.bestTranscription.formattedString
                    self.onUpdate?(self.composedText)
                    if result.isFinal {
                        self.commitCurrentUtterance()
                        self.restartRecognitionSegment()
                        return
                    }
                }
                if let error {
                    if self.isBenignError(error) {
                        self.commitCurrentUtterance()
                        self.restartRecognitionSegment()
                    } else {
                        self.finish(commit: true)
                    }
                }
            }
        }
    }

    /// Original composer text plus everything dictated so far.
    ///
    /// Three parts joined with single spaces, skipping empties so dictating into
    /// an empty box produces no leading whitespace: what the user had typed, the
    /// Original composer text plus everything dictated so far.
    ///
    /// Prevents sentence duplication if the user repeats what was already in the draft box.
    private var composedText: String {
        let start = textAtStart.trimmingCharacters(in: .whitespacesAndNewlines)
        let committed = committedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let partial = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        let liveDictation = [committed, partial].filter { !$0.isEmpty }.joined(separator: " ")
        if start.isEmpty {
            return liveDictation
        }
        if liveDictation.isEmpty {
            return start
        }
        // If the live dictation repeats or matches start text, do not duplicate
        if start == liveDictation || start.hasSuffix(liveDictation) {
            return start
        }
        if liveDictation.hasPrefix(start) {
            return liveDictation
        }
        return start + " " + liveDictation
    }

    /// Stops listening and keeps whatever was transcribed.
    func stop() {
        guard isListening else { return }
        // Commit the in-flight utterance *before* tearing anything down. The old
        // ordering called finish() immediately, and the cancel() callback then
        // published an empty transcript — which is what erased the user's speech
        // when they tapped the mic button instead of send.
        commitCurrentUtterance()
        finish(commit: true)
    }

    /// Tears down recognition.
    ///
    /// - Parameter commit: whether to publish the accumulated text one last time.
    ///   Always true in practice; the parameter documents that the final emit is a
    ///   deliberate step rather than an accident of teardown ordering.
    private func finish(commit: Bool) {
        // Latch first so any callback the cancellation triggers is ignored.
        isStopping = true

        request?.endAudio()
        cleanUpAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil

        if commit {
            let final = composedText
            // Only publish when something was actually captured, so a mic tap with
            // no speech leaves the existing draft untouched.
            if !final.isEmpty { onUpdate?(final) }
        }

        partialTranscript = ""
        committedTranscript = ""
        onUpdate = nil
        isStopping = false
        if case .unavailable = state {} else { state = .idle }
    }

    private func cleanUpAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// Clears a terminal error so the mic button becomes usable again after the
    /// user has fixed permissions in System Settings.
    func dismissError() {
        if case .unavailable = state { state = .idle }
    }

    private var isFailed: Bool {
        if case .unavailable = state { return true }
        return false
    }

    private var configChangeObserver: NSObjectProtocol?

    private func setupAudioEngineObservers() {
        if configChangeObserver == nil {
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: audioEngine,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleAudioRouteDisconnect()
                }
            }
        }
    }

    private func handleAudioRouteDisconnect() {
        guard state == .listening else { return }
        stop()
        state = .unavailable("Microphone configuration changed or disconnected.")
    }
}
