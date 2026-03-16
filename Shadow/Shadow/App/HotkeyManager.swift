import Cocoa
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "HotkeyManager")

/// Registers global hotkeys:
/// - **Option+Space**: Opens/dismisses the search overlay (primary hotkey).
/// - **Option+Escape**: Kill switch — cancels all agent procedure execution immediately.
///   This is the highest-priority hotkey and CANNOT be disabled while a procedure is running.
/// - **Cmd+Shift+L**: Toggle learning mode — starts/stops recording user actions for procedure synthesis.
@MainActor
final class HotkeyManager {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var action: (() -> Void)?

    /// Kill switch callback — invoked when Option+Escape is pressed.
    /// Set by ProcedureExecutor when execution starts.
    var killSwitchAction: (() -> Void)?

    /// Learning mode callback — invoked when Cmd+Shift+L is pressed.
    /// Set by AppDelegate to toggle LearningRecorder on/off.
    var learningModeAction: (() -> Void)?

    func register(action: @escaping () -> Void) {
        self.action = action

        // Global monitor: fires when our app is NOT active
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            // Kill switch has highest priority
            if self.isKillSwitch(event) {
                Task { @MainActor in
                    self.killSwitchAction?()
                }
                return
            }
            // Learning mode toggle
            if self.isLearningModeHotkey(event) {
                Task { @MainActor in
                    self.learningModeAction?()
                }
                return
            }
            guard self.isHotkey(event) else { return }
            Task { @MainActor in
                self.action?()
            }
        }

        // Local monitor: fires when our app IS active
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Kill switch has highest priority
            if self.isKillSwitch(event) {
                Task { @MainActor in
                    self.killSwitchAction?()
                }
                return nil // consume the event
            }
            // Learning mode toggle
            if self.isLearningModeHotkey(event) {
                Task { @MainActor in
                    self.learningModeAction?()
                }
                return nil // consume the event
            }
            guard self.isHotkey(event) else { return event }
            Task { @MainActor in
                self.action?()
            }
            return nil // consume the event
        }

        logger.info("Global hotkeys registered (Option+Space, Option+Escape kill switch, Cmd+Shift+L learning)")
    }

    func unregister() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        action = nil
        killSwitchAction = nil
        learningModeAction = nil
        logger.info("Global hotkeys unregistered")
    }

    /// Check if the event matches Option+Space (no other modifiers).
    /// Uses charactersIgnoringModifiers instead of keyCode for keyboard layout
    /// independence — keyCode 49 is space on US QWERTY but may differ on
    /// Dvorak, AZERTY, or other layouts.
    private nonisolated func isHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.charactersIgnoringModifiers == " "
            && flags == .option
    }

    /// Check if the event matches Option+Escape (kill switch).
    /// keyCode 53 is Escape on all keyboard layouts.
    private nonisolated func isKillSwitch(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 53
            && flags == .option
    }

    /// Check if the event matches Cmd+Shift+L (learning mode toggle).
    /// keyCode 37 is L on all standard keyboard layouts.
    private nonisolated func isLearningModeHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 37
            && flags == [.command, .shift]
    }
}
