import Combine
import CoreGraphics
import Foundation
import SwiftyBeaver

/// Runs prerequisite checks on every launch in sequence:
/// Input Monitoring → WhisperKit model → Ollama health.
///
/// Each step publishes its status so Phase 7's FirstRunView can
/// later wrap the sequence with user-facing onboarding UI.
@MainActor
final class AppInitializer: ObservableObject {

    // MARK: - Step model

    enum Step: String, CaseIterable, Sendable {
        case inputMonitoring
        case whisperKit
        case ollama
    }

    enum StepStatus: Sendable {
        case pending
        case inProgress
        case ready
        case failed(String)
    }

    @Published private(set) var steps: [Step: StepStatus] = {
        var dict = [Step: StepStatus]()
        for step in Step.allCases { dict[step] = .pending }
        return dict
    }()

    @Published private(set) var currentStep: Step?

    /// True when all critical prerequisites are met.
    /// Ollama is non-critical (app works without it via raw transcription fallback).
    var isReady: Bool {
        guard case .ready = steps[.inputMonitoring] else { return false }
        guard case .ready = steps[.whisperKit] else { return false }
        return true
    }

    // MARK: - Run

    /// Execute the full initialization sequence.
    /// Call once from AppDelegate after subsystems and UI are created.
    func run(
        settings: SettingsService,
        hotkey: HotkeyManager,
        transcriber: any Transcribing,
        formatter: any Formatting,
        orchestrator: PipelineOrchestrator
    ) async {
        // Step 1: Input Monitoring
        await runStep(.inputMonitoring) {
            if !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
                throw InitError.message("Input Monitoring permission requested. Grant it in System Settings — the hotkey activates automatically once granted.")
            }
            let granted = hotkey.start()
            if !granted {
                throw InitError.message("Event tap creation failed despite Input Monitoring permission being granted.")
            }
        }
        if case .failed = steps[.inputMonitoring], !CGPreflightListenEventAccess() {
            pollInputMonitoring(hotkey: hotkey)
        }

        // Step 2: WhisperKit model download + load
        await runStep(.whisperKit) {
            let modelName = settings.whisperModel
            let model = WhisperModel(rawValue: modelName) ?? .default
            try await transcriber.setup(model: model)
            orchestrator.modelReady = true
        }

        // Step 3: Ollama health (non-critical — failure doesn't block the app)
        await runStep(.ollama) {
            await orchestrator.checkOllamaHealth()
            if !orchestrator.ollamaAvailable {
                throw InitError.message("Ollama not reachable. Formatting will be skipped — raw transcription will be used.")
            }
        }

        // Preload Ollama model into VRAM in background (non-blocking),
        // but only if at least one formatting context is enabled.
        if orchestrator.ollamaAvailable &&
           (settings.formatGeneral || settings.formatEmail) {
            Task { await formatter.warmup() }
        }
    }

    // MARK: - Private

    private var inputMonitoringPollTask: Task<Void, Never>?

    /// The permission is often lost after an update (TCC re-keys the binary)
    /// and users rarely restart the app after re-granting it. Keep checking
    /// and install the event tap as soon as access appears.
    private func pollInputMonitoring(hotkey: HotkeyManager) {
        inputMonitoringPollTask?.cancel()
        log.info("Input Monitoring not granted — polling for permission grant")
        inputMonitoringPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard CGPreflightListenEventAccess() else { continue }
                if hotkey.start() {
                    self?.steps[.inputMonitoring] = .ready
                    log.info("Init step [inputMonitoring] ready (granted after launch)")
                } else {
                    let message = "Event tap creation failed despite Input Monitoring permission being granted. Restart the app."
                    self?.steps[.inputMonitoring] = .failed(message)
                    log.warning("[inputMonitoring] \(message)")
                }
                return
            }
        }
    }

    private func runStep(_ step: Step, action: () async throws -> Void) async {
        currentStep = step
        steps[step] = .inProgress
        log.info("Init step [\(step.rawValue)] started")

        do {
            try await action()
            steps[step] = .ready
            log.info("Init step [\(step.rawValue)] ready")
        } catch {
            let message = (error as? InitError)?.description ?? error.localizedDescription
            steps[step] = .failed(message)
            log.warning("[\(step.rawValue)] \(message)")
        }
    }
}

private enum InitError: Error {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}
