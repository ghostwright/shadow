import Foundation

/// The steps of the Shadow onboarding flow.
///
/// Persisted to UserDefaults as a raw string value so the onboarding can resume
/// at the correct step after an app restart (e.g., after granting Screen Recording).
/// Written before every step transition so progress is never lost.
enum OnboardingStep: String, CaseIterable, Codable, Sendable {
    /// Shadow introduces itself. The ghost wakes up. Text streams.
    case welcome
    /// The user grants permissions. Trust is built one toggle at a time.
    case permissions
    /// Shadow's intelligence comes alive. Cloud key or local model setup.
    case modelSetup
    /// The send-off. Shadow thanks the user and starts.
    case launch
    /// Onboarding is done. All capture subsystems are running.
    case complete

    // MARK: - UserDefaults persistence

    /// The UserDefaults key used to store the current onboarding step.
    static let defaultsKey = "onboardingStep"

    /// Read the persisted step from UserDefaults, defaulting to `.welcome`.
    static func persisted() -> OnboardingStep {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let step = OnboardingStep(rawValue: raw) else {
            return .welcome
        }
        return step
    }

    /// Write this step to UserDefaults. Call before every transition.
    func persist() {
        UserDefaults.standard.set(rawValue, forKey: OnboardingStep.defaultsKey)
    }
}
