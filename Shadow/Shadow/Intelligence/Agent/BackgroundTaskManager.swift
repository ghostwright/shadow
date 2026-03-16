import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "BackgroundTaskManager")

/// Manages the lifecycle of background agent tasks.
///
/// When the agent needs to interact with another app's UI, the search panel can't stay
/// in the foreground (it would steal focus). The BackgroundTaskManager handles the transition:
///
/// 1. **Enter background**: Dismiss the search panel, show the status indicator,
///    continue the agent run in the background.
/// 2. **Agent works**: The agent focuses other apps, reads their UI, clicks, types, etc.
///    The status indicator shows progress. The user can cancel via the indicator or Option+Escape.
/// 3. **Exit background**: When done, the status indicator shows completion. The user
///    can press Option+Space to re-show the overlay with results, or tap the indicator.
///
/// Thread safety: @MainActor — all UI operations on main thread.
@MainActor
final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()

    /// The status indicator panel shown during background execution.
    private(set) var statusIndicator: AgentStatusIndicator?

    /// Whether a background task is currently running.
    private(set) var isBackgroundTaskActive: Bool = false

    /// Whether a background run completed with results that haven't been viewed yet.
    /// Set to true on complete()/fail(), cleared on exitBackground().
    /// Used by SearchPanelController to decide whether to show results on toggle.
    private(set) var hasUnviewedResults: Bool = false

    /// Callback to dismiss the search panel when entering background.
    var onDismissPanel: (() -> Void)?

    /// Callback to re-show the search panel when the user requests results.
    var onShowPanel: (() -> Void)?

    /// Callback to cancel the agent run via kill switch.
    var onCancelAgent: (() -> Void)?

    private init() {}

    // MARK: - Enter Background

    /// Transition to background execution mode.
    ///
    /// Called when the agent focuses an external app (via ax_focus_app).
    /// Dismisses the search panel and shows the status indicator.
    ///
    /// - Parameter task: Description of the task being executed (user's original query).
    func enterBackground(task: String) {
        guard !isBackgroundTaskActive else {
            logger.debug("Already in background mode")
            return
        }

        isBackgroundTaskActive = true

        // Create and show status indicator
        let indicator = AgentStatusIndicator()
        indicator.onCancel = { [weak self] in
            self?.onCancelAgent?()
        }
        indicator.onShowResults = { [weak self] in
            self?.exitBackground()
            self?.onShowPanel?()
        }
        indicator.show(task: task)
        self.statusIndicator = indicator

        // Dismiss the search panel (agent run continues in background)
        // We do NOT cancel the agent — the agent is still running.
        // The panel dismiss is "visual only" — the SearchViewModel state is preserved.
        // NOTE: We cannot dismiss the panel here because that would cancel the command.
        // Instead, we just order the panel out without cancelling.
        onDismissPanel?()

        DiagnosticsStore.shared.increment("background_task_start_total")
        logger.info("Entered background mode: \(task)")
    }

    // MARK: - Update

    /// Update the status indicator with current progress.
    func updateProgress(currentTool: String?, step: Int, totalSteps: Int) {
        statusIndicator?.updateProgress(currentTool: currentTool, step: step, totalSteps: totalSteps)
    }

    /// Mark the background task as complete.
    func complete(summary: String) {
        statusIndicator?.showComplete(summary: summary)
        isBackgroundTaskActive = false
        hasUnviewedResults = true

        DiagnosticsStore.shared.increment("background_task_complete_total")
        logger.info("Background task complete: \(summary)")
    }

    /// Mark the background task as failed.
    func fail(error: String) {
        statusIndicator?.showFailed(error: error)
        isBackgroundTaskActive = false
        hasUnviewedResults = true

        DiagnosticsStore.shared.increment("background_task_fail_total")
        logger.info("Background task failed: \(error)")
    }

    // MARK: - Exit Background

    /// Exit background mode. Dismisses the status indicator.
    func exitBackground() {
        statusIndicator?.dismiss()
        statusIndicator = nil
        isBackgroundTaskActive = false
        hasUnviewedResults = false

        logger.info("Exited background mode")
    }
}
