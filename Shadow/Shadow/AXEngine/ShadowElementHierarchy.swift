@preconcurrency import ApplicationServices
import Foundation

// MARK: - Hierarchy Navigation

extension ShadowElement {
    /// Direct children via kAXChildrenAttribute.
    @MainActor func children() -> [ShadowElement] {
        guard let raw = axRaw(kAXChildrenAttribute) else { return [] }
        // AX children are always returned as CFArray of AXUIElement
        guard let array = raw as? [AXUIElement] else { return [] }
        return array.map(ShadowElement.init)
    }

    /// All children including alternative sources (AXVisibleChildren, AXWindows, etc.)
    /// Mirrors AXorcist's ChildCollector pattern with deduplication.
    @MainActor func allChildren(maxCount: Int = 50_000) -> [ShadowElement] {
        var seen = Set<UInt>()
        var result: [ShadowElement] = []

        func add(_ elements: [AXUIElement]) {
            for el in elements {
                guard result.count < maxCount else { return }
                let h = CFHash(el)
                if seen.insert(h).inserted {
                    result.append(ShadowElement(el))
                }
            }
        }

        // Primary children
        if let raw = axRaw(kAXChildrenAttribute), let c = raw as? [AXUIElement] { add(c) }

        // Alternative child attributes (from AXorcist's collectAlternativeChildren)
        let altAttrs = [
            "AXVisibleChildren", "AXWebAreaChildren", "AXContents",
            "AXChildrenInNavigationOrder", "AXRows", "AXColumns", "AXTabs"
        ]
        for attr in altAttrs {
            if let raw = axRaw(attr), let c = raw as? [AXUIElement] { add(c) }
        }

        // For application elements: add AXWindows and AXFocusedUIElement
        if role() == "AXApplication" {
            if let raw = axRaw(kAXWindowsAttribute), let w = raw as? [AXUIElement] { add(w) }
            if let raw = axRaw(kAXFocusedUIElementAttribute) {
                // Single AXUIElement — force cast is safe here since
                // AXUIElementCopyAttributeValue succeeded and kAXFocusedUIElementAttribute
                // always returns an AXUIElement.
                let focused = raw as! AXUIElement
                add([focused])
            }
        }

        return result
    }

    @MainActor func parent() -> ShadowElement? {
        guard let raw = axRaw(kAXParentAttribute) else { return nil }
        return ShadowElement(raw as! AXUIElement)
    }

    @MainActor func focusedWindow() -> ShadowElement? {
        guard let raw = axRaw(kAXFocusedWindowAttribute) else { return nil }
        return ShadowElement(raw as! AXUIElement)
    }

    @MainActor func focusedUIElement() -> ShadowElement? {
        guard let raw = axRaw(kAXFocusedUIElementAttribute) else { return nil }
        return ShadowElement(raw as! AXUIElement)
    }

    /// All windows for an application element.
    @MainActor func windows() -> [ShadowElement] {
        guard let raw = axRaw(kAXWindowsAttribute) else { return [] }
        guard let array = raw as? [AXUIElement] else { return [] }
        return array.map(ShadowElement.init)
    }
}
