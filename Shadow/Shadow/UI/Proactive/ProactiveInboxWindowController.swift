import Cocoa
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ProactiveInboxWindow")

/// Manages a dedicated window for the Proactive Inbox.
/// Launched from menu bar or overlay click-through. Non-modal, independent of search panel.
@MainActor
final class ProactiveInboxWindowController {
    private var window: NSWindow?
    private var viewModel: ProactiveInboxViewModel?
    private let proactiveStore: ProactiveStore

    /// Deep-link callback — same path as search/agent evidence.
    var onOpenTimeline: ((UInt64, UInt32?) -> Void)?

    /// Feedback callback — routes through ProactiveDeliveryManager.
    var onFeedback: ((UUID, FeedbackEventType) -> Void)?

    /// Set before calling showOrFocus() to scroll to a specific suggestion.
    var focusSuggestionId: UUID?

    init(proactiveStore: ProactiveStore) {
        self.proactiveStore = proactiveStore
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    func showOrFocus() {
        // Reuse existing window if it hasn't been closed
        if let window {
            // Apply focus target to existing VM if set
            if let focusId = focusSuggestionId {
                viewModel?.focusSuggestionId = focusId
                viewModel?.refresh()
                focusSuggestionId = nil
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = ProactiveInboxViewModel(store: proactiveStore)
        viewModel.onOpenTimeline = { [weak self] ts, displayId in
            self?.onOpenTimeline?(ts, displayId)
        }
        viewModel.onFeedback = { [weak self] suggestionId, eventType in
            self?.onFeedback?(suggestionId, eventType)
        }
        viewModel.focusSuggestionId = focusSuggestionId
        focusSuggestionId = nil
        self.viewModel = viewModel

        let view = ProactiveInboxView(viewModel: viewModel)
        let hosting = NSHostingController(rootView: view)

        let win = NSWindow(contentViewController: hosting)
        win.title = "Proactive Inbox"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 520, height: 680))
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
                self?.viewModel = nil
            }
        }

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        logger.debug("Proactive Inbox window opened")
    }

    func close() {
        window?.orderOut(nil)
    }
}
