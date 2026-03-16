@preconcurrency import ApplicationServices
import Foundation

// MARK: - Attribute Accessors

extension ShadowElement {
    // MARK: - Core Attributes

    @MainActor func role() -> String? {
        axString(kAXRoleAttribute)
    }

    @MainActor func subrole() -> String? {
        axString(kAXSubroleAttribute)
    }

    @MainActor func title() -> String? {
        axString(kAXTitleAttribute)
    }

    /// Returns string representation of the value attribute; truncates to 500 chars.
    @MainActor func value() -> String? {
        guard let raw = axRaw(kAXValueAttribute) else { return nil }
        if let s = raw as? String { return String(s.prefix(500)) }
        if let n = raw as? NSNumber { return n.stringValue }
        return String(describing: raw).prefix(500).description
    }

    @MainActor func identifier() -> String? {
        axString(kAXIdentifierAttribute)
    }

    @MainActor func descriptionText() -> String? {
        axString(kAXDescriptionAttribute)
    }

    @MainActor func placeholderValue() -> String? {
        axString("AXPlaceholderValue")
    }

    @MainActor func help() -> String? {
        axString(kAXHelpAttribute)
    }

    @MainActor func roleDescription() -> String? {
        axString(kAXRoleDescriptionAttribute)
    }

    // MARK: - State Attributes

    @MainActor func isEnabled() -> Bool {
        axBool(kAXEnabledAttribute) ?? true
    }

    @MainActor func isFocused() -> Bool {
        axBool(kAXFocusedAttribute) ?? false
    }

    @MainActor func isHidden() -> Bool {
        axBool(kAXHiddenAttribute) ?? false
    }

    // MARK: - Geometry

    @MainActor func position() -> CGPoint? {
        guard let raw = axRaw(kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    @MainActor func size() -> CGSize? {
        guard let raw = axRaw(kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    @MainActor func frame() -> CGRect? {
        guard let pos = position(), let sz = size() else { return nil }
        return CGRect(origin: pos, size: sz)
    }

    // MARK: - Actions

    @MainActor func supportedActions() -> [String] {
        var names: CFArray?
        let err = AXUIElementCopyActionNames(ref, &names)
        guard err == .success, let actions = names as? [String] else { return [] }
        return actions
    }

    @MainActor func performAction(_ action: String) throws {
        let err = AXUIElementPerformAction(ref, action as CFString)
        guard err == .success else {
            throw AXEngineError.actionFailed(action: action, axError: err.rawValue)
        }
    }

    @MainActor func setValue(_ value: Any, forAttribute attr: String) -> Bool {
        let cfValue: CFTypeRef
        if let s = value as? String { cfValue = s as CFString }
        else if let b = value as? Bool { cfValue = b as CFBoolean }
        else if let n = value as? NSNumber { cfValue = n }
        else { return false }

        let err = AXUIElementSetAttributeValue(ref, attr as CFString, cfValue)
        return err == .success
    }

    // MARK: - DOM Attributes (Web Content)

    @MainActor func domId() -> String? {
        axString("AXDOMIdentifier")
    }

    @MainActor func domClassList() -> String? {
        axString("AXDOMClassList")
    }

    // MARK: - Computed Name

    /// Computed name: title > value > identifier > description > placeholder > role.
    /// Same cascade as AXorcist's Element+ComputedName.swift.
    @MainActor func computedName() -> String? {
        if let t = title(), !t.isEmpty { return t }
        if let v = value(), !v.isEmpty { return String(v.prefix(50)) }
        if let i = identifier(), !i.isEmpty { return i }
        if let d = descriptionText(), !d.isEmpty { return d }
        if let p = placeholderValue(), !p.isEmpty { return p }
        if let r = role() { return r.replacingOccurrences(of: "AX", with: "") }
        return nil
    }

    // MARK: - Internal Helpers

    @MainActor private func axString(_ attr: String) -> String? {
        axRaw(attr) as? String
    }

    @MainActor private func axBool(_ attr: String) -> Bool? {
        guard let raw = axRaw(attr) else { return nil }
        if let n = raw as? NSNumber { return n.boolValue }
        return nil
    }

    @MainActor func axRaw(_ attr: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(ref, attr as CFString, &value)
        guard err == .success else { return nil }
        return value
    }
}
