import Foundation

/// Supported languages for transcription and formatting.
/// Raw values are ISO 639-1 codes expected by WhisperKit and Ollama.
enum Language: String, Sendable, CaseIterable {
    case german = "de"
    case english = "en"
}

/// The detected communication context based on the active application.
enum FormatContext: String, Sendable {
    case email
    case general
}

/// Raw transcription output from WhisperKit.
struct Transcription: Sendable {
    let text: String
    let language: Language
}

/// Formatted text produced by the LLM.
struct FormattedOutput: Sendable {
    let text: String
    let context: FormatContext
    let pasted: Bool
    let keptOnClipboard: Bool
    let smartPasteFallback: Bool
}

/// How the formatted output is delivered to the user.
enum OutputMode: String, Sendable, CaseIterable {
    case clipboard = "clipboard"
    case paste = "paste"
    case clipboardAndPaste = "clipboardAndPaste"
}

/// Result of checking whether the focused UI element can accept pasted text.
enum TextFieldDetectionResult: Sendable {
    case confirmed   // known editable AX role — safe to paste
    case denied      // confirmed non-editable or no focused element — skip paste
    case unknown     // unrecognized role (Finder browser, VS Code file tree, etc.) — skip paste
}

/// Available Whisper model variants for on-device transcription.
/// English-only variants excluded (German support needed).
enum WhisperModel: String, CaseIterable, Sendable, Identifiable {
    case tiny = "tiny"
    case base = "base"
    case small = "small"
    case largeTurbo = "large-v3_turbo"

    var id: String { rawValue }

    static let `default`: WhisperModel = .small

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .largeTurbo: return "Large V3 Turbo"
        }
    }

    var sizeDescription: String {
        switch self {
        case .tiny: return "~75 MB"
        case .base: return "~140 MB"
        case .small: return "~460 MB"
        case .largeTurbo: return "~1.6 GB"
        }
    }
}

/// Progress update from an Ollama model pull operation.
struct PullProgress: Sendable {
    let status: String
    let completed: Int64?
    let total: Int64?
}

/// The current state of the processing pipeline, observed by the UI.
enum PipelineState: Sendable {
    case idle
    case recording(duration: TimeInterval, audioLevel: Float, locked: Bool)
    case processing
    case result(FormattedOutput)
    case error(String)

    /// Stable identifier for the current case, used to drive SwiftUI animations
    /// when the state changes between cases (ignoring associated values).
    var discriminator: Int {
        switch self {
        case .idle: return 0
        case .recording: return 1
        case .processing: return 2
        case .result: return 3
        case .error: return 4
        }
    }
}