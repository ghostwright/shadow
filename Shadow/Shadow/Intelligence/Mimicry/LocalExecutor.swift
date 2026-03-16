import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "LocalExecutor")

/// Executes TaskPlan steps locally using AX tree operations and VLM grounding.
///
/// The LocalExecutor is the "hands" of the two-tier Mimicry architecture.
/// Given a plan from the CloudPlanner, it executes each step autonomously:
///
/// 1. Find the target element (AX search first, VLM grounding fallback)
/// 2. Execute the action (click, type, hotkey, etc.)
/// 3. Verify the outcome (wait for condition or check AX tree change)
/// 4. Report result and advance to next step
///
/// If a step fails twice, the executor escalates to the CloudPlanner for
/// revised instructions. For routine tasks, the planner is called ONCE and
/// the executor handles everything locally.
///
/// Mimicry Phase C: Local Executor.
actor LocalExecutor {

    /// The grounding oracle for element resolution.
    private let groundingOracle: GroundingOracle?

    /// Maximum retries per step before escalating.
    private let maxRetriesPerStep: Int

    /// Delay between retries (seconds).
    private let retryDelay: TimeInterval

    /// Number of plans executed this session.
    private(set) var plansExecuted: Int = 0

    /// Number of steps executed this session.
    private(set) var stepsExecuted: Int = 0

    /// Number of escalations triggered this session.
    private(set) var escalationCount: Int = 0

    // MARK: - Init

    init(
        groundingOracle: GroundingOracle? = nil,
        maxRetriesPerStep: Int = 2,
        retryDelay: TimeInterval = 1.0
    ) {
        self.groundingOracle = groundingOracle
        self.maxRetriesPerStep = maxRetriesPerStep
        self.retryDelay = retryDelay
    }

    // MARK: - Execution

    /// Execute a complete plan step by step.
    ///
    /// Iterates through all steps in order, executing each one via the AX engine.
    /// Returns a `PlanExecutionState` with results for each step.
    ///
    /// - Parameters:
    ///   - plan: The plan to execute.
    ///   - onStepComplete: Optional callback after each step completes.
    ///   - onEscalation: Optional handler for escalation requests. If nil, failed steps are skipped.
    /// - Returns: The final execution state with per-step results.
    func execute(
        plan: TaskPlan,
        onStepStart: ((PlanStep) async -> Void)? = nil,
        onStepComplete: ((StepResult) async -> Void)? = nil,
        onEscalation: ((EscalationRequest) async -> EscalationResponse?)? = nil
    ) async -> PlanExecutionState {
        var state = PlanExecutionState(plan: plan, status: .executing)
        DiagnosticsStore.shared.increment("executor_plan_total")
        let planStartTime = CFAbsoluteTimeGetCurrent()

        logger.notice("[MIMICRY] Executing plan: '\(plan.taskDescription, privacy: .public)' (\(plan.stepCount) steps)")

        for step in plan.steps {
            state.currentStepIndex = step.index
            var retryCount = 0
            var stepSucceeded = false

            // Notify that we're about to start this step
            await onStepStart?(step)

            while retryCount <= maxRetriesPerStep && !stepSucceeded {
                let result = await executeStep(step, retryCount: retryCount)
                stepsExecuted += 1

                if result.status == .succeeded {
                    state.stepResults.append(result)
                    stepSucceeded = true
                    await onStepComplete?(result)
                    DiagnosticsStore.shared.increment("executor_step_success_total")
                } else if retryCount < maxRetriesPerStep {
                    // Retry after delay
                    retryCount += 1
                    logger.info("Step \(step.index + 1) failed (attempt \(retryCount)/\(self.maxRetriesPerStep)): \(result.message, privacy: .public)")
                    try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                } else {
                    // Max retries exhausted -- try escalation
                    if let escalationHandler = onEscalation {
                        escalationCount += 1
                        DiagnosticsStore.shared.increment("executor_escalation_total")

                        let axState = await captureAXState()
                        let escalationRequest = EscalationRequest(
                            plan: plan,
                            failedStepIndex: step.index,
                            failureReason: result.message,
                            currentAXState: axState,
                            retryCount: retryCount
                        )

                        if let response = await escalationHandler(escalationRequest) {
                            if response.shouldAbort {
                                logger.warning("Plan aborted by planner at step \(step.index + 1)")
                                state.status = .failed
                                state.stepResults.append(StepResult(
                                    stepIndex: step.index,
                                    status: .escalated,
                                    message: "Aborted: \(response.advice ?? "Planner requested abort")",
                                    durationMs: 0,
                                    groundingStrategy: nil,
                                    retryCount: retryCount
                                ))
                                plansExecuted += 1
                                return state
                            }

                            // If planner provided revised steps, execute the first one as a retry
                            if let revisedSteps = response.revisedSteps, !revisedSteps.isEmpty {
                                logger.info("Escalation returned \(revisedSteps.count) revised steps for step \(step.index + 1)")
                                let revisedResult = await executeStep(revisedSteps[0], retryCount: retryCount)
                                if revisedResult.status == .succeeded {
                                    state.stepResults.append(StepResult(
                                        stepIndex: step.index,
                                        status: .escalated,
                                        message: "Escalated and resolved via revised step",
                                        durationMs: revisedResult.durationMs,
                                        groundingStrategy: revisedResult.groundingStrategy,
                                        retryCount: retryCount
                                    ))
                                    stepSucceeded = true
                                    continue
                                }
                                // Revised step also failed — fall through to failure
                                logger.warning("Revised step also failed: \(revisedResult.message, privacy: .public)")
                            }

                            // Planner says resolved but no revised steps — trust it
                            if response.resolved {
                                state.stepResults.append(StepResult(
                                    stepIndex: step.index,
                                    status: .escalated,
                                    message: "Escalated and resolved: \(response.advice ?? "")",
                                    durationMs: 0,
                                    groundingStrategy: nil,
                                    retryCount: retryCount
                                ))
                                stepSucceeded = true
                                continue
                            }
                        }
                    }

                    // Escalation failed or no handler -- record failure and continue
                    state.stepResults.append(result)
                    await onStepComplete?(result)
                    DiagnosticsStore.shared.increment("executor_step_fail_total")
                    logger.error("Step \(step.index + 1) failed after \(retryCount + 1) attempts: \(result.message, privacy: .public)")
                    break
                }
            }
        }

        // Determine overall status
        let allSucceeded = state.stepResults.allSatisfy { $0.status == .succeeded || $0.status == .escalated }
        state.status = allSucceeded ? .succeeded : .failed

        plansExecuted += 1
        let elapsed = (CFAbsoluteTimeGetCurrent() - planStartTime) * 1000
        DiagnosticsStore.shared.recordLatency("executor_plan_duration_ms", ms: elapsed)

        let statusStr = state.status.rawValue
        logger.notice("[MIMICRY] Plan execution \(statusStr, privacy: .public): \(state.completedSteps)/\(plan.stepCount) steps succeeded in \(String(format: "%.0f", elapsed))ms")
        // Log each step result for post-mortem analysis
        for sr in state.stepResults {
            let stepDesc = sr.stepIndex < plan.steps.count ? plan.steps[sr.stepIndex].description : "?"
            logger.notice("[MIMICRY] Result step \(sr.stepIndex + 1): \(sr.status.rawValue, privacy: .public) - \(stepDesc, privacy: .public) (\(sr.message, privacy: .public))")
        }

        return state
    }

    // MARK: - Step Execution

    /// Execute a single plan step.
    private func executeStep(_ step: PlanStep, retryCount: Int) async -> StepResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        logger.notice("[MIMICRY] Step \(step.index + 1): \(step.description, privacy: .public) [action=\(step.actionType.rawValue, privacy: .public), target='\(step.targetDescription ?? "none", privacy: .public)', inputText='\(step.inputText ?? "none", privacy: .public)', keys=\(step.keys?.joined(separator: "+") ?? "none", privacy: .public)]")

        do {
            var groundingStrategy: GroundingStrategy?

            switch step.actionType {
            case .click:
                groundingStrategy = try await executeClick(step)

            case .type:
                groundingStrategy = try await executeType(step)

            case .hotkey:
                try await executeHotkey(step)

            case .keyPress:
                try await executeKeyPress(step)

            case .focusApp:
                try await executeFocusApp(step)

            case .wait:
                try await executeWait(step)

            case .scroll:
                try await executeScroll(step)

            case .navigate:
                try await executeNavigate(step)
            }

            // Post-action wait (if specified)
            if let waitCondition = step.waitCondition, !waitCondition.isEmpty {
                let timeout = step.waitTimeoutSeconds ?? 5.0
                try await waitForCondition(waitCondition, timeout: timeout)
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.notice("[MIMICRY] Step \(step.index + 1) SUCCEEDED in \(String(format: "%.0f", elapsed))ms (grounding: \(groundingStrategy?.rawValue ?? "n/a", privacy: .public))")
            return StepResult(
                stepIndex: step.index,
                status: .succeeded,
                message: "OK",
                durationMs: elapsed,
                groundingStrategy: groundingStrategy,
                retryCount: retryCount
            )
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.notice("[MIMICRY] Step \(step.index + 1) FAILED in \(String(format: "%.0f", elapsed))ms: \(error.localizedDescription, privacy: .public)")
            return StepResult(
                stepIndex: step.index,
                status: .failed,
                message: error.localizedDescription,
                durationMs: elapsed,
                groundingStrategy: nil,
                retryCount: retryCount
            )
        }
    }

    // MARK: - Action Implementations

    /// Execute a click action using the grounding cascade.
    @discardableResult
    private func executeClick(_ step: PlanStep) async throws -> GroundingStrategy? {
        guard let targetDesc = step.targetDescription else {
            throw ExecutorError.missingTarget("Click step has no target description")
        }

        // Get the target app
        guard let appInfo = await getTargetApp() else {
            throw ExecutorError.noTargetApp
        }

        // Extract clean label text (strip AX role prefixes like "AXButton titled 'Compose'")
        let cleanQuery = GroundingOracle.extractCleanLabel(from: targetDesc)
        logger.notice("[MIMICRY] Click: searching for '\(cleanQuery, privacy: .public)' (raw: '\(targetDesc, privacy: .public)') in \(appInfo.name, privacy: .public), oracle=\(self.groundingOracle != nil ? "YES" : "nil", privacy: .public)")

        // Use grounding oracle if available
        if let oracle = groundingOracle {
            let match = await oracle.findElement(
                description: targetDesc,
                role: step.roleHint,
                in: appInfo.element
            )

            if let match, let point = match.point {
                logger.notice("[MIMICRY] Click: FOUND via \(match.strategy.rawValue, privacy: .public) at (\(String(format: "%.0f", point.x)), \(String(format: "%.0f", point.y)))")
                // Execute click at the found coordinates (center point from oracle)
                try await MainActor.run {
                    try InputSynthesizer.click(at: point)
                }
                return match.strategy
            } else if let match, let element = match.element {
                // Oracle found element but no point — try AXPress
                logger.info("Click: oracle found element but no point, trying AXPress")
                do {
                    try await MainActor.run {
                        try element.performAction(kAXPressAction)
                    }
                    return match.strategy
                } catch {
                    logger.info("Click: AXPress failed for oracle match: \(error, privacy: .public)")
                }
            }
        }

        // Fallback 1: AX tree search with clean query, NO role filter
        // Web apps (Gmail, Slack, etc.) expose elements with unpredictable AX roles.
        // Searching by text only is more reliable than filtering by role.
        let results = await MainActor.run {
            findElements(
                in: appInfo.element,
                role: nil,
                query: cleanQuery,
                maxResults: 5,
                maxDepth: 25,
                timeout: 5.0
            )
        }

        if let bestMatch = results.first {
            let position = await MainActor.run { bestMatch.element.position() }
            let size = await MainActor.run { bestMatch.element.size() }

            if let position, let size {
                let center = CGPoint(
                    x: position.x + size.width / 2,
                    y: position.y + size.height / 2
                )
                logger.info("Click: fallback AX found '\(cleanQuery, privacy: .public)' at center (\(String(format: "%.0f", center.x)), \(String(format: "%.0f", center.y))) via \(bestMatch.matchStrategy, privacy: .public)")
                try await MainActor.run {
                    try InputSynthesizer.click(at: center)
                }
                return .axFuzzy
            }

            // Try AXPress action as last resort
            do {
                try await MainActor.run {
                    try bestMatch.element.performAction(kAXPressAction)
                }
                logger.info("Click: fallback AXPress succeeded for '\(cleanQuery, privacy: .public)'")
                return .axFuzzy
            } catch {
                logger.info("Click: fallback AXPress also failed: \(error, privacy: .public)")
            }
        }

        throw ExecutorError.elementNotFound(cleanQuery)
    }

    /// Execute a type action.
    ///
    /// If a target field is specified, attempts to click it first. If the click
    /// fails (common in web apps where fields have poor AX metadata), types at
    /// whatever element currently has focus. This is almost always correct because:
    /// - Tab key moves focus to the next field (previous step)
    /// - A successful click in a prior step already focused the field
    /// - Gmail/Slack auto-focus the first field in compose windows
    @discardableResult
    private func executeType(_ step: PlanStep) async throws -> GroundingStrategy? {
        guard let text = step.inputText, !text.isEmpty else {
            throw ExecutorError.missingInput("Type step has no inputText")
        }

        var strategy: GroundingStrategy?

        // If a target is specified, try to find and focus it first.
        // But use a SINGLE attempt with reduced timeout — don't burn 15+ seconds
        // retrying a click in a web app where fields are hard to find via AX.
        if let targetDesc = step.targetDescription, !targetDesc.isEmpty {
            do {
                strategy = try await executeClick(
                    PlanStep(
                        index: step.index,
                        description: "Focus field: \(targetDesc)",
                        actionType: .click,
                        targetDescription: targetDesc,
                        inputText: nil,
                        keys: nil,
                        waitCondition: nil,
                        roleHint: nil,  // Never filter by role for type targets
                        waitTimeoutSeconds: nil
                    )
                )
                // Small delay after focusing
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                // Field not found — fall back to typing at whatever is focused.
                // In web apps, the field might already be focused (after Tab or previous click)
                // but not discoverable via AX search. This is the EXPECTED path for Gmail.
                logger.info("Type: target '\(targetDesc, privacy: .public)' not found, typing at focused element instead")
            }
        }

        // Type the text using synthetic keyboard input
        logger.notice("[MIMICRY] Type: about to type \(text.count) chars: '\(text.prefix(200), privacy: .public)'\(text.count > 200 ? "...[TRUNCATED]" : "", privacy: .public)")
        try await MainActor.run {
            try InputSynthesizer.typeText(text)
        }

        logger.notice("[MIMICRY] Type: DONE typing \(text.count) characters")
        return strategy
    }

    /// Execute a hotkey action.
    private func executeHotkey(_ step: PlanStep) async throws {
        guard let keys = step.keys, !keys.isEmpty else {
            throw ExecutorError.missingInput("Hotkey step has no keys")
        }

        try await MainActor.run {
            try InputSynthesizer.hotkey(keys)
        }
    }

    /// Execute a single key press (uses hotkey with single key).
    private func executeKeyPress(_ step: PlanStep) async throws {
        guard let keys = step.keys, let key = keys.first else {
            throw ExecutorError.missingInput("KeyPress step has no keys")
        }

        // Use hotkey for single keys -- it handles string-to-keycode mapping
        try await MainActor.run {
            try InputSynthesizer.hotkey([key])
        }
    }

    /// Execute an app focus action.
    ///
    /// Activates the target app AND updates AgentFocusManager so subsequent
    /// AX operations (click, type, etc.) target the correct app.
    private func executeFocusApp(_ step: PlanStep) async throws {
        guard let appName = step.targetDescription else {
            throw ExecutorError.missingTarget("FocusApp step has no target app name")
        }

        let activated = await MainActor.run { () -> Bool in
            let apps = NSWorkspace.shared.runningApplications
            // Exact match first, then case-insensitive contains
            let target = apps.first(where: {
                $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame
            }) ?? apps.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            })

            guard let app = target else { return false }

            let success = app.activate()
            if success {
                // Update AgentFocusManager so AX tools target this app
                AgentFocusManager.shared.setTarget(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? appName,
                    bundleId: app.bundleIdentifier ?? ""
                )
                logger.info("Focused app: \(app.localizedName ?? appName, privacy: .public) (pid \(app.processIdentifier))")
            }
            return success
        }

        guard activated else {
            throw ExecutorError.appNotFound(appName)
        }

        // Wait for app to become frontmost
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    /// Execute a wait action.
    private func executeWait(_ step: PlanStep) async throws {
        let timeout = step.waitTimeoutSeconds ?? 5.0
        if let condition = step.waitCondition, !condition.isEmpty {
            try await waitForCondition(condition, timeout: timeout)
        } else {
            // Simple time-based wait
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        }
    }

    /// Execute a scroll action.
    private func executeScroll(_ step: PlanStep) async throws {
        let direction = step.targetDescription ?? "down"
        let amount: Int32 = direction.lowercased().contains("up") ? 3 : -3

        try await MainActor.run {
            try InputSynthesizer.scroll(deltaY: amount)
        }
    }

    /// Execute a navigate action (open URL).
    private func executeNavigate(_ step: PlanStep) async throws {
        guard let urlString = step.inputText,
              let url = URL(string: urlString) else {
            throw ExecutorError.missingInput("Navigate step has no valid URL")
        }

        await MainActor.run {
            NSWorkspace.shared.open(url)
        }

        // Wait for page to load
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    // MARK: - Wait Condition

    /// Wait for a condition to be met (e.g., "elementExists: 'Compose'").
    private func waitForCondition(_ condition: String, timeout: TimeInterval) async throws {
        // Parse condition format: "elementExists: 'Element Name'"
        if condition.lowercased().hasPrefix("elementexists:") {
            let rawElementName = condition
                .replacingOccurrences(of: "elementExists:", with: "")
                .replacingOccurrences(of: "elementexists:", with: "")
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))

            // Clean any AX role prefixes from the element name
            let elementName = GroundingOracle.extractCleanLabel(from: rawElementName)

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let found = await MainActor.run { () -> Bool in
                    guard let appInfo = AgentFocusManager.shared.targetAppInfo() else {
                        return false
                    }
                    let results = findElements(
                        in: appInfo.element,
                        query: elementName,
                        maxResults: 1,
                        maxDepth: 25,
                        timeout: 2.0
                    )
                    return !results.isEmpty
                }

                if found {
                    logger.info("Wait: condition met - found '\(elementName, privacy: .public)'")
                    return
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            // For web apps, wait conditions often fail because the element exists but
            // has a different AX representation. Log warning but don't throw — let
            // the next step try anyway.
            logger.warning("Wait: condition timed out for '\(elementName, privacy: .public)' after \(String(format: "%.0f", timeout))s — continuing anyway")
            return
        }

        // Default: simple sleep
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
    }

    // MARK: - Helpers

    /// Get the current target app.
    private func getTargetApp() async -> (element: ShadowElement, pid: pid_t, name: String)? {
        await MainActor.run {
            guard let info = AgentFocusManager.shared.targetAppInfo() else {
                return nil
            }
            return (element: info.element, pid: info.pid, name: info.name)
        }
    }

    /// Capture a summary of the current AX tree state (for escalation context).
    private func captureAXState() async -> String? {
        await MainActor.run { () -> String? in
            guard let info = AgentFocusManager.shared.targetAppInfo() else {
                return nil
            }
            let elements = collectInteractiveElements(
                in: info.element,
                maxDepth: 10,
                maxCount: 30,
                timeout: 2.0
            )
            return elements.map { el -> String in
                let role = el.role() ?? "?"
                let title = el.title() ?? ""
                return "\(role): \(title)"
            }.joined(separator: "\n")
        }
    }
}

// MARK: - Errors

enum ExecutorError: Error, LocalizedError {
    case elementNotFound(String)
    case missingTarget(String)
    case missingInput(String)
    case noTargetApp
    case appNotFound(String)
    case waitConditionTimeout(String)
    case actionFailed(String)

    var errorDescription: String? {
        switch self {
        case .elementNotFound(let desc):
            return "Element not found: \(desc)"
        case .missingTarget(let reason):
            return "Missing target: \(reason)"
        case .missingInput(let reason):
            return "Missing input: \(reason)"
        case .noTargetApp:
            return "No target application is available"
        case .appNotFound(let name):
            return "Application not found: \(name)"
        case .waitConditionTimeout(let condition):
            return "Wait condition timed out: \(condition)"
        case .actionFailed(let reason):
            return "Action failed: \(reason)"
        }
    }
}
