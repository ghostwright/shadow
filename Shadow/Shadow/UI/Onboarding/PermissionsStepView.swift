import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "PermissionsStep")

/// Step 2 of onboarding: Permission grants.
///
/// Small ghost (32x32) in the top-left, still animated (breathing, blinking).
/// 5 permissions in order with title, description, status indicator, action button.
/// Progress bar (5 segments). Stuck-state escalation. Ghost bounces on each grant.
/// Screen Recording restart flow. All 5 permissions are required.
struct PermissionsStepView: View {
    @Bindable var permissions: PermissionManager
    @Binding var ghostMood: GhostMood

    /// Called when the user taps "Continue to Setup" (advances to modelSetup step).
    let onContinue: @MainActor () -> Void

    // MARK: - State

    /// Whether Screen Recording was already granted when this step appeared.
    /// If it transitions false -> true during this step, a restart is needed.
    @State private var screenRecordingWasGranted: Bool = false

    /// Tracks previous grant count to detect new grants (for ghost bounce + window-to-front).
    @State private var prevGrantedCount: Int = 0

    /// Per-permission stuck-state wait start times (keyed by permission index 0-4).
    @State private var waitStartTimes: [Int: Date] = [:]

    /// Current stuck-state elapsed seconds per permission (updated by timer).
    @State private var waitElapsed: [Int: TimeInterval] = [:]

    /// Timer handle for the stuck-state elapsed time updater.
    @State private var stuckTimer: Timer?

    /// Timer handle for the ghost mood reset (after excited bounce).
    @State private var moodResetTimer: Timer?

    // MARK: - Computed Properties

    /// Count of currently granted permissions (of 5 total).
    private var grantedCount: Int {
        [permissions.screenRecordingGranted,
         permissions.inputMonitoringGranted,
         permissions.accessibilityGranted,
         permissions.microphoneGranted,
         permissions.speechRecognitionGranted].filter(\.self).count
    }

    /// The first ungranted permission index in order, or nil if all are granted.
    private var nextStep: Int? {
        if !permissions.screenRecordingGranted { return 0 }
        if !permissions.inputMonitoringGranted { return 1 }
        if !permissions.accessibilityGranted { return 2 }
        if !permissions.microphoneGranted { return 3 }
        if !permissions.speechRecognitionGranted { return 4 }
        return nil
    }

    /// Whether Screen Recording was granted during this onboarding session
    /// (meaning a restart is required for it to take effect).
    private var needsRestart: Bool {
        !screenRecordingWasGranted && permissions.screenRecordingGranted
    }

    // MARK: - Permission Definitions

    private struct PermissionInfo {
        let index: Int
        let icon: String
        let title: String
        let description: String
        let isGranted: () -> Bool
        let action: () -> Void
        let buttonLabel: String
    }

