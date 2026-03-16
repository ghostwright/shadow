import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "WelcomeStep")

/// Step 1 of onboarding: Shadow introduces itself.
///
/// The ghost starts sleeping, wakes up as text begins streaming, and settles
/// into its neutral state. The text streams character by character in 5 groups
/// with pauses between them, creating the feeling of AI speech.
///
/// After text completes, a Continue button fades in. A Skip link appears after
/// 4 seconds regardless of text progress. Keyboard shortcuts: Return/Space
/// triggers Continue (if visible) or fast-forwards text (if still streaming).
struct WelcomeStepView: View {
    @Binding var ghostMood: GhostMood

    /// Called when the user taps Continue or presses Return/Space after text completes.
    let onContinue: @MainActor () -> Void

    /// Called when the user taps Skip.
    let onSkip: @MainActor () -> Void

    // MARK: - Text Groups (exact copy from spec)

    private let textGroups: [[String]] = [
        [
            "Your computer sees everything you do.",
            "But it forgets everything, instantly.",
        ],
        [
            "Shadow remembers.",
            "Every screen. Every conversation. Every moment of focus.",
        ],
        [
            "Search your entire day in seconds.",
            "Ask questions about what happened.",
            "Replay any moment.",
        ],
        [
            "And over time, Shadow learns how you work.",
            "It starts to help before you ask.",
        ],
        [
            "Everything stays on your Mac.",
            "Your memory belongs to you.",
        ],
    ]

    /// Group pause durations: 800ms, 700ms, 700ms, 800ms (between groups).
    /// StreamingTextView uses a single groupPause value, but the spec calls for
    /// alternating pauses. We use 750ms (the midpoint) since the TextStreamer
    /// applies a uniform pause. The rhythm difference is imperceptible.
    private let groupPause: TimeInterval = 0.75

    // MARK: - State

    /// Set to true to fast-forward all streaming text.
    @State private var revealAll = false

    /// Whether the streaming text has finished revealing.
    @State private var textComplete = false

    /// Whether the Continue button should be visible (delayed after text completes).
    @State private var showContinueButton = false

    /// Whether the Skip link should be visible (appears after 4 seconds).
    @State private var showSkipLink = false

    /// Timer handle for the ghost waking sequence.
    @State private var wakingTimer: Timer?

    /// Timer handle for the ghost neutral transition.
    @State private var neutralTimer: Timer?

    /// Timer handle for the Skip link delay.
    @State private var skipTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 48)

            // Ghost: 120x120, starts sleeping
            ExpressiveGhostView(mood: $ghostMood, size: 120)
                .frame(width: 120, height: 120)

            Spacer()
                .frame(height: 32)

            // Streaming narrative text
            StreamingTextView(
                groups: textGroups,
                characterDelay: 0.035,
                groupPause: groupPause,
                revealAll: $revealAll,
                onComplete: { @MainActor in
                    textComplete = true
                    logger.debug("Welcome text streaming complete")

                    // Show Continue button with 0.3s delay, then 0.3s fade
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        MainActor.assumeIsolated {
                            withAnimation(.easeOut(duration: 0.3)) {
                                showContinueButton = true
                            }
                        }
                    }
                }
            )
            .padding(.horizontal, 40)

            Spacer()
                .frame(minHeight: 20, maxHeight: 48)

            // Continue button (fades in after text completes)
            VStack(spacing: 14) {
                if showContinueButton {
                    Button {
                        triggerContinue()
                    } label: {
                        Text("Continue")
                            .frame(minWidth: OnboardingTheme.primaryButtonMinWidth, minHeight: 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(OnboardingTheme.accent)
                }

                // Skip link (appears after 4 seconds)
                if showSkipLink {
                    Button {
                        logger.info("User tapped Skip on welcome step")
                        onSkip()
                    } label: {
                        Text("Skip")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 76)

            Spacer()
                .frame(height: 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startGhostWakingSequence()
            startSkipLinkTimer()
        }
        .onDisappear {
            cleanupTimers()
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

    // MARK: - Ghost Waking Sequence

    /// T+0.0s: sleeping (set by container)
    /// T+1.0s: waking (eyes begin to open)
    /// T+1.5s: neutral (fully awake, standard animation)
    private func startGhostWakingSequence() {
        ghostMood = .sleeping
        logger.debug("Ghost waking sequence started")

        // T+1.0s: transition to waking
        wakingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            MainActor.assumeIsolated {
                ghostMood = .waking
                logger.debug("Ghost mood -> waking")
            }
        }

        // T+1.5s: transition to neutral
        neutralTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                ghostMood = .neutral
                logger.debug("Ghost mood -> neutral")
            }
        }
    }

    // MARK: - Skip Link Timer

    /// Show the Skip link 4 seconds after the welcome view loads.
    private func startSkipLinkTimer() {
        skipTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
            MainActor.assumeIsolated {
                withAnimation(.easeOut(duration: 0.3)) {
                    showSkipLink = true
                }
            }
        }
    }

    // MARK: - Keyboard Handling

    /// Return/Space: if Continue button is showing, trigger Continue.
    /// If text is still streaming, fast-forward (reveal all text).
    private func handleKeyPress() {
        if showContinueButton {
            triggerContinue()
        } else if !textComplete {
            revealAll = true
        }
    }

    // MARK: - Actions

    private func triggerContinue() {
        logger.info("User triggered Continue on welcome step")
        onContinue()
    }

    // MARK: - Cleanup

    private func cleanupTimers() {
        wakingTimer?.invalidate()
        wakingTimer = nil
        neutralTimer?.invalidate()
        neutralTimer = nil
        skipTimer?.invalidate()
        skipTimer = nil
    }
}
