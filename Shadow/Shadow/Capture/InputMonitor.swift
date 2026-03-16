import Cocoa
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "InputMonitor")

/// Monitors keyboard and mouse input system-wide via CGEventTap.
/// Sends events to the Rust storage engine as Track 2 (input stream).
///
/// Privacy: Detects AXSecureTextField (password fields) and pauses keystroke
/// logging. Records "secure_field" event instead of the actual characters.
///
/// Not @MainActor — the event tap callback fires on the main run loop.
/// Marked @unchecked Sendable because all access is from the main thread.
final class InputMonitor: @unchecked Sendable {
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isMonitoring = false

    /// When true, events are received but not written to storage.
    var isPaused = false

    /// Whether the monitor is actually capturing input.
    /// False if: not started, tap creation failed, or tap is disabled (stale permission).
    var isCapturing: Bool {
        guard isMonitoring, let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// When set, input events are forwarded to the LearningRecorder for procedure recording.
    /// Set by AppDelegate when learning mode is toggled via Cmd+Shift+L.
    var learningRecorder: LearningRecorder?

    /// Called on key/mouse activity to signal user presence.
    /// Wired by AppDelegate to AXTreeLogger.recordUserActivity() for periodic capture gating.
    var onUserActivity: (@MainActor () -> Void)?

    // Throttle mouse moves: only emit when cursor has moved at least N points
    // or N seconds have elapsed since the last emission.
    private var lastMouseX: Double = 0
    private var lastMouseY: Double = 0
    private var lastMouseMoveTime: UInt64 = 0
    private static let mouseDistanceThreshold: Double = 50
    private static let mouseTimeThresholdUs: UInt64 = 2_000_000 // 2 seconds

    // Secure field detection
    private var secureFieldNotified = false

    // Diagnostic: track whether key events are actually arriving
    private var keyEventsReceived: Int = 0
    private var mouseEventsReceived: Int = 0
    private var diagnosticLogTime: UInt64 = 0

    deinit {
        // Safety net: ensure the CGEventTap is disabled if this object is
        // deallocated without an explicit stopMonitoring() call. The tap's
        // C callback holds an unretained reference to self via Unmanaged,
        // so a live tap after dealloc would access freed memory.
        if isMonitoring {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
    }

    // MARK: - Public API

    func startMonitoring() {
        guard !isMonitoring else { return }

        var eventMask: CGEventMask = 0
        eventMask |= (1 << CGEventType.keyDown.rawValue)
        eventMask |= (1 << CGEventType.leftMouseDown.rawValue)
        eventMask |= (1 << CGEventType.leftMouseUp.rawValue)
        eventMask |= (1 << CGEventType.rightMouseDown.rawValue)
        eventMask |= (1 << CGEventType.rightMouseUp.rawValue)
        eventMask |= (1 << CGEventType.mouseMoved.rawValue)
        eventMask |= (1 << CGEventType.leftMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.rightMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.scrollWheel.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: inputEventCallback,
            userInfo: userInfo
        ) else {
            logger.error("Failed to create CGEventTap. Is Input Monitoring permission granted?")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        isMonitoring = true
        let tapEnabled = CGEvent.tapIsEnabled(tap: tap)
        logger.info("Input monitoring started (tap enabled: \(tapEnabled))")

        if !tapEnabled {
            logger.error("CGEventTap created but NOT enabled — Input Monitoring permission likely stale. Run scripts/reset-permissions.sh and re-grant.")
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil

        logger.info("Input monitoring stopped")
    }

    // MARK: - Event Processing

    /// Tag value set on all synthesized events by InputSynthesizer.
    /// When detected, the event is from Shadow's agent — skip recording it.
    static let shadowSynthesizedEventTag: Int64 = 0x5348_4457  // "SHDW" in hex

    fileprivate func handleEvent(_ type: CGEventType, _ event: CGEvent) {
        // Filter out events synthesized by Shadow's InputSynthesizer.
        // These are tagged with kCGEventSourceUserData = 0x5348_4457 ("SHDW").
        if event.getIntegerValueField(.eventSourceUserData) == Self.shadowSynthesizedEventTag {
            return
        }

        // Still count events for diagnostics even when paused
        switch type {
        case .keyDown:
            keyEventsReceived += 1
        case .leftMouseDown, .rightMouseDown:
            mouseEventsReceived += 1
        default:
            break
        }

        // Signal user activity for periodic AX capture gating (Mimicry Phase A2).
        // Only key and mouse-down events count as meaningful activity signals.
        if type == .keyDown || type == .leftMouseDown || type == .rightMouseDown {
            if let callback = onUserActivity {
                Task { @MainActor in callback() }
            }
        }

        // Skip writing to storage when paused
        guard !isPaused else { return }

        switch type {
        case .keyDown:
            handleKeyDown(event)
        case .leftMouseDown, .rightMouseDown:
            handleMouseDown(type, event)
        case .leftMouseUp, .rightMouseUp:
            handleMouseUp(type, event)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            handleMouseMove(event)
        case .scrollWheel:
            handleScroll(event)
        default:
            break
        }

        // Periodic diagnostic: warn if mouse events are arriving but keyboard events are not.
        // This indicates a stale Input Monitoring permission (common during development).
        let now = EventWriter.now()
        if now - diagnosticLogTime > 60_000_000 { // every 60 seconds
            diagnosticLogTime = now
            if mouseEventsReceived > 20 && keyEventsReceived == 0 {
                logger.warning("Keyboard events not being delivered (mouse: \(self.mouseEventsReceived), keys: \(self.keyEventsReceived)). Input Monitoring permission may be stale — run scripts/reset-permissions.sh")
            }
        }
    }

    // MARK: - Key Events

    private func handleKeyDown(_ event: CGEvent) {
        // Check for secure field (password input)
        if isSecureFieldFocused() {
            if !secureFieldNotified {
                secureFieldNotified = true
                EventWriter.inputEvent(type: "secure_field", details: [:])
            }
            return
        }

        secureFieldNotified = false

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        let chars = keyChars(from: event)

        var details: [String: MsgPackValue] = [
            "key_code": .int32(Int32(keyCode)),
        ]

        if let chars {
            details["chars"] = .string(chars)
        }

        var mods: [String] = []
        if flags.contains(.maskCommand) { mods.append("cmd") }
        if flags.contains(.maskShift) { mods.append("shift") }
        if flags.contains(.maskAlternate) { mods.append("opt") }
        if flags.contains(.maskControl) { mods.append("ctrl") }
        if !mods.isEmpty {
            details["modifiers"] = .string(mods.joined(separator: "+"))
        }

        // Mimicry: add app context so events_index has app_name for workflow extraction.
        addAppContext(to: &details)

        // Key events: infer display from focused window
        let displayID = DisplayMapper.focusedWindowDisplayID()
        EventWriter.inputEvent(type: "key_down", details: details, displayID: displayID)

        // Forward to learning recorder if active
        if let recorder = learningRecorder {
            let isCharacterKey = chars != nil && mods.isEmpty
            let keyName = keyNameForCode(Int(keyCode))
            let ts = EventWriter.now()
            Task {
                await recorder.recordKeystroke(
                    chars: chars,
                    keyCode: Int(keyCode),
                    keyName: keyName,
                    modifiers: mods,
                    isCharacterKey: isCharacterKey,
                    timestamp: ts
                )
            }
        }
    }

    private func keyChars(from event: CGEvent) -> String? {
        guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
        let chars = nsEvent.characters
        guard let chars, !chars.isEmpty else { return nil }
        // Don't log control characters (backspace, return, etc.)
        if chars.unicodeScalars.allSatisfy({ $0.value < 32 || $0.value == 127 }) {
            return nil
        }
        return chars
    }

    // MARK: - Mouse Events

    private func handleMouseDown(_ type: CGEventType, _ event: CGEvent) {
        let location = event.location
        let button: String = type == .leftMouseDown ? "left" : "right"
        let clickCount = event.getIntegerValueField(.mouseEventClickState)
        let displayID = DisplayMapper.displayID(for: location)

        var details: [String: MsgPackValue] = [
            "button": .string(button),
            "x": .int32(Int32(location.x)),
            "y": .int32(Int32(location.y)),
            "clicks": .int32(Int32(clickCount)),
            // Mimicry: store click coordinates in the timeline index for training data generation.
            // These are separate from the raw "x"/"y" event fields because the EventHeader uses
            // click_x/click_y to populate the corresponding events_index columns.
            "click_x": .int32(Int32(location.x)),
            "click_y": .int32(Int32(location.y)),
        ]

        // Mimicry: add app context so events_index has app_name for workflow extraction.
        addAppContext(to: &details)

        // Mimicry Phase A1: AX enrichment — identify what was clicked.
        // Uses AXUIElementCopyElementAtPosition directly (sub-ms, Mach IPC).
        // This runs on the main thread via the CGEventTap callback.
        // We call the C API directly instead of ShadowElement.atPoint because
        // that method is @MainActor-isolated and we're in a non-isolated context.
        enrichMouseDownWithAX(location: location, details: &details)

        EventWriter.inputEvent(type: "mouse_down", details: details, displayID: displayID)
    }

    private func handleMouseUp(_ type: CGEventType, _ event: CGEvent) {
        let location = event.location
        let button: String = type == .leftMouseUp ? "left" : "right"
        let displayID = DisplayMapper.displayID(for: location)

        EventWriter.inputEvent(type: "mouse_up", details: [
            "button": .string(button),
            "x": .int32(Int32(location.x)),
            "y": .int32(Int32(location.y)),
        ], displayID: displayID)

        // Forward to learning recorder if active
        if let recorder = learningRecorder {
            let ts = EventWriter.now()
            Task {
                await recorder.recordClick(
                    x: Double(location.x),
                    y: Double(location.y),
                    button: button,
                    clickCount: 1,
                    timestamp: ts
                )
            }
        }
    }

    private func handleMouseMove(_ event: CGEvent) {
        let location = event.location
        let now = EventWriter.now()

        let dx = location.x - lastMouseX
        let dy = location.y - lastMouseY
        let distance = (dx * dx + dy * dy).squareRoot()
        let timeSinceLast = now - lastMouseMoveTime

        guard distance >= Self.mouseDistanceThreshold
                || timeSinceLast >= Self.mouseTimeThresholdUs else {
            return
        }

        lastMouseX = location.x
        lastMouseY = location.y
        lastMouseMoveTime = now

        let displayID = DisplayMapper.displayID(for: location)
        EventWriter.inputEvent(type: "mouse_move", details: [
            "x": .int32(Int32(location.x)),
            "y": .int32(Int32(location.y)),
        ], displayID: displayID)
    }

    // MARK: - Scroll Events

    private func handleScroll(_ event: CGEvent) {
        let deltaY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let deltaX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        guard deltaX != 0 || deltaY != 0 else { return }

        let location = event.location

        let displayID = DisplayMapper.displayID(for: location)
        var scrollDetails: [String: MsgPackValue] = [
            "dx": .int32(Int32(deltaX)),
            "dy": .int32(Int32(deltaY)),
            "x": .int32(Int32(location.x)),
            "y": .int32(Int32(location.y)),
        ]
        // Mimicry: add app context so events_index has app_name for workflow extraction.
        addAppContext(to: &scrollDetails)
        EventWriter.inputEvent(type: "scroll", details: scrollDetails, displayID: displayID)

        // Forward to learning recorder if active
        if let recorder = learningRecorder {
            let ts = EventWriter.now()
            Task {
                await recorder.recordScroll(
                    deltaX: Int(deltaX),
                    deltaY: Int(deltaY),
                    x: Double(location.x),
                    y: Double(location.y),
                    timestamp: ts
                )
            }
        }
    }

    // MARK: - Key Name Mapping

    /// Map a virtual key code to a human-readable key name for LearningRecorder.
    private func keyNameForCode(_ code: Int) -> String {
        switch code {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Escape"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PageUp"
        case 121: return "PageDown"
        case 117: return "ForwardDelete"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: return "key\(code)"
        }
    }

    // MARK: - App Context for Input Events (Mimicry)

    /// Add current frontmost app context to the event details dict.
    /// The workflow extractor and behavioral search need app_name, bundle_id, and
    /// window_title on Track 2 input events to correctly segment per-app workflows
    /// and match behavioral sequences. Without this, events_index.app_name is NULL
    /// for all Track 2 events, breaking workflow extraction and top_interactions queries.
    ///
    /// Safe to call from the CGEventTap callback — runs on the main run loop.
    private func addAppContext(to details: inout [String: MsgPackValue]) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        if let name = frontApp.localizedName {
            details["app_name"] = .string(name)
        }
        if let bundleId = frontApp.bundleIdentifier {
            details["bundle_id"] = .string(bundleId)
        }
        details["pid"] = .int32(frontApp.processIdentifier)
    }

    // MARK: - AX Click Enrichment (Mimicry Phase A1)

    /// Enrich a mouse_down event with AX context: what element was clicked.
    /// Called directly in the CGEventTap callback on the main run loop.
    /// Uses the C AX API directly to avoid @MainActor isolation requirements.
    private func enrichMouseDownWithAX(location: CGPoint, details: inout [String: MsgPackValue]) {
        var element: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        let err = AXUIElementCopyElementAtPosition(
            systemWide, Float(location.x), Float(location.y), &element)
        guard err == .success, let el = element else { return }

        // Read role
        if let roleVal = axAttribute(el, kAXRoleAttribute) as? String {
            details["ax_role"] = .string(roleVal)
        }

        // Read title (truncate to 200 chars)
        if let titleVal = axAttribute(el, kAXTitleAttribute) as? String, !titleVal.isEmpty {
            details["ax_title"] = .string(String(titleVal.prefix(200)))
        }

        // Read identifier (truncate to 200 chars)
        if let identVal = axAttribute(el, kAXIdentifierAttribute) as? String, !identVal.isEmpty {
            details["ax_identifier"] = .string(String(identVal.prefix(200)))
        }
    }

    // MARK: - Secure Field Detection

    private func isSecureFieldFocused() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        guard let elementValue = axAttribute(appElement, kAXFocusedUIElementAttribute) else {
            return false
        }
        let focusedElement = elementValue as! AXUIElement // CF type cast, always succeeds

        let role = axAttribute(focusedElement, kAXRoleAttribute) as? String
        return role == "AXSecureTextField"
    }
}

// MARK: - C Callback

/// CGEventTap callback — must be a plain C function.
private func inputEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Handle tap being disabled by the system (e.g., too slow)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let monitor = Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                logger.warning("Event tap re-enabled after system disabled it")
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.handleEvent(type, event)

    return Unmanaged.passUnretained(event)
}
