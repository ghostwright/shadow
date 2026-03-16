import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "LearningIndicator")

/// Manages a non-activating floating NSPanel that shows the learning mode indicator.
///
/// The panel appears top-center, never steals focus, and stays visible until dismissed.
/// Uses the same NSPanel pattern as ProactiveOverlayController.
@MainActor
final class LearningIndicatorController {

    private var panel: NSPanel?
    private var elapsedTimer: Timer?
    private var elapsedSeconds: Int = 0
    private var actionCount: Int = 0

    /// Callback invoked when the user clicks Stop.
    var onStop: (() -> Void)?

    // MARK: - Show

    func show() {
        dismissImmediate()

        elapsedSeconds = 0
        actionCount = 0

        let view = LearningIndicatorView(
            elapsedSeconds: elapsedSeconds,
            actionCount: actionCount,
            onStop: { [weak self] in
                self?.onStop?()
            }
        )
        let hosting = NSHostingController(rootView: view)

        let p = NSPanel(contentViewController: hosting)
        p.styleMask = [.nonactivatingPanel, .fullSizeContentView]
        p.level = .floating
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.animationBehavior = .utilityWindow

        hosting.view.layoutSubtreeIfNeeded()
        let fittingSize = hosting.view.fittingSize
        p.setContentSize(NSSize(width: max(fittingSize.width, 300), height: max(fittingSize.height, 36)))

        positionTopCenter(p)

        // Fade in
        p.alphaValue = 0
        p.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1.0
        }

        self.panel = p

        // Start elapsed time counter
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickElapsed()
            }
        }

        logger.info("Learning indicator shown")
    }

    // MARK: - Update

    /// Update the action count displayed in the indicator.
    func updateActionCount(_ count: Int) {
        actionCount = count
        refreshView()
    }

    private func tickElapsed() {
        elapsedSeconds += 1
        refreshView()
    }

    private func refreshView() {
        guard let panel else { return }

        let view = LearningIndicatorView(
            elapsedSeconds: elapsedSeconds,
            actionCount: actionCount,
            onStop: { [weak self] in
                self?.onStop?()
            }
        )
        let hosting = NSHostingController(rootView: view)
        panel.contentViewController = hosting
    }

    // MARK: - Dismiss

    func dismiss() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        guard let panel else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
    }

    private func dismissImmediate() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Positioning

    private func positionTopCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        let x = screenFrame.origin.x + (screenFrame.width - panelSize.width) / 2
        let y = screenFrame.origin.y + screenFrame.height - panelSize.height - 8

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
