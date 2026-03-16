import SwiftUI

/// Shared color and typography constants for the onboarding experience.
///
/// The onboarding uses a custom dark gradient background regardless of system appearance,
/// creating a "stage" for Shadow to introduce itself. These values derive from the
/// twilight purple palette defined in the UI/UX vision doc.
enum OnboardingTheme {

    // MARK: - Ghost Colors (Purple palette, converted from SVG green)

    /// Body gradient top: SVG #6ee7a8 converted to twilight purple.
    static let ghostBodyTop = Color(red: 0.627, green: 0.431, blue: 0.906)       // #a06ee7

    /// Body gradient bottom: SVG #34d48c converted to deeper purple.
    static let ghostBodyBottom = Color(red: 0.471, green: 0.204, blue: 0.831)     // #7834d4

    /// Body stroke: SVG #1fa86e converted to deep purple.
    static let ghostStroke = Color(red: 0.353, green: 0.122, blue: 0.659)         // #5a1fa8

    /// Eye and mouth fill. Kept dark from the original SVG.
    static let ghostDark = Color(red: 0.102, green: 0.102, blue: 0.180)           // #1a1a2e

    /// Tongue fill: lighter purple at reduced opacity.
    static let ghostTongue = Color(red: 0.627, green: 0.431, blue: 0.906)         // #a06ee7 at 0.5

    /// Cheek blush: warm coral, kept from SVG for contrast.
    static let ghostBlush = Color(red: 0.941, green: 0.502, blue: 0.439)          // #f08070

    // MARK: - Background

    /// Onboarding window dark gradient top (lighter edge).
    static let backgroundTop = Color(red: 25.0/255, green: 15.0/255, blue: 35.0/255)

    /// Onboarding window dark gradient bottom (darker edge).
    static let backgroundBottom = Color(red: 15.0/255, green: 10.0/255, blue: 20.0/255)

    /// The full onboarding background gradient.
    static let backgroundGradient = LinearGradient(
        colors: [backgroundBottom, backgroundTop],
        startPoint: .bottom,
        endPoint: .top
    )

    // MARK: - Accent

    /// Primary accent: twilight purple for progress indicators and active states.
    static let accent = Color(red: 120.0/255, green: 80.0/255, blue: 200.0/255)

    /// Soft accent: twilight purple at 15% for hover states and selection highlights.
    static let accentSoft = Color(red: 120.0/255, green: 80.0/255, blue: 200.0/255, opacity: 0.15)

    // MARK: - Typography Helpers

    /// Narrative text style: .title2 .regular with generous line spacing.
    /// Used for the streaming welcome text.
    static func narrativeText(_ text: Text) -> some View {
        text
            .font(.title2)
            .fontWeight(.regular)
            .lineSpacing(10)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
    }

    /// Keyboard hint style: .caption .monospaced for shortcut labels.
    static func keyboardHint(_ text: Text) -> some View {
        text
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
    }

    /// Button label style: .body .semibold.
    static func buttonLabel(_ text: Text) -> some View {
        text
            .font(.body)
            .fontWeight(.semibold)
    }

    // MARK: - Button Sizing

    /// Standard minimum width for primary action buttons.
    static let primaryButtonMinWidth: CGFloat = 280

    /// Minimum width for secondary/smaller action buttons.
    static let secondaryButtonMinWidth: CGFloat = 200
}
