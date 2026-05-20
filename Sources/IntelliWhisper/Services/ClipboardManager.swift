import AppKit
import SwiftyBeaver

/// Manages clipboard writes with undo support and a short history
/// of overwritten items.
@MainActor
final class ClipboardManager {
    private let pasteboard = NSPasteboard.general
    private let maxHistorySize = 5

    /// Items previously on the clipboard that were overwritten by this app.
    private(set) var history: [String] = []

    /// The most recently overwritten clipboard content, used for undo.
    private var previousItem: String?

    /// Copy text to the clipboard. Saves the current clipboard content
    /// to history before overwriting.
    func copy(text: String) {
        // Save whatever is currently on the clipboard
        if let current = pasteboard.string(forType: .string) {
            previousItem = current
            history.insert(current, at: 0)
            if history.count > maxHistorySize {
                history.removeLast()
            }
        } else {
            previousItem = nil
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        log.info("Copied \(text.count) chars to clipboard")
    }

    /// Copy text to the clipboard, simulate Cmd+V to paste it into the
    /// frontmost application, then restore the original clipboard content.
    /// Returns true if the paste was attempted, false if accessibility
    /// permission is missing (text remains on clipboard as fallback).
    @discardableResult
    func copyAndPaste(text: String) async -> Bool {
        let originalContent = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        log.info("Copied \(text.count) chars to clipboard (paste mode)")

        guard AXIsProcessTrusted() else {
            // Paste impossible — leave text on clipboard and track in history
            // so undo works, matching copy() fallback behavior.
            if let original = originalContent {
                previousItem = original
                history.insert(original, at: 0)
                if history.count > maxHistorySize {
                    history.removeLast()
                }
            } else {
                previousItem = nil
            }
            log.warning("Accessibility not trusted — paste skipped, text is on clipboard")
            return false
        }

        // Brief delay so the pasteboard is ready before the synthetic keystroke.
        try? await Task.sleep(for: .milliseconds(50))

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)   // 'v'
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = CGEventFlags.maskCommand
        keyUp?.flags   = CGEventFlags.maskCommand
        keyDown?.post(tap: CGEventTapLocation.cghidEventTap)
        keyUp?.post(tap: CGEventTapLocation.cghidEventTap)

        log.info("Simulated Cmd+V paste")

        // Wait for the target app to process the paste, then restore
        // the user's original clipboard content.
        try? await Task.sleep(for: .milliseconds(150))

        pasteboard.clearContents()
        if let original = originalContent {
            pasteboard.setString(original, forType: .string)
            log.info("Restored original clipboard content (\(original.count) chars)")
        } else {
            log.info("Clipboard cleared (was empty before paste)")
        }

        return true
    }

    /// Copy text to the clipboard, simulate Cmd+V to paste it into the
    /// frontmost application, and keep the text on the clipboard afterward.
    /// Returns true if the paste was attempted, false if accessibility
    /// permission is missing (text remains on clipboard as fallback).
    @discardableResult
    func copyAndPasteKeeping(text: String) async -> Bool {
        copy(text: text)

        guard AXIsProcessTrusted() else {
            log.warning("Accessibility not trusted — paste skipped, text is on clipboard")
            return false
        }

        try? await Task.sleep(for: .milliseconds(50))

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = CGEventFlags.maskCommand
        keyUp?.flags   = CGEventFlags.maskCommand
        keyDown?.post(tap: CGEventTapLocation.cghidEventTap)
        keyUp?.post(tap: CGEventTapLocation.cghidEventTap)

        log.info("Simulated Cmd+V paste (keeping clipboard)")
        return true
    }

    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]
    private static let nonEditableRoles: Set<String> = [
        "AXButton", "AXImage", "AXCheckBox", "AXRadioButton",
        "AXWindow", "AXGroup", "AXList", "AXTable", "AXTabGroup",
        "AXToolbar", "AXMenuBar", "AXApplication", "AXStaticText",
    ]

    /// Checks whether the frontmost app's focused element can accept pasted text.
    /// Returns .confirmed for known editable roles, .denied when there is no focused
    /// element or AX is not trusted, and .unknown for unrecognized roles. Both .denied
    /// and .unknown cause smart paste to fall back to clipboard-only.
    func detectFocusedTextField() -> TextFieldDetectionResult {
        guard AXIsProcessTrusted() else { return .denied }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return .denied }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef else { return .denied }

        // AXUIElementCopyAttributeValue always returns AXUIElement for focused-element attribute
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRef
        ) == .success, let role = roleRef as? String else { return .unknown }

        if Self.editableRoles.contains(role) { return .confirmed }
        if Self.nonEditableRoles.contains(role) { return .denied }
        return .unknown
    }

    /// Restore the clipboard content that was overwritten by the last copy().
    func undo() {
        guard let previous = previousItem else {
            log.info("Undo requested but no previous clipboard item")
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(previous, forType: .string)
        previousItem = nil
        log.info("Clipboard undo — restored previous content")
    }
}