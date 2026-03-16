import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "CloudPlanner")

/// Generates structured execution plans from natural language task descriptions.
///
/// The CloudPlanner is the "brain" of the two-tier Mimicry architecture.
/// It takes a user's task description along with rich context (behavioral history,
/// learned procedures, current AX tree state) and produces a detailed step-by-step
/// plan that the LocalExecutor can follow autonomously.
///
/// The planner is called ONCE per task. The executor handles everything locally,
/// escalating back to the planner only when a step fails repeatedly or an
/// unexpected state is encountered. This reduces cloud cost by 80-90% compared
/// to sending full context on every tool call.
///
/// Mimicry Phase C: Cloud Planner.
actor CloudPlanner {

    /// The LLM orchestrator for generating plans.
    private let orchestrator: LLMOrchestrator

    /// Number of plans generated this session.
    private(set) var plansGenerated: Int = 0

    /// Number of escalations handled this session.
    private(set) var escalationsHandled: Int = 0

    // MARK: - Init

    init(orchestrator: LLMOrchestrator) {
        self.orchestrator = orchestrator
    }

    // MARK: - Plan Generation

    /// Generate an execution plan for a user task.
    ///
    /// Sends the task description along with contextual information to the cloud LLM,
    /// which returns a structured plan. The plan is validated against basic structural
    /// requirements before being returned.
    ///
    /// - Parameters:
    ///   - task: Natural language task description (e.g., "Send an email to John").
    ///   - behavioralContext: Retrieved behavioral context from past interactions.
    ///   - procedures: Relevant learned procedures for the target app.
    ///   - axTreeSummary: Current AX tree state of the target app.
    ///   - targetApp: The application the task will be performed in.
    /// - Returns: A `TaskPlan` with concrete execution steps.
    /// - Throws: `PlannerError` if generation or parsing fails.
    func generatePlan(
        task: String,
        behavioralContext: String = "",
        procedures: String = "",
        axTreeSummary: String = "",
        targetApp: String? = nil
    ) async throws -> TaskPlan {
        let startTime = CFAbsoluteTimeGetCurrent()
        DiagnosticsStore.shared.increment("planner_attempt_total")

        let systemPrompt = buildSystemPrompt()
        let userPrompt = buildUserPrompt(
            task: task,
            behavioralContext: behavioralContext,
            procedures: procedures,
            axTreeSummary: axTreeSummary
        )

        let request = LLMRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: 4096,
            temperature: 0.2,
            responseFormat: .json
        )

        let response: LLMResponse
        do {
            response = try await orchestrator.generate(request: request)
        } catch {
            DiagnosticsStore.shared.increment("planner_fail_total")
            logger.error("Plan generation failed: \(error, privacy: .public)")
            throw PlannerError.generationFailed(error.localizedDescription)
        }

        // Parse the JSON response into a TaskPlan
        let plan: TaskPlan
        do {
            plan = try parsePlanResponse(response.content, task: task, targetApp: targetApp)
        } catch {
            DiagnosticsStore.shared.increment("planner_parse_fail_total")
            logger.error("Plan parsing failed: \(error, privacy: .public)")
            throw PlannerError.invalidPlanFormat(error.localizedDescription)
        }

        // Validate the plan
        guard !plan.steps.isEmpty else {
            throw PlannerError.emptyPlan
        }

        plansGenerated += 1
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        DiagnosticsStore.shared.increment("planner_success_total")
        DiagnosticsStore.shared.recordLatency("planner_latency_ms", ms: elapsed)
        logger.notice("[MIMICRY] Plan generated: \(plan.stepCount) steps for '\(task, privacy: .public)' in \(String(format: "%.0f", elapsed))ms")
        // Log every step so we can see exactly what the LLM planned
        for step in plan.steps {
            logger.notice("[MIMICRY] Plan step \(step.index + 1): \(step.actionType.rawValue, privacy: .public) target='\(step.targetDescription ?? "nil", privacy: .public)' input='\(step.inputText?.prefix(100) ?? "nil", privacy: .public)' keys=\(step.keys?.joined(separator: "+") ?? "nil", privacy: .public)")
        }

        return plan
    }

    // MARK: - Escalation Handling

    /// Handle an escalation from the LocalExecutor.
    ///
    /// When a step fails repeatedly, the executor sends an escalation request
    /// with the failure context. The planner generates revised steps or advice.
    ///
    /// - Parameter request: The escalation request with failure details.
    /// - Returns: An `EscalationResponse` with revised steps or abort signal.
    func handleEscalation(_ request: EscalationRequest) async throws -> EscalationResponse {
        DiagnosticsStore.shared.increment("planner_escalation_total")

        let systemPrompt = """
        You are the planning layer of a two-tier computer use system. The local \
        executor has encountered a problem and needs your help.

        A step in the execution plan has failed. Based on the failure details and \
        current UI state, provide revised steps or advice.

        Respond in JSON format:
        {
          "resolved": true/false,
          "revised_steps": [...],  // array of step objects if resolved
          "advice": "...",         // guidance for the executor
          "should_abort": false    // true only if the task cannot be completed
        }
        """

        let failedStep = request.plan.steps[safe: request.failedStepIndex]
        let userPrompt = """
        Original task: \(request.plan.taskDescription)

        Failed step (\(request.failedStepIndex + 1)/\(request.plan.steps.count)): \
        \(failedStep?.description ?? "unknown")

        Failure reason: \(request.failureReason)

        Retry count: \(request.retryCount)

        Current UI state:
        \(request.currentAXState ?? "Not available")

        Remaining steps after failed step:
        \(request.plan.steps.dropFirst(request.failedStepIndex + 1).map { "- \($0.description)" }.joined(separator: "\n"))
        """

        let llmRequest = LLMRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: 2048,
            temperature: 0.2,
            responseFormat: .json
        )

        let response = try await orchestrator.generate(request: llmRequest)
        let escalationResponse = try parseEscalationResponse(response.content)

        escalationsHandled += 1
        DiagnosticsStore.shared.increment("planner_escalation_success_total")

        return escalationResponse
    }

    // MARK: - Prompt Building

    private func buildSystemPrompt() -> String {
        """
        You are the planning layer of a two-tier computer use system. Your job is to \
        decompose a user's task into concrete UI action steps.

        You do NOT execute actions. A local executor on the user's machine will follow \
        your plan step-by-step using the accessibility tree and a grounding vision model.

        For each step, describe:
        - WHAT to do (click, type, hotkey, wait, focusApp, scroll, keyPress, navigate)
        - WHERE to do it (the element's visible text label — NOT its AX role)
        - HOW to verify it worked (wait condition after the action)

        Action types:
        - click: Click a UI element. Provide targetDescription with the element's visible label text.
        - type: Type text into a field. Provide inputText and optionally targetDescription. \
          If the field is already focused (e.g., after a Tab or click), omit targetDescription.
        - hotkey: Press a keyboard shortcut. Provide keys array (e.g., ["cmd", "return"]).
        - keyPress: Press a single key. Provide keys array with one key (e.g., ["tab"]).
        - wait: Wait for a condition. Provide waitCondition.
        - focusApp: Bring an app to front. Provide targetDescription with app name.
        - scroll: Scroll in a direction. Provide targetDescription with direction.
        - navigate: Navigate to a URL. Provide inputText with the URL.

        CRITICAL — target_description rules (STRICT, violations cause failures):
        - target_description MUST be the element's VISIBLE TEXT LABEL and nothing else. \
          One or two words only. Examples: "Compose", "Send", "To", "Subject", "Search mail".
        - NEVER include AX role names, prefixes, or qualifiers in target_description. \
          WRONG: "AXButton titled 'Compose'" / "AXTextField for 'To' recipients" \
          RIGHT: "Compose" / "To"
        - NEVER include context qualifiers like "in compose window" or "in the toolbar". \
          WRONG: "Subject in compose window" — RIGHT: "Subject"
        - role_hint: ALWAYS set to null. The executor ignores it anyway. \
          Role-based filtering causes false negatives in web apps.

        Respond in JSON format:
        {
          "steps": [
            {
              "index": 0,
              "description": "Human-readable description of the step",
              "action_type": "click",
              "target_description": "Compose",
              "input_text": null,
              "keys": null,
              "wait_condition": "elementExists: 'To'",
              "role_hint": null,
              "wait_timeout_seconds": 5
            }
          ],
          "success_criteria": "Email sent confirmation visible",
          "recovery_hint": "If compose window doesn't open, check if Gmail is fully loaded"
        }

        Important guidelines:
        - If the task targets a specific app, start with a focusApp step to ensure the right app is active.
        - After clicking buttons that open dialogs or new views, add a brief wait (1-2s).
        - For text input in web apps: ALWAYS use Tab/keyPress to navigate between fields. \
          Do NOT click on text fields — web app fields are nearly impossible to find via AX. \
          Pattern: click the first actionable element (e.g., Compose button), then use \
          Tab to move between fields, typing into each focused field WITHOUT targetDescription.
        - For Gmail email composition (EXACT recipe — follow this precisely):
          1. focusApp: "Google Chrome"
          2. click: target_description="Compose" (the compose button)
          3. wait: 2 seconds (for compose window to open, To field auto-focuses)
          4. type: input_text="recipient@email.com" (NO target_description — To field is already focused)
          5. keyPress: ["tab"] (moves to Subject field)
          6. type: input_text="Subject text" (NO target_description — Subject is focused)
          7. keyPress: ["tab"] (moves to body area)
          8. type: input_text="Body text" (NO target_description — body is focused)
          9. hotkey: ["cmd", "return"] (sends the email)
        - For keyboard shortcuts: use hotkey with keys array (e.g., ["cmd", "return"]).
        - Keep steps atomic — one action per step.
        - When a type step targets a field that is already focused (after Tab or previous click), \
          ALWAYS omit targetDescription (set to null). This types directly into the focused element.
        """
    }

    private func buildUserPrompt(
        task: String,
        behavioralContext: String,
        procedures: String,
        axTreeSummary: String
    ) -> String {
        var prompt = "Task: \(task)\n"

        if !behavioralContext.isEmpty {
            prompt += "\nContext about the user's past interactions:\n\(behavioralContext)\n"
        }

        if !procedures.isEmpty {
            prompt += "\nAvailable procedures (learned from past interactions):\n\(procedures)\n"
        }

        if !axTreeSummary.isEmpty {
            prompt += "\nCurrent app state (accessibility tree):\n\(axTreeSummary)\n"
        }

        prompt += "\nGenerate a step-by-step plan to complete this task."
        return prompt
    }

    // MARK: - Response Parsing

    /// Parse the LLM's JSON response into a TaskPlan.
    private func parsePlanResponse(
        _ response: String,
        task: String,
        targetApp: String?
    ) throws -> TaskPlan {
        // Extract JSON from the response (may be wrapped in markdown code blocks)
        let jsonString = extractJSON(from: response)

        guard let data = jsonString.data(using: .utf8) else {
            throw PlannerError.invalidPlanFormat("Response is not valid UTF-8")
        }

        let decoded = try JSONDecoder().decode(PlanResponseDTO.self, from: data)

        let steps = decoded.steps.enumerated().map { index, stepDTO in
            // Defense-in-depth: clean AX role prefixes from target_description.
            // Even though the system prompt says not to use them, LLMs frequently
            // mirror the AX tree format they see in the context. Clean it here
            // so the executor always gets a usable label.
            let cleanedTarget = stepDTO.targetDescription.map {
                GroundingOracle.extractCleanLabel(from: $0)
            }

            // For web apps, force roleHint to nil. Web apps (Gmail, Slack, etc.)
            // have unpredictable AX roles — searching by role causes false negatives.
            // The prompt already says this, but LLMs still emit role hints.
            let cleanedRoleHint: String? = nil  // Always nil — role filtering hurts more than it helps

            return PlanStep(
                index: index,
                description: stepDTO.description,
                actionType: PlanActionType(rawValue: stepDTO.actionType) ?? .click,
                targetDescription: cleanedTarget,
                inputText: stepDTO.inputText,
                keys: stepDTO.keys,
                waitCondition: stepDTO.waitCondition,
                roleHint: cleanedRoleHint,
                waitTimeoutSeconds: stepDTO.waitTimeoutSeconds
            )
        }

        return TaskPlan(
            taskDescription: task,
            steps: steps,
            successCriteria: decoded.successCriteria ?? "Task completed",
            recoveryHint: decoded.recoveryHint ?? "",
            targetApp: targetApp
        )
    }

    /// Parse an escalation response from the LLM.
    private func parseEscalationResponse(_ response: String) throws -> EscalationResponse {
        let jsonString = extractJSON(from: response)

        guard let data = jsonString.data(using: .utf8) else {
            throw PlannerError.invalidPlanFormat("Escalation response is not valid UTF-8")
        }

        let decoded = try JSONDecoder().decode(EscalationResponseDTO.self, from: data)

        let revisedSteps = decoded.revisedSteps?.enumerated().map { index, stepDTO in
            PlanStep(
                index: index,
                description: stepDTO.description,
                actionType: PlanActionType(rawValue: stepDTO.actionType) ?? .click,
                targetDescription: stepDTO.targetDescription,
                inputText: stepDTO.inputText,
                keys: stepDTO.keys,
                waitCondition: stepDTO.waitCondition,
                roleHint: stepDTO.roleHint,
                waitTimeoutSeconds: stepDTO.waitTimeoutSeconds
            )
        }

        return EscalationResponse(
            resolved: decoded.resolved,
            revisedSteps: revisedSteps,
            advice: decoded.advice,
            shouldAbort: decoded.shouldAbort ?? false
        )
    }

    /// Extract JSON from a response that may be wrapped in markdown code blocks.
    private func extractJSON(from response: String) -> String {
        // Try to find JSON between ```json and ``` markers
        if let jsonMatch = response.firstMatch(
            of: /```(?:json)?\s*\n([\s\S]*?)\n\s*```/
        ) {
            return String(jsonMatch.1)
        }

        // Try to find the first { ... } block
        if let start = response.firstIndex(of: "{"),
           let end = response.lastIndex(of: "}") {
            return String(response[start...end])
        }

        return response
    }
}

