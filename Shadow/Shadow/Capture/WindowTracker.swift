import Cocoa
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "WindowTracker")

// MARK: - Browser URL Extraction

/// Extracts the current URL from browser windows via the Accessibility API.
/// Works for Chrome, Safari, Arc, Firefox, Brave, and most Chromium-based browsers.
enum URLExtractor {
    /// Known browser bundle IDs that expose a URL bar via AX.
    private static let browserBundles: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "company.thebrowser.Browser",    // Arc
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    /// Returns the URL from the browser's address bar, or nil if not a browser / not accessible.
    static func extractURL(bundleID: String?, appElement: AXUIElement) -> String? {
        guard let bundleID, browserBundles.contains(bundleID) else { return nil }

        // Strategy: find the focused window, then look for the URL text field.
        // Chrome/Arc/Brave: AXTextField with description "Address and search bar"
        // Safari: AXTextField with description "Search or enter website name"  or AXGroup containing URL
        // Firefox: AXTextField with description "Search with ... or enter address"

        guard let windowValue = axAttribute(appElement, kAXFocusedWindowAttribute) else {
            return nil
        }
        let focusedWindow = windowValue as! AXUIElement // CF type cast, always succeeds

        // Try to find the URL text field by walking the toolbar area
        if let url = findURLField(in: focusedWindow) {
            return url
        }

        return nil
    }

    /// Recursively search for the URL text field. Limited depth to avoid expensive tree walks.
    private static func findURLField(in element: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }

        let role = axAttribute(element, kAXRoleAttribute) as? String

        if role == "AXTextField" || role == "AXComboBox" {
            // Check if this is the URL field by reading its description
            let desc = axAttribute(element, kAXDescriptionAttribute) as? String ?? ""
            let descLower = desc.lowercased()
            if descLower.contains("address") || descLower.contains("url")
                || descLower.contains("search or enter") || descLower.contains("enter address")
            {
                let value = axAttribute(element, kAXValueAttribute) as? String
                return value
            }
        }

        // Recurse into children
        guard let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let url = findURLField(in: child, depth: depth + 1) {
                return url
            }
        }

        return nil
    }
}

// MARK: - Window Tracker

/// Monitors app switches and window title changes, emitting events to the storage engine.
///
/// @MainActor because:
/// - NSWorkspace notifications fire on the main thread
/// - AXUIElement calls should be made from the main thread for the frontmost app
/// - All state (lastAppName, lastWindowTitle) accessed from main thread only
@MainActor
final class WindowTracker: NSObject {
    private var lastAppName: String?
    private var lastWindowTitle: String?
    private var lastURL: String?
    private var titlePollTimer: Timer?

    private(set) var isTracking = false

    /// When true, events are received but not written to storage.
    var isPaused = false

    /// AX tree logger for capturing accessibility tree snapshots on app/title changes.
    var axTreeLogger: AXTreeLogger?

    // MARK: - Public API

