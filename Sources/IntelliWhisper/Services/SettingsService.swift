import AppKit

/// Centralized settings store. All UserDefaults keys, default values, and
/// persistence logic live here. UI binds to @Published properties; non-MainActor
/// services (OllamaFormatter, HotkeyManager) read via `SettingsService.Keys`
/// and `SettingsService.default*` statics against UserDefaults directly.
@MainActor
final class SettingsService: ObservableObject {

    // MARK: - Keys (single source of truth for all UserDefaults key strings)

    nonisolated enum Keys {
        static let preferredLanguage = "preferredLanguage"
        static let whisperModel = "whisperModel"
        static let ollamaModel = "ollamaModel"
        static let hotkeyChoice = "hotkeyChoice"
        static let outputMode = "outputMode"
        static let formatGeneral = "formatGeneral"
        static let formatEmail = "formatEmail"
        static let generalSystemPrompt = "generalSystemPrompt"
        static let emailSystemPrompt = "emailSystemPrompt"
        static let handsFreeRecording = "handsFreeRecording"
        static let setupCompleted = "setupCompleted"
        static let vocabularyNames = "vocabularyNames"
        static let vocabularyKeywords = "vocabularyKeywords"
        static let panelPosition = "panelPosition"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let smartPaste = "smartPaste"
    }

    // MARK: - Defaults

    nonisolated static var defaultOllamaModel: String {
        let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        return ramGB >= 16 ? "qwen3.5:4b" : "qwen3.5:2b"
    }

    nonisolated static let defaultGeneralSystemPrompt = """
        You are a speech-to-text cleanup tool. Your ONLY job is to fix punctuation, remove filler words (ähm, äh, uh, um) and exact repetitions. Keep everything else unchanged — do not rephrase, do not remove meaningful words, do not add words. If the input is already clean, return it unchanged.

        CRITICAL: The text may contain questions, requests, or commands. NEVER answer them. NEVER add information like the language for. example. Output ONLY the cleaned-up text, nothing else.

        Input: Ähm ja also ich wollte sagen, dass das Projekt, das Projekt gut läuft und wir sind im Zeitplan.
        Output: Ja, ich wollte sagen, dass das Projekt gut läuft und wir sind im Zeitplan.

        Input: Ähm was ist die Hauptstadt von Frankreich?
        Output: Was ist die Hauptstadt von Frankreich?

        Input: Um can you explain how machine learning works?
        Output: Can you explain how machine learning works?
        """

    nonisolated static let defaultEmailSystemPrompt = """
        Clean up speech-to-text into a professional email. CRITICAL: The speaker's words are the content to format into an email. NEVER answer questions contained in the speech. NEVER add information the speaker did not say. Remove filler words and repetitions, fix grammar and punctuation. Keep the greeting exactly as spoken — if the speaker says "Hallo Andrin", use "Hallo Andrin,". Never invent or change names. If no greeting is spoken, use "Sehr geehrte Damen und Herren,". Add a closing if none is spoken. Preserve all specific details (names, numbers, dates, technical terms) exactly as spoken. Do not add placeholder text. For German, use "Sie" unless "du" is explicit. Never use 'ß', use 'ss' instead. Keep the same language. Output only the email.

        Input: Ähm hallo Andrin hast du heute Zeit für ein Meeting, ein Meeting wegen dem Projekt?
        Output: Hallo Andrin,

        hast du heute Zeit für ein Meeting wegen dem Projekt?

        Freundliche Grüsse
        """

    // MARK: - Published properties

    @Published var preferredLanguage: String {
        didSet { save(Keys.preferredLanguage, preferredLanguage) }
    }

    @Published var whisperModel: String {
        didSet { save(Keys.whisperModel, whisperModel) }
    }

    @Published var ollamaModel: String {
        didSet { save(Keys.ollamaModel, ollamaModel) }
    }

    @Published var hotkeyChoice: String {
        didSet { save(Keys.hotkeyChoice, hotkeyChoice) }
    }

    @Published var outputMode: String {
        didSet { save(Keys.outputMode, outputMode) }
    }

    @Published var smartPaste: Bool {
        didSet { save(Keys.smartPaste, smartPaste) }
    }

    @Published var formatGeneral: Bool {
        didSet { save(Keys.formatGeneral, formatGeneral) }
    }

    @Published var formatEmail: Bool {
        didSet { save(Keys.formatEmail, formatEmail) }
    }

    @Published var generalSystemPrompt: String {
        didSet { save(Keys.generalSystemPrompt, generalSystemPrompt) }
    }