// MARK: - DTOs (JSON Decoding)

/// DTO for the plan response JSON.
private struct PlanResponseDTO: Codable {
    let steps: [PlanStepDTO]
    let successCriteria: String?
    let recoveryHint: String?

    enum CodingKeys: String, CodingKey {
        case steps
        case successCriteria = "success_criteria"
        case recoveryHint = "recovery_hint"
    }
}

/// DTO for a single plan step in JSON.
private struct PlanStepDTO: Codable {
    let index: Int?
    let description: String
    let actionType: String
    let targetDescription: String?
    let inputText: String?
    let keys: [String]?
    let waitCondition: String?
    let roleHint: String?
    let waitTimeoutSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case index
        case description
        case actionType = "action_type"
        case targetDescription = "target_description"
        case inputText = "input_text"
        case keys
        case waitCondition = "wait_condition"
        case roleHint = "role_hint"
        case waitTimeoutSeconds = "wait_timeout_seconds"
    }
}

/// DTO for the escalation response JSON.
private struct EscalationResponseDTO: Codable {
    let resolved: Bool
    let revisedSteps: [PlanStepDTO]?
    let advice: String?
    let shouldAbort: Bool?

    enum CodingKeys: String, CodingKey {
        case resolved
        case revisedSteps = "revised_steps"
        case advice
        case shouldAbort = "should_abort"
    }
}

// MARK: - Errors

enum PlannerError: Error, LocalizedError {
    case generationFailed(String)
    case invalidPlanFormat(String)
    case emptyPlan
    case escalationFailed(String)

    var errorDescription: String? {
        switch self {
        case .generationFailed(let reason):
            return "Plan generation failed: \(reason)"
        case .invalidPlanFormat(let reason):
            return "Invalid plan format: \(reason)"
        case .emptyPlan:
            return "Generated plan has no steps"
        case .escalationFailed(let reason):
            return "Escalation handling failed: \(reason)"
        }
    }
}

// MARK: - Array Safe Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
