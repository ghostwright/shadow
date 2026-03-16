import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "AgentAXTools")

// MARK: - AX Agent Tools

/// Factory methods for the 5 AX-based agent tools.
/// These give the agent the ability to read and control the accessibility tree.
///
/// All tools use injectable dependencies for testing:
/// - `appProvider`: Returns the frontmost app's ShadowElement + metadata
/// - Live AX calls are @MainActor, so tool handlers use MainActor.run
extension AgentTools {

    /// Register all AX tools into an existing tool dictionary.
    ///
    /// - Parameters:
    ///   - tools: Mutable dictionary to register tools into.
    ///   - orchestrator: Optional LLM orchestrator. Accepted for API compatibility.
    ///   - procedureExecutor: Optional shared executor for replay_procedure.
    ///     When provided, procedure replays use this shared instance.
    static func registerAXTools(
        into tools: inout [String: RegisteredTool],
        orchestrator: LLMOrchestrator? = nil,
        procedureExecutor: ProcedureExecutor? = nil,
        onExecutionStarted: (@MainActor @Sendable (ProcedureTemplate) -> Void)? = nil,
        onExecutionEvent: (@MainActor @Sendable (ExecutionEvent) -> Void)? = nil
    ) {
        tools["ax_tree_query"] = axTreeQueryTool()
        tools["ax_click"] = axClickTool(orchestrator: orchestrator)
        tools["ax_type"] = axTypeTool()
        tools["ax_hotkey"] = axHotkeyTool()
        tools["ax_scroll"] = axScrollTool()
        tools["ax_wait"] = axWaitTool()
        tools["ax_focus_app"] = axFocusAppTool()
        tools["ax_read_text"] = axReadTextTool()
        tools["ax_inspect"] = axInspectTool()
        tools["ax_element_at"] = axElementAtTool()
        tools["ax_list_apps"] = axListAppsTool()
        tools["capture_live_screenshot"] = captureLiveScreenshotTool()
        tools["get_procedures"] = getProceduresTool()
        tools["replay_procedure"] = replayProcedureTool(
            executor: procedureExecutor,
            onExecutionStarted: onExecutionStarted,
            onExecutionEvent: onExecutionEvent
        )
    }

    // MARK: - ax_tree_query

