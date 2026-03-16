import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ExpressiveGhost")

/// An animated ghost rendered with Canvas + TimelineView.
///
/// The ghost is derived from the 512x512 SVG at `logo.svg`, with all green
/// colors converted to the twilight purple palette. It is drawn procedurally
/// so every element (body, eyes, highlights, mouth, tongue, blush) can be
/// animated independently based on the current `GhostMood`.
///
/// `TimelineView(.animation)` drives re-renders every frame. The Canvas
/// closure updates `GhostAnimationState` (a plain class, not @Observable)
/// and then draws. No SwiftUI animation modifiers are used. All transitions
/// are frame-by-frame interpolation.
struct ExpressiveGhostView: View {
    @Binding var mood: GhostMood
    let size: CGFloat

    /// Mutable animation state. Not @Observable because TimelineView already
    /// drives frame-by-frame re-renders. We use @State to keep a stable
    /// reference across re-renders.
    @State private var animState = GhostAnimationState()

    var body: some View {
        SwiftUI.TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, canvasSize in
                animState.update(mood: mood, time: time)
                GhostRenderer.draw(
                    ctx: &ctx,
                    size: canvasSize,
                    time: time,
                    state: animState
                )
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Animation State

/// Mutable animation state for the ghost, updated each frame.
///
/// This is a plain class (not @Observable) because TimelineView already triggers
/// re-renders every frame. Making it @Observable would cause redundant re-render
/// cycles. The Canvas closure mutates this state and then reads from it in the
/// same synchronous call.
final class GhostAnimationState: @unchecked Sendable {
    var params = AnimationParameters()
    var lastTime: Double = 0
    var blinkScale: Double = 1.0
    var nextBlinkTime: Double = 0
    var isBlinking: Bool = false
    var isDoubleBlink: Bool = false
    var initialized: Bool = false

    /// Update all animation state for the current frame.
    func update(mood: GhostMood, time: Double) {
        if !initialized {
            initialized = true
            lastTime = time
            nextBlinkTime = time + Self.randomBlinkInterval()
            params = AnimationParameters.target(for: mood)
            return
        }

        let delta = min(time - lastTime, 0.1)
        lastTime = time

        let target = AnimationParameters.target(for: mood)
        let rate = AnimationParameters.rate(deltaTime: delta, duration: 0.3)
        params.lerp(toward: target, rate: rate)

        updateBlink(mood: mood, time: time)
    }

    // MARK: - Blink

    private func updateBlink(mood: GhostMood, time: Double) {
        guard mood != .sleeping else {
            blinkScale = 1.0
            isBlinking = false
            return
        }

        if !isBlinking {
            if time >= nextBlinkTime {
                isBlinking = true
                isDoubleBlink = Double.random(in: 0.0...1.0) < 0.1
                computeBlinkScale(startTime: nextBlinkTime, currentTime: time)
            } else {
                blinkScale = 1.0
            }
        } else {
            computeBlinkScale(startTime: nextBlinkTime, currentTime: time)
        }
    }

    private func computeBlinkScale(startTime: Double, currentTime: Double) {
        let elapsed = currentTime - startTime
        let closeDur = 0.15
        let openDur = 0.15
        let singleDur = closeDur + openDur
        let gap = 0.1

        if isDoubleBlink {
            let totalDur = singleDur + gap + singleDur
            if elapsed >= totalDur {
                blinkScale = 1.0
                isBlinking = false
                isDoubleBlink = false
                nextBlinkTime = currentTime + Self.randomBlinkInterval()
                return
            }
            if elapsed < singleDur {
                blinkScale = Self.blinkPhase(elapsed: elapsed, closeDur: closeDur, openDur: openDur)
            } else if elapsed < singleDur + gap {
                blinkScale = 1.0
            } else {
                blinkScale = Self.blinkPhase(
                    elapsed: elapsed - singleDur - gap,
                    closeDur: closeDur,
                    openDur: openDur
                )
            }
        } else {
            if elapsed >= singleDur {
                blinkScale = 1.0
                isBlinking = false
                nextBlinkTime = currentTime + Self.randomBlinkInterval()
                return
            }
            blinkScale = Self.blinkPhase(elapsed: elapsed, closeDur: closeDur, openDur: openDur)
        }
    }

    private static func blinkPhase(elapsed: Double, closeDur: Double, openDur: Double) -> Double {
        if elapsed < closeDur {
            return 1.0 - easeInOut(elapsed / closeDur)
        } else {
            return easeInOut(min((elapsed - closeDur) / openDur, 1.0))
        }
    }

    private static func easeInOut(_ t: Double) -> Double {
        t * t * (3.0 - 2.0 * t)
    }

    static func randomBlinkInterval() -> Double {
        Double.random(in: 3.0...6.0)
    }
}

// MARK: - Ghost Renderer

/// Pure rendering functions for the ghost. Reads from GhostAnimationState, writes to GraphicsContext.
/// All coordinates are in SVG's 512x512 space, scaled by `size.width / 512`.
enum GhostRenderer {

    /// Body gradient top: #a06ee7 raw RGB
    private static let bodyTopRGB = (r: 0.627, g: 0.431, b: 0.906)
    /// Body gradient bottom: #7834d4 raw RGB
    private static let bodyBottomRGB = (r: 0.471, g: 0.204, b: 0.831)

    // MARK: - Main Draw

    static func draw(
        ctx: inout GraphicsContext,
        size: CGSize,
        time: Double,
        state: GhostAnimationState
    ) {
        let s = size.width / 512.0
        let params = state.params

        let breathingOffset = sin(time * 2.0 * .pi / 3.0) * params.breathingAmplitude
        let yOff = (params.bodyYOffset + breathingOffset) * Double(s)

        drawBody(ctx: &ctx, s: s, yOff: yOff, brightness: params.gradientBrightness)
        drawEyes(ctx: &ctx, s: s, yOff: yOff)
        drawEyeHighlights(
            ctx: &ctx, s: s, yOff: yOff, time: time,
            opacity: params.eyeHighlightOpacity,
            highlightYOffset: params.eyeHighlightYOffset,
            blinkScale: state.blinkScale
        )
        drawMouth(ctx: &ctx, s: s, yOff: yOff, mouthRY: params.mouthRY)
        drawTongue(ctx: &ctx, s: s, yOff: yOff, mouthRY: params.mouthRY)
        drawBlush(ctx: &ctx, s: s, yOff: yOff, opacity: params.blushOpacity)
    }

    // MARK: - Body

    private static func drawBody(
        ctx: inout GraphicsContext, s: CGFloat, yOff: Double, brightness: Double
    ) {
        var path = Path()

        path.move(to: pt(256, 52, s: s, yOff: yOff))
        path.addCurve(
            to: pt(100, 230, s: s, yOff: yOff),
            control1: pt(160, 52, s: s, yOff: yOff),
            control2: pt(100, 130, s: s, yOff: yOff)
        )
        path.addLine(to: pt(100, 380, s: s, yOff: yOff))
        path.addCurve(
            to: pt(122, 395, s: s, yOff: yOff),
            control1: pt(100, 395, s: s, yOff: yOff),
            control2: pt(112, 405, s: s, yOff: yOff)
        )
        path.addCurve(
            to: pt(160, 405, s: s, yOff: yOff),
            control1: pt(135, 382, s: s, yOff: yOff),
            control2: pt(148, 398, s: s, yOff: yOff)
        )
        path.addCurve(
            to: pt(198, 390, s: s, yOff: yOff),
            control1: pt(175, 414, s: s, yOff: yOff),
            control2: pt(185, 395, s: s, yOff: yOff)
        )
        path.addCurve(
            to: pt(232, 408, s: s, yOff: yOff),
            control1: pt(210, 386, s: s, yOff: yOff),
            control2: pt(218, 404, s: s, yOff: yOff)
        )
        path.addCurve(
            to: pt(256, 394, s: s, yOff: yOff),
            control1: pt(244, 412, s: s, yOff: yOff),
            control2: pt(250, 398, s: s, yOff: yOff)
        )
        path.addCurve(
            to: pt(280, 408, s: s, yOff: yOff),
            control1: pt(262, 398, s: s, yOff: yOff),
            control2: pt(268, 412, s: s, yOff: yOff)
        )
        path.addCurve(
            to: pt(314, 390, s: s, yOff: yOff),
            control1: pt(294, 404, s: s, yOff: yOff),
            control2: pt(302, 386, s: s, yOff: yOff)
        )
        path.addCurve(
            to: pt(352, 405, s: s, yOff: yOff),
            control1: pt(327, 395, s: s, yOff: yOff),
            control2: pt(337, 414, s: s, yOff: yOff)
        )
        path.addCurve(
            to: pt(390, 395, s: s, yOff: yOff),
            control1: pt(364, 398, s: s, yOff: yOff),
            control2: pt(377, 382, s: s, yOff: yOff)
        )
        path.addCurve(
            to: pt(412, 380, s: s, yOff: yOff),
            control1: pt(400, 405, s: s, yOff: yOff),
            control2: pt(412, 395, s: s, yOff: yOff)
        )
        path.addLine(to: pt(412, 230, s: s, yOff: yOff))
        path.addCurve(
            to: pt(256, 52, s: s, yOff: yOff),
            control1: pt(412, 130, s: s, yOff: yOff),
            control2: pt(352, 52, s: s, yOff: yOff)
        )
        path.closeSubpath()

        // Brightness-adjusted gradient colors
        let topColor = Color(
            red: min(bodyTopRGB.r * brightness, 1.0),
            green: min(bodyTopRGB.g * brightness, 1.0),
            blue: min(bodyTopRGB.b * brightness, 1.0)
        )
        let bottomColor = Color(
            red: min(bodyBottomRGB.r * brightness, 1.0),
            green: min(bodyBottomRGB.g * brightness, 1.0),
            blue: min(bodyBottomRGB.b * brightness, 1.0)
        )

        ctx.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [topColor, bottomColor]),
                startPoint: pt(256, 52, s: s, yOff: yOff),
                endPoint: pt(256, 414, s: s, yOff: yOff)
            )
        )

