@preconcurrency import ApplicationServices
import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ActionVerifier")

// MARK: - Action Verification

/// Verifies that an action produced the expected result by examining the
/// post-action AX tree state.
///
/// Used after each step in procedure replay to confirm the action worked
/// before proceeding. Verification strategies vary by action type:
///
/// - Click: Check if the expected element state changed (enabled, focused, etc.)
/// - Type: Readback verification (compare field value to expected text)
/// - Hotkey: Check for expected UI changes (new window, menu opened, etc.)
/// - Scroll: Check scroll position or visible content changed
enum ActionVerifier {

    /// Result of a post-action verification.
    struct VerificationResult: Sendable {
        let passed: Bool
        let confidence: Double  // 0.0 - 1.0
        let details: String
    }

    // MARK: - Click Verification

    /// Verify a click action produced a state change.
    ///
    /// Checks:
    /// 1. If the element gained focus (for interactive elements)
    /// 2. If a new element appeared (e.g., dropdown after clicking a popup button)
    /// 3. If the focused element changed from the target
    @MainActor
    static func verifyClick(
        element: ShadowElement,
        preClickFocused: ShadowElement?,
        app: ShadowElement
    ) -> VerificationResult {
        // Check 1: Did the element or its descendant gain focus?
        if let focused = app.focusedUIElement() {
            if focused == element {
                return VerificationResult(passed: true, confidence: 0.90,
                                          details: "Target element gained focus")
            }
            // If focus changed from what it was before, the click had an effect
            if let pre = preClickFocused, focused != pre {
                return VerificationResult(passed: true, confidence: 0.75,
                                          details: "Focus changed from pre-click state")
            }
        }

        // Check 2: For buttons, the action is fire-and-forget — assume success
        // if AXPress didn't throw.
        if let role = element.role(), role == "AXButton" || role == "AXMenuItem" {
            return VerificationResult(passed: true, confidence: 0.70,
                                      details: "Button/menu item clicked (no explicit state change to verify)")
        }

        // Check 3: Element still exists and is enabled
        if element.isEnabled() {
            return VerificationResult(passed: true, confidence: 0.60,
                                      details: "Element still enabled after click")
        }

        return VerificationResult(passed: false, confidence: 0.30,
                                  details: "Could not verify click effect")
    }

    // MARK: - Type Verification

    /// Verify text was entered correctly into a field.
    ///
    /// Reads back the element's value and compares the prefix to the expected text.
    /// Uses prefix comparison because:
    /// - Autocomplete may add extra text
    /// - The field may have a prefix/placeholder
    /// - Formatting may alter the exact text (e.g., phone number fields)
    @MainActor
    static func verifyTextEntry(
        element: ShadowElement,
        expectedText: String,
        prefixLength: Int = 10
    ) -> VerificationResult {
        guard let readback = element.value(), !readback.isEmpty else {
            return VerificationResult(passed: false, confidence: 0.10,
                                      details: "Field is empty after typing")
        }

        let expectedPrefix = String(expectedText.prefix(prefixLength))
        let readbackPrefix = String(readback.prefix(prefixLength))

        if readbackPrefix == expectedPrefix {
            return VerificationResult(passed: true, confidence: 0.95,
                                      details: "Readback matches expected text")
        }

        // Case-insensitive comparison (some fields transform case)
        if readbackPrefix.lowercased() == expectedPrefix.lowercased() {
            return VerificationResult(passed: true, confidence: 0.85,
                                      details: "Readback matches expected text (case-insensitive)")
        }

        // Check if the expected text is contained anywhere (field may have prefix)
        if readback.lowercased().contains(expectedText.lowercased().prefix(prefixLength)) {
            return VerificationResult(passed: true, confidence: 0.75,
                                      details: "Expected text found within field value")
        }

        return VerificationResult(passed: false, confidence: 0.10,
                                  details: "Readback mismatch: expected '\(expectedPrefix)', got '\(readbackPrefix)'")
    }

    // MARK: - State Change Verification

    /// Verify that the AX tree changed between two snapshots.
    ///
    /// Uses FNV-1a tree hashing to detect any structural change.
    /// Returns true if the tree is different (i.e., the action had an effect).
    static func verifyTreeChanged(
        preHash: UInt64,
        postHash: UInt64
    ) -> VerificationResult {
        if preHash != postHash {
            return VerificationResult(passed: true, confidence: 0.80,
                                      details: "AX tree structure changed")
        }
        return VerificationResult(passed: false, confidence: 0.40,
                                  details: "AX tree unchanged after action")
    }

    // MARK: - Window Verification

    /// Verify that a new window appeared (expected after some actions).
    @MainActor
    static func verifyNewWindow(
        app: ShadowElement,
        preWindowCount: Int
    ) -> VerificationResult {
        let currentWindows = app.windows()
        if currentWindows.count > preWindowCount {
            return VerificationResult(passed: true, confidence: 0.90,
                                      details: "New window appeared (count: \(preWindowCount) -> \(currentWindows.count))")
        }
        return VerificationResult(passed: false, confidence: 0.30,
                                  details: "No new window appeared")
    }

    /// Verify the focused window title matches an expected value.
    @MainActor
    static func verifyWindowTitle(
        app: ShadowElement,
        expectedTitle: String
    ) -> VerificationResult {
        guard let window = app.focusedWindow(),
              let title = window.title() else {
            return VerificationResult(passed: false, confidence: 0.20,
                                      details: "No focused window or no title")
        }

        if title == expectedTitle {
            return VerificationResult(passed: true, confidence: 0.95,
                                      details: "Window title matches exactly")
        }

        if title.lowercased().contains(expectedTitle.lowercased()) {
            return VerificationResult(passed: true, confidence: 0.80,
                                      details: "Window title contains expected text")
        }

        return VerificationResult(passed: false, confidence: 0.20,
                                  details: "Window title '\(title)' does not match '\(expectedTitle)'")
    }
}
