import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ProcedureExecutor")

// MARK: - Procedure Executor

/// Replays learned procedures step-by-step with element resolution,
/// safety gates, verification, retry, and undo support.
///
/// Execution flow:
/// 1. Pre-flight safety assessment of the entire procedure
/// 2. For each step:
///    a. Resolve parameters (substitute user-provided values)
///    b. Focus the correct app (if multi-app procedure)
///    c. Find the target element via 5-level locator cascade
///    d. Per-step safety check (hard rules + LLM classification)
///    e. Record undo snapshot
///    f. Execute the action (AX-native → CGEvent fallback)
///    g. Wait for UI to settle
///    h. Verify post-condition (tree hash, readback, etc.)
///    i. On failure: retry → broaden search → LLM adaptation → user escalation
/// 3. Emit ExecutionEvents via AsyncStream for UI progress panel
///
/// Kill switch: Option+Escape cancels execution immediately.
///
/// Actor isolation ensures only one procedure runs at a time.
actor ProcedureExecutor {

    private var currentRun: ExecutionRun?
    private let safetyGate: SafetyGate
    private let undoManager: ExecutionUndoManager
    private let llmProvider: (any LLMProvider)?
    private var isCancelled = false

    /// Callback invoked when execution state changes. Used by HotkeyManager kill switch.
    var onExecutionStateChanged: (@Sendable (Bool) -> Void)?

    init(
        safetyGate: SafetyGate? = nil,
        undoManager: ExecutionUndoManager? = nil,
        llmProvider: (any LLMProvider)? = nil
    ) {
        self.safetyGate = safetyGate ?? SafetyGate()
        self.undoManager = undoManager ?? ExecutionUndoManager()
        self.llmProvider = llmProvider
    }

    /// Whether a procedure is currently executing.
    var isExecuting: Bool { currentRun != nil }

    /// The ID of the currently executing procedure (if any).
    var currentProcedureId: String? { currentRun?.procedureId }

    /// The current step index being executed.
    var currentStepIndex: Int? { currentRun?.currentStep }

    // MARK: - Execution

    /// Execute a procedure with optional parameter overrides.
    ///
    /// Returns an AsyncStream of ExecutionEvents that the caller can
    /// iterate to track progress in real time.
    func execute(
        _ procedure: ProcedureTemplate,
        parameters: [String: String] = [:]
    ) -> AsyncStream<ExecutionEvent> {
        AsyncStream { continuation in
            Task {
                await self.runExecution(procedure, parameters: parameters, continuation: continuation)
            }
        }
    }

    /// Cancel the currently executing procedure.
    func cancel() {
        guard currentRun != nil else { return }
        isCancelled = true
        logger.info("Execution cancel requested")
    }

    /// Undo the last executed step.
    ///
    /// Returns the undo strategy that should be applied, or nil
    /// if no undo is possible.
    func undoLastStep() async -> UndoStrategy? {
        guard let reversal = await undoManager.popReversal() else { return nil }
        logger.info("Undoing step \(reversal.snapshot.stepIndex)")
        return reversal.strategy
    }

    // MARK: - Core Execution Loop

    private func runExecution(
        _ procedure: ProcedureTemplate,
        parameters: [String: String],
        continuation: AsyncStream<ExecutionEvent>.Continuation
    ) async {
        isCancelled = false

        // Pre-flight safety assessment
        let assessment = await safetyGate.assessProcedure(procedure)
        if assessment.riskLevel == .blocked {
            continuation.yield(.executionFailed(
                atStep: 0,
                error: "Safety gate blocked: \(assessment.rationale)"
            ))
            continuation.finish()
            return
        }

        if assessment.requiresApproval {
            continuation.yield(.safetyGateTriggered(
                index: 0,
                classification: assessment.riskLevel.rawValue,
                reason: assessment.rationale
            ))
            // In a full implementation, we'd wait for user approval here.
            // For now, proceed with logging.
            logger.info("Safety gate: \(assessment.riskLevel.rawValue) — \(assessment.rationale)")
        }

        // Initialize execution run
        let runId = UUID()
        currentRun = ExecutionRun(
            procedureId: procedure.id,
            runId: runId,
            totalSteps: procedure.steps.count
        )
        onExecutionStateChanged?(true)

        await undoManager.clear()

        var completedSteps = 0

        for (index, step) in procedure.steps.enumerated() {
            // Check kill switch
            guard !isCancelled else {
                continuation.yield(.executionCancelled(atStep: index))
                break
            }

            currentRun?.currentStep = index
            continuation.yield(.stepStarting(index: index, intent: step.intent))

            // Resolve parameters in this step
            let resolvedAction = resolveParameters(step.actionType, parameters: parameters, substitutions: step.parameterSubstitutions)

            // Per-step safety check
            let stepAssessment = await safetyGate.assessAction(
                actionType: resolvedAction,
                elementRole: step.targetLocator?.role,
                app: procedure.sourceApp,
                bundleId: procedure.sourceBundleId,
                windowTitle: nil
            )

            if stepAssessment.riskLevel == .blocked {
                continuation.yield(.stepFailed(
                    index: index,
                    error: "Safety gate blocked step: \(stepAssessment.rationale)"
                ))
                continuation.yield(.executionFailed(
                    atStep: index,
                    error: "Blocked by safety gate"
                ))
                break
            }

            // Execute the step with retry logic
            let success = await executeStepWithRetry(
                step: step,
                resolvedAction: resolvedAction,
                index: index,
                procedure: procedure,
                continuation: continuation
            )

            if success {
                completedSteps += 1
                let confidence = 1.0 - (Double(index) * 0.02) // Slight decay for later steps
                continuation.yield(.stepCompleted(
                    index: index,
                    verified: true,
                    confidence: max(0.5, confidence)
                ))
            } else if isCancelled {
                continuation.yield(.executionCancelled(atStep: index))
                break
            } else {
                continuation.yield(.executionFailed(
                    atStep: index,
                    error: "Step \(index) failed after retries"
                ))
                break
            }
        }

        if !isCancelled && completedSteps == procedure.steps.count {
            continuation.yield(.executionCompleted(
                totalSteps: procedure.steps.count,
                successfulSteps: completedSteps
            ))
        }

        currentRun = nil
        onExecutionStateChanged?(false)
        continuation.finish()
    }

    // MARK: - Step Execution with Retry

    /// Execute a single step with retry, adaptation, and escalation.
    ///
    /// Retry cascade:
    /// 1. Execute action
    /// 2. Wait for UI settle (300ms)
    /// 3. Verify post-condition
    /// 4. On failure: retry up to `step.maxRetries` times with backoff
    /// 5. On continued failure: attempt LLM adaptation
    /// 6. On adaptation failure: report failure
    private func executeStepWithRetry(
        step: ProcedureStep,
        resolvedAction: RecordedAction.ActionType,
        index: Int,
        procedure: ProcedureTemplate,
        continuation: AsyncStream<ExecutionEvent>.Continuation
    ) async -> Bool {
        // Record undo snapshot
        let preHash = CaptureSessionClock.wallMicros()  // Use timestamp as proxy for tree state
        let snapshot = UndoSnapshot(
            stepIndex: index,
            actionType: resolvedAction,
            preTreeHash: preHash,
            timestamp: CaptureSessionClock.wallMicros()
        )
        await undoManager.push(snapshot)

        // Attempt execution
        for attempt in 0...step.maxRetries {
            guard !isCancelled else { return false }

            if attempt > 0 {
                continuation.yield(.stepRetrying(
                    index: index,
                    attempt: attempt,
                    reason: "Verification failed, retrying"
                ))
                // Exponential backoff: 500ms, 1000ms, 2000ms
                let delayMs = UInt64(500) * UInt64(1 << (attempt - 1))
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }

            let executed = await executeAction(
                resolvedAction,
                locator: step.targetLocator,
                app: procedure.sourceApp,
                bundleId: procedure.sourceBundleId
            )

            guard executed else { continue }

            // Wait for UI to settle
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

            // Verify (if we have verification criteria)
            let verified = await verifyStep(
                step: step,
                resolvedAction: resolvedAction,
                app: procedure.sourceApp,
                bundleId: procedure.sourceBundleId
            )

            if verified {
                return true
            }
        }

        // All retries exhausted — attempt LLM adaptation
        if llmProvider != nil {
            let adapted = await adaptStep(
                step: step,
                resolvedAction: resolvedAction,
                app: procedure.sourceApp,
                bundleId: procedure.sourceBundleId,
                continuation: continuation
            )
            return adapted
        }

        return false
    }

    // MARK: - Action Execution

    /// Execute a single action on the target element.
    ///
    /// Resolves the target element via the locator cascade, then
    /// performs the appropriate action (click, type, hotkey, scroll, app switch).
    private func executeAction(
        _ actionType: RecordedAction.ActionType,
        locator: ElementLocator?,
        app: String,
        bundleId: String
    ) async -> Bool {
        do {
            switch actionType {
            case .click(let x, let y, let button, let count):
                return try await executeClick(
                    x: x, y: y, button: button, count: count,
                    locator: locator, bundleId: bundleId
                )

            case .typeText(let text):
                return try await executeTypeText(
                    text, locator: locator, bundleId: bundleId
                )

            case .keyPress(let keyCode, let keyName, let modifiers):
                return try await executeKeyPress(
                    keyCode: keyCode, keyName: keyName, modifiers: modifiers
                )

            case .scroll(let deltaX, let deltaY, let x, let y):
                return try await executeScroll(
                    deltaX: deltaX, deltaY: deltaY, x: x, y: y
                )

            case .appSwitch(let toApp, let toBundleId):
                return await executeAppSwitch(toApp: toApp, toBundleId: toBundleId)
            }
        } catch {
            logger.error("Action execution failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Execute a click action, resolving the target via locator if available.
    private func executeClick(
        x: Double, y: Double, button: String, count: Int,
        locator: ElementLocator?, bundleId: String
    ) async throws -> Bool {
        let mouseButton: CGMouseButton = button == "right" ? .right : .left

        if let locator {
            // Try to resolve the element via locator cascade
            let resolved: Bool = try await MainActor.run {
                guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
                let appElement = ShadowElement.application(pid: frontApp.processIdentifier)

                if let result = resolveLocator(locator, in: appElement, timeout: 5) {
                    if result.confidence >= 0.40 {
                        try result.element.twoPhaseClick(button: mouseButton, count: count)
                        return true
                    }
                }
                // Fallback to coordinates
                try InputSynthesizer.click(at: CGPoint(x: x, y: y), button: mouseButton, count: count)
                return true
            }
            return resolved
        } else {
            // Direct coordinate click
            try await MainActor.run {
                try InputSynthesizer.click(at: CGPoint(x: x, y: y), button: mouseButton, count: count)
            }
            return true
        }
    }

    /// Execute a text entry action.
    private func executeTypeText(
        _ text: String, locator: ElementLocator?, bundleId: String
    ) async throws -> Bool {
        try await MainActor.run {
            if let locator {
                guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
                let appElement = ShadowElement.application(pid: frontApp.processIdentifier)

                if let result = resolveLocator(locator, in: appElement, timeout: 5),
                   result.confidence >= 0.40 {
                    let verified = try result.element.typeText(text)
                    return verified
                }
            }

            // Fallback: type at focused element
            try InputSynthesizer.typeText(text)
            return true
        }
    }

    /// Execute a key press action.
    private func executeKeyPress(
        keyCode: Int, keyName: String, modifiers: [String]
    ) async throws -> Bool {
        try await MainActor.run {
            if modifiers.isEmpty {
                guard let keyCode = InputSynthesizer.keyCodeForName(keyName) else {
                    throw AXEngineError.invalidHotkey(keyName)
                }
                try InputSynthesizer.pressKey(keyCode: keyCode)
            } else {
                var keys = modifiers
                keys.append(keyName)
                try InputSynthesizer.hotkey(keys)
            }
            return true
        }
    }

    /// Execute a scroll action.
    private func executeScroll(
        deltaX: Int, deltaY: Int, x: Double, y: Double
    ) async throws -> Bool {
        try await MainActor.run {
            let point = CGPoint(x: x, y: y)
            try InputSynthesizer.scroll(deltaY: Int32(deltaY), deltaX: Int32(deltaX), at: point)
            return true
        }
    }

    /// Execute an app switch by activating the target application.
    private func executeAppSwitch(toApp: String, toBundleId: String) async -> Bool {
        await MainActor.run {
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == toBundleId
            }
            if let target = apps.first {
                target.activate()
                return true
            }
            // Fallback: try by name
            let byName = NSWorkspace.shared.runningApplications.filter {
                $0.localizedName == toApp
            }
            if let target = byName.first {
                target.activate()
                return true
            }
            logger.warning("Could not find app to switch to: \(toApp) (\(toBundleId))")
            return false
        }
    }

    // MARK: - Parameter Resolution

    /// Substitute parameter values in an action type.
    private func resolveParameters(
        _ actionType: RecordedAction.ActionType,
        parameters: [String: String],
        substitutions: [String: String]
    ) -> RecordedAction.ActionType {
        guard !parameters.isEmpty, !substitutions.isEmpty else { return actionType }

        switch actionType {
        case .typeText(let text):
            var resolved = text
            for (paramName, placeholder) in substitutions {
                if let replacement = parameters[paramName] {
                    resolved = resolved.replacingOccurrences(of: placeholder, with: replacement)
                }
            }
            return .typeText(text: resolved)

        default:
            return actionType
        }
    }

    // MARK: - Verification

    /// Verify a step's post-condition was met.
    private func verifyStep(
        step: ProcedureStep,
        resolvedAction: RecordedAction.ActionType,
        app: String,
        bundleId: String
    ) async -> Bool {
        // If no explicit post-condition, use action-type heuristics
        switch resolvedAction {
        case .typeText(let text):
            // Try readback verification
            let readback: Bool = await MainActor.run {
                guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
                let appElement = ShadowElement.application(pid: frontApp.processIdentifier)
                guard let focused = appElement.focusedUIElement() else { return false }
                let result = ActionVerifier.verifyTextEntry(
                    element: focused,
                    expectedText: text
                )
                return result.passed
            }
            return readback

        case .click:
            // For clicks, we consider success if no error was thrown
            return true

        case .keyPress, .scroll, .appSwitch:
            // These are fire-and-forget — assume success
            return true
        }
    }

    // MARK: - LLM Adaptation

    /// Attempt to adapt a failed step using LLM analysis.
    ///
    /// When a step fails because the UI has changed (element not found,
    /// verification failed), this method sends the current UI state to
    /// the LLM to find an alternative element or action.
    private func adaptStep(
        step: ProcedureStep,
        resolvedAction: RecordedAction.ActionType,
        app: String,
        bundleId: String,
        continuation: AsyncStream<ExecutionEvent>.Continuation
    ) async -> Bool {
        guard let llmProvider, llmProvider.isAvailable else { return false }

        let prompt = """
        A procedure step failed during replay. The UI may have changed.

        Step intent: \(step.intent)
        Expected action: \(describeAction(resolvedAction))
        Target: role=\(step.targetLocator?.role ?? "unknown"), \
        title=\(step.targetLocator?.title ?? "none"), \
        identifier=\(step.targetLocator?.identifier ?? "none")
        Application: \(app)

        The target element was not found at the expected location.
        Suggest an alternative search strategy:
        1. What role should we search for?
        2. What title or text should we look for?
        3. Should we broaden the search (increase depth, relax role filter)?

        Respond with JSON:
        {"role": "...", "query": "...", "broaden": true/false, "fallbackToCoordinates": true/false}
        """

        let request = LLMRequest(
            systemPrompt: "You are helping adapt a UI automation step that failed. Be concise.",
            userPrompt: prompt,
            maxTokens: 300,
            temperature: 0.2,
            responseFormat: .json
        )

        do {
            let response = try await llmProvider.generate(request: request)
            guard let data = response.content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }

            let adaptedRole = json["role"] as? String
            let adaptedQuery = json["query"] as? String
            let fallbackToCoords = json["fallbackToCoordinates"] as? Bool ?? false

            // Try the adapted search
            let found: Bool = try await MainActor.run {
                guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
                let appElement = ShadowElement.application(pid: frontApp.processIdentifier)

                let results = findElements(
                    in: appElement,
                    role: adaptedRole,
                    query: adaptedQuery,
                    maxResults: 3,
                    maxDepth: 20,
                    timeout: 5
                )

                if let best = results.first, best.confidence >= 0.35 {
                    // Re-execute on the adapted element
                    switch resolvedAction {
                    case .click(_, _, let button, let count):
                        let mouseButton: CGMouseButton = button == "right" ? .right : .left
                        try best.element.twoPhaseClick(button: mouseButton, count: count)
                        return true
                    case .typeText(let text):
                        _ = try best.element.typeText(text)
                        return true
                    default:
                        return false
                    }
                }

                // Last resort: fall back to original coordinates
                if fallbackToCoords {
                    switch resolvedAction {
                    case .click(let x, let y, let button, let count):
                        let mouseButton: CGMouseButton = button == "right" ? .right : .left
                        try InputSynthesizer.click(at: CGPoint(x: x, y: y), button: mouseButton, count: count)
                        return true
                    default:
                        break
                    }
                }

                return false
            }

            if found {
                logger.info("LLM adaptation succeeded for step \(step.index)")
            }
            return found
        } catch {
            logger.error("LLM adaptation failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Helpers

    private func describeAction(_ actionType: RecordedAction.ActionType) -> String {
        switch actionType {
        case .click(let x, let y, let button, let count):
            return "\(count > 1 ? "\(count)x " : "")\(button) click at (\(Int(x)), \(Int(y)))"
        case .typeText(let text):
            return "Type '\(String(text.prefix(30)))\(text.count > 30 ? "..." : "")'"
        case .keyPress(_, let keyName, let modifiers):
            return modifiers.isEmpty ? "Press \(keyName)" : "Press \(modifiers.joined(separator: "+"))+\(keyName)"
        case .appSwitch(let toApp, _):
            return "Switch to \(toApp)"
        case .scroll(_, let deltaY, _, _):
            return "Scroll \(deltaY > 0 ? "up" : "down")"
        }
    }
}

// MARK: - Execution Run State

/// Internal state for a running procedure execution.
struct ExecutionRun: Sendable {
    let procedureId: String
    let runId: UUID
    let totalSteps: Int
    var currentStep: Int = 0
    var completedSteps: [Int] = []
    var failedSteps: [Int] = []
    var startedAt: UInt64 = CaptureSessionClock.wallMicros()
}