        ctx.stroke(
            path,
            with: .color(OnboardingTheme.ghostStroke),
            lineWidth: 3.0 * s
        )
    }

    // MARK: - Eyes

    private static func drawEyes(ctx: inout GraphicsContext, s: CGFloat, yOff: Double) {
        ctx.fill(
            ellipsePath(cx: 210, cy: 225, rx: 32, ry: 38, s: s, yOff: yOff),
            with: .color(OnboardingTheme.ghostDark)
        )
        ctx.fill(
            ellipsePath(cx: 302, cy: 225, rx: 32, ry: 38, s: s, yOff: yOff),
            with: .color(OnboardingTheme.ghostDark)
        )
    }

    // MARK: - Eye Highlights

    private static func drawEyeHighlights(
        ctx: inout GraphicsContext,
        s: CGFloat,
        yOff: Double,
        time: Double,
        opacity: Double,
        highlightYOffset: Double,
        blinkScale: Double
    ) {
        let effectiveOpacity = opacity * blinkScale
        guard effectiveOpacity > 0.001 else { return }

        // Subtle eye wander: sinusoidal Y offset (1pt amplitude, 2s period)
        let wanderY = sin(time * 2.0 * .pi / 2.0) * 1.0 + highlightYOffset

        let r = 11.0
        let scaledR = r * Double(s)
        let blinkH = scaledR * blinkScale

        // Left highlight: SVG cx=222, cy=213
        let lc = pt(222, 213 + wanderY, s: s, yOff: yOff)
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: lc.x - scaledR, y: lc.y - blinkH,
                width: scaledR * 2, height: blinkH * 2
            )),
            with: .color(.white.opacity(effectiveOpacity))
        )

        // Right highlight: SVG cx=314, cy=213
        let rc = pt(314, 213 + wanderY, s: s, yOff: yOff)
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: rc.x - scaledR, y: rc.y - blinkH,
                width: scaledR * 2, height: blinkH * 2
            )),
            with: .color(.white.opacity(effectiveOpacity))
        )
    }

    // MARK: - Mouth

    private static func drawMouth(
        ctx: inout GraphicsContext, s: CGFloat, yOff: Double, mouthRY: Double
    ) {
        ctx.fill(
            ellipsePath(cx: 256, cy: 300, rx: 28, ry: mouthRY, s: s, yOff: yOff),
            with: .color(OnboardingTheme.ghostDark)
        )
    }

    // MARK: - Tongue

    private static func drawTongue(
        ctx: inout GraphicsContext, s: CGFloat, yOff: Double, mouthRY: Double
    ) {
        guard mouthRY > 12.0 else { return }
        let tongueOpacity = min((mouthRY - 12.0) / 10.0, 1.0) * 0.5
        ctx.fill(
            ellipsePath(cx: 256, cy: 312, rx: 15, ry: 10, s: s, yOff: yOff),
            with: .color(OnboardingTheme.ghostTongue.opacity(tongueOpacity))
        )
    }

    // MARK: - Blush

    private static func drawBlush(
        ctx: inout GraphicsContext, s: CGFloat, yOff: Double, opacity: Double
    ) {
        guard opacity > 0.01 else { return }
        ctx.fill(
            ellipsePath(cx: 175, cy: 265, rx: 24, ry: 24, s: s, yOff: yOff),
            with: .color(OnboardingTheme.ghostBlush.opacity(opacity))
        )
        ctx.fill(
            ellipsePath(cx: 337, cy: 265, rx: 24, ry: 24, s: s, yOff: yOff),
            with: .color(OnboardingTheme.ghostBlush.opacity(opacity))
        )
    }

    // MARK: - Coordinate Helpers

    /// Convert SVG coordinate to Canvas point. Both use Y-down.
    private static func pt(_ svgX: Double, _ svgY: Double, s: CGFloat, yOff: Double) -> CGPoint {
        CGPoint(x: svgX * Double(s), y: svgY * Double(s) + yOff)
    }

    /// Create an ellipse Path from SVG center/radius values.
    private static func ellipsePath(
        cx: Double, cy: Double, rx: Double, ry: Double, s: CGFloat, yOff: Double
    ) -> Path {
        let center = pt(cx, cy, s: s, yOff: yOff)
        return Path(ellipseIn: CGRect(
            x: center.x - rx * Double(s),
            y: center.y - ry * Double(s),
            width: rx * 2.0 * Double(s),
            height: ry * 2.0 * Double(s)
        ))
    }
}
