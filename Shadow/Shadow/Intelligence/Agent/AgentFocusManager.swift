import AppKit
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "AgentFocusManager")

/// Tracks which application the agent should target with AX tools.
///
/// Solves the fundamental problem: when the search overlay opens, `NSApp.activate()`
/// makes Shadow the frontmost app. Without this manager, all AX tools see Shadow
/// instead of the app the user was working in.
///
/// Lifecycle:
/// 1. User presses Option+Space -> `snapshotFrontmostApp()` captures current app
/// 2. `NSApp.activate()` makes Shadow frontmost (needed for keyboard input)
/// 3. AX tools call `targetAppInfo()` which returns the snapshot, not Shadow
/// 4. If agent calls `ax_focus_app("Chrome")`, `setTarget()` updates the target
/// 5. When overlay closes without agent, `clearTarget()` resets
///
/// Thread safety: @MainActor — all callers are on main thread (UI + AX tools via MainActor.run).
@MainActor
final class AgentFocusManager {
    static let shared = AgentFocusManager()

    /// The app the agent should target. Set when overlay opens, updated by ax_focus_app.
    private(set) var targetApp: TargetApp?

    /// The app the user was using when the overlay was opened.
    /// Stored separately from `targetApp` because `targetApp` changes as the agent
    /// focuses different apps, while `originApp` stays fixed for the entire run.
    /// Used to restore the user's context after the agent completes.
    private(set) var originApp: TargetApp?

    /// Whether an agent run is actively executing. When true, the search panel
    /// suppresses auto-dismiss on resignKey so the agent can focus other apps.
    private(set) var isAgentRunning: Bool = false

    /// Shadow's own bundle identifier, used to filter it from frontmost app queries.
    private let shadowBundleId = Bundle.main.bundleIdentifier ?? "com.shadow.app"

    struct TargetApp: Sendable {
        let pid: pid_t
        let name: String
        let bundleId: String
    }

    private init() {}

    // MARK: - Snapshot

    /// Capture the frontmost app before Shadow activates.
    /// Called by SearchPanelController.show() BEFORE NSApp.activate().
    func snapshotFrontmostApp() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            logger.debug("No frontmost app to snapshot")
            return
        }

        // If Shadow is already frontmost (e.g., user toggling the panel),
        // try to find the next app in the running list.
        let bundleId = frontApp.bundleIdentifier ?? ""
        if bundleId == shadowBundleId {
            // Shadow is frontmost — find the most recently activated non-Shadow app
            if let fallback = findNonShadowApp() {
                let snapped = TargetApp(
                    pid: fallback.processIdentifier,
                    name: fallback.localizedName ?? "Unknown",
                    bundleId: fallback.bundleIdentifier ?? ""
                )
                targetApp = snapped
                originApp = snapped
                logger.debug("Snapshot (fallback): \(self.targetApp?.name ?? "nil") (pid \(self.targetApp?.pid ?? 0))")
            } else {
                logger.debug("No non-Shadow app found for snapshot")
            }
            return
        }

        let snapped = TargetApp(
            pid: frontApp.processIdentifier,
            name: frontApp.localizedName ?? "Unknown",
            bundleId: bundleId
        )
        targetApp = snapped
        originApp = snapped
        logger.debug("Snapshot: \(self.targetApp?.name ?? "nil") (pid \(self.targetApp?.pid ?? 0))")
    }

    // MARK: - Target Management

    /// Update target to a specific app. Called when the agent uses ax_focus_app.
    func setTarget(pid: pid_t, name: String, bundleId: String) {
        targetApp = TargetApp(pid: pid, name: name, bundleId: bundleId)
        logger.debug("Target updated: \(name) (pid \(pid))")
    }

    /// Clear target and origin. Called when overlay closes without an active agent run.
    func clearTarget() {
        targetApp = nil
        originApp = nil
        logger.debug("Target cleared")
    }

    // MARK: - Agent Run Lifecycle

    /// Mark that an agent run has started. Suppresses panel auto-dismiss.
    func agentRunStarted() {
        isAgentRunning = true
        logger.debug("Agent run started — panel dismiss suppressed")
    }

    /// Mark that an agent run has ended. Re-enables panel auto-dismiss.
    func agentRunEnded() {
        isAgentRunning = false
        logger.debug("Agent run ended — panel dismiss re-enabled")
    }

    // MARK: - Origin Restoration

    /// Restore focus to the app the user was using when the overlay was opened.
    ///
    /// Called after a successful or failed agent run. Brings the origin app to the
    /// front so the user's context is preserved. Skips restoration if:
    /// - No origin was captured
    /// - The origin process terminated during the run
    /// - The user explicitly cancelled (caller should not call this on cancel)
    func restoreOrigin() {
        guard let origin = originApp else {
            logger.debug("No origin app to restore")
            return
        }

        guard let app = NSRunningApplication(processIdentifier: origin.pid),
              !app.isTerminated else {
            logger.debug("Origin app '\(origin.name)' (pid \(origin.pid)) is no longer running")
            return
        }

        app.activate()
        logger.info("Restored focus to origin app: \(origin.name) (pid \(origin.pid))")
    }

    // MARK: - Target Resolution

    /// Get the target app's AX element and metadata for AX tool use.
    ///
    /// Resolution order:
    /// 1. If a target is set and the process is still running: return it
    /// 2. Find the frontmost non-Shadow app
    /// 3. Return nil if nothing found
    func targetAppInfo() -> (element: ShadowElement, pid: pid_t, name: String, bundleId: String)? {
        // Path 1: Use explicit target if available and alive
        if let target = targetApp {
            let app = NSRunningApplication(processIdentifier: target.pid)
            if let app, !app.isTerminated {
                let element = ShadowElement.application(pid: target.pid)
                return (element: element, pid: target.pid, name: target.name, bundleId: target.bundleId)
            }
            // Target process died — clear it
            logger.warning("Target app '\(target.name)' (pid \(target.pid)) is no longer running")
            targetApp = nil
        }

        // Path 2: Find the frontmost non-Shadow app
        if let app = findNonShadowApp() {
            let pid = app.processIdentifier
            let element = ShadowElement.application(pid: pid)
            return (
                element: element,
                pid: pid,
                name: app.localizedName ?? "Unknown",
                bundleId: app.bundleIdentifier ?? ""
            )
        }

        return nil
    }

    // MARK: - Helpers

    /// Find the frontmost non-Shadow running application.
    /// Uses NSWorkspace ordering which reflects activation order.
    private func findNonShadowApp() -> NSRunningApplication? {
        // First check: is the frontmost app not Shadow?
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != shadowBundleId {
            return front
        }

        // Frontmost is Shadow — find the most recently activated other app.
        // NSWorkspace.runningApplications is NOT ordered by activation time,
        // so we use the menu bar ordering: the frontmost non-Shadow app in
        // the running applications list that has .isActive or was recently active.
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            guard app.bundleIdentifier != shadowBundleId,
                  app.activationPolicy == .regular,
                  !app.isTerminated else { continue }
            return app
        }

        return nil
    }
}
