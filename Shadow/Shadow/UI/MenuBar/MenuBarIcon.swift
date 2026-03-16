import SwiftUI

/// Custom ghost icon for the menu bar.
/// Drawn programmatically as a template image so it adapts to light/dark mode
/// and matches macOS menu bar conventions (monochrome, ~18pt).
struct MenuBarIcon: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Bridge openWindow to AppDelegate during body evaluation —
        // onAppear does not fire for MenuBarExtra label views.
        let _ = {
            if (NSApp.delegate as? AppDelegate)?.openTimelineAction == nil {
                (NSApp.delegate as? AppDelegate)?.openTimelineAction = openWindow
            }
        }()
        Image(nsImage: Self.ghostImage())
            .accessibilityLabel("Shadow")
    }

    /// Render a minimal ghost silhouette as an NSImage template.
    /// Template images automatically invert for dark/light menu bars.
    private static func ghostImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Ghost body: rounded top (head) tapering to wavy bottom (tail).
            // Drawn in a 18x18 canvas with 1pt inset for optical balance.
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
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()

            // Eyes: two small circles
            let eyeRadius: CGFloat = 1.4
            let eyeY: CGFloat = 11
            // Left eye
            ctx.addEllipse(in: CGRect(x: 6.5 - eyeRadius, y: eyeY - eyeRadius,
                                      width: eyeRadius * 2, height: eyeRadius * 2))
            // Right eye
            ctx.addEllipse(in: CGRect(x: 11.5 - eyeRadius, y: eyeY - eyeRadius,
                                      width: eyeRadius * 2, height: eyeRadius * 2))
            ctx.setBlendMode(.clear)
            ctx.fillPath()

            return true
        }

        image.isTemplate = true
        return image
    }
}