    func startTracking() {
        guard !isTracking else { return }
        isTracking = true

        // App activation (switch) notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Poll window title every 2 seconds to catch title changes
        // within the same app (e.g., switching tabs in Chrome, opening a new file in VS Code).
        // NSWorkspace only notifies on app switches, not window title changes.
        titlePollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollWindowTitle()
            }
        }

        // Capture the current state immediately
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            recordAppState(frontApp)
        }

        logger.info("Window tracking started")
    }

    func stopTracking() {
        guard isTracking else { return }
        isTracking = false

        NSWorkspace.shared.notificationCenter.removeObserver(self)
        titlePollTimer?.invalidate()
        titlePollTimer = nil

        logger.info("Window tracking stopped")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Notification Handlers

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        recordAppState(app)
    }

    // MARK: - State Capture

    private func recordAppState(_ app: NSRunningApplication) {
        let appName = app.localizedName ?? "Unknown"
        let bundleID = app.bundleIdentifier
        let pid = app.processIdentifier

        let appElement = AXUIElementCreateApplication(pid)
        let windowTitle = readWindowTitle(appElement)
        let url = URLExtractor.extractURL(bundleID: bundleID, appElement: appElement)

        // Only emit if something changed
        guard appName != lastAppName || windowTitle != lastWindowTitle else { return }

        lastAppName = appName
        lastWindowTitle = windowTitle
        lastURL = url

        // Skip writing to storage when paused (but keep tracking state for change detection)
        guard !isPaused else { return }

        // Get window frame and display attribution
        let windowInfo = DisplayMapper.focusedWindowInfo(forPID: pid)

        EventWriter.appSwitch(
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            url: url,
            displayID: windowInfo?.displayID,
            pid: pid,
            windowFrame: windowInfo?.frame
        )

        logger.debug("App switch: \(appName, privacy: .public) — \(windowTitle ?? "(no title)", privacy: .public)")

        // Trigger AX tree capture on app switch
        axTreeLogger?.onAppSwitch(app: app)
    }

    /// Poll the current frontmost app's window title. Detects tab switches, file opens, etc.
    private func pollWindowTitle() {
        guard isTracking, !isPaused else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }

        let appName = app.localizedName ?? "Unknown"
        let bundleID = app.bundleIdentifier
        let pid = app.processIdentifier

        let appElement = AXUIElementCreateApplication(pid)
        let windowTitle = readWindowTitle(appElement)

        // Only emit if the meaningful part of the title actually changed.
        // Terminal apps (iTerm2, Terminal) use spinner characters (Braille patterns)
        // in their tab titles that cycle every fraction of a second. Comparing raw
        // titles would emit noise events every 2 seconds.
        guard appName == lastAppName,
              let windowTitle,
              Self.stripSpinnerPrefix(windowTitle) != Self.stripSpinnerPrefix(lastWindowTitle ?? "") else { return }

        lastWindowTitle = windowTitle

        let url = URLExtractor.extractURL(bundleID: bundleID, appElement: appElement)
        lastURL = url

        let windowInfo = DisplayMapper.focusedWindowInfo(forPID: pid)
        EventWriter.windowTitleChanged(
            appName: appName,
            windowTitle: windowTitle,
            url: url,
            displayID: windowInfo?.displayID,
            pid: pid,
            bundleID: bundleID
        )

        logger.debug("Title changed: \(appName, privacy: .public) — \(windowTitle, privacy: .public)")

        // Trigger debounced AX tree capture on title change
        axTreeLogger?.onWindowTitleChanged(app: app)
    }

    // MARK: - Title Normalization

    /// Strip leading spinner/progress indicator characters from a window title.
    /// Terminal emulators (iTerm2, Terminal.app) prefix tab titles with Braille
    /// pattern characters (U+2800–U+28FF) or other Unicode spinners that cycle
    /// rapidly. We strip these so that "⠂ Documentation" and "⠐ Documentation"
    /// are treated as the same title.
    static func stripSpinnerPrefix(_ title: String) -> String {
        var scalars = title.unicodeScalars[...]
        while let first = scalars.first {
            // Braille Patterns block: U+2800–U+28FF
            if first.value >= 0x2800 && first.value <= 0x28FF {
                scalars = scalars.dropFirst()
                continue
            }
            // Leading whitespace after spinner
            if first == " " || first == "\t" {
                scalars = scalars.dropFirst()
                continue
            }
            break
        }
        return String(scalars)
    }

    // MARK: - AX Helpers

    private func readWindowTitle(_ appElement: AXUIElement) -> String? {
        guard let windowValue = axAttribute(appElement, kAXFocusedWindowAttribute) else {
            return nil
        }
        let window = windowValue as! AXUIElement // CF type cast, always succeeds
        return axAttribute(window, kAXTitleAttribute) as? String
    }
}

// MARK: - AXUIElement Helpers

/// Read a single accessibility attribute. Returns nil on any error.
func axAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success else { return nil }
    return value
}