    @Published var emailSystemPrompt: String {
        didSet { save(Keys.emailSystemPrompt, emailSystemPrompt) }
    }

    @Published var handsFreeRecording: Bool {
        didSet { save(Keys.handsFreeRecording, handsFreeRecording) }
    }

    @Published var setupCompleted: Bool {
        didSet { save(Keys.setupCompleted, setupCompleted) }
    }

    @Published var vocabularyNames: [String] {
        didSet { save(Keys.vocabularyNames, encodeJSON(vocabularyNames)) }
    }

    @Published var vocabularyKeywords: [String] {
        didSet { save(Keys.vocabularyKeywords, encodeJSON(vocabularyKeywords)) }
    }

    @Published var panelPosition: String? {
        didSet {
            if let panelPosition {
                save(Keys.panelPosition, panelPosition)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.panelPosition)
            }
        }
    }

    /// True if UserDefaults contained any hotkey value before this init ran,
    /// meaning the user has launched the app before. Used by the setup wizard
    /// to decide whether to offer "keep current key" vs "use default (Fn)".
    private(set) var hotkeyWasPreviouslyConfigured: Bool = false

    // MARK: - Init

    init() {
        let d = UserDefaults.standard
        self.preferredLanguage = d.string(forKey: Keys.preferredLanguage) ?? "de"
        self.whisperModel = d.string(forKey: Keys.whisperModel) ?? WhisperModel.default.rawValue
        self.ollamaModel = d.string(forKey: Keys.ollamaModel) ?? Self.defaultOllamaModel
        // Hotkey: migrate legacy enum values (fn/rightOption/sectionSign) to JSON
        let rawHotkey = d.string(forKey: Keys.hotkeyChoice) ?? ""
        self.hotkeyWasPreviouslyConfigured = !rawHotkey.isEmpty
        if !rawHotkey.isEmpty, CustomHotkey.fromJSON(rawHotkey) != nil {
            self.hotkeyChoice = rawHotkey
        } else {
            let migrated = (CustomHotkey.fromLegacy(rawHotkey) ?? .default).toJSON()
            self.hotkeyChoice = migrated
            d.set(migrated, forKey: Keys.hotkeyChoice)
        }
        // Migrate legacy "smartPaste" output mode (was briefly a 4th mode,
        // now a toggle on top of "paste"). Treat it as paste + smartPaste=true.
        let rawOutputMode = d.string(forKey: Keys.outputMode) ?? OutputMode.clipboard.rawValue
        if rawOutputMode == "smartPaste" {
            self.outputMode = OutputMode.paste.rawValue
            d.set(OutputMode.paste.rawValue, forKey: Keys.outputMode)
            self.smartPaste = true
            d.set(true, forKey: Keys.smartPaste)
        } else {
            self.outputMode = rawOutputMode
            self.smartPaste = d.bool(forKey: Keys.smartPaste)
        }
        self.formatGeneral = d.object(forKey: Keys.formatGeneral) as? Bool ?? true
        self.formatEmail = d.object(forKey: Keys.formatEmail) as? Bool ?? true
        self.generalSystemPrompt = d.string(forKey: Keys.generalSystemPrompt) ?? Self.defaultGeneralSystemPrompt
        self.emailSystemPrompt = d.string(forKey: Keys.emailSystemPrompt) ?? Self.defaultEmailSystemPrompt
        self.handsFreeRecording = d.object(forKey: Keys.handsFreeRecording) as? Bool ?? false
        self.setupCompleted = d.bool(forKey: Keys.setupCompleted)
        self.vocabularyNames = decodeJSON(d.string(forKey: Keys.vocabularyNames)) ?? []
        self.vocabularyKeywords = decodeJSON(d.string(forKey: Keys.vocabularyKeywords)) ?? []
        self.panelPosition = d.string(forKey: Keys.panelPosition)
    }

    // MARK: - Panel position helpers

    var panelPositionPoint: NSPoint? {
        guard let pos = panelPosition else { return nil }
        let parts = pos.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return NSPoint(x: parts[0], y: parts[1])
    }

    func savePanelPosition(_ point: NSPoint) {
        panelPosition = "\(point.x),\(point.y)"
    }

    func resetPanelPosition() {
        panelPosition = nil
    }

    // MARK: - Persistence

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

// MARK: - JSON helpers for [String] persistence

private func encodeJSON(_ array: [String]) -> String {
    (try? JSONEncoder().encode(array)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
}

private func decodeJSON(_ string: String?) -> [String]? {
    guard let data = string?.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode([String].self, from: data)
}
