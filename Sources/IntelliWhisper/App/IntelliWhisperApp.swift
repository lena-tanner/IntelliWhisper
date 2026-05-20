import AppKit
import Combine
import SwiftyBeaver
import SwiftUI

@main
struct IntelliWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible window — UI is driven by NSStatusItem and the floating panel.
        Settings { EmptyView() }
    }
}

/// Bootstraps all subsystems, wires them to the orchestrator, and runs
/// the prerequisite initializer before the app becomes fully operational.
///
/// On first launch, shows the FirstRunView onboarding wizard instead of
/// the headless AppInitializer.
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var settings: SettingsService!
    private var orchestrator: PipelineOrchestrator!
    private var hotkeyManager: HotkeyManager!
    private var initializer: AppInitializer!
    private var menuBarController: MenuBarController!
    private var floatingPanelController: FloatingPanelController!
    private var healthCheckTimer: Timer?
    private var accessibilityTimer: Timer?

    // First-run
    private var firstRunWindow: NSWindow?
    private var firstRunCoordinator: FirstRunCoordinator?
    private var firstRunCancellable: AnyCancellable?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupLogging()
        log.info("App launching")

        // 0. Centralized settings
        settings = SettingsService()

        // 1. Create subsystems (sync, instant)
        let recorder = WhisperKitRecorder()
        let transcriber = WhisperKitTranscriber()
        let contextDetector = ContextDetector()
        let formatter = OllamaFormatter()
        let clipboard = ClipboardManager()

        orchestrator = PipelineOrchestrator(
            settings: settings,
            recorder: recorder,
            transcriber: transcriber,
            contextDetector: contextDetector,
            formatter: formatter,
            clipboard: clipboard
        )

        // Restore persisted preferences into the orchestrator.
        orchestrator.preferredLanguage = Language(rawValue: settings.preferredLanguage)
        orchestrator.outputMode = OutputMode(rawValue: settings.outputMode) ?? .clipboard
        orchestrator.smartPaste = settings.smartPaste
        log.info("Preferences restored: lang=\(orchestrator.preferredLanguage?.rawValue ?? "auto"), output=\(orchestrator.outputMode.rawValue)")

        // 2. Create hotkey manager (start() is deferred to initializer or first-run)
        hotkeyManager = HotkeyManager()

        // 3. Create UI controllers
        menuBarController = MenuBarController(orchestrator: orchestrator)
        floatingPanelController = FloatingPanelController(orchestrator: orchestrator, settings: settings)

        // 4. First-run or normal initialization
        if !settings.setupCompleted {
            log.info("First launch — showing setup wizard")
            let coordinator = FirstRunCoordinator(
                settings: settings,
                transcriber: transcriber,
                formatter: formatter,
                hotkey: hotkeyManager,
                orchestrator: orchestrator
            )
            firstRunCoordinator = coordinator

            // Observe completion → close window, start normal operation
            firstRunCancellable = coordinator.$isComplete
                .filter { $0 }
                .first()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.firstRunCompleted()
                }

            showFirstRunWindow(coordinator: coordinator)
        } else {
            // Subsequent launch: wire hotkey and run headless checks
            log.info("Subsequent launch — running headless initialization")
            orchestrator.wire(hotkey: hotkeyManager)
            initializer = AppInitializer()
            Task {
                await initializer.run(
                    settings: settings,
                    hotkey: hotkeyManager,
                    transcriber: transcriber,
                    formatter: formatter,
                    orchestrator: orchestrator
                )
                // Poll for Accessibility permission — auto-restart when granted
                if !AXIsProcessTrusted() {
                    self.startAccessibilityPolling()
                }
            }
            startHealthCheckTimer()

            // Silently check for updates in the background (rate-limited to once/hour)
            Task { await menuBarController.performUpdateCheck(silent: true) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("App terminating")
        healthCheckTimer?.invalidate()
        accessibilityTimer?.invalidate()
    }

    // MARK: - First-run window

    @MainActor
    private func showFirstRunWindow(coordinator: FirstRunCoordinator) {
        let firstRunView = FirstRunView(coordinator: coordinator)
        let hostingController = NSHostingController(rootView: firstRunView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "IntelliWhisper Setup"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 480))
        window.center()
        // Follow the user to their active Space so the window is never invisible
        // behind a full-screen app or a different Space.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }

        firstRunWindow = window
    }

    @MainActor
    private func firstRunCompleted() {
        log.info("First-run wizard completed — relaunching for permissions to take effect")
        firstRunWindow?.close()

        // After an update the wizard runs from /tmp (the old app launched us
        // from there so the window would get proper foreground focus). Now that
        // the wizard is complete we must relaunch from the permanent
        // /Applications copy — that's where the swap script installed the new
        // binary. For normal first-run installs, that path also exists and is
        // preferred over Bundle.main.bundleURL so the behaviour is identical.
        let permanentApp = URL(
            fileURLWithPath: "/Applications/IntelliWhisper/IntelliWhisper Core.app"
        )
        let launchURL = FileManager.default.fileExists(atPath: permanentApp.path)
            ? permanentApp
            : Bundle.main.bundleURL  // fallback for dev builds not in /Applications

        let runningFromTmp = Bundle.main.bundleURL.path.hasPrefix("/tmp/")
        log.info("Relaunching from \(launchURL.path) (fromTmp: \(runningFromTmp))")

        NSWorkspace.shared.openApplication(
            at: launchURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in
            DispatchQueue.main.async {
                // The new /Applications instance is running; safe to remove
                // the tmp bundle we were launched from.
                if runningFromTmp {
                    try? FileManager.default.removeItem(atPath: "/tmp/iw-update")
                }
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Accessibility polling

    @MainActor
    private func startAccessibilityPolling() {
        log.info("Accessibility not trusted — polling for permission grant")
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            if AXIsProcessTrusted() {
                self?.accessibilityTimer?.invalidate()
                self?.accessibilityTimer = nil
                log.info("Accessibility granted — relaunching to activate")
                let bundleURL = Bundle.main.bundleURL
                NSWorkspace.shared.openApplication(
                    at: bundleURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in
                    DispatchQueue.main.async {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    // MARK: - Health check

    @MainActor
    private func startHealthCheckTimer() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.orchestrator.checkOllamaHealth()
            }
        }
    }
}
