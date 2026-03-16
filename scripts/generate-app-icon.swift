#!/usr/bin/env swift

// Generates AppIcon.appiconset PNGs for the Shadow app.
// Uses the same ghost silhouette as the menu bar icon, rendered on a
// dark gradient background at all required macOS icon sizes.
//
// Usage: swift scripts/generate-app-icon.swift

import Cocoa

// MARK: - Ghost Path

/// Create the ghost shape path, scaled to fit within a given rect with padding.
func ghostPath(in rect: CGRect, padding: CGFloat) -> CGPath {
    let inset = rect.insetBy(dx: padding, dy: padding)
    let path = CGMutablePath()

    // The ghost is designed on an 18x18 canvas. Scale to fit the inset rect.
    // The ghost body spans roughly x:3-15, y:2-16 in the original coordinate space.
    let ghostBounds = CGRect(x: 3, y: 2, width: 12, height: 14)
    let scaleX = inset.width / ghostBounds.width
    let scaleY = inset.height / ghostBounds.height
    let scale = min(scaleX, scaleY)

    // Center the ghost in the inset rect
    let scaledWidth = ghostBounds.width * scale
    let scaledHeight = ghostBounds.height * scale
    let offsetX = inset.minX + (inset.width - scaledWidth) / 2 - ghostBounds.minX * scale
    let offsetY = inset.minY + (inset.height - scaledHeight) / 2 - ghostBounds.minY * scale

    var transform = CGAffineTransform(translationX: offsetX, y: offsetY)
        .scaledBy(x: scale, y: scale)

    // Wavy bottom edge
    path.move(to: CGPoint(x: 3, y: 2), transform: transform)
    path.addQuadCurve(to: CGPoint(x: 5.5, y: 4), control: CGPoint(x: 4, y: 4), transform: transform)
    path.addQuadCurve(to: CGPoint(x: 8, y: 2), control: CGPoint(x: 7, y: 2), transform: transform)
    path.addQuadCurve(to: CGPoint(x: 10.5, y: 4), control: CGPoint(x: 9, y: 4), transform: transform)
    path.addQuadCurve(to: CGPoint(x: 13, y: 2), control: CGPoint(x: 12, y: 2), transform: transform)
    path.addQuadCurve(to: CGPoint(x: 15, y: 3.5), control: CGPoint(x: 14, y: 3.5), transform: transform)

    // Right side up to head
    path.addLine(to: CGPoint(x: 15, y: 10), transform: transform)

    // Rounded head
    path.addArc(center: CGPoint(x: 9, y: 10),
                radius: 6,
                startAngle: 0,
                endAngle: .pi,
                clockwise: false,
                transform: transform)

    // Left side down
    path.addLine(to: CGPoint(x: 3, y: 2), transform: transform)
    path.closeSubpath()

    return path
}

/// Create eye ellipses for the ghost.
func eyePaths(in rect: CGRect, padding: CGFloat) -> [(CGRect)] {
    let inset = rect.insetBy(dx: padding, dy: padding)
    let ghostBounds = CGRect(x: 3, y: 2, width: 12, height: 14)
    let scaleX = inset.width / ghostBounds.width
    let scaleY = inset.height / ghostBounds.height
    let scale = min(scaleX, scaleY)

    let scaledWidth = ghostBounds.width * scale
    let scaledHeight = ghostBounds.height * scale
    let offsetX = inset.minX + (inset.width - scaledWidth) / 2 - ghostBounds.minX * scale
    let offsetY = inset.minY + (inset.height - scaledHeight) / 2 - ghostBounds.minY * scale

    let eyeRadius: CGFloat = 1.4 * scale
    let eyeY: CGFloat = 11 * scale + offsetY

    let leftEye = CGRect(
        x: 6.5 * scale + offsetX - eyeRadius,
        y: eyeY - eyeRadius,
        width: eyeRadius * 2,
        height: eyeRadius * 2
    )
    let rightEye = CGRect(
        x: 11.5 * scale + offsetX - eyeRadius,
        y: eyeY - eyeRadius,
        width: eyeRadius * 2,
        height: eyeRadius * 2
    )

    return [leftEye, rightEye]
}

// MARK: - Icon Rendering

func renderIcon(size: Int) -> NSImage {
    let sz = NSSize(width: size, height: size)
    let image = NSImage(size: sz, flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

        // Background: dark rounded rectangle with gradient
        let cornerRadius = CGFloat(size) * 0.22 // macOS icon corner radius
        let bgPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // Gradient: deep indigo to dark purple
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(red: 0.15, green: 0.10, blue: 0.25, alpha: 1.0),  // Dark indigo
            CGColor(red: 0.25, green: 0.12, blue: 0.35, alpha: 1.0),  // Deep purple
        ]
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0.0, 1.0])!

        ctx.saveGState()
        ctx.addPath(bgPath)
        ctx.clip()
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(size)),
            end: CGPoint(x: CGFloat(size), y: 0),
            options: []
        )
        ctx.restoreGState()

        // Subtle inner shadow / border
        ctx.saveGState()
        ctx.addPath(bgPath)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
        ctx.setLineWidth(max(1, CGFloat(size) / 128))
        ctx.strokePath()
        ctx.restoreGState()

        // Ghost body - white with slight transparency
        let padding = CGFloat(size) * 0.18
        let ghost = ghostPath(in: rect, padding: padding)

        ctx.addPath(ghost)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.fillPath()

        // Ghost shadow (subtle glow effect)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(size) * 0.01),
                       blur: CGFloat(size) * 0.06,
                       color: CGColor(red: 0.5, green: 0.3, blue: 0.8, alpha: 0.4))
        ctx.addPath(ghost)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.fillPath()
        ctx.restoreGState()

        // Eyes - cut out from ghost body
        let eyes = eyePaths(in: rect, padding: padding)
        for eyeRect in eyes {
            ctx.addEllipse(in: eyeRect)
        }
        // Fill eyes with the background color (dark)
        ctx.setFillColor(CGColor(red: 0.18, green: 0.11, blue: 0.28, alpha: 1.0))
        ctx.fillPath()

        return true
    }
    return image
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to create PNG for \(path)")
        return
    }
    do {
        try pngData.write(to: URL(fileURLWithPath: path))
        print("  Wrote \(path)")
    } catch {
        print("  Failed to write \(path): \(error)")
    }
}

// MARK: - Main

let assetDir = "Shadow/Shadow/Resources/Assets.xcassets/AppIcon.appiconset"

// Create directory
let fm = FileManager.default
try? fm.createDirectory(atPath: assetDir, withIntermediateDirectories: true)

// macOS icon sizes: point size × scale factor
let sizes: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

print("Generating app icons...")

var images: [[String: String]] = []

for (points, scale) in sizes {
    let pixels = points * scale
    let filename = "icon_\(points)x\(points)@\(scale)x.png"
    let path = "\(assetDir)/\(filename)"

    let image = renderIcon(size: pixels)
    savePNG(image, to: path)

    images.append([
        "filename": filename,
        "idiom": "mac",
        "scale": "\(scale)x",
        "size": "\(points)x\(points)"
    ])
}

// Write Contents.json
let contents: [String: Any] = [
    "images": images,
    "info": [
        "author": "xcode",
        "version": 1
    ] as [String: Any]
]

let jsonData = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
let jsonPath = "\(assetDir)/Contents.json"
try jsonData.write(to: URL(fileURLWithPath: jsonPath))
print("  Wrote \(jsonPath)")

print("Done! \(sizes.count) icons generated.")
