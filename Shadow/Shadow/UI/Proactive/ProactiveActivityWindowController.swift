import Cocoa
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ProactiveActivityWindow")

/// Manages a dedicated window for inspecting proactive engine activity.
/// Launched from the Diagnostics view. Non-modal, independent of search panel.
@MainActor
final class ProactiveActivityWindowController {
    private var window: NSWindow?
    private let proactiveStore: ProactiveStore
    private let trustTuner: TrustTuner

    /// Deep-link callback — same path as search/agent evidence.
    var onOpenTimeline: ((UInt64, UInt32?) -> Void)?

    init(proactiveStore: ProactiveStore, trustTuner: TrustTuner) {
        self.proactiveStore = proactiveStore
        self.trustTuner = trustTuner
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    func showOrFocus() {
        // Reuse existing window if it hasn't been closed
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = ProactiveActivityViewModel(
            store: proactiveStore,
            tuner: trustTuner
        )
        viewModel.onOpenTimeline = { [weak self] ts, displayId in
            self?.onOpenTimeline?(ts, displayId)
        }

        let view = ProactiveActivityView(viewModel: viewModel)
        let hosting = NSHostingController(rootView: view)

        let win = NSWindow(contentViewController: hosting)
        win.title = "Proactive Activity"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 560, height: 640))
        win.minSize = NSSize(width: 420, height: 400)
        win.center()

        // Nil out our reference when the window is closed so we create a fresh one next time
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window = nil
            }
        }

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        logger.debug("Proactive Activity window opened")
    }

    func close() {
        window?.orderOut(nil)
    }
}
