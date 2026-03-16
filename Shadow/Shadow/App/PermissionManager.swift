import Cocoa
@preconcurrency import AVFoundation
@preconcurrency import Speech
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "Permissions")

/// Checks and tracks macOS permission state for Shadow's capture subsystems.
@Observable
@MainActor
final class PermissionManager {
    // MARK: - Core permissions (required for capture)

    var screenRecordingGranted: Bool = false
    var accessibilityGranted: Bool = false
    var inputMonitoringGranted: Bool = false

    // MARK: - Audio permissions (optional — audio/transcript lanes disabled when denied)

    var microphoneGranted: Bool = false
    var speechRecognitionGranted: Bool = false

    /// Whether it's safe to probe Input Monitoring via CGEventTap.
    /// On macOS Sequoia, creating a CGEventTap triggers a system permission
    /// dialog if Input Monitoring hasn't been granted yet. We only probe
    /// after the user has been through onboarding or if they've already
    /// granted all permissions on a previous launch.
    var canProbeInputMonitoring = false

    /// Check all permissions. Call on launch and periodically.
    ///
    /// - Parameter probeInputMonitoring: Whether to probe Input Monitoring via CGEventTap.
    ///   Set to false when calling from MenuBarView.onAppear -- the probe can give false
    ///   negatives on macOS Sequoia. The reconciler sets inputMonitoringGranted from
    ///   real InputMonitor health instead.
    func checkAll(probeInputMonitoring: Bool = true) {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()

        if canProbeInputMonitoring && probeInputMonitoring {
            inputMonitoringGranted = Self.checkInputMonitoring()
        }

        // Audio permissions — safe to check without triggering prompts
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechRecognitionGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Check Input Monitoring permission by attempting to create a CGEventTap.
    /// There is no direct API for this. The tap creation succeeds even without
    /// permission, but `CGEvent.tapIsEnabled` returns false when the system
    /// won't deliver events due to a stale TCC entry.
    ///
    /// IMPORTANT: Only call after the user has gone through onboarding,
    /// because CGEvent.tapCreate triggers a system dialog on macOS Sequoia
    /// if Input Monitoring hasn't been granted yet.
    private static func checkInputMonitoring() -> Bool {
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        guard let tap else { return false }
        let enabled = CGEvent.tapIsEnabled(tap: tap)
        // Don't leave the test tap running
        CGEvent.tapEnable(tap: tap, enable: false)
        return enabled
    }

    // MARK: - Core permission requests

    /// Request Screen Recording permission (opens system prompt).
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    /// Open System Settings to the Accessibility pane.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Request Input Monitoring permission.
    ///
    /// On macOS Sequoia, creating a CGEventTap triggers the system's
    /// "Keystroke Receiving" dialog — this is the primary grant mechanism.
    /// We create a temporary tap to trigger this dialog. If the dialog was
    /// already shown (user previously denied), we also open System Settings
    /// as a fallback so the user can toggle the switch manually.
    func requestInputMonitoring() {
        // Create a temporary CGEventTap to trigger the system dialog.
        // On Sequoia, this shows "Shadow would like to receive keystrokes
        // from any application" with Allow/Don't Allow buttons.
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        if let tap {
            let enabled = CGEvent.tapIsEnabled(tap: tap)
            CGEvent.tapEnable(tap: tap, enable: false)
            if enabled {
                // Already granted — update state immediately
                inputMonitoringGranted = true
                return
            }
        }

        // Fallback: also open System Settings in case the system dialog
        // was already shown and dismissed on a previous attempt.
        openInputMonitoringSettings()
    }

    // MARK: - Audio permission requests

    /// Request Microphone permission. Shows system dialog if not yet determined.
    /// If previously denied/restricted, opens System Settings instead (request API is a no-op).
    func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                await MainActor.run {
                    self.microphoneGranted = granted
                }
            }
        case .authorized:
            microphoneGranted = true
        case .denied, .restricted:
            logger.info("Microphone previously denied — opening System Settings")
            openMicrophoneSettings()
        @unknown default:
            openMicrophoneSettings()
        }
    }

    /// Request Speech Recognition permission. Shows system dialog if not yet determined.
    /// If previously denied/restricted, opens System Settings instead (request API is a no-op).
    func requestSpeechRecognition() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            Task {
                let status = await Self.awaitSpeechAuthorization()
                self.speechRecognitionGranted = (status == .authorized)
            }
        case .authorized:
            speechRecognitionGranted = true
        case .denied, .restricted:
            logger.info("Speech Recognition previously denied — opening System Settings")
            openSpeechRecognitionSettings()
        @unknown default:
            openSpeechRecognitionSettings()
        }
    }

    /// Bridge `SFSpeechRecognizer.requestAuthorization` to async.
    ///
    /// Must be `nonisolated static` so the callback closure is formed outside any
    /// `@MainActor` context. In Swift 6, closures inherit actor isolation from their
    /// enclosing scope — even through nested closures. If formed inside a `@MainActor`
    /// method (even via Task + withCheckedContinuation), the runtime inserts an executor
    /// check at closure entry that crashes when the callback fires on a background queue
    /// (`dispatch_assert_queue_fail` / EXC_BREAKPOINT).
    private nonisolated static func awaitSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Settings pane URLs

    /// Open System Settings to the Input Monitoring pane.
    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings to the Screen Recording pane.
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings to the Microphone pane.
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings to the Speech Recognition pane.
    func openSpeechRecognitionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Aggregate state

    /// Core permissions required for basic capture (screen, input, accessibility).
    /// Gates the "Get Started" button in onboarding.
    var coreGranted: Bool {
        screenRecordingGranted && accessibilityGranted && inputMonitoringGranted
    }

    /// Audio permissions (microphone + speech recognition).
    /// When false, audio capture and transcription lanes are disabled.
    var audioGranted: Bool {
        microphoneGranted && speechRecognitionGranted
    }

    /// All permissions granted (core + audio).
    var allGranted: Bool {
        coreGranted && audioGranted
    }

    /// Description of what's missing.
    var missingPermissions: [String] {
        var missing: [String] = []
        if !screenRecordingGranted { missing.append("Screen Recording") }
        if !accessibilityGranted { missing.append("Accessibility") }
        if !inputMonitoringGranted { missing.append("Input Monitoring") }
        if !microphoneGranted { missing.append("Microphone") }
        if !speechRecognitionGranted { missing.append("Speech Recognition") }
        return missing
    }
}