    private var allPermissions: [PermissionInfo] {
        [
            PermissionInfo(
                index: 0,
                icon: "rectangle.inset.filled.and.person.filled",
                title: "Screen Recording",
                description: "Captures your screen so you can search and replay any moment from your day.",
                isGranted: { permissions.screenRecordingGranted },
                action: { permissions.requestScreenRecording() },
                buttonLabel: "Open Settings"
            ),
            PermissionInfo(
                index: 1,
                icon: "keyboard",
                title: "Input Monitoring",
                description: "Tracks what you type and click so you can find anything by what you were doing.",
                isGranted: { permissions.inputMonitoringGranted },
                action: {
                    permissions.canProbeInputMonitoring = true
                    permissions.requestInputMonitoring()
                },
                buttonLabel: "Open Settings"
            ),
            PermissionInfo(
                index: 2,
                icon: "hand.raised",
                title: "Accessibility",
                description: "Reads window titles and browser URLs to know what app you were using.",
                isGranted: { permissions.accessibilityGranted },
                action: { permissions.openAccessibilitySettings() },
                buttonLabel: "Open Settings"
            ),
            PermissionInfo(
                index: 3,
                icon: "mic",
                title: "Microphone",
                description: "Records meeting audio so you can search what was said.",
                isGranted: { permissions.microphoneGranted },
                action: { permissions.requestMicrophone() },
                buttonLabel: "Grant Access"
            ),
            PermissionInfo(
                index: 4,
                icon: "waveform",
                title: "Speech Recognition",
                description: "Transcribes audio into searchable text on-device.",
                isGranted: { permissions.speechRecognitionGranted },
                action: { permissions.requestSpeechRecognition() },
                buttonLabel: "Grant Access"
            ),
        ]
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Top: small ghost + title
            headerSection
                .padding(.top, 28)

            // Progress bar
            progressBar
                .padding(.horizontal, 40)
                .padding(.top, 20)
                .padding(.bottom, 20)

            // Permission list (scrollable if needed)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(allPermissions, id: \.index) { perm in
                        permissionRow(perm)
                    }
                }
                .padding(.horizontal, 28)
            }

            Spacer(minLength: 0)

            // Footer: privacy note + action button
            footerSection
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            screenRecordingWasGranted = permissions.screenRecordingGranted
            // Check if Screen Recording was granted during a previous session (restart scenario)
            if UserDefaults.standard.bool(forKey: "onboardingScreenRecordingGrantedDuringSession") {
                screenRecordingWasGranted = true
            }
            prevGrantedCount = grantedCount
            ghostMood = .neutral
            permissions.checkAll()
            logger.info("Permissions step appeared. Screen recording was granted: \(self.screenRecordingWasGranted)")
        }
        .onDisappear {
            cleanupTimers()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            permissions.checkAll()
            handlePermissionChange()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            // Ghost, 56x56, still animated
            ExpressiveGhostView(mood: $ghostMood, size: 56)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                Text(headerSubtitle)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private var headerTitle: String {
        if permissions.allGranted {
            return needsRestart ? "Almost there" : "You're all set"
        }
        return "Shadow needs access"
    }

    private var headerSubtitle: String {
        if permissions.allGranted {
            if needsRestart {
                return "Shadow needs to restart for Screen Recording\nto take effect."
            }
            return "Shadow has everything it needs."
        }
        return "Shadow needs a few permissions to record\nyour screen, audio, and make everything searchable."
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(isSegmentGranted(i) ? OnboardingTheme.accent : Color.secondary.opacity(0.15))
                    .frame(height: 6)
                    .animation(.easeInOut(duration: 0.4), value: grantedCount)
            }

            Text("\(grantedCount) of 5")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.leading, 4)
        }
    }

    /// Map segment index to whether that specific permission is granted.
    private func isSegmentGranted(_ index: Int) -> Bool {
        switch index {
        case 0: return permissions.screenRecordingGranted
        case 1: return permissions.inputMonitoringGranted
        case 2: return permissions.accessibilityGranted
        case 3: return permissions.microphoneGranted
        case 4: return permissions.speechRecognitionGranted
        default: return false
        }
    }

    // MARK: - Permission Row

    private func permissionRow(_ perm: PermissionInfo) -> some View {
        let granted = perm.isGranted()
        let isNext = (nextStep == perm.index)
        let isFuture = !granted && !isNext
        let elapsed = waitElapsed[perm.index] ?? 0

        return HStack(alignment: .top, spacing: 14) {
            // Step indicator circle
            ZStack {
                Circle()
                    .fill(granted
                          ? Color.green
                          : (isNext ? OnboardingTheme.accent : Color.secondary.opacity(0.12)))
                    .frame(width: 38, height: 38)

                if granted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(perm.index + 1)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isNext ? .white : .secondary)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: granted)

            VStack(alignment: .leading, spacing: 4) {
                // Title row
                HStack(spacing: 6) {
                    Image(systemName: perm.icon)
                        .font(.body)
                        .foregroundColor(granted ? .green : (isNext ? .white : .white.opacity(0.3)))

                    Text(perm.title)
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(isFuture ? .white.opacity(0.4) : .white)
                }

                // Description
                Text(perm.description)
                    .font(.callout)
                    .foregroundStyle(isFuture ? .white.opacity(0.2) : .white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                // Action button + waiting/stuck states (only for active step)
                if isNext {
                    Button {
                        perm.action()
                        startWaiting(for: perm.index)
                    } label: {
                        Text(perm.buttonLabel)
                            .frame(minWidth: OnboardingTheme.secondaryButtonMinWidth)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(OnboardingTheme.accent)
                    .padding(.top, 4)

                    // Waiting state (only after button clicked)
                    if waitStartTimes[perm.index] != nil {
                        stuckStateView(for: perm, elapsed: elapsed)
                            .padding(.top, 4)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 10)
    }

    // MARK: - Stuck State View

    @ViewBuilder
    private func stuckStateView(for perm: PermissionInfo, elapsed: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Waiting indicator (always shown once button clicked)
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.5))
                Text("Waiting for permission...")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.4))
            }

            // 8s hint
            if elapsed >= 8 {
                Text("Look for Shadow in the list and toggle it on.")
                    .font(.callout)
                    .foregroundStyle(OnboardingTheme.accent)
                    .transition(.opacity.animation(.easeOut(duration: 0.3)))
            }

            // 15s extended hint
            if elapsed >= 15 {
                Text("Still stuck? In System Settings, find Privacy & Security, then \(perm.title). Make sure Shadow's toggle is on.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.animation(.easeOut(duration: 0.3)))
            }

            // 30s help link
            if elapsed >= 30 {
                Button {
                    openPrivacySettings(for: perm)
                } label: {
                    Text("Need help?")
                        .font(.callout)
                        .foregroundStyle(OnboardingTheme.accent)
                        .underline()
                }
                .buttonStyle(.plain)
                .transition(.opacity.animation(.easeOut(duration: 0.3)))

                Text("Opens System Settings > Privacy & Security > \(perm.title).")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 16) {
            // Privacy note (always visible)
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                Text("All data stays on your Mac. Nothing is uploaded.")
                    .font(.callout)
            }
            .foregroundStyle(.white.opacity(0.3))

            // Action button (visible when all 5 permissions are granted)
            if permissions.allGranted {
                if needsRestart {
                    Button {
                        performRestart()
                    } label: {
                        Text("Restart Shadow")
                            .frame(minWidth: OnboardingTheme.primaryButtonMinWidth, minHeight: 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(OnboardingTheme.accent)
                } else {
                    Button {
                        logger.info("User tapped Continue to Setup")
                        onContinue()
                    } label: {
                        Text("Continue to Setup")
                            .frame(minWidth: OnboardingTheme.primaryButtonMinWidth, minHeight: 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(OnboardingTheme.accent)
                }
            }
        }
    }

    // MARK: - Permission Change Detection

    private func handlePermissionChange() {
        let newCount = grantedCount
        if newCount > prevGrantedCount {
            logger.info("New permission granted (count \(self.prevGrantedCount) -> \(newCount))")
            prevGrantedCount = newCount

            // Ghost bounce: set excited, reset after 0.6s
            ghostMood = .excited
            moodResetTimer?.invalidate()
            moodResetTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
                MainActor.assumeIsolated {
                    self.ghostMood = .neutral
                }
            }

            // Bring window to front
            NSApp.activate(ignoringOtherApps: true)
            NSApp.keyWindow?.makeKeyAndOrderFront(nil)

            // Clear any stuck-state timers for permissions that are now granted
            clearGrantedWaitStates()
        }
    }

    // MARK: - Stuck-State Timing

    private func startWaiting(for index: Int) {
        guard waitStartTimes[index] == nil else { return }
        waitStartTimes[index] = Date()
        logger.debug("Started waiting for permission at index \(index)")

        // Start the 1-second tick timer for stuck-state UI if not already running
        if stuckTimer == nil {
            stuckTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    self.updateWaitElapsed()
                }
            }
        }
    }

    private func updateWaitElapsed() {
        let now = Date()
        for (index, start) in waitStartTimes {
            waitElapsed[index] = now.timeIntervalSince(start)
        }
    }

    private func clearGrantedWaitStates() {
        // Remove wait states for any permissions that are now granted
        for perm in allPermissions where perm.isGranted() {
            waitStartTimes.removeValue(forKey: perm.index)
            waitElapsed.removeValue(forKey: perm.index)
        }

        // If no more wait states, stop the timer
        if waitStartTimes.isEmpty {
            stuckTimer?.invalidate()
            stuckTimer = nil
        }
    }

    // MARK: - Help: Open Privacy Settings

    /// Opens System Settings to the Privacy & Security pane for the given permission.
    private func openPrivacySettings(for perm: PermissionInfo) {
        logger.info("User requested help for \(perm.title) at index \(perm.index)")

        // Deep-link into System Settings > Privacy & Security for the relevant permission.
        // These URLs work on macOS 14+.
        let urlString: String
        switch perm.index {
        case 0: urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case 1: urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case 2: urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case 3: urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case 4: urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        default: urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Screen Recording Restart

    private func performRestart() {
        logger.info("User initiated restart for Screen Recording")

        // Persist onboarding state so we resume at permissions after restart
        OnboardingStep.permissions.persist()
        UserDefaults.standard.set(false, forKey: "onboardingCompleted")
        UserDefaults.standard.set(true, forKey: "onboardingScreenRecordingGrantedDuringSession")

        // Relaunch: open a new instance, then quit this one
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Cleanup

    private func cleanupTimers() {
        stuckTimer?.invalidate()
        stuckTimer = nil
        moodResetTimer?.invalidate()
        moodResetTimer = nil
    }
}
