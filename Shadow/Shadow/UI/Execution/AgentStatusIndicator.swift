import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "AgentStatusIndicator")

/// A small, non-activating floating panel that shows agent progress during background execution.
///
/// Appears when the agent goes to the background to work on a task (e.g., interacting with
/// another app). Shows the current step, tool being used, and provides a cancel button.
///
/// Design:
/// - Non-activating panel (never steals focus from the target app)
/// - Floating level (always visible, even above other windows)
/// - Compact: ~320x80, positioned at top-right of screen
/// - Translucent material background matching system appearance
/// - Auto-dismisses 5 seconds after completion
///
/// The panel is managed by `BackgroundTaskManager`, which creates it when entering
/// background mode and dismisses it when the task completes or is cancelled.
@MainActor
final class AgentStatusIndicator {

    private var panel: NSPanel?

    /// Current state displayed in the indicator.
    private(set) var state: IndicatorState = .idle

    /// Cancel callback — routes to the kill switch.
    var onCancel: (() -> Void)?

    /// Callback when user taps to re-show the search panel with results.
    var onShowResults: (() -> Void)?

    enum IndicatorState: Equatable {
        case idle
        case working(task: String, currentTool: String?, step: Int, totalSteps: Int)
        case complete(task: String, summary: String)
        case failed(task: String, error: String)
    }

    // MARK: - Show

    /// Show the indicator for a background task.
    func show(task: String) {
        state = .working(task: task, currentTool: nil, step: 0, totalSteps: 0)
        renderPanel()
        logger.info("Agent status indicator shown: \(task)")
    }

    // MARK: - Update

    /// Update the indicator with current progress.
    func updateProgress(currentTool: String?, step: Int, totalSteps: Int) {
        guard case .working(let task, _, _, _) = state else { return }
        state = .working(task: task, currentTool: currentTool, step: step, totalSteps: totalSteps)
        renderPanel()
    }

    /// Mark the task as complete.
    func showComplete(summary: String) {
        guard case .working(let task, _, _, _) = state else { return }
        state = .complete(task: task, summary: summary)
        renderPanel()

        // Auto-dismiss after 5 seconds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            // Only dismiss if still showing completion (user might have already dismissed)
            if case .complete = self.state {
                self.dismiss()
            }
        }
    }

    /// Mark the task as failed.
    func showFailed(error: String) {
        guard case .working(let task, _, _, _) = state else { return }
        state = .failed(task: task, error: error)
        renderPanel()

        // Auto-dismiss after 8 seconds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if case .failed = self.state {
                self.dismiss()
            }
        }
    }

    // MARK: - Dismiss

    func dismiss() {
        guard let panel else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
            self?.state = .idle
        }

        logger.info("Agent status indicator dismissed")
    }

    // MARK: - Rendering

    private func renderPanel() {
        let view = AgentStatusView(
            state: state,
            onCancel: { [weak self] in
                self?.onCancel?()
            },
            onShowResults: { [weak self] in
                self?.onShowResults?()
            }
        )
        let hosting = NSHostingController(rootView: view)

        if let existing = panel {
            existing.contentViewController = hosting
        } else {
            let p = NSPanel(contentViewController: hosting)
            p.styleMask = [.nonactivatingPanel, .fullSizeContentView, .titled]
            p.level = .floating
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.animationBehavior = .utilityWindow
            p.isMovableByWindowBackground = true

            hosting.view.layoutSubtreeIfNeeded()
            let fittingSize = hosting.view.fittingSize
            p.setContentSize(NSSize(
                width: max(fittingSize.width, 320),
                height: max(fittingSize.height, 72)
            ))

            positionTopRight(p)

            p.alphaValue = 0
            p.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 1.0
            }

            self.panel = p
        }
    }

    private func positionTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 16
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        let x = screenFrame.maxX - panelSize.width - margin
        let y = screenFrame.origin.y + screenFrame.height - panelSize.height - margin

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Status View

/// SwiftUI view for the agent status indicator.
private struct AgentStatusView: View {
    let state: AgentStatusIndicator.IndicatorState
    let onCancel: () -> Void
    let onShowResults: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            statusContent
            Spacer()
            actionButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .idle:
            EmptyView()
        case .working:
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 20, height: 20)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 18))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 18))
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch state {
        case .idle:
            EmptyView()

        case .working(let task, let tool, let step, _):
            VStack(alignment: .leading, spacing: 2) {
                Text(task)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if let tool {
                    Text(formatToolName(tool))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if step > 0 {
                    Text("Step \(step)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Starting...")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

        case .complete(_, let summary):
            VStack(alignment: .leading, spacing: 2) {
                Text("Complete")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        case .failed(_, let error):
            VStack(alignment: .leading, spacing: 2) {
                Text("Failed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .idle:
            EmptyView()
        case .working:
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("Cancel (Option+Escape)")
        case .complete:
            Button(action: onShowResults) {
                Image(systemName: "arrow.up.forward.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("Show results")
        case .failed:
            Button(action: onShowResults) {
                Image(systemName: "arrow.up.forward.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("Show details")
        }
    }

    /// Format a tool name for display (e.g., "ax_tree_query" -> "Reading UI tree").
    private func formatToolName(_ name: String) -> String {
        let displayNames: [String: String] = [
            "ax_tree_query": "Reading UI tree",
            "ax_click": "Clicking element",
            "ax_type": "Typing text",
            "ax_hotkey": "Pressing hotkey",
            "ax_scroll": "Scrolling",
            "ax_wait": "Waiting for UI",
            "ax_focus_app": "Switching app",
            "ax_read_text": "Reading text",
            "search_hybrid": "Searching",
            "inspect_screenshots": "Inspecting screen",
            "get_transcript_window": "Reading transcript",
            "get_timeline_context": "Getting context",
            "get_day_summary": "Getting summary",
            "get_activity_sequence": "Getting activity",
            "resolve_latest_meeting": "Finding meeting",
            "search_visual_memories": "Visual search",
            "search_summaries": "Searching summaries",
            "get_knowledge": "Checking knowledge",
            "set_directive": "Creating directive",
            "get_directives": "Listing directives",
            "get_procedures": "Finding procedures",
            "replay_procedure": "Running procedure",
        ]
        return displayNames[name] ?? name
    }
}
