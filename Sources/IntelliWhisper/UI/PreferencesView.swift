import ServiceManagement
import SwiftUI

/// Settings window with General and Formatting tabs.
struct PreferencesView: View {
    @ObservedObject var settings: SettingsService
    @ObservedObject var orchestrator: PipelineOrchestrator

    private enum Tab: Hashable {
        case general
        case formatting
        case vocabulary
    }
    @State private var selectedTab: Tab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralTab(settings: settings, orchestrator: orchestrator)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(Tab.general)

            FormattingTab(settings: settings, orchestrator: orchestrator)
                .tabItem { Label("Formatting", systemImage: "text.quote") }
                .tag(Tab.formatting)

            VocabularyTab(settings: settings)
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
                .tag(Tab.vocabulary)
        }
        .frame(minWidth: 380, idealWidth: 380, maxWidth: 380, minHeight: 540)
        .task {
            await orchestrator.refreshAvailableModels()
        }
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @ObservedObject var settings: SettingsService
    @ObservedObject var orchestrator: PipelineOrchestrator
    // Initialised to false; updated asynchronously in .task to avoid blocking
    // the main thread with SMAppService's IPC call during body evaluation.
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Language", selection: $settings.preferredLanguage) {
                    Text("German").tag("de")
                    Text("English").tag("en")
                    Text("Auto-detect").tag("auto")
                }
                .onChange(of: settings.preferredLanguage) { _, newValue in
                    orchestrator.preferredLanguage = Language(rawValue: newValue)
                }

                Picker("Whisper Model", selection: $settings.whisperModel) {
                    ForEach(WhisperModel.allCases) { model in
                        HStack {
                            Text(model.displayName)
                            Text(model.sizeDescription)
                                .foregroundStyle(.secondary)
                            if model == .default {
                                Text("Recommended")
                                    .font(.caption)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.blue.opacity(0.15))
                                    .foregroundStyle(.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        .tag(model.rawValue)
                    }
                }
                .disabled(orchestrator.modelLoading)
                .onChange(of: settings.whisperModel) { _, newValue in
                    guard let model = WhisperModel(rawValue: newValue) else { return }
                    Task {
                        await orchestrator.switchWhisperModel(model)
                    }
                }

                if orchestrator.modelLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading model…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Hotkey") {
                HStack {
                    Text("Push-to-talk key")
                    Spacer()
                    HotkeyRecorderView(
                        hotkeyJSON: $settings.hotkeyChoice,
                        onRecordingChanged: { recording in
                            if recording {
                                orchestrator.pauseHotkey()
                            } else {
                                orchestrator.resumeHotkey()
                            }
                        }
                    )
                }

                if let hotkey = CustomHotkey.fromJSON(settings.hotkeyChoice), hotkey.isFnKey {
                    Text("Set \"Press fn key to\" → \"Do Nothing\" in System Settings → Keyboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Hands-free recording", isOn: $settings.handsFreeRecording)

                if settings.handsFreeRecording {
                    Text("Press hotkey to start, press again to stop. No need to hold.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Output") {
                Picker("After transcription", selection: $settings.outputMode) {
                    Text("Copy to clipboard").tag(OutputMode.clipboard.rawValue)
                    Text("Paste directly").tag(OutputMode.paste.rawValue)
                    Text("Paste and keep on clipboard").tag(OutputMode.clipboardAndPaste.rawValue)
                }
                .onChange(of: settings.outputMode) { _, newValue in
                    orchestrator.outputMode = OutputMode(rawValue: newValue) ?? .clipboard
                    orchestrator.smartPaste = settings.smartPaste
                }

                if settings.outputMode == OutputMode.paste.rawValue {
                    Text("Requires Accessibility permission. Original clipboard is restored after paste.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Smart paste", isOn: $settings.smartPaste)
                        .onChange(of: settings.smartPaste) { _, newValue in
                            orchestrator.smartPaste = newValue
                        }
                    Text("Only paste when a text field is confirmed focused. Falls back to clipboard if none is detected or uncertain (e.g. Finder, VS Code file tree).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if settings.outputMode == OutputMode.clipboardAndPaste.rawValue {
                    Text("Requires Accessibility permission. Text stays on clipboard after paste.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Widget") {
                Button("Reset widget position") {
                    settings.resetPanelPosition()
                }
                .disabled(settings.panelPosition == nil)

                Text("Drag the floating widget to reposition it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }

                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
                        .foregroundStyle(.secondary)
                        .font(.body.monospacedDigit())
                }
            }
        }
        .formStyle(.grouped)
        .task {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Formatting Tab

private struct FormattingTab: View {
    @ObservedObject var settings: SettingsService
    @ObservedObject var orchestrator: PipelineOrchestrator

    private enum FocusedField: Hashable {
        case ollamaModel
        case generalPrompt
        case emailPrompt
    }
    @FocusState private var focusedField: FocusedField?
    @State private var showGeneralInfo = false
    @State private var showEmailInfo = false

    var body: some View {
        Form {
            Section("Formatting") {
                Toggle("Format general transcriptions", isOn: $settings.formatGeneral)
                Toggle("Format email transcriptions", isOn: $settings.formatEmail)

                if !settings.formatGeneral && !settings.formatEmail {
                    Text("All formatting disabled — raw transcription will be used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if orchestrator.availableModels.isEmpty {
                    TextField("Ollama model", text: $settings.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .ollamaModel)
                } else {
                    Picker("Ollama model", selection: $settings.ollamaModel) {
                        ForEach(orchestrator.availableModels, id: \.self) { model in
                            HStack {
                                Text(model)
                                if let desc = modelDescription(model) {
                                    Text(desc)
                                        .foregroundStyle(.secondary)
                                }
                                if model == SettingsService.defaultOllamaModel {
                                    Text("Recommended")
                                        .font(.caption)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(.blue.opacity(0.15))
                                        .foregroundStyle(.blue)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                            }
                            .tag(model)
                        }
                    }
                }

                Text("Showing models installed on your machine. For best results, use qwen3.5. Install more with `ollama pull <model>` in Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Circle()
                        .fill(orchestrator.ollamaAvailable ? .green : .yellow)
                        .frame(width: 8, height: 8)
                    Text(orchestrator.ollamaAvailable ? "Ollama connected" : "Ollama unavailable — raw transcription will be used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.formatGeneral {
                Section {
                    TextEditor(text: $settings.generalSystemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120, maxHeight: 200)
                        .focused($focusedField, equals: .generalPrompt)

                    if settings.generalSystemPrompt != SettingsService.defaultGeneralSystemPrompt {
                        Text("Custom prompt — formatting results may differ from defaults.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Button("Reset to Default") {
                        settings.generalSystemPrompt = SettingsService.defaultGeneralSystemPrompt
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("General System Prompt")
                        Button {
                            showGeneralInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showGeneralInfo) {
                            Text("Instructions sent to Ollama for general transcriptions. Controls how speech is cleaned up — punctuation, filler word removal, and repetition handling.")
                                .font(.caption)
                                .padding()
                                .frame(width: 250)
                        }
                    }
                }
            }

            if settings.formatEmail {
                Section {
                    TextEditor(text: $settings.emailSystemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120, maxHeight: 200)
                        .focused($focusedField, equals: .emailPrompt)

                    if settings.emailSystemPrompt != SettingsService.defaultEmailSystemPrompt {
                        Text("Custom prompt — formatting results may differ from defaults.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Button("Reset to Default") {
                        settings.emailSystemPrompt = SettingsService.defaultEmailSystemPrompt
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("Email System Prompt")
                        Button {
                            showEmailInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showEmailInfo) {
                            Text("Instructions sent to Ollama for email transcriptions. Controls how speech is formatted into a professional email — greetings, closings, tone, and language.")
                                .font(.caption)
                                .padding()
                                .frame(width: 250)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .defaultFocus($focusedField, nil)
    }

    private func modelDescription(_ name: String) -> String? {
        switch name {
        case let n where n.contains("0.8b"): return "Fastest, basic quality"
        case let n where n.contains(":2b"):  return "Fast, good quality"
        case let n where n.contains(":4b"):  return "Balanced, best for most users"
        case let n where n.contains(":9b"):  return "Slowest, highest quality"
        default: return nil
        }
    }
}

// MARK: - Vocabulary Tab

private struct VocabularyTab: View {
    @ObservedObject var settings: SettingsService
    @State private var newName = ""
    @State private var newKeyword = ""

    /// WhisperKit's maxPromptLen = (448/2)/2 - 1 = 111 tokens
    private let maxTokens = 111

    /// Rough token estimate: ~1 token per 4 characters (conservative BPE heuristic)
    private var estimatedTokens: Int {
        let prompt = VocabularyPromptBuilder.buildPrompt(
            names: settings.vocabularyNames,
            keywords: settings.vocabularyKeywords
        )
        guard !prompt.isEmpty else { return 0 }
        return max(1, prompt.count / 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Info & token budget (non-scrolling header)
            VStack(alignment: .leading, spacing: 6) {
                Text("Add names and keywords to improve recognition of specific terms. These are passed to the speech model as context hints.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Estimated usage")
                        .font(.caption)
                    Spacer()
                    Text("~\(estimatedTokens) / \(maxTokens) tokens")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(tokenColor)
                }

                if estimatedTokens > maxTokens {
                    Text("Token limit exceeded. Oldest entries may be ignored by the model.")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if estimatedTokens > maxTokens * 3 / 4 {
                    Text("Approaching token limit. More words may reduce accuracy.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Two independently scrollable word lists
            HStack(spacing: 0) {
                WordListEditor(
                    title: "Names",
                    words: $settings.vocabularyNames,
                    newWord: $newName,
                    placeholder: "Add a name…"
                )

                Divider()

                WordListEditor(
                    title: "Keywords",
                    words: $settings.vocabularyKeywords,
                    newWord: $newKeyword,
                    placeholder: "Add a keyword…"
                )
            }
        }
    }

    private var tokenColor: Color {
        if estimatedTokens > maxTokens { return .red }
        if estimatedTokens > maxTokens * 3 / 4 { return .orange }
        return .secondary
    }
}

// MARK: - Word List Editor

private struct WordListEditor: View {
    let title: String
    @Binding var words: [String]
    @Binding var newWord: String
    var placeholder: String

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            Divider()

            // Scrollable word list
            List {
                ForEach(words, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button {
                            words.removeAll { $0 == word }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)

            Divider()

            // Add field pinned at bottom
            HStack(spacing: 6) {
                TextField(placeholder, text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addWord() }
                Button {
                    addWord()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !words.contains(trimmed) else { return }
        words.append(trimmed)
        newWord = ""
    }
}
