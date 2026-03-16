@preconcurrency import ApplicationServices
import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "InputSynthesizer")

// MARK: - Input Synthesizer

/// Generates synthetic CGEvents for mouse clicks, keyboard input, scrolling, and drag.
///
/// All events are tagged with `kCGEventSourceUserData = 0x5348_4457` ("SHDW") so
/// InputMonitor can filter them out and avoid self-recording.
///
/// @MainActor because CGEvent.post must be called from the main thread for
/// proper event delivery to the frontmost application.
enum InputSynthesizer {

    /// Tag value set on all synthesized events.
    /// Matches `InputMonitor.shadowSynthesizedEventTag`.
    static let shadowEventTag: Int64 = 0x5348_4457  // "SHDW" in hex

    // MARK: - Mouse

    /// Synthetic click at a screen point.
    ///
    /// Posts mouseDown + mouseUp pairs for each click in the count.
    /// Double-click: pass count=2. Triple-click: count=3.
    @MainActor
    static func click(
        at point: CGPoint,
        button: CGMouseButton = .left,
        count: Int = 1
    ) throws {
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp

        for clickIndex in 1...max(1, count) {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                                     mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                                   mouseCursorPosition: point, mouseButton: button)
            else { throw AXEngineError.eventCreationFailed }

            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            tagEvent(down)
            tagEvent(up)

            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.01)
            up.post(tap: .cghidEventTap)

            if clickIndex < count {
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
    }

    /// Synthetic drag from one point to another with interpolation.
    @MainActor
    static func drag(from start: CGPoint, to end: CGPoint, steps: Int = 20) throws {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: start, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: end, mouseButton: .left)
        else { throw AXEngineError.eventCreationFailed }

        tagEvent(down)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)

        for i in 1...max(1, steps) {
            let t = CGFloat(i) / CGFloat(steps)
            let pos = CGPoint(x: start.x + (end.x - start.x) * t,
                              y: start.y + (end.y - start.y) * t)
            guard let move = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                     mouseCursorPosition: pos, mouseButton: .left)
            else { continue }
            tagEvent(move)
            move.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.002)
        }

        tagEvent(up)
        up.post(tap: .cghidEventTap)
    }

    /// Synthetic scroll event.
    @MainActor
    static func scroll(deltaY: Int32, deltaX: Int32 = 0, at point: CGPoint? = nil) throws {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                  wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0)
        else { throw AXEngineError.eventCreationFailed }

        if let point { event.location = point }
        tagEvent(event)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    /// Type a string of text character-by-character using Unicode keyboard events.
    ///
    /// Special characters: `\n` sends Return (keyCode 36), `\t` sends Tab (keyCode 48).
    /// All other characters are sent via `keyboardSetUnicodeString` which handles
    /// international characters, symbols, and emoji correctly.
    @MainActor
    static func typeText(_ text: String, delayPerChar: TimeInterval = 0.005) throws {
        for char in text {
            if char == "\n" {
                try pressKey(keyCode: 36) // Return
            } else if char == "\t" {
                try pressKey(keyCode: 48) // Tab
            } else {
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                else { throw AXEngineError.eventCreationFailed }

                let chars = Array(String(char).utf16)
                chars.withUnsafeBufferPointer { buf in
                    down.keyboardSetUnicodeString(stringLength: chars.count,
                                                  unicodeString: buf.baseAddress!)
                    up.keyboardSetUnicodeString(stringLength: chars.count,
                                                unicodeString: buf.baseAddress!)
                }
                tagEvent(down)
                tagEvent(up)
                down.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.001)
                up.post(tap: .cghidEventTap)
            }
            if delayPerChar > 0 { Thread.sleep(forTimeInterval: delayPerChar) }
        }
    }

    /// Press a single key (down + up) with optional modifier flags.
    @MainActor
    static func pressKey(keyCode: CGKeyCode, modifiers: CGEventFlags = []) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { throw AXEngineError.eventCreationFailed }

        down.flags = modifiers
        up.flags = modifiers
        tagEvent(down)
        tagEvent(up)

        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.001)
        up.post(tap: .cghidEventTap)
    }

    /// Execute a hotkey combination (e.g., ["cmd", "a"] for Select All).
    ///
    /// Parses modifier names (cmd/shift/option/ctrl) and a main key name.
    /// After the keypress, posts a flagsChanged event with zero flags to
    /// clear any stuck modifiers (from GhostOS's modifier cleanup pattern).
    @MainActor
    static func hotkey(_ keys: [String], holdDuration: TimeInterval = 0.05) throws {
        var modifiers: CGEventFlags = []
        var mainKeyCode: CGKeyCode?

        for key in keys {
            switch key.lowercased() {
            case "cmd", "command": modifiers.insert(.maskCommand)
            case "shift": modifiers.insert(.maskShift)
            case "option", "opt", "alt": modifiers.insert(.maskAlternate)
            case "ctrl", "control": modifiers.insert(.maskControl)
            default:
                mainKeyCode = keyCodeForName(key.lowercased())
            }
        }

        guard let keyCode = mainKeyCode else {
            throw AXEngineError.invalidHotkey(keys.joined(separator: "+"))
        }

        try pressKey(keyCode: keyCode, modifiers: modifiers)

        // Modifier cleanup: post flagsChanged with zero flags to prevent stuck keys.
        // This is critical — without it, modifier keys can remain "pressed" in the
        // target app after the hotkey finishes, causing unpredictable behavior.
        Thread.sleep(forTimeInterval: holdDuration)
        if let cleanup = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
            cleanup.flags = []
            cleanup.type = .flagsChanged
            tagEvent(cleanup)
            cleanup.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Helpers

    /// Tag a CGEvent with Shadow's synthesized event marker.
    private static func tagEvent(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: shadowEventTag)
    }

    /// Map key names to CGKeyCode values.
    /// Covers A-Z, 0-9, function keys, and common special keys.
    static func keyCodeForName(_ name: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            // Letters (QWERTY layout)
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
            "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
            "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
            "y": 16, "z": 6,
            // Numbers
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
            "7": 26, "8": 28, "9": 25,
            // Special keys
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
            "escape": 53, "up": 126, "down": 125, "left": 123, "right": 124,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "forwarddelete": 117,
            // Function keys
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            // Punctuation
            "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39,
            ",": 43, ".": 47, "/": 44, "`": 50,
        ]
        return map[name]
    }
}
