import Combine
import Foundation
import SwiftyBeaver

/// Central coordinator that wires the four subsystems together and drives the
/// state machine. All public methods and state mutations run on @MainActor to
/// serialize access — this eliminates race conditions between hotkey callbacks,
/// async processing, and UI observation.
@MainActor
final class PipelineOrchestrator: ObservableObject {
    @Published private(set) var state: PipelineState = .idle

    // MARK: - Subsystems (protocol-typed for swappability)

    let settings: SettingsService
    private let recorder: any AudioRecording
    private let transcriber: any Transcribing
    private let contextDetector: any ContextDetecting
    private let formatter: any Formatting
    let clipboard: ClipboardManager

    /// The context captured at Fn key-down, used when processing completes.
    @Published private(set) var detectedContext: FormatContext = .general

    /// Preferred transcription language (nil = auto-detect).
    var preferredLanguage: Language? = .german

    /// How the formatted output is delivered: clipboard-only or auto-paste.
    var outputMode: OutputMode = .clipboard

    /// When true, checks the focused element before pasting; falls back to clipboard
    /// only when a text field is confirmed absent. Unknown roles (browsers) defer to outputMode.
    var smartPaste: Bool = false

    /// Whether the transcription model has finished loading.
    /// Recording is blocked until this is true.
    @Published var modelReady = false

    /// Whether the transcription model is currently being switched.
    @Published var modelLoading = false

    /// Whether the Ollama backend is reachable.
    /// Optimistic default: assume Ollama is up. If formatting fails, this
    /// flips to false and skips Ollama on subsequent recordings until the
    /// periodic health check restores it.
    @Published private(set) var ollamaAvailable = true

    /// Model names available on the Ollama backend, for the preferences picker.
    @Published var availableModels: [String] = []

    // MARK: - In-flight work

    /// The current processing task. Stored so it can be cancelled on discard
    /// or when a new recording starts before processing finishes.
    private var processingTask: Task<Void, Never>?

    /// Subscriptions for reacting to settings changes (e.g. formatting toggles).
    private var cancellables = Set<AnyCancellable>()

    /// Timer that updates the recording duration for the UI.
    private var durationTimer: Timer?
    private var recordingStartTime: Date?

    /// Reference to the hotkey manager, needed to set `recordingLocked`.
    private weak var hotkeyManager: HotkeyManager?

    // MARK: - Init

