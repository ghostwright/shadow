import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ProactiveOverlayController")

/// Manages a non-activating floating NSPanel that displays push_now suggestion nudges.
///
/// The panel appears bottom-right, never steals focus, and auto-dismisses after 30 seconds.
/// Clicking the card opens the inbox; the X button dismisses immediately.
///
/// Window leak prevention: `dismiss()` is called from four paths (replace, timer, user dismiss,
/// open inbox). Each path invalidates the timer, orders the panel out, and nils references.
@MainActor
final class ProactiveOverlayController {

    /// How long the nudge stays visible before auto-dismissing.
    static let autoHideInterval: TimeInterval = 30.0

    private var panel: NSPanel?
    private var autoDismissTimer: Timer?
    private var currentSuggestionId: UUID?

    /// Callback when user clicks the nudge card to open inbox.
    var onOpenInbox: ((UUID?) -> Void)?

    // MARK: - Show

    /// Show a push_now suggestion as a floating nudge.
    ///
    /// Dismisses any existing nudge first. Creates a fresh panel each time
    /// to avoid stale SwiftUI state. Fade-in animation over 0.3s.
    func show(_ suggestion: ProactiveSuggestion) {
        // Clear any existing nudge
        dismissImmediate()

        currentSuggestionId = suggestion.id

        let view = ProactiveOverlayView(
            suggestion: suggestion,
            onDismiss: { [weak self] in
                DiagnosticsStore.shared.increment("proactive_overlay_dismissed_total")
                self?.dismiss()
            },
            onOpenInbox: { [weak self] in
                DiagnosticsStore.shared.increment("proactive_overlay_clicked_total")
                let id = self?.currentSuggestionId
                self?.dismissImmediate()
                self?.onOpenInbox?(id)
            }
        )
        let hosting = NSHostingController(rootView: view)

        let p = NSPanel(contentViewController: hosting)
        p.styleMask = [.nonactivatingPanel, .fullSizeContentView, .titled]
        p.level = .floating
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.animationBehavior = .utilityWindow

        // Force layout so hosting controller computes intrinsic content size
        hosting.view.layoutSubtreeIfNeeded()
        let fittingSize = hosting.view.fittingSize
        p.setContentSize(NSSize(width: max(fittingSize.width, 340), height: max(fittingSize.height, 60)))

        // Position bottom-right
        positionBottomRight(p)

        // Fade in
        p.alphaValue = 0
        p.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().alphaValue = 1.0
        }

        self.panel = p

        // Auto-dismiss timer
        autoDismissTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoHideInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                DiagnosticsStore.shared.increment("proactive_overlay_autodismiss_total")
                self?.dismiss()
            }
        }

        DiagnosticsStore.shared.increment("proactive_overlay_shown_total")
        logger.info("Overlay shown for suggestion: \(suggestion.id)")
    }

    // MARK: - Dismiss

    /// Dismiss with fade-out animation (0.2s).
    func dismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil

        guard let panel else {
            currentSuggestionId = nil
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
            self?.currentSuggestionId = nil
        }
    }

    /// Dismiss without animation (for replacement or immediate cleanup).
    private func dismissImmediate() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
        currentSuggestionId = nil
    }

    // MARK: - Positioning

    /// Position the panel at bottom-right of the main screen's visible area.
    private func positionBottomRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 20
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        let x = screenFrame.maxX - panelSize.width - margin
        let y = screenFrame.origin.y + margin

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
