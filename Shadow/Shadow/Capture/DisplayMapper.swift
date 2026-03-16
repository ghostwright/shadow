import Cocoa
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "DisplayMapper")

/// Maps screen coordinates and window frames to display IDs.
/// Uses CoreGraphics display APIs for fast coordinate-to-display lookup.
enum DisplayMapper {

    /// Find which display contains a given screen point.
    /// Uses CGGetDisplaysWithPoint (lightweight, no disk I/O).
    static func displayID(for point: CGPoint) -> CGDirectDisplayID? {
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let err = CGGetDisplaysWithPoint(point, 1, &displayID, &count)
        guard err == .success, count > 0 else { return nil }
        return displayID
    }

    /// Find the display with the most overlap for a given window frame.
    static func displayID(for frame: CGRect) -> CGDirectDisplayID? {
        guard !frame.isEmpty else { return nil }

        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let err = CGGetDisplaysWithRect(frame, UInt32(displays.count), &displays, &count)
        guard err == .success, count > 0 else { return nil }

        if count == 1 { return displays[0] }

        // Multiple displays: pick the one with the largest overlap area
        var bestDisplay = displays[0]
        var bestArea: CGFloat = 0

        for i in 0..<Int(count) {
            let displayBounds = CGDisplayBounds(displays[i])
            let overlap = frame.intersection(displayBounds)
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                bestDisplay = displays[i]
            }
        }

        return bestDisplay
    }

    /// Get the frame and display ID of the focused window for a given app.
    /// Returns nil if the window's position/size can't be read via AX.
    static func focusedWindowInfo(forPID pid: pid_t) -> (frame: CGRect, displayID: CGDirectDisplayID)? {
        let appElement = AXUIElementCreateApplication(pid)
        guard let windowValue = axAttribute(appElement, kAXFocusedWindowAttribute) else {
            return nil
        }
        let window = windowValue as! AXUIElement

        guard let positionValue = axAttribute(window, kAXPositionAttribute),
              let sizeValue = axAttribute(window, kAXSizeAttribute) else {
            return nil
        }

        var position = CGPoint.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)

        var size = CGSize.zero
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        let frame = CGRect(origin: position, size: size)
        guard let display = displayID(for: frame) else { return nil }

        return (frame, display)
    }

    /// Get display_id for the currently focused window.
    /// Useful for keyboard events where we don't have a direct screen coordinate.
    static func focusedWindowDisplayID() -> CGDirectDisplayID? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        return focusedWindowInfo(forPID: frontApp.processIdentifier)?.displayID
    }
}