    init(
        settings: SettingsService,
        recorder: any AudioRecording,
        transcriber: any Transcribing,
        contextDetector: any ContextDetecting,
        formatter: any Formatting,
        clipboard: ClipboardManager
    ) {
        self.settings = settings
        self.recorder = recorder
        self.transcriber = transcriber
        self.contextDetector = contextDetector
        self.formatter = formatter
        self.clipboard = clipboard

        // Unload the Ollama model when all formatting is disabled;
        // re-warm it when at least one context is re-enabled.
        settings.$formatGeneral
            .combineLatest(settings.$formatEmail)
            .map { $0 || $1 }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] anyEnabled in
                guard let self else { return }
                if anyEnabled {
                    Task { await self.formatter.warmup() }
                } else {
                    Task { await self.formatter.unload() }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Hotkey-triggered actions

    /// Called on Fn key-down. Detects context and starts recording.
    func handleRecordStart() {
        guard modelReady else {
            log.warning("Fn pressed but model not ready")
            state = .error("Warming up…")
            return
        }

        // Don't cancel in-flight transcription from accidental hotkey re-press.
        if case .processing = state {
            log.info("Fn pressed during processing — ignoring")
            return
        }

        // Cancel any in-flight processing from a previous recording.
        cancelProcessing()

        detectedContext = contextDetector.detectContext()
        log.info("Fn down — context=\(detectedContext.rawValue), starting recording")

        let handsFree = settings.handsFreeRecording
        recordingStartTime = Date()
        state = .recording(duration: 0, audioLevel: 0, locked: handsFree)
        if handsFree { hotkeyManager?.recordingLocked = true }
        startDurationTimer()

        Task {
            do {
                try await recorder.startRecording()
                log.info("Recorder started")
            } catch {
                stopDurationTimer()
                log.error("Recorder failed: \(error)")
                state = .error("Microphone access failed.")
            }
        }

        // Pre-warm Ollama model into VRAM while recording (GPU + ANE don't compete),
        // but only if formatting is enabled for the detected context.
        let shouldWarmup = detectedContext == .email ? settings.formatEmail : settings.formatGeneral
        if shouldWarmup {
            Task { await formatter.warmup() }
        }
    }

    /// Called on Fn key-up. Stops recording and kicks off the
    /// transcribe → format → copy pipeline.
    func handleRecordStop() {
        hotkeyManager?.recordingLocked = false
        stopDurationTimer()

        // Capture context before entering the async task — it won't change.
        let context = detectedContext

        processingTask = Task {
            let pipelineStart = CFAbsoluteTimeGetCurrent()
            log.info("Fn up — stopping recorder")
            let audio = await recorder.stopRecording()
            log.info("Recorder stopped. Samples: \(audio.count) (\(String(format: "%.1f", Double(audio.count) / 16000))s audio)")

            // Empty buffer means < 0.5s recording (accidental press).
            guard !audio.isEmpty else {
                log.info("Empty buffer — ignoring")
                state = .idle
                return
            }

            state = .processing

            do {
                log.info("Transcribing (lang=\(preferredLanguage?.rawValue ?? "auto"))...")
                let t0 = CFAbsoluteTimeGetCurrent()
                let transcription = try await transcriber.transcribe(
                    audio: audio,
                    language: preferredLanguage
                )
                let t1 = CFAbsoluteTimeGetCurrent()
                log.info("Transcription done in \(String(format: "%.1f", t1 - t0))s [lang=\(transcription.language.rawValue)]")
                log.verbose("  RAW: \"\(transcription.text)\"")

                let f0 = CFAbsoluteTimeGetCurrent()
                let formatted = await formatWithFallback(
                    transcription: transcription,
                    context: context
                )
                let f1 = CFAbsoluteTimeGetCurrent()
                let elapsed = f1 - f0
                if formatted == transcription.text {
                    log.info("Formatting skipped")
                } else {
                    log.info("Formatting done in \(String(format: "%.1f", elapsed))s")
                }
                log.verbose("  OUTPUT: \"\(formatted)\"")

                // Check we weren't cancelled (e.g. by a discard or new recording).
                guard !Task.isCancelled else { return }

                var pasted = false
                var smartPasteFallback = false

                // Smart paste only applies to .paste mode: only paste when a text field is
                // confirmed present. Both .denied (no editable element) and .unknown (role
                // unrecognized — e.g. Finder browser, VS Code file tree) fall back to clipboard.
                // WebKit and VS Code's code editor both expose real AX text roles, so .confirmed
                // correctly covers those cases.
                // .clipboardAndPaste always keeps text on clipboard so no fallback needed.
                let detection: TextFieldDetectionResult = smartPaste && self.outputMode == .paste
                    ? clipboard.detectFocusedTextField()
                    : .confirmed

                switch (self.outputMode, detection) {
                case (.paste, .confirmed):
                    pasted = await clipboard.copyAndPaste(text: formatted)
                case (.paste, _):
                    clipboard.copy(text: formatted)
                    smartPasteFallback = true
                case (.clipboardAndPaste, _):
                    pasted = await clipboard.copyAndPasteKeeping(text: formatted)
                case (.clipboard, _):
                    clipboard.copy(text: formatted)
                }

                let keptOnClipboard = self.outputMode == .clipboardAndPaste
                    || self.outputMode == .clipboard
                    || smartPasteFallback
                let total = CFAbsoluteTimeGetCurrent() - pipelineStart
                log.info("\(pasted ? "Pasted" : "Copied to clipboard") — total pipeline: \(String(format: "%.1f", total))s")
                state = .result(FormattedOutput(text: formatted, context: context, pasted: pasted, keptOnClipboard: keptOnClipboard, smartPasteFallback: smartPasteFallback))

            } catch is CancellationError {
                log.info("Cancelled")
                return
            } catch let error as TranscriberError where error == .noSpeechDetected {
                log.info("No speech detected")
                state = .error("No speech detected.")
            } catch {
                log.error("Error: \(error)")
                state = .error(error.localizedDescription)
            }
        }
    }

    /// Called on Escape while Fn is held. Discards the recording entirely.
    func handleDiscard() {
        log.info("Discard — cancelling recording")
        hotkeyManager?.recordingLocked = false
        cancelProcessing()
        stopDurationTimer()

        // Stop the recorder and throw away the buffer.
        Task { _ = await recorder.stopRecording() }

        state = .idle
    }

    /// Called when L is pressed during recording. Locks hands-free mode so
    /// the user can release the hotkey and keep recording.
    func handleRecordLock() {
        guard case .recording(let duration, let audioLevel, let locked) = state,
              !locked else { return }
        log.info("Recording locked — hands-free mode")
        state = .recording(duration: duration, audioLevel: audioLevel, locked: true)
        hotkeyManager?.recordingLocked = true
    }

    /// Restore the previous clipboard content (called from the result preview).
    func undoLastCopy() {
        log.info("Undo last copy")
        clipboard.undo()
        state = .idle
    }

    /// Dismiss the result or error panel, returning to idle.
    func dismissResult() {
        guard case .result = state else {
            if case .error = state { state = .idle }
            return
        }
        state = .idle
    }

    // MARK: - Model switching

    /// Switch to a different Whisper model at runtime.
    func switchWhisperModel(_ model: WhisperModel) async {
        modelReady = false
        modelLoading = true
        do {
            try await transcriber.switchModel(model)
            modelReady = true
        } catch {
            log.error("Model switch failed: \(error)")
            state = .error("Failed to load model: \(error.localizedDescription)")
        }
        modelLoading = false
    }

    // MARK: - Ollama health

    /// Check whether the Ollama backend is reachable and update the flag.
    func checkOllamaHealth() async {
        let was = ollamaAvailable
        ollamaAvailable = await formatter.healthCheck()
        if was != ollamaAvailable {
            log.info("Ollama availability changed: \(was) → \(ollamaAvailable)")
        }
    }

    /// Refresh the list of models available on the Ollama backend.
    func refreshAvailableModels() async {
        availableModels = await formatter.fetchModels()
    }

    // MARK: - Hotkey wiring

    /// Pause the hotkey event tap (e.g. during hotkey recording in preferences).
    func pauseHotkey() {
        hotkeyManager?.paused = true
    }

    /// Resume the hotkey event tap after recording.
    func resumeHotkey() {
        hotkeyManager?.paused = false
    }

    /// Connect HotkeyManager callbacks to this orchestrator.
    func wire(hotkey: HotkeyManager) {
        log.info("Wiring hotkey callbacks to orchestrator")
        self.hotkeyManager = hotkey
        hotkey.onRecordStart = { [weak self] in self?.handleRecordStart() }
        hotkey.onRecordStop = { [weak self] in self?.handleRecordStop() }
        hotkey.onRecordLock = { [weak self] in self?.handleRecordLock() }
        hotkey.onDiscard = { [weak self] in self?.handleDiscard() }
    }

    // MARK: - Private helpers

    /// Attempt Ollama formatting; on any failure, return the raw transcription.
    private func formatWithFallback(
        transcription: Transcription,
        context: FormatContext
    ) async -> String {
        // Check if formatting is enabled for this context.
        let formatEnabled = context == .email ? settings.formatEmail : settings.formatGeneral
        guard formatEnabled else {
            log.info("Formatting disabled for \(context.rawValue) — returning raw transcription")
            return transcription.text
        }

        // Skip Ollama entirely if we already know it's unreachable.
        guard ollamaAvailable else {
            log.warning("Ollama unavailable — returning raw transcription")
            return transcription.text
        }

        do {
            var result = ""
            log.info("Ollama streaming started")
            let stream = formatter.format(
                transcription: transcription.text,
                context: context,
                language: preferredLanguage ?? transcription.language
            )
            for try await token in stream {
                try Task.checkCancellation()
                result += token
            }
            log.info("Ollama streaming complete — \(result.count) chars")
            return result.isEmpty ? transcription.text : result
        } catch is CancellationError {
            log.info("Ollama cancelled")
            return transcription.text
        } catch {
            log.error("Ollama error: \(error) — falling back to raw")
            ollamaAvailable = false
            return transcription.text
        }
    }

    private func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
    }

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let start = self.recordingStartTime else { return }
                let locked: Bool
                if case .recording(_, _, let isLocked) = self.state {
                    locked = isLocked
                } else {
                    locked = false
                }
                self.state = .recording(
                    duration: Date().timeIntervalSince(start),
                    audioLevel: self.recorder.audioLevel,
                    locked: locked
                )
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil
    }
}