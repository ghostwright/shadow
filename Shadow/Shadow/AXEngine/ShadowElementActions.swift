@preconcurrency import ApplicationServices
import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ShadowElementActions")

// MARK: - Element Actions

extension ShadowElement {

    /// Two-phase click: try AX-native AXPress first, fall back to synthetic CGEvent.
    ///
    /// AX-native is preferred because:
    /// 1. It doesn't move the cursor (no visual disruption)
    /// 2. It doesn't steal focus from the current app
    /// 3. It works even when the element is partially occluded
    ///
    /// If AXPress fails (not supported, actionFailed), we compute the element's
    /// center point and send a synthetic CGEvent click.
    @MainActor
    func twoPhaseClick(button: CGMouseButton = .left, count: Int = 1) throws {
        // Phase 1: Try AX-native AXPress (only for single left click)
        if button == .left && count == 1 {
            let actions = supportedActions()
            if actions.contains("AXPress") {
                do {
                    try performAction("AXPress")
                    logger.debug("AXPress succeeded for element role=\(self.role() ?? "?", privacy: .public)")
                    return
                } catch {
                    logger.debug("AXPress failed, falling back to synthetic click: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Phase 2: Synthetic CGEvent click at element center
        guard let frame = frame() else {
            throw AXEngineError.elementHasNoFrame
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        try InputSynthesizer.click(at: center, button: button, count: count)
    }

    /// Type text into this element with readback verification.
    ///
    /// Strategy:
    /// 1. Focus the element via AXFocused attribute
    /// 2. If `clear`, select all + delete existing content
    /// 3. Try AX-native setValue — if the API succeeds, the text IS written. Done.
    /// 4. Only if setValue FAILS (API error), fall back to synthetic keyboard typing.
    /// 5. Readback the value to verify (best-effort — web apps may not reflect immediately)
    ///
    /// IMPORTANT: setValue and synthetic typing are MUTUALLY EXCLUSIVE. Never do both.
    /// Web apps (Chrome, Safari) often succeed on setValue but don't immediately reflect
    /// the new value through AX readback — that does NOT mean the text wasn't written.
    /// Falling through to synthetic typing after a successful setValue causes double text.
    ///
    /// Returns true if readback matches, false if verification couldn't confirm.
    @MainActor
    func typeText(_ text: String, clear: Bool = false) throws -> Bool {
        // Focus the element
        _ = setValue(true, forAttribute: kAXFocusedAttribute)
        Thread.sleep(forTimeInterval: 0.05)

        if clear {
            try InputSynthesizer.hotkey(["cmd", "a"])
            Thread.sleep(forTimeInterval: 0.05)
            try InputSynthesizer.pressKey(keyCode: 51) // Delete
            Thread.sleep(forTimeInterval: 0.05)
        }

        // Try AX-native setValue first (most reliable for text fields).
        // If the API call succeeds, the text IS written — do NOT also type synthetically.
        let setValueSucceeded = setValue(text, forAttribute: kAXValueAttribute)

        if setValueSucceeded {
            // Give the app a moment to propagate the value through AX
            Thread.sleep(forTimeInterval: 0.1)
            let readback = value() ?? ""
            if readback.hasPrefix(String(text.prefix(10))) {
                logger.debug("AX setValue succeeded with readback verification")
                return true
            }
            // setValue API succeeded but readback doesn't match. This is NORMAL for web apps
            // (Chrome, Safari) where the AX value attribute lags behind the actual field content.
            // The text WAS written — do NOT fall through to synthetic typing.
            logger.debug("AX setValue succeeded (API returned .success) but readback didn't match — expected for web apps. NOT retrying with synthetic typing.")
            return false
        }

        // setValue failed (API error) — fall back to synthetic keyboard typing.
        // This path is for apps/elements that don't support AXValueAttribute writes.
        logger.debug("AX setValue failed, falling back to synthetic keyboard typing")
        try InputSynthesizer.typeText(text)
        Thread.sleep(forTimeInterval: 0.1)

        // Readback verification
        let readback = value() ?? ""
        let match = readback.hasPrefix(String(text.prefix(10)))
        if !match {
            logger.warning("Readback verification failed: expected '\(text.prefix(10), privacy: .public)...', got '\(readback.prefix(10), privacy: .public)...'")
        }
        return match
    }

    /// Check if this element supports a specific action.
    @MainActor
    func isActionSupported(_ action: String) -> Bool {
        supportedActions().contains(action)
    }

    /// AX-native confirm (AXConfirm action for dialogs/sheets).
    @MainActor
    func confirm() throws {
        try performAction("AXConfirm")
    }

    /// AX-native cancel (AXCancel action for dialogs/sheets).
    @MainActor
    func cancel() throws {
        try performAction("AXCancel")
    }

    /// AX-native show menu (AXShowMenu for context menus).
    @MainActor
    func showMenu() throws {
        try performAction("AXShowMenu")
    }

    /// AX-native increment (AXIncrement for sliders/steppers).
    @MainActor
    func increment() throws {
        try performAction("AXIncrement")
    }

    /// AX-native decrement (AXDecrement for sliders/steppers).
    @MainActor
    func decrement() throws {
        try performAction("AXDecrement")
    }

    /// Focus this element (set AXFocused to true).
    @MainActor
    func focus() -> Bool {
        setValue(true, forAttribute: kAXFocusedAttribute)
    }

    /// Select this element (set AXSelected to true, useful for table rows/tabs).
    @MainActor
    func select() -> Bool {
        setValue(true, forAttribute: kAXSelectedAttribute)
    }

    /// Set the value of a text field.
    @MainActor
    func setTextValue(_ text: String) -> Bool {
        setValue(text, forAttribute: kAXValueAttribute)
    }
}
