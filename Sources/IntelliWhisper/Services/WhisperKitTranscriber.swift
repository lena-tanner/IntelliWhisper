import Foundation
import SwiftyBeaver
import WhisperKit

/// Transcribes audio using WhisperKit with a locally cached Core ML model.
final class WhisperKitTranscriber: Transcribing, @unchecked Sendable {
    private var whisperKit: WhisperKit?

    /// Base directory for the HuggingFace download cache.
    /// Models end up in a subfolder like `models/argmaxinc/whisperkit-coreml/openai_whisper-small/`.
    private static let downloadBase: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("IntelliWhisper/Models")
    }()

    /// Folder for a model variant that WhisperKit has already downloaded, or nil.
    /// Checked so a launch without network (e.g. login before Wi-Fi is up) can
    /// load from disk instead of failing on the HuggingFace API round-trip.
    private static func cachedModelFolder(for model: WhisperModel) -> URL? {
        let folder = downloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent("openai_whisper-\(model.rawValue)")
        let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "config.json"]
        let fm = FileManager.default
        guard required.allSatisfy({ fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) else {
            return nil
        }
        return folder
    }

    private static func makeConfig(model: WhisperModel, localFolder: URL?) -> WhisperKitConfig {
        let config = WhisperKitConfig()
        config.model = model.rawValue
        config.downloadBase = downloadBase
        // Keep the tokenizer next to the models. WhisperKit's default is
        // ~/Documents/huggingface, which macOS guards with a Files & Folders
        // permission we never request — on Tahoe the read is denied and model
        // setup fails with "config.json couldn't be opened".
        config.tokenizerFolder = downloadBase
        config.modelFolder = localFolder?.path
        config.download = localFolder == nil
        config.prewarm = true
        config.load = true
        config.verbose = true
        return config
    }

    /// Initialize WhisperKit with the given model, downloading on first use.
    /// A complete cached download is loaded directly from disk without
    /// contacting HuggingFace; if that fails, fall back to a fresh download.
    func setup(model: WhisperModel) async throws {
        log.info("Loading model: \(model.rawValue)")

        if let cached = Self.cachedModelFolder(for: model) {
            do {
                whisperKit = try await WhisperKit(Self.makeConfig(model: model, localFolder: cached))
                log.info("Model \(model.rawValue) loaded from cache")
                return
            } catch {
                log.warning("Cached model \(model.rawValue) failed to load — retrying with download: \(error.localizedDescription)")
            }
        }

        whisperKit = try await WhisperKit(Self.makeConfig(model: model, localFolder: nil))
        log.info("Model \(model.rawValue) loaded successfully")
    }

    /// Switch to a different model at runtime.
    func switchModel(_ model: WhisperModel) async throws {
        log.info("Switching model to \(model.rawValue)")
        whisperKit = nil
        try await setup(model: model)
    }

    /// Transcribe audio samples.
    /// - Parameters:
    ///   - audio: 16kHz mono Float32 samples.
    ///   - language: Preferred language, or nil for auto-detection.
    /// - Returns: The transcription with text and detected language.
    func transcribe(audio: [Float], language: Language?) async throws -> Transcription {
        guard let kit = whisperKit else {
            log.error("Transcribe called but model not initialized")
            throw TranscriberError.notInitialized
        }

        // Read vocabulary from UserDefaults (non-MainActor safe pattern)
        let namesJSON = UserDefaults.standard.string(forKey: SettingsService.Keys.vocabularyNames)
        let keywordsJSON = UserDefaults.standard.string(forKey: SettingsService.Keys.vocabularyKeywords)
        let names = namesJSON.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        let keywords = keywordsJSON.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []

        // Build prompt tokens if vocabulary is configured
        let promptTokens: [Int]?
        let prompt = VocabularyPromptBuilder.buildPrompt(names: names, keywords: keywords)
        if !prompt.isEmpty, let tokenizer = kit.tokenizer {
            promptTokens = tokenizer.encode(text: prompt)
            log.info("Vocabulary prompt (\(promptTokens!.count) tokens): \(prompt.prefix(80))")
        } else {
            promptTokens = nil
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: language?.rawValue,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            withoutTimestamps: true,
            promptTokens: promptTokens,
            chunkingStrategy: .vad
        )

        let results: [TranscriptionResult] = try await kit.transcribe(
            audioArray: audio,
            decodeOptions: options
        )

        guard !results.isEmpty else {
            throw TranscriberError.noSpeechDetected
        }

        let combinedText = results.map { $0.text }.joined(separator: " ")
        let trimmed = combinedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw TranscriberError.noSpeechDetected
        }

        let detectedLanguage = Language(rawValue: results[0].language) ?? .german

        return Transcription(
            text: trimmed,
            language: detectedLanguage
        )
    }
}

enum TranscriberError: Error, LocalizedError {
    case notInitialized
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WhisperKit has not been initialized. Call setup() first."
        case .noSpeechDetected:
            return "No speech detected."
        }
    }
}