    /// Query the AX tree of the frontmost app. Returns interactive elements
    /// with roles, titles, and positions for agent decision-making.
    ///
    /// This is the agent's "eyes" — it reads the UI structure to understand
    /// what elements are available before deciding what to click/type.
    static func axTreeQueryTool(
        appProvider: (@Sendable () async -> (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?)? = nil
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "ax_tree_query",
            description: "Read the accessibility tree of the frontmost application. Returns interactive UI elements (buttons, text fields, links, etc.) with their roles, titles, positions, and available actions. Use this to understand what's on screen before clicking or typing.",
            inputSchema: objectSchema(
                properties: [
                    "role": prop("string", "Filter by AX role (e.g., AXButton, AXTextField). Optional — omit to get all interactive elements."),
                    "query": prop("string", "Search for elements by title, value, or identifier. Optional fuzzy match."),
                    "maxDepth": prop("integer", "Maximum tree depth to search (default 15, max 25)"),
                    "maxResults": prop("integer", "Maximum elements to return (default 50, max 200)"),
                ],
                required: []
            )
        )

        let handler: AgentToolHandler = { args in
            let role = args["role"]?.stringValue
            let query = args["query"]?.stringValue
            let maxDepth = try parseClampedInt(args, key: "maxDepth", defaultValue: 15, min: 1, max: 25)
            let maxResults = try parseClampedInt(args, key: "maxResults", defaultValue: 50, min: 1, max: 200)

            let appInfo: (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?
            if let appProvider {
                appInfo = await appProvider()
            } else {
                appInfo = await MainActor.run { getFrontmostAppInfo() }
            }

            guard let app = appInfo else {
                return formatJSONLine(["error": "No frontmost application found"])
            }

            let elements: [AXSearchResult] = await MainActor.run {
                if role != nil || query != nil {
                    // Targeted search
                    return findElements(
                        in: app.element,
                        role: role,
                        query: query,
                        maxResults: maxResults,
                        maxDepth: maxDepth,
                        timeout: 5
                    )
                } else {
                    // Collect all interactive elements
                    let root: ShadowElement
                    if let window = app.element.focusedWindow() {
                        root = window
                    } else {
                        root = app.element
                    }
                    let interactiveElements = collectInteractiveElements(
                        in: root,
                        maxDepth: maxDepth,
                        maxCount: maxResults,
                        timeout: 3
                    )
                    return interactiveElements.enumerated().map { idx, el in
                        AXSearchResult(
                            element: el,
                            confidence: 1.0,
                            matchStrategy: "interactive",
                            semanticDepth: 0,
                            realDepth: idx
                        )
                    }
                }
            }

            if elements.isEmpty {
                return formatJSONLine(["result": "no_elements_found", "app": app.name])
            }

            var lines: [String] = [
                formatJSONLine(["app": app.name, "bundleId": app.bundleId, "elementCount": elements.count])
            ]

            for result in elements.prefix(maxResults) {
                let el = result.element
                let confidence = result.confidence
                let matchStrategy = result.matchStrategy
                let line: String = await MainActor.run {
                    var info: [String: Any] = [
                        "role": el.role() ?? "AXUnknown",
                    ]
                    if let title = el.title(), !title.isEmpty { info["title"] = title }
                    if let value = el.value(), !value.isEmpty { info["value"] = String(value.prefix(100)) }
                    if let identifier = el.identifier(), !identifier.isEmpty { info["identifier"] = identifier }
                    if let desc = el.descriptionText(), !desc.isEmpty { info["description"] = desc }
                    if let frame = el.frame() {
                        info["x"] = Int(frame.origin.x)
                        info["y"] = Int(frame.origin.y)
                        info["width"] = Int(frame.size.width)
                        info["height"] = Int(frame.size.height)
                    }
                    let actions = el.supportedActions()
                    if !actions.isEmpty { info["actions"] = actions }
                    if confidence < 1.0 {
                        info["confidence"] = String(format: "%.2f", confidence)
                        info["matchStrategy"] = matchStrategy
                    }
                    return formatJSONLine(info)
                }
                lines.append(line)
            }

            return lines.joined(separator: "\n")
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - ax_click

    /// Click an element identified by query, role, or coordinates.
    /// Uses two-phase click: AX-native first, CGEvent fallback.
    ///
    /// The `orchestrator` parameter is accepted for API compatibility but no longer
    /// used for automatic verification. The agent decides when to verify via ax_wait
    /// or ax_tree_query.
    static func axClickTool(
        appProvider: (@Sendable () async -> (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?)? = nil,
        orchestrator: LLMOrchestrator? = nil
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "ax_click",
            description: "Click a UI element. Finds the element by query text, role, or screen coordinates. Uses AX-native click first (no focus steal), falls back to synthetic mouse click. Supports double-click and right-click.",
            inputSchema: objectSchema(
                properties: [
                    "query": prop("string", "Text to find the element by (title, value, identifier, or description). Optional if x/y provided."),
                    "role": prop("string", "AX role filter (e.g., AXButton). Optional."),
                    "x": prop("number", "Screen X coordinate for direct click. Optional — use instead of query."),
                    "y": prop("number", "Screen Y coordinate for direct click. Optional — must pair with x."),
                    "button": prop("string", "Mouse button: 'left' (default) or 'right'"),
                    "count": prop("integer", "Click count: 1=single (default), 2=double, 3=triple"),
                ],
                required: []
            )
        )

        let handler: AgentToolHandler = { args in
            let queryText = args["query"]?.stringValue
            let roleFilter = args["role"]?.stringValue
            let xCoord = args["x"]?.doubleValue
            let yCoord = args["y"]?.doubleValue
            let buttonStr = args["button"]?.stringValue ?? "left"
            let clickCount = args["count"]?.intValue ?? 1

            let button: CGMouseButton = buttonStr == "right" ? .right : .left

            // Direct coordinate click
            if let x = xCoord, let y = yCoord {
                try await MainActor.run {
                    try InputSynthesizer.click(at: CGPoint(x: x, y: y), button: button, count: clickCount)
                }
                return formatJSONLine(["result": "clicked", "x": Int(x), "y": Int(y), "button": buttonStr, "count": clickCount])
            }

            // Query-based click
            guard queryText != nil || roleFilter != nil else {
                throw ToolError.missingArgument("query or x/y")
            }

            let appInfo: (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?
            if let appProvider {
                appInfo = await appProvider()
            } else {
                appInfo = await MainActor.run { getFrontmostAppInfo() }
            }

            guard let app = appInfo else {
                return formatJSONLine(["error": "No frontmost application found"])
            }

            let result: String = try await MainActor.run {
                let results = findElements(
                    in: app.element,
                    role: roleFilter,
                    query: queryText,
                    maxResults: 1,
                    timeout: 5
                )

                guard let best = results.first else {
                    let desc = [queryText, roleFilter].compactMap { $0 }.joined(separator: ", ")
                    throw AXEngineError.elementNotFound(description: desc)
                }

                if best.confidence < 0.40 {
                    throw AXEngineError.lowConfidenceMatch(confidence: best.confidence, threshold: 0.40)
                }

                try best.element.twoPhaseClick(button: button, count: clickCount)

                // Brief settle time before capturing post-action context
                Thread.sleep(forTimeInterval: 0.15)

                var info: [String: Any] = [
                    "result": "clicked",
                    "role": best.element.role() ?? "AXUnknown",
                    "confidence": String(format: "%.2f", best.confidence),
                    "strategy": best.matchStrategy,
                ]
                if let title = best.element.title() { info["title"] = title }

                // Capture post-action context for the agent to see what happened
                let postCtx = capturePostActionContext(app: app.element, appName: app.name)
                return formatJSONLine(info) + "\n" + postCtx
            }

            return result
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - ax_type

    /// Type text into a UI element with readback verification.
    static func axTypeTool(
        appProvider: (@Sendable () async -> (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?)? = nil
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "ax_type",
            description: "Type text into a text field. Finds the field by query, role, or identifier, then enters the text. Verifies the text was entered correctly via readback. Optionally clears the field first.",
            inputSchema: objectSchema(
                properties: [
                    "text": prop("string", "Text to type into the field"),
                    "into": prop("string", "Query to find the target field (title, placeholder, identifier). Optional — types at the currently focused element if omitted."),
                    "role": prop("string", "AX role filter (e.g., AXTextField). Optional."),
                    "clear": prop("boolean", "Clear the field before typing (default false)"),
                ],
                required: ["text"]
            )
        )

        let handler: AgentToolHandler = { args in
            guard let text = args["text"]?.stringValue else {
                throw ToolError.missingArgument("text")
            }
            let intoQuery = args["into"]?.stringValue
            let roleFilter = args["role"]?.stringValue
            let clear: Bool
            if case .bool(let b) = args["clear"] {
                clear = b
            } else {
                clear = false
            }

            let appInfo: (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?
            if let appProvider {
                appInfo = await appProvider()
            } else {
                appInfo = await MainActor.run { getFrontmostAppInfo() }
            }

            guard let app = appInfo else {
                return formatJSONLine(["error": "No frontmost application found"])
            }

            let result: String = try await MainActor.run {
                let targetElement: ShadowElement

                if let intoQuery {
                    // Find the target field
                    let editableRoles: Set<String> = [
                        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"
                    ]
                    let results = findElements(
                        in: app.element,
                        role: roleFilter,
                        query: intoQuery,
                        maxResults: 5,
                        timeout: 5
                    )

                    // Prefer editable fields among matches
                    let editable = results.filter { r in
                        if let role = r.element.role() { return editableRoles.contains(role) }
                        return false
                    }
                    guard let best = editable.first ?? results.first else {
                        throw AXEngineError.elementNotFound(description: intoQuery)
                    }

                    targetElement = best.element
                } else {
                    // Type at the currently focused element
                    guard let focused = app.element.focusedUIElement() else {
                        throw AXEngineError.elementNotFound(description: "no focused element")
                    }
                    targetElement = focused
                }

                let verified = try targetElement.typeText(text, clear: clear)

                var info: [String: Any] = [
                    "result": verified ? "typed_verified" : "typed_unverified",
                    "role": targetElement.role() ?? "AXUnknown",
                    "textLength": text.count,
                    "cleared": clear,
                ]
                if let title = targetElement.title() { info["fieldTitle"] = title }
                if let placeholder = targetElement.placeholderValue() { info["placeholder"] = placeholder }

                // Capture post-action context
                let postCtx = capturePostActionContext(app: app.element, appName: app.name)
                return formatJSONLine(info) + "\n" + postCtx
            }

            return result
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - ax_hotkey

    /// Press a keyboard shortcut (e.g., Cmd+C, Cmd+Shift+P).
    static func axHotkeyTool() -> RegisteredTool {
        let spec = ToolSpec(
            name: "ax_hotkey",
            description: "Press a keyboard shortcut. Specify modifier keys (cmd, shift, option, ctrl) and a main key. Cleans up modifier state after execution to prevent stuck keys.",
            inputSchema: objectSchema(
                properties: [
                    "keys": AnyCodable.dictionary([
                        "type": AnyCodable.string("array"),
                        "description": AnyCodable.string("Key combination as array of strings. Modifiers: 'cmd', 'shift', 'option'/'opt', 'ctrl'. Main key: 'a'-'z', '0'-'9', 'return', 'tab', 'space', 'delete', 'escape', 'up', 'down', 'left', 'right', 'f1'-'f12'. Example: ['cmd', 'shift', 'p'] for Cmd+Shift+P."),
                        "items": AnyCodable.dictionary([
                            "type": AnyCodable.string("string"),
                        ]),
                    ]),
                ],
                required: ["keys"]
            )
        )

        let handler: AgentToolHandler = { args in
            guard let keysRaw = args["keys"]?.arrayValue else {
                throw ToolError.missingArgument("keys")
            }

            let keys = keysRaw.compactMap { $0.stringValue }
            guard !keys.isEmpty else {
                throw ToolError.invalidArgument("keys", detail: "must contain at least one key")
            }

            let result: String = try await MainActor.run {
                try InputSynthesizer.hotkey(keys)

                // Brief settle time before capturing post-action context
                Thread.sleep(forTimeInterval: 0.15)

                let actionResult = formatJSONLine(["result": "hotkey_pressed", "keys": keys.joined(separator: "+")])

                // Capture post-action context
                if let appInfo = getTargetAppInfo() {
                    let postCtx = capturePostActionContext(app: appInfo.element, appName: appInfo.name)
                    return actionResult + "\n" + postCtx
                }
                return actionResult
            }

            return result
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - ax_scroll

    /// Scroll in the frontmost application.
    static func axScrollTool() -> RegisteredTool {
        let spec = ToolSpec(
            name: "ax_scroll",
            description: "Scroll content in the frontmost application. Specify direction and amount in lines. Optionally scroll at a specific screen position.",
            inputSchema: objectSchema(
                properties: [
                    "direction": prop("string", "Scroll direction: 'up', 'down', 'left', or 'right'"),
                    "amount": prop("integer", "Scroll amount in lines (default 3, max 50)"),
                    "x": prop("number", "Screen X coordinate to scroll at. Optional."),
                    "y": prop("number", "Screen Y coordinate to scroll at. Optional."),
                ],
                required: ["direction"]
            )
        )

        let handler: AgentToolHandler = { args in
            guard let direction = args["direction"]?.stringValue else {
                throw ToolError.missingArgument("direction")
            }
            let amount = try parseClampedInt(args, key: "amount", defaultValue: 3, min: 1, max: 50)
            let xCoord = args["x"]?.doubleValue
            let yCoord = args["y"]?.doubleValue

            let deltaY: Int32
            let deltaX: Int32
            switch direction.lowercased() {
            case "up":    deltaY = Int32(amount);  deltaX = 0
            case "down":  deltaY = -Int32(amount); deltaX = 0
            case "left":  deltaY = 0; deltaX = Int32(amount)
            case "right": deltaY = 0; deltaX = -Int32(amount)
            default:
                throw ToolError.invalidArgument("direction", detail: "must be 'up', 'down', 'left', or 'right'")
            }

            let point: CGPoint?
            if let x = xCoord, let y = yCoord {
                point = CGPoint(x: x, y: y)
            } else {
                point = nil
            }

            try await MainActor.run {
                try InputSynthesizer.scroll(deltaY: deltaY, deltaX: deltaX, at: point)
            }

            var info: [String: Any] = [
                "result": "scrolled",
                "direction": direction,
                "amount": amount,
            ]
            if let x = xCoord, let y = yCoord {
                info["x"] = Int(x)
                info["y"] = Int(y)
            }
            return formatJSONLine(info)
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - ax_wait

    /// Wait for a UI condition before proceeding.
    /// Critical for multi-step automation — after clicking a button,
    /// the agent needs to wait for the UI to update before taking the next action.
    static func axWaitTool(
        appProvider: (@Sendable () async -> (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?)? = nil
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "ax_wait",
            description: "Wait for a UI condition before proceeding. Essential after clicks or hotkeys that trigger UI changes (dialogs opening, pages loading, elements appearing). Polls the accessibility tree until the condition is met or timeout expires.",
            inputSchema: objectSchema(
                properties: [
                    "condition": prop("string", "What to wait for: 'elementExists' (element matching query appears), 'elementGone' (element disappears), 'titleContains' (window title includes text), 'titleChanged' (window title differs from current)"),
                    "value": prop("string", "Match value for the condition. For elementExists/elementGone: element query text. For titleContains: expected substring. For titleChanged: current title to watch for change."),
                    "role": prop("string", "AX role filter for element conditions. Optional."),
                    "timeout": prop("number", "Maximum seconds to wait (default 5, max 30)"),
                ],
                required: ["condition", "value"]
            )
        )

        let handler: AgentToolHandler = { args in
            guard let condition = args["condition"]?.stringValue else {
                throw ToolError.missingArgument("condition")
            }
            guard let value = args["value"]?.stringValue, !value.isEmpty else {
                throw ToolError.missingArgument("value")
            }

            let validConditions: Set<String> = ["elementExists", "elementGone", "titleContains", "titleChanged"]
            guard validConditions.contains(condition) else {
                throw ToolError.invalidArgument("condition", detail: "must be: \(validConditions.sorted().joined(separator: ", "))")
            }

            let roleFilter = args["role"]?.stringValue
            let timeout = min(args["timeout"]?.doubleValue ?? 5.0, 30.0)
            let pollInterval: TimeInterval = 0.3
            let startTime = CFAbsoluteTimeGetCurrent()
            var elapsed: Double = 0

            while elapsed < timeout {
                let matched: Bool = await MainActor.run {
                    let appInfo: (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?
                    if let appProvider {
                        // Can't call async from MainActor.run without nonisolated static.
                        // For live use, appProvider is nil and we use the default path.
                        appInfo = nil
                    } else {
                        appInfo = getFrontmostAppInfo()
                    }

                    guard let app = appInfo else { return false }

                    switch condition {
                    case "elementExists":
                        let results = findElements(
                            in: app.element,
                            role: roleFilter,
                            query: value,
                            maxResults: 1,
                            timeout: 2
                        )
                        return !results.isEmpty

                    case "elementGone":
                        let results = findElements(
                            in: app.element,
                            role: roleFilter,
                            query: value,
                            maxResults: 1,
                            timeout: 2
                        )
                        return results.isEmpty

                    case "titleContains":
                        if let window = app.element.focusedWindow(),
                           let title = window.title() {
                            return title.localizedCaseInsensitiveContains(value)
                        }
                        return false

                    case "titleChanged":
                        if let window = app.element.focusedWindow(),
                           let title = window.title() {
                            return title != value
                        }
                        return false

                    default:
                        return false
                    }
                }

                if matched {
                    let waitMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    return formatJSONLine([
                        "result": "condition_met",
                        "condition": condition,
                        "value": value,
                        "waitMs": Int(waitMs),
                    ])
                }

                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                elapsed = CFAbsoluteTimeGetCurrent() - startTime
            }

            return formatJSONLine([
                "result": "timeout",
                "condition": condition,
                "value": value,
                "timeoutSeconds": timeout,
            ])
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - ax_focus_app

    /// Bring an application to the front by name and update the agent's target.
    static func axFocusAppTool() -> RegisteredTool {
        let spec = ToolSpec(
            name: "ax_focus_app",
            description: "Bring an application to the front by name. Updates the agent's target so subsequent AX tools interact with this app. The app must already be running. If the app is not found, launch it via Spotlight: ax_hotkey(['cmd','space']), ax_type the name, ax_hotkey(['return']).",
            inputSchema: objectSchema(
                properties: [
                    "app": prop("string", "Application name (e.g., 'Safari', 'Finder', 'Mail'). Case-insensitive partial match."),
                ],
                required: ["app"]
            )
        )

        let handler: AgentToolHandler = { args in
            guard let appName = args["app"]?.stringValue, !appName.isEmpty else {
                throw ToolError.missingArgument("app")
            }

            let result: String = await MainActor.run {
                let workspace = NSWorkspace.shared
                let apps = workspace.runningApplications

                // Find the best match: exact match first, then case-insensitive contains
                let target = apps.first(where: {
                    $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame
                }) ?? apps.first(where: {
                    $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
                })

                guard let app = target else {
                    return formatJSONLine(["error": "App not found: \(appName)", "suggestion": "The app may not be running. Available apps can be found via ax_tree_query."])
                }

                let activated = app.activate()

                // Update AgentFocusManager so subsequent AX tools target this app
                if activated {
                    let focusMgr = AgentFocusManager.shared
                    focusMgr.setTarget(
                        pid: app.processIdentifier,
                        name: app.localizedName ?? appName,
                        bundleId: app.bundleIdentifier ?? ""
                    )

                    // If focusing a non-Shadow app during an agent run,
                    // transition to background mode so the panel doesn't steal focus.
                    let shadowBundleId = Bundle.main.bundleIdentifier ?? "com.shadow.app"
                    if focusMgr.isAgentRunning,
                       app.bundleIdentifier != shadowBundleId,
                       !BackgroundTaskManager.shared.isBackgroundTaskActive {
                        let task = focusMgr.targetApp.map { "Working with \($0.name)" } ?? "Working..."
                        BackgroundTaskManager.shared.enterBackground(task: task)
                    }
                }

                return formatJSONLine([
                    "result": activated ? "focused" : "focus_failed",
                    "app": app.localizedName ?? appName,
                    "bundleId": app.bundleIdentifier ?? "",
                    "pid": app.processIdentifier,
                ])
            }

            return result
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - ax_read_text

    /// Read the text content of the frontmost app or a specific element.
    /// Concatenates text from the accessibility tree for reading document content,
    /// text areas, or general page text.
    static func axReadTextTool(
        appProvider: (@Sendable () async -> (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?)? = nil
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "ax_read_text",
            description: "Read text content from the frontmost app. Collects text from the accessibility tree by traversing elements. Use this to read document content, text areas, web page text, or any displayed text. Optionally filter to a specific element by query.",
            inputSchema: objectSchema(
                properties: [
                    "query": prop("string", "Optional: narrow to a specific element by title/value/identifier. Omit to read all visible text."),
                    "maxDepth": prop("integer", "Maximum tree depth to traverse (default 25, max 50). Higher values reveal more web content (product listings, email threads)."),
                    "maxChars": prop("integer", "Maximum characters to return (default 8000, max 12000)"),
                ],
                required: []
            )
        )

        let handler: AgentToolHandler = { args in
            let query = args["query"]?.stringValue
            let maxDepth = try parseClampedInt(args, key: "maxDepth", defaultValue: 25, min: 1, max: 50)
            let maxChars = try parseClampedInt(args, key: "maxChars", defaultValue: 8000, min: 100, max: 12000)

            let appInfo: (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?
            if let appProvider {
                appInfo = await appProvider()
            } else {
                appInfo = await MainActor.run { getFrontmostAppInfo() }
            }

            guard let app = appInfo else {
                return formatJSONLine(["error": "No frontmost application found"])
            }

            let textContent: String = await MainActor.run {
                let root: ShadowElement
                if let query {
                    // Find the specific element
                    let results = findElements(
                        in: app.element,
                        role: nil,
                        query: query,
                        maxResults: 1,
                        timeout: 5
                    )
                    root = results.first?.element ?? app.element.focusedWindow() ?? app.element
                } else {
                    root = app.element.focusedWindow() ?? app.element
                }

                // Collect text by depth-first traversal using iterative approach
                // (avoids nested function closure isolation issues with @MainActor)
                var texts: [String] = []
                var charCount = 0
                let startTime = Date()
                let timeout: TimeInterval = 0.5  // 500ms max to avoid blocking on huge trees
                var stack: [(element: ShadowElement, depth: Int)] = [(root, 0)]
                var visited = Set<UInt>()

                while let (element, depth) = stack.popLast() {
                    guard depth <= maxDepth && charCount < maxChars else { continue }
                    guard Date().timeIntervalSince(startTime) < timeout else { break }
                    guard visited.insert(element.cfHash).inserted else { continue }

                    let role = element.role() ?? ""

                    // Collect this element's text content with role prefix for context
                    if let val = element.value(), !val.isEmpty, val.count > 1 {
                        let prefix: String
                        if role.contains("Button") || role.contains("Link") || role.contains("MenuItem") {
                            prefix = "[\(role)] "
                        } else {
                            prefix = ""
                        }
                        let textToAdd = String((prefix + val).prefix(maxChars - charCount))
                        texts.append(textToAdd)
                        charCount += textToAdd.count
                    } else if let title = element.title(), !title.isEmpty {
                        let prefix: String
                        if role.contains("Button") || role.contains("Link") || role.contains("MenuItem") {
                            prefix = "[\(role)] "
                        } else {
                            prefix = ""
                        }
                        let textToAdd = prefix + title
                        texts.append(textToAdd)
                        charCount += textToAdd.count
                    } else if let desc = element.descriptionText(), !desc.isEmpty, desc.count > 1 {
                        // Also collect description text (images, icons)
                        texts.append(desc)
                        charCount += desc.count
                    }

                    guard charCount < maxChars else { continue }

                    // Push children in reverse order so first child is processed first
                    let kids = element.children()
                    for child in kids.reversed() {
                        stack.append((child, depth + 1))
                    }
                }

                return texts.joined(separator: "\n")
            }

            if textContent.isEmpty {
                return formatJSONLine(["result": "no_text_found", "app": app.name])
            }

            let truncated = String(textContent.prefix(maxChars))
            var result: [String: Any] = [
                "app": app.name,
                "textLength": truncated.count,
            ]
            if truncated.count < textContent.count {
                result["truncated"] = true
            }

            return formatJSONLine(result) + "\n" + truncated
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - get_procedures

    /// List and search saved procedures.
    static func getProceduresTool(
        store: ProcedureStore? = nil
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "get_procedures",
            description: "List or search saved automation procedures. Returns procedure names, descriptions, step counts, and execution history. Use this to find a procedure before replaying it.",
            inputSchema: objectSchema(
                properties: [
                    "query": prop("string", "Search query to filter procedures by name, tag, or description. Optional — omit to list all."),
                    "limit": prop("integer", "Maximum results (default 10, max 50)"),
                ],
                required: []
            )
        )

        let handler: AgentToolHandler = { args in
            let procedureStore = store ?? ProcedureStore()
            let query = args["query"]?.stringValue
            let limit = try parseClampedInt(args, key: "limit", defaultValue: 10, min: 1, max: 50)

            let procedures: [ProcedureTemplate]
            if let query, !query.isEmpty {
                procedures = await procedureStore.search(query: query)
            } else {
                procedures = await procedureStore.listAll()
            }

            if procedures.isEmpty {
                return formatJSONLine(["result": "no_procedures_found"])
            }

            return Array(procedures.prefix(limit)).map { proc in
                var fields: [String: Any] = [
                    "id": proc.id,
                    "name": proc.name,
                    "description": proc.description,
                    "stepCount": proc.steps.count,
                    "sourceApp": proc.sourceApp,
                    "executionCount": proc.executionCount,
                ]
                if !proc.tags.isEmpty { fields["tags"] = proc.tags }
                if !proc.parameters.isEmpty {
                    fields["parameters"] = proc.parameters.map { p in
                        "\(p.name) (\(p.paramType))"
                    }
                }
                if let lastExec = proc.lastExecutedAt { fields["lastExecutedAt"] = lastExec }
                return formatJSONLine(fields)
            }.joined(separator: "\n")
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - replay_procedure

    /// Replay a saved procedure by ID with optional parameter overrides.
    ///
    /// - Parameters:
    ///   - store: Injectable procedure store for testing.
    ///   - executor: Shared executor instance. When provided, enables kill switch + progress UI.
    ///   - onExecutionStarted: Called on MainActor when execution begins. Receives the procedure template.
    ///   - onExecutionEvent: Called on MainActor for each execution event. Drives progress UI updates.
    static func replayProcedureTool(
        store: ProcedureStore? = nil,
        executor: ProcedureExecutor? = nil,
        onExecutionStarted: (@MainActor @Sendable (ProcedureTemplate) -> Void)? = nil,
        onExecutionEvent: (@MainActor @Sendable (ExecutionEvent) -> Void)? = nil
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "replay_procedure",
            description: "Replay a saved automation procedure. Specify the procedure ID and optionally override parameters. The procedure executes step-by-step with safety checks, verification, and retry. Option+Escape cancels execution immediately.",
            inputSchema: objectSchema(
                properties: [
                    "procedureId": prop("string", "ID of the procedure to replay (from get_procedures)"),
                    "parameters": .dictionary([
                        "type": .string("object"),
                        "description": .string("Parameter overrides as key-value pairs. Keys are parameter names from the procedure's parameter list."),
                        "additionalProperties": .dictionary([
                            "type": .string("string"),
                        ]),
                    ]),
                ],
                required: ["procedureId"]
            )
        )

        let handler: AgentToolHandler = { args in
            guard let procedureId = args["procedureId"]?.stringValue else {
                throw ToolError.missingArgument("procedureId")
            }

            let procedureStore = store ?? ProcedureStore()
            let procedureExecutor = executor ?? ProcedureExecutor()

            // Load the procedure
            guard let procedure = try await procedureStore.load(id: procedureId) else {
                throw ToolError.invalidArgument("procedureId", detail: "Procedure '\(procedureId)' not found")
            }

            // Parse parameter overrides
            var parameters: [String: String] = [:]
            if let paramsRaw = args["parameters"]?.dictionaryValue {
                for (key, value) in paramsRaw {
                    if let strValue = value.stringValue {
                        parameters[key] = strValue
                    }
                }
            }

            // Notify progress UI that execution is starting
            if let onStarted = onExecutionStarted {
                await onStarted(procedure)
            }

            // Execute the procedure
            var results: [String] = []
            results.append(formatJSONLine([
                "status": "starting",
                "procedure": procedure.name,
                "steps": procedure.steps.count,
                "parameters": parameters.isEmpty ? "none" : parameters.keys.joined(separator: ", "),
            ]))

            let stream = await procedureExecutor.execute(procedure, parameters: parameters)
            for await event in stream {
                // Forward event to progress UI
                if let onEvent = onExecutionEvent {
                    await onEvent(event)
                }

                switch event {
                case .stepStarting(let index, let intent):
                    results.append(formatJSONLine([
                        "event": "step_starting",
                        "step": index,
                        "intent": intent,
                    ]))

                case .stepCompleted(let index, let verified, let confidence):
                    results.append(formatJSONLine([
                        "event": "step_completed",
                        "step": index,
                        "verified": verified,
                        "confidence": String(format: "%.2f", confidence),
                    ]))

                case .stepFailed(let index, let error):
                    results.append(formatJSONLine([
                        "event": "step_failed",
                        "step": index,
                        "error": error,
                    ]))

                case .stepRetrying(let index, let attempt, let reason):
                    results.append(formatJSONLine([
                        "event": "step_retrying",
                        "step": index,
                        "attempt": attempt,
                        "reason": reason,
                    ]))

                case .safetyGateTriggered(let index, let classification, let reason):
                    results.append(formatJSONLine([
                        "event": "safety_gate",
                        "step": index,
                        "classification": classification,
                        "reason": reason,
                    ]))

                case .executionCompleted(let totalSteps, let successfulSteps):
                    results.append(formatJSONLine([
                        "event": "completed",
                        "totalSteps": totalSteps,
                        "successfulSteps": successfulSteps,
                    ]))
                    // Record successful execution
                    try? await procedureStore.recordExecution(id: procedureId)

                case .executionFailed(let atStep, let error):
                    results.append(formatJSONLine([
                        "event": "failed",
                        "atStep": atStep,
                        "error": error,
                    ]))

                case .executionCancelled(let atStep):
                    results.append(formatJSONLine([
                        "event": "cancelled",
                        "atStep": atStep,
                    ]))
                }
            }

            return results.joined(separator: "\n")
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - Target App Helper

    /// Get the target application's AX element and metadata.
    ///
    // MARK: - ax_inspect

    /// Inspect a single element in the frontmost app. Returns full metadata:
    /// role, title, value, position, size, actionable status, available actions,
    /// editable state. Like Ghost OS's ghost_inspect.
    static func axInspectTool(
        appProvider: (@Sendable () async -> (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?)? = nil
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "ax_inspect",
            description: "Get full metadata about a specific UI element. Returns role, title, value, position, size, center point, available actions, editable state, and whether it is a password field. Use when you need detailed info about one element found via ax_tree_query.",
            inputSchema: objectSchema(
                properties: [
                    "query": prop("string", "Element text/name to find and inspect"),
                    "role": prop("string", "AX role filter (e.g., AXButton, AXTextField) for precision"),
                ],
                required: ["query"]
            )
        )

        let handler: AgentToolHandler = { args in
            guard let query = args["query"]?.stringValue, !query.isEmpty else {
                throw ToolError.missingArgument("query")
            }
            let role = args["role"]?.stringValue

            let appInfo: (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?
            if let appProvider {
                appInfo = await appProvider()
            } else {
                appInfo = await MainActor.run { getFrontmostAppInfo() }
            }

            guard let app = appInfo else {
                return formatJSONLine(["error": "No frontmost application found"])
            }

            let results: [AXSearchResult] = await MainActor.run {
                findElements(
                    in: app.element,
                    role: role,
                    query: query,
                    maxResults: 1,
                    maxDepth: 20,
                    timeout: 5
                )
            }

            guard let match = results.first else {
                return formatJSONLine(["error": "No element found matching '\(query)'", "app": app.name])
            }

            // Build detailed metadata from the matched ShadowElement
            let result: String = await MainActor.run {
                let el = match.element
                let elRole = el.role() ?? "AXUnknown"
                var info: [String: Any] = [
                    "app": app.name,
                    "role": elRole,
                    "confidence": String(format: "%.2f", match.confidence),
                    "matchStrategy": match.matchStrategy,
                ]
                if let title = el.title(), !title.isEmpty { info["title"] = title }
                if let value = el.value(), !value.isEmpty { info["value"] = String(value.prefix(200)) }
                if let ident = el.identifier(), !ident.isEmpty { info["identifier"] = ident }
                if let desc = el.descriptionText(), !desc.isEmpty { info["description"] = desc }

                if let frame = el.frame() {
                    info["x"] = Int(frame.origin.x)
                    info["y"] = Int(frame.origin.y)
                    info["width"] = Int(frame.size.width)
                    info["height"] = Int(frame.size.height)
                    info["centerX"] = Int(frame.midX)
                    info["centerY"] = Int(frame.midY)
                }

                let actions = el.supportedActions()
                if !actions.isEmpty { info["actions"] = actions }
                info["actionable"] = !actions.isEmpty
                info["isSecure"] = elRole == "AXSecureTextField"
                info["isFocused"] = el.isFocused()
                info["isEnabled"] = el.isEnabled()

                // Editable detection
                let editableRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
                info["editable"] = editableRoles.contains(elRole)

                return formatJSONLine(info)
            }

            return result
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - ax_element_at

    /// Identify what element is at specific screen coordinates.
    /// Bridges screenshots to the accessibility tree -- given x/y from a screenshot,
    /// find what interactive element is there.
    static func axElementAtTool(
        appProvider: (@Sendable () async -> (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?)? = nil
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "ax_element_at",
            description: "Find what UI element is at specific screen coordinates. Bridges visual content (screenshots) to the accessibility tree. Returns the element's role, title, value, and available actions.",
            inputSchema: objectSchema(
                properties: [
                    "x": prop("number", "X coordinate (screen pixels)"),
                    "y": prop("number", "Y coordinate (screen pixels)"),
                ],
                required: ["x", "y"]
            )
        )

        let handler: AgentToolHandler = { args in
            guard let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue else {
                throw ToolError.missingArgument("x and y")
            }

            let appInfo: (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?
            if let appProvider {
                appInfo = await appProvider()
            } else {
                appInfo = await MainActor.run { getFrontmostAppInfo() }
            }

            guard let app = appInfo else {
                return formatJSONLine(["error": "No frontmost application found"])
            }

            // Use macOS accessibility to find element at point
            let result: String = await MainActor.run {
                let point = CGPoint(x: x, y: y)

                // Try system-wide hit test first
                if let hitElement = ShadowElement.atPoint(point) {
                    return formatJSONLine(buildElementInfo(hitElement, app: app.name, point: point))
                }

                // Fallback: try within the target app specifically
                if let hitElement = ShadowElement.atPoint(point, inApp: app.pid) {
                    return formatJSONLine(buildElementInfo(hitElement, app: app.name, point: point))
                }

                return formatJSONLine(["error": "No element found at (\(Int(x)), \(Int(y)))", "app": app.name])
            }

            return result
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    /// Build a dictionary of element info from a ShadowElement hit test result.
    @MainActor
    private static func buildElementInfo(_ element: ShadowElement, app: String, point: CGPoint) -> [String: Any] {
        var fields: [String: Any] = ["app": app, "hitX": Int(point.x), "hitY": Int(point.y)]

        if let role = element.role() { fields["role"] = role }
        if let title = element.title(), !title.isEmpty { fields["title"] = title }
        if let value = element.value(), !value.isEmpty { fields["value"] = String(value.prefix(200)) }

        if let frame = element.frame() {
            fields["x"] = Int(frame.origin.x)
            fields["y"] = Int(frame.origin.y)
            fields["width"] = Int(frame.size.width)
            fields["height"] = Int(frame.size.height)
            fields["centerX"] = Int(frame.midX)
            fields["centerY"] = Int(frame.midY)
        }

        let actions = element.supportedActions()
        if !actions.isEmpty { fields["actions"] = actions }
        fields["actionable"] = !actions.isEmpty

        return fields
    }

    // MARK: - ax_list_apps

    /// List all running applications with their window information.
    /// Like Ghost OS's ghost_state — gives the agent awareness of what apps are available.
    // MARK: - capture_live_screenshot

    /// Take a real-time screenshot of an app window using ScreenCaptureKit.
    /// Unlike `inspect_screenshots` (which reads from the recording buffer with 2-5s lag),
    /// this captures a live frame in ~100-200ms representing the actual current screen state.
    ///
    /// Adapted from Ghost OS's `ghost_screenshot` / `ScreenCapture.captureWindow()`.
    static func captureLiveScreenshotTool(
        appProvider: (@Sendable () async -> (element: ShadowElement, pid: pid_t, name: String, bundleId: String)?)? = nil
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "capture_live_screenshot",
            description: "Take a real-time screenshot of an app window. Captures a live frame in ~100ms showing the actual current screen state. Use for verifying actions, debugging failures, or when the AX tree is insufficient. Returns an image for visual analysis.",
            inputSchema: objectSchema(
                properties: [
                    "app": prop("string", "App name to screenshot. Defaults to the current target app."),
                    "fullResolution": prop("boolean", "If true, capture at native resolution. Default false (max 1280px width)."),
                ],
                required: []
            )
        )

        let imageHandler: AgentImageToolHandler = { args in
            let appName = args["app"]?.stringValue
            let fullResolution: Bool
            if case .bool(let b) = args["fullResolution"] {
                fullResolution = b
            } else {
                fullResolution = false
            }

            // Resolve target PID
            let targetPid: pid_t
            let targetName: String

            if let appName {
                // Find the specified app
                let found: (pid: pid_t, name: String)? = await MainActor.run {
                    let apps = NSWorkspace.shared.runningApplications
                    let shadowBundleId = Bundle.main.bundleIdentifier ?? "com.shadow.app"
                    for app in apps {
                        guard app.activationPolicy == .regular,
                              !app.isTerminated,
                              app.bundleIdentifier != shadowBundleId else { continue }
                        if let name = app.localizedName,
                           name.localizedCaseInsensitiveContains(appName) {
                            return (pid: app.processIdentifier, name: name)
                        }
                        if let bundleId = app.bundleIdentifier,
                           bundleId.localizedCaseInsensitiveContains(appName) {
                            return (pid: app.processIdentifier, name: app.localizedName ?? appName)
                        }
                    }
                    return nil
                }
                guard let found else {
                    throw ToolError.invalidArgument("app", detail: "App not found: '\(appName)'")
                }
                targetPid = found.pid
                targetName = found.name
            } else if let provider = appProvider {
                guard let appInfo = await provider() else {
                    throw ToolError.invalidArgument("app", detail: "No target app available")
                }
                targetPid = appInfo.pid
                targetName = appInfo.name
            } else {
                let appInfo: (element: ShadowElement, pid: pid_t, name: String, bundleId: String)? =
                    await MainActor.run { getTargetAppInfo() }
                guard let appInfo else {
                    throw ToolError.invalidArgument("app", detail: "No target app available")
                }
                targetPid = appInfo.pid
                targetName = appInfo.name
            }

            // Check Screen Recording permission
            guard CGPreflightScreenCaptureAccess() else {
                throw ToolError.invalidArgument("app", detail: "Screen Recording permission not granted")
            }

            // Capture the window using ScreenCaptureKit
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false
                )

                // Find the largest window belonging to the target PID
                let pidWindows = content.windows.filter {
                    $0.owningApplication?.processID == targetPid
                }
                guard let window = pidWindows
                    .filter({ $0.frame.width > 100 && $0.frame.height > 100 })
                    .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
                else {
                    throw ToolError.invalidArgument("app", detail: "No visible window found for '\(targetName)'")
                }

                // Configure capture
                let config = SCStreamConfiguration()
                config.showsCursor = false
                if fullResolution {
                    config.width = Int(window.frame.width)
                    config.height = Int(window.frame.height)
                } else {
                    let maxWidth = 1280
                    let aspect = window.frame.height / window.frame.width
                    let captureWidth = min(maxWidth, Int(window.frame.width))
                    config.width = captureWidth
                    config.height = Int(CGFloat(captureWidth) * aspect)
                }

                let filter = SCContentFilter(desktopIndependentWindow: window)
                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )

                // Convert to JPEG for smaller payload
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                guard let jpegData = bitmap.representation(
                    using: .jpeg, properties: [.compressionFactor: 0.85]
                ) else {
                    throw ToolError.invalidArgument("app", detail: "Failed to encode screenshot as JPEG")
                }

                let base64 = jpegData.base64EncodedString()
                let meta = formatJSONLine([
                    "app": targetName,
                    "windowTitle": window.title ?? "",
                    "width": cgImage.width,
                    "height": cgImage.height,
                    "capturedAt": ISO8601DateFormatter().string(from: Date()),
                ] as [String: Any])

                return AgentToolOutput(
                    text: meta,
                    images: [ImageData(mediaType: "image/jpeg", base64Data: base64)]
                )
            } catch {
                throw ToolError.invalidArgument("app", detail: "Screenshot capture failed: \(error.localizedDescription)")
            }
        }

        return RegisteredTool(spec: spec, imageHandler: imageHandler)
    }

    // MARK: - ax_list_apps

    static func axListAppsTool() -> RegisteredTool {
        let spec = ToolSpec(
            name: "ax_list_apps",
            description: "List all running applications with their names, bundle IDs, and active status. Use to find which apps are available before using ax_focus_app.",
            inputSchema: objectSchema(
                properties: [:],
                required: []
            )
        )

        let handler: AgentToolHandler = { _ in
            let result: String = await MainActor.run {
                let running = NSWorkspace.shared.runningApplications
                let shadowBundleId = Bundle.main.bundleIdentifier ?? "com.shadow.app"

                let apps = running
                    .filter { $0.activationPolicy == .regular && !$0.isTerminated }
                    .filter { $0.bundleIdentifier != shadowBundleId }
                    .map { app -> [String: Any] in
                        var fields: [String: Any] = [
                            "name": app.localizedName ?? "Unknown",
                            "pid": Int(app.processIdentifier),
                            "isActive": app.isActive,
                        ]
                        if let bundleId = app.bundleIdentifier {
                            fields["bundleId"] = bundleId
                        }
                        if app.isHidden {
                            fields["hidden"] = true
                        }
                        return fields
                    }

                if apps.isEmpty {
                    return formatJSONLine(["result": "no_running_apps"])
                }

                return apps.map { formatJSONLine($0) }.joined(separator: "\n")
            }

            return result
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - AX Target Resolution

    /// Uses `AgentFocusManager` to resolve the correct app:
    /// 1. If a target app was snapshot when the overlay opened, returns that app
    /// 2. If the agent has focused a specific app via `ax_focus_app`, returns that
    /// 3. Falls back to the frontmost non-Shadow app
    ///
    /// Must be called on MainActor.
    @MainActor
    private static func getTargetAppInfo() -> (element: ShadowElement, pid: pid_t, name: String, bundleId: String)? {
        guard let resolved = AgentFocusManager.shared.targetAppInfo() else {
            return nil
        }

        // Auto-dismiss overlay when any AX tool targets a non-Shadow app.
        // Same pattern as ax_focus_app (lines 637-643) but applied at the common
        // resolution point so ALL AX tools benefit — not just ax_focus_app.
        let shadowBundleId = Bundle.main.bundleIdentifier ?? "com.shadow.app"
        if AgentFocusManager.shared.isAgentRunning,
           resolved.bundleId != shadowBundleId,
           !BackgroundTaskManager.shared.isBackgroundTaskActive {
            let task = "Working with \(resolved.name)"
            BackgroundTaskManager.shared.enterBackground(task: task)
        }

        return resolved
    }

    /// Legacy alias for compatibility — routes through AgentFocusManager.
    @MainActor
    private static func getFrontmostAppInfo() -> (element: ShadowElement, pid: pid_t, name: String, bundleId: String)? {
        getTargetAppInfo()
    }

    // MARK: - Post-Action Context Capture

    /// Capture a lightweight post-action context snapshot.
    /// Returns a JSON string with the window title, focused element, and up to 10 visible
    /// interactive elements. This lets the agent see what happened after an action without
    /// making a separate ax_tree_query call, saving an LLM round-trip.
    ///
    /// Must be called on MainActor. Called with a 150ms delay after actions to let UI settle.
    @MainActor
    static func capturePostActionContext(
        app: ShadowElement,
        appName: String
    ) -> String {
        let window = app.focusedWindow()

        var ctx: [String: Any] = [
            "app": appName,
        ]

        // Window title
        if let windowTitle = window?.title() ?? app.title() {
            ctx["windowTitle"] = windowTitle
        }

        // Focused element
        if let focused = app.focusedUIElement() {
            var focusedInfo: [String: Any] = [:]
            if let role = focused.role() { focusedInfo["role"] = role }
            if let title = focused.title() { focusedInfo["title"] = title }
            if let value = focused.value() { focusedInfo["value"] = String(value.prefix(80)) }
            ctx["focusedElement"] = focusedInfo
        }

        // Up to 10 interactive elements (depth 3, fast scan)
        let root = window ?? app
        var interactiveNames: [String] = []
        var stack: [(element: ShadowElement, depth: Int)] = [(root, 0)]

        while let (el, depth) = stack.popLast() {
            guard depth <= 3, interactiveNames.count < 10 else { continue }

            let role = el.role() ?? ""
            let isInteractive = role.contains("Button") || role.contains("TextField")
                || role.contains("ComboBox") || role.contains("Link")
                || role.contains("MenuItem") || role.contains("TextArea")
                || role.contains("PopUpButton") || role.contains("Checkbox")

            if isInteractive {
                if let title = el.title(), !title.isEmpty {
                    interactiveNames.append(title)
                } else if let value = el.value(), !value.isEmpty {
                    interactiveNames.append(String(value.prefix(40)))
                }
            }

            let kids = el.children()
            for child in kids.reversed() {
                stack.append((child, depth + 1))
            }
        }

        if !interactiveNames.isEmpty {
            ctx["visibleElements"] = interactiveNames
        }

        return formatJSONLine(ctx)
    }
}

// MARK: - Screenshot Verification

/// Captures a screenshot and asks Haiku to verify whether a UI action succeeded.
///
/// Complements the existing `ActionVerifier` (AX-tree-based verification) with
/// visual verification using a fast LLM. Particularly useful for actions whose
/// effects are visible on screen but not easily detected via AX state changes
/// (e.g., page loads, animation completions, visual feedback).
///
/// Uses `modelOverride` to route through fast Haiku (~200ms) instead of the
/// user's selected model. The verifier is optional and injectable.
enum ScreenshotVerifier {

    /// Verification model — Claude Haiku for speed (~200ms).
    static let verificationModelId = "claude-haiku-4-5-20251001"

    /// Captures the current screen and sends it to Haiku for verification.
    ///
    /// - Parameters:
    ///   - actionDescription: What action was performed (e.g., "clicked 'Submit' button")
    ///   - orchestrator: The LLM orchestrator for routing the Haiku request
    /// - Returns: A short verification note, or nil if verification is unavailable
    static func verify(
        action actionDescription: String,
        orchestrator: LLMOrchestrator
    ) async -> String? {
        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. Capture screenshot of the current screen
        guard let screenshot = await captureMainDisplay() else {
            logger.warning("ScreenshotVerifier: failed to capture screenshot")
            return nil
        }

        // 2. Encode as JPEG (quality 0.6 for speed — we only need enough for Haiku)
        guard let jpegData = jpegEncode(screenshot, quality: 0.6) else {
            logger.warning("ScreenshotVerifier: failed to encode screenshot")
            return nil
        }

        let base64 = jpegData.base64EncodedString()

        // 3. Build verification request with image
        let userContent: [LLMMessageContent] = [
            .image(mediaType: "image/jpeg", base64Data: base64),
            .text("I just performed this action: \(actionDescription)\n\nLook at the screenshot. Did the action succeed? What changed on screen? Answer in 1-2 sentences."),
        ]

        let request = LLMRequest(
            systemPrompt: "You are a UI verification assistant. You receive a screenshot taken immediately after a UI action. Confirm whether the action appears to have succeeded based on visual evidence. Be concise.",
            userPrompt: "",
            maxTokens: 100,
            temperature: 0.0,
            responseFormat: .text,
            messages: [LLMMessage(role: "user", content: userContent)],
            modelOverride: verificationModelId
        )

        // 4. Send to Haiku
        do {
            let response = try await orchestrator.generate(request: request)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.info("ScreenshotVerifier: verified in \(String(format: "%.0f", elapsedMs))ms")
            DiagnosticsStore.shared.increment("action_verify_total")
            DiagnosticsStore.shared.recordLatency("action_verify_ms", ms: elapsedMs)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.warning("ScreenshotVerifier: Haiku call failed: \(error.localizedDescription)")
            DiagnosticsStore.shared.increment("action_verify_error_total")
            return nil
        }
    }

    // MARK: - Screenshot Capture

    /// Capture the main display as a CGImage using CGWindowListCreateImage.
    /// This is fast (~10ms) and doesn't require ScreenCaptureKit streams.
    @MainActor
    private static func captureMainDisplay() -> CGImage? {
        CGWindowListCreateImage(
            CGRect.null, // null = entire display
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
    }

    /// Encode a CGImage as JPEG data.
    private static func jpegEncode(_ image: CGImage, quality: CGFloat) -> Data? {
        let bitmapRep = NSBitmapImageRep(cgImage: image)
        return bitmapRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: quality]
        )
    }
}
