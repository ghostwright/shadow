@preconcurrency import ApplicationServices
import Foundation

/// Lightweight wrapper around AXUIElement for Shadow's AX engine.
///
/// Unlike AXorcist's Element, this struct does NOT require @MainActor for
/// construction. It dispatches to MainActor internally only for cross-process
/// AX calls that require run-loop integration. All attribute reads are
/// @MainActor since AX API calls are Mach IPC.
///
/// Sendable because AXUIElement is a CFType (reference-counted, thread-safe for reads).
/// All mutation happens through AX API calls, not on this struct.
struct ShadowElement: Equatable, Hashable, Sendable {
    let ref: AXUIElement

    init(_ element: AXUIElement) {
        self.ref = element
    }

    static func == (lhs: ShadowElement, rhs: ShadowElement) -> Bool {
        CFEqual(lhs.ref, rhs.ref)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(ref))
    }

    /// Unique hash for cycle detection during tree traversal.
    var cfHash: UInt { CFHash(ref) }
}

// MARK: - Factory Methods

extension ShadowElement {
    /// Application element for a given PID.
    static func application(pid: pid_t) -> ShadowElement {
        ShadowElement(AXUIElementCreateApplication(pid))
    }

    /// System-wide element (for global queries like elementAtPoint).
    static func systemWide() -> ShadowElement {
        ShadowElement(AXUIElementCreateSystemWide())
    }

    /// Element at a screen point (system-wide hit test).
    @MainActor
    static func atPoint(_ point: CGPoint) -> ShadowElement? {
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(point.x), Float(point.y), &element)
        guard err == .success, let el = element else { return nil }
        return ShadowElement(el)
    }

    /// Element at point within a specific app.
    @MainActor
    static func atPoint(_ point: CGPoint, inApp pid: pid_t) -> ShadowElement? {
        var element: AXUIElement?
        let appRef = AXUIElementCreateApplication(pid)
        let err = AXUIElementCopyElementAtPosition(
            appRef, Float(point.x), Float(point.y), &element)
        guard err == .success, let el = element else { return nil }
        return ShadowElement(el)
    }
}
