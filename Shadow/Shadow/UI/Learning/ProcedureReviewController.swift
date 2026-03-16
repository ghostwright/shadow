import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ProcedureReview")

/// Manages a floating NSPanel that displays the procedure review UI.
///
/// Shows the synthesized procedure steps and allows the user to edit the name
/// and save or cancel. Uses the same NSPanel pattern as ProactiveOverlayController.
@MainActor
final class ProcedureReviewController {

    private var panel: NSPanel?

    // MARK: - Show

    /// Show the review panel for a synthesized procedure.
    ///
    /// - Parameters:
    ///   - template: The synthesized procedure to review.
    ///   - onSave: Called when the user saves the (possibly renamed) procedure.
    func show(template: ProcedureTemplate, onSave: @escaping (ProcedureTemplate) -> Void) {
        dismissImmediate()

        let view = ProcedureReviewView(
            template: template,
            onSave: { [weak self] saved in
                onSave(saved)
                self?.dismiss()
            },
            onCancel: { [weak self] in
                self?.dismiss()
            }
        )
        let hosting = NSHostingController(rootView: view)

        let p = NSPanel(contentViewController: hosting)
        p.styleMask = [.titled, .closable, .fullSizeContentView]
        p.level = .floating
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.title = "Review Procedure"
        p.animationBehavior = .utilityWindow
        p.isMovableByWindowBackground = true

        hosting.view.layoutSubtreeIfNeeded()
        let fittingSize = hosting.view.fittingSize
        p.setContentSize(NSSize(width: max(fittingSize.width, 480), height: max(fittingSize.height, 300)))

        positionCenter(p)

        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = p
        logger.info("Procedure review panel shown: \(template.name)")
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
        }
    }

    private func dismissImmediate() {
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Positioning

    private func positionCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        let x = screenFrame.origin.x + (screenFrame.width - panelSize.width) / 2
        let y = screenFrame.origin.y + (screenFrame.height - panelSize.height) / 2

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
