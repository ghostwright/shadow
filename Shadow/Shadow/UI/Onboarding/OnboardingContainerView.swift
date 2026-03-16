import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "OnboardingContainer")

/// Top-level onboarding view that manages step transitions.
///
/// Owns the current step state (persisted to UserDefaults) and the ghost mood.
/// Switches between step views based on `currentStep` with slide transitions.
/// All four steps are implemented: Welcome, Permissions, Model Setup, Launch.
///
/// Instantiated by AppDelegate in `showOnboardingWindow()` and hosted inside
/// an NSWindow via NSHostingController. Not a SwiftUI Scene.
struct OnboardingContainerView: View {
    let permissions: PermissionManager

    @State private var currentStep: OnboardingStep
    @State private var ghostMood: GhostMood = .sleeping

    init(permissions: PermissionManager) {
        self.permissions = permissions
        let persisted = OnboardingStep.persisted()
        // If the app was restarted after completing onboarding, default to welcome
        // rather than showing a completed state. The complete case is handled by
        // AppDelegate not showing the onboarding window at all.
        let step = (persisted == .complete) ? .welcome : persisted
        _currentStep = State(initialValue: step)
        logger.info("Onboarding container initialized at step: \(step.rawValue)")
    }

    var body: some View {
        ZStack {
            // Dark gradient stage background
            OnboardingTheme.backgroundGradient
                .ignoresSafeArea()

            // Step content with transitions
            Group {
                switch currentStep {
                case .welcome:
                    WelcomeStepView(
                        ghostMood: $ghostMood,
                        onContinue: { advanceTo(.permissions) },
                        onSkip: { advanceTo(.permissions) }
                    )
                    .transition(stepTransition)

                case .permissions:
                    PermissionsStepView(
                        permissions: permissions,
                        ghostMood: $ghostMood,
                        onContinue: { advanceTo(.modelSetup) }
                    )
                    .transition(stepTransition)

                case .modelSetup:
                    ModelSetupStepView(
                        ghostMood: $ghostMood,
                        onContinue: { advanceTo(.launch) }
                    )
                    .transition(stepTransition)

                case .launch:
                    LaunchStepView(
                        ghostMood: $ghostMood,
                        onContinue: {
                            logger.info("Onboarding complete. Closing window to start capture.")
                            NSApp.keyWindow?.close()
                        }
                    )
                    .transition(stepTransition)

                case .complete:
                    // Should not be reached; AppDelegate skips onboarding when complete.
                    EmptyView()
                }
            }
        }
        .frame(width: 560, height: 720)
    }

    // MARK: - Navigation

    private func advanceTo(_ step: OnboardingStep) {
        step.persist()
        logger.info("Onboarding advancing to step: \(step.rawValue)")
        withAnimation(.easeInOut(duration: 0.4)) {
            currentStep = step
        }
    }

    // MARK: - Transition

    /// Asymmetric slide transition: outgoing view slides left, incoming slides from right.
    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

}
