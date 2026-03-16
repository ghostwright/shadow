import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ExecutionProgress")

/// Manages a non-activating floating NSPanel that shows procedure execution progress.
///
/// The panel appears near the top-right of the screen, never steals focus.
/// Updated in real-time as ExecutionEvents arrive from ProcedureExecutor.
@MainActor
final class ExecutionProgressController {

    private var panel: NSPanel?
    private var procedureName: String = ""
    private var steps: [StepStatus] = []
    private var currentStepIndex: Int?

    /// Kill switch callback — invoked when user clicks Cancel in the progress panel.
    var onCancel: (() -> Void)?

    // MARK: - Show

    /// Show the execution progress panel for a procedure.
    func show(procedure: ProcedureTemplate) {
        dismissImmediate()

        procedureName = procedure.name
        steps = procedure.steps.map { step in
            StepStatus(intent: step.intent, state: .pending)
        }
        currentStepIndex = nil

        renderPanel()

        logger.info("Execution progress panel shown: \(procedure.name)")
    }

    // MARK: - Update

    /// Update the panel based on an execution event.
    func handleEvent(_ event: ExecutionEvent) {
        switch event {
        case .stepStarting(let index, _):
            if index < steps.count {
                steps[index] = StepStatus(intent: steps[index].intent, state: .running)
            }
            currentStepIndex = index

        case .stepCompleted(let index, _, _):
            if index < steps.count {
                steps[index] = StepStatus(intent: steps[index].intent, state: .completed)
            }

        case .stepFailed(let index, _):
            if index < steps.count {
                steps[index] = StepStatus(intent: steps[index].intent, state: .failed)
            }

        case .stepRetrying(let index, _, _):
            if index < steps.count {
                steps[index] = StepStatus(intent: steps[index].intent, state: .running)
            }

        case .executionCompleted(_, _):
            // Auto-dismiss after a brief delay
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.dismiss()
            }

        case .executionFailed(_, _):
            // Stay visible so user sees the failure
            break

        case .executionCancelled(_):
            dismiss()

        case .safetyGateTriggered(_, _, _):
            break
        }

        renderPanel()
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

    // MARK: - Rendering

    private func renderPanel() {
        let view = ExecutionProgressView(
            procedureName: procedureName,
            steps: steps,
            currentStepIndex: currentStepIndex,
            onCancel: { [weak self] in
                self?.onCancel?()
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
            p.setContentSize(NSSize(width: max(fittingSize.width, 340), height: max(fittingSize.height, 200)))

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

    // MARK: - Positioning

    private func positionTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 20
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        let x = screenFrame.maxX - panelSize.width - margin
        let y = screenFrame.origin.y + screenFrame.height - panelSize.height - margin

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
