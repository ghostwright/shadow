import SwiftUI
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "LaunchStep")

/// Step 4 of onboarding: The send-off.
///
/// The ghost is in its happiest state. Streaming text delivers the final message.
/// After text completes, a usage hints bar and "Start Shadow" button fade in.
/// Clicking Start Shadow persists completion, closes the window (which triggers
/// capture start in AppDelegate.onboardingWindowWillClose), and optionally
/// sends a one-time macOS notification.
struct LaunchStepView: View {
    @Binding var ghostMood: GhostMood

    /// Called when the user clicks "Start Shadow."
    let onContinue: @MainActor () -> Void

    // MARK: - Text Groups (exact copy from spec)

    private let textGroups: [[String]] = [
        [
            "Shadow is ready.",
        ],
        [
            "From now on, every screen you see,",
            "every conversation you have,",
            "every moment of focus is remembered.",
        ],
        [
            "Shadow lives in your menu bar.",
            "Look for the ghost icon at the top of your screen.",
        ],
        [
            "Press Option + Space anytime to search your day.",
        ],
        [
            "Open the timeline to see your entire day as a visual story.",
        ],
    ]

    // MARK: - State

    /// Set to true to fast-forward all streaming text.
    @State private var revealAll = false

    /// Whether the streaming text has finished revealing.
    @State private var textComplete = false

    /// Whether the usage hints bar should be visible (delayed after text completes).
    @State private var showHints = false

    /// Whether the Start Shadow button should be visible (delayed after text completes).
    @State private var showStartButton = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 36)

            // Ghost: 140x140, happy mood
            ExpressiveGhostView(mood: $ghostMood, size: 140)
                .frame(width: 140, height: 140)

            Spacer()
                .frame(height: 24)

            // Streaming narrative text
            StreamingTextView(
                groups: textGroups,
                characterDelay: 0.035,
                groupPause: 0.65,
                revealAll: $revealAll,
                onComplete: { @MainActor in
                    textComplete = true
                    logger.debug("Launch text streaming complete")

                    // Show hints bar with 0.3s delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        MainActor.assumeIsolated {
                            withAnimation(.easeOut(duration: 0.3)) {
                                showHints = true
                            }
                        }
                    }

                    // Show Start Shadow button with 0.5s delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        MainActor.assumeIsolated {
                            withAnimation(.easeOut(duration: 0.3)) {
                                showStartButton = true
                            }
                        }
                    }
                }
            )
            .padding(.horizontal, 40)

            Spacer()
                .frame(minHeight: 12, maxHeight: 24)

            // Usage hints bar (fades in after text completes)
            if showHints {
                usageHintsBar
                    .transition(.opacity)
            }

            Spacer()
                .frame(minHeight: 12, maxHeight: 24)

            // Start Shadow button (fades in after text completes)
            if showStartButton {
                Button {
                    triggerStart()
                } label: {
                    Text("Start Shadow")
                        .frame(minWidth: OnboardingTheme.primaryButtonMinWidth, minHeight: 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(OnboardingTheme.accent)
                .transition(.opacity)
            }

            Spacer()
                .frame(height: 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            ghostMood = .happy
            logger.debug("Launch step appeared, ghost mood -> happy")
        }
        .onKeyPress(.return) {
            handleKeyPress()
            return .handled
        }
        .onKeyPress(.space) {
            handleKeyPress()
            return .handled
        }
    }

    // MARK: - Usage Hints Bar

    private var usageHintsBar: some View {
        HStack(spacing: 20) {
            // Menu bar hint
            VStack(spacing: 6) {
                Image(nsImage: Self.menuBarGhostImage())
                    .frame(width: 18, height: 18)
                Text("Menu bar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 36)

            // Hotkey hint
            VStack(spacing: 6) {
                Text("Option + Space")
                    .font(.callout)
                    .fontWeight(.medium)
                    .monospaced()
                    .foregroundStyle(.white)
                Text("Search your day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Keyboard Handling

    private func handleKeyPress() {
        if showStartButton {
            triggerStart()
        } else if !textComplete {
            revealAll = true
        }
    }

    // MARK: - Actions

    private func triggerStart() {
        logger.info("User triggered Start Shadow")

        // Persist completion
        OnboardingStep.complete.persist()
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")

        // Clean up temporary onboarding state
        UserDefaults.standard.removeObject(forKey: "onboardingScreenRecordingGrantedDuringSession")

        // Schedule the one-time notification before closing
        scheduleNotificationIfNeeded()

        // Call the continue handler (which closes the window)
        onContinue()
    }

    // MARK: - Notification

    /// Send a one-time macOS notification reminding the user of the hotkey.
    /// Gated by "launchNotificationShown" UserDefault. Shows once, never again.
    private func scheduleNotificationIfNeeded() {
        let key = "launchNotificationShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        // Use a nonisolated static helper and fire-and-forget add() call.
        // Avoid completion-handler callbacks here to prevent Swift 6 actor
        // isolation/queue-mismatch crashes during onboarding window teardown.
        Self.postLaunchNotification()
    }

    /// Nonisolated to break @MainActor closure-isolation inheritance chains.
    nonisolated private static func postLaunchNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Shadow is watching"
        content.body = "Press Option+Space anytime to search your day."

        let request = UNNotificationRequest(
            identifier: "shadow.launch.notification",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Ghost Image for Usage Hints

    /// Renders a minimal ghost silhouette matching the menu bar icon.
    /// Replicates the drawing from MenuBarIcon.ghostImage() since that method
    /// is private. This is a static 18x18 template image.
    private static func menuBarGhostImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let path = CGMutablePath()

            // Start at bottom-left wave trough
            path.move(to: CGPoint(x: 3, y: 2))

            // Wavy bottom edge: three rounded bumps
            path.addQuadCurve(to: CGPoint(x: 5.5, y: 4), control: CGPoint(x: 4, y: 4))
            path.addQuadCurve(to: CGPoint(x: 8, y: 2), control: CGPoint(x: 7, y: 2))
            path.addQuadCurve(to: CGPoint(x: 10.5, y: 4), control: CGPoint(x: 9, y: 4))
            path.addQuadCurve(to: CGPoint(x: 13, y: 2), control: CGPoint(x: 12, y: 2))
            path.addQuadCurve(to: CGPoint(x: 15, y: 3.5), control: CGPoint(x: 14, y: 3.5))

            // Right side up to the head
            path.addLine(to: CGPoint(x: 15, y: 10))

            // Rounded head (semicircle from right to left)
            path.addArc(center: CGPoint(x: 9, y: 10),
                        radius: 6,
                        startAngle: 0,
                        endAngle: .pi,
                        clockwise: false)

            // Left side down to the bottom
            path.addLine(to: CGPoint(x: 3, y: 2))

            path.closeSubpath()

            // Fill the ghost body
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()

            // Eyes: two small circles
            let eyeRadius: CGFloat = 1.4
            let eyeY: CGFloat = 11
            ctx.addEllipse(in: CGRect(x: 6.5 - eyeRadius, y: eyeY - eyeRadius,
                                      width: eyeRadius * 2, height: eyeRadius * 2))
            ctx.addEllipse(in: CGRect(x: 11.5 - eyeRadius, y: eyeY - eyeRadius,
                                      width: eyeRadius * 2, height: eyeRadius * 2))
            ctx.setBlendMode(.clear)
            ctx.fillPath()

            return true
        }

        return image
    }
}
