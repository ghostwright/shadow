import Foundation

/// The mood states of the expressive ghost during onboarding.
///
/// Each mood determines a set of animation parameters (eye highlight opacity,
/// mouth openness, body offset, breathing amplitude, blush intensity, etc.).
/// Transitions between moods are smoothed by `AnimationParameters`, which
/// interpolates toward the target state over 0.3 seconds using the TimelineView
/// time signal.
enum GhostMood: String, CaseIterable, Equatable, Sendable {
    /// Eyes closed, minimal movement. The ghost is dormant.
    case sleeping
    /// Eyes opening. Transition from sleeping to neutral (0.3s).
    case waking
    /// Standard breathing, blinking, floating. The default alive state.
    case neutral
    /// Quick upward bounce, wider eyes. Triggered by a permission grant or positive event.
    case excited
    /// Mouth open, eyes tracking downward. Active during AI text streaming.
    case speaking
    /// Brighter gradient, floats higher, smile shape. The send-off state.
    case happy
}

/// Interpolated animation parameters driven by the current `GhostMood`.
///
/// Rather than snapping between moods, this struct holds the current "rendered"
/// values and lerps toward the target mood's values each frame. The result is
/// smooth organic transitions with no SwiftUI animation modifiers needed.
/// All timing is driven by `TimelineView(.animation)`.
struct AnimationParameters: Equatable {

    // MARK: - Current interpolated values

    /// Opacity of the white eye highlights (0.0 = closed/sleeping, 0.9 = normal, 1.0 = bright).
    var eyeHighlightOpacity: Double = 0.0

    /// Additional Y offset for eye highlights, in 512-space points (positive = down in SVG space).
    var eyeHighlightYOffset: Double = 0.0

    /// Mouth vertical radius in 512-space. Controls how open the mouth is.
    var mouthRY: Double = 8.0

    /// Base Y offset for the entire ghost body in 512-space, before breathing is added.
    var bodyYOffset: Double = 0.0

    /// Amplitude of the sinusoidal breathing oscillation, in 512-space points.
    var breathingAmplitude: Double = 2.0

    /// Opacity of the cheek blush circles.
    var blushOpacity: Double = 0.15

    /// Brightness multiplier for the body gradient (1.0 = normal, 0.9 = dimmed, 1.1 = bright).
    var gradientBrightness: Double = 0.9

    // MARK: - Target values (derived from mood)

    /// Returns the target parameter set for a given mood.
    static func target(for mood: GhostMood) -> AnimationParameters {
        switch mood {
        case .sleeping:
            return AnimationParameters(
                eyeHighlightOpacity: 0.0,
                eyeHighlightYOffset: 0.0,
                mouthRY: 8.0,
                bodyYOffset: 0.0,
                breathingAmplitude: 2.0,
                blushOpacity: 0.15,
                gradientBrightness: 0.9
            )
        case .waking:
            // Waking is a transition toward neutral. The interpolation handles the
            // smooth eye-open effect. We set the target to neutral values so the
            // lerp gradually opens the eyes.
            return AnimationParameters(
                eyeHighlightOpacity: 0.9,
                eyeHighlightYOffset: 0.0,
                mouthRY: 12.0,
                bodyYOffset: 0.0,
                breathingAmplitude: 2.5,
                blushOpacity: 0.25,
                gradientBrightness: 0.95
            )
        case .neutral:
            return AnimationParameters(
                eyeHighlightOpacity: 0.9,
                eyeHighlightYOffset: 0.0,
                mouthRY: 16.0,
                bodyYOffset: 0.0,
                breathingAmplitude: 3.0,
                blushOpacity: 0.35,
                gradientBrightness: 1.0
            )
        case .excited:
            return AnimationParameters(
                eyeHighlightOpacity: 1.0,
                eyeHighlightYOffset: -2.0,
                mouthRY: 16.0,
                bodyYOffset: -6.0,
                breathingAmplitude: 3.0,
                blushOpacity: 0.4,
                gradientBrightness: 1.0
            )
        case .speaking:
            return AnimationParameters(
                eyeHighlightOpacity: 0.9,
                eyeHighlightYOffset: 3.0,
                mouthRY: 22.0,
                bodyYOffset: 0.0,
                breathingAmplitude: 3.0,
                blushOpacity: 0.35,
                gradientBrightness: 1.0
            )
        case .happy:
            return AnimationParameters(
                eyeHighlightOpacity: 1.0,
                eyeHighlightYOffset: -2.0,
                mouthRY: 14.0,
                bodyYOffset: -2.0,
                breathingAmplitude: 4.0,
                blushOpacity: 0.5,
                gradientBrightness: 1.1
            )
        }
    }

    // MARK: - Interpolation

    /// Smoothly interpolate all values toward a target at the given rate.
    ///
    /// Called every frame from the Canvas render. A `rate` of 0.0 means no change;
    /// 1.0 means snap to target instantly.
    ///
    /// - Parameters:
    ///   - target: The target parameter set (from the current mood).
    ///   - rate: Interpolation rate per call. Typical: `1.0 - pow(0.001, deltaTime / 0.3)`,
    ///           which reaches ~95% of the target in 0.3 seconds.
    mutating func lerp(toward target: AnimationParameters, rate: Double) {
        let r = min(max(rate, 0.0), 1.0)
        eyeHighlightOpacity += (target.eyeHighlightOpacity - eyeHighlightOpacity) * r
        eyeHighlightYOffset += (target.eyeHighlightYOffset - eyeHighlightYOffset) * r
        mouthRY += (target.mouthRY - mouthRY) * r
        bodyYOffset += (target.bodyYOffset - bodyYOffset) * r
        breathingAmplitude += (target.breathingAmplitude - breathingAmplitude) * r
        blushOpacity += (target.blushOpacity - blushOpacity) * r
        gradientBrightness += (target.gradientBrightness - gradientBrightness) * r
    }

    /// Convenience: compute the interpolation rate from a time delta.
    ///
    /// Uses an exponential decay formula so that ~95% of the transition
    /// completes in `duration` seconds regardless of frame rate.
    static func rate(deltaTime: Double, duration: Double = 0.3) -> Double {
        guard duration > 0 else { return 1.0 }
        return 1.0 - pow(0.001, deltaTime / duration)
    }
}
