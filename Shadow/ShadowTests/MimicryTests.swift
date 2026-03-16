import XCTest
@testable import Shadow

// MARK: - TaskPlan Tests

final class TaskPlanTests: XCTestCase {

    func testTaskPlan_init_defaults() {
        let plan = TaskPlan(
            taskDescription: "Send email",
            steps: [],
            successCriteria: "Email sent"
        )
        XCTAssertFalse(plan.id.isEmpty)
        XCTAssertEqual(plan.taskDescription, "Send email")
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(plan.successCriteria, "Email sent")
        XCTAssertEqual(plan.recoveryHint, "")
        XCTAssertNil(plan.targetApp)
        XCTAssertFalse(plan.isValidated)
    }

    func testTaskPlan_init_withAllFields() {
        let date = Date(timeIntervalSince1970: 1000)
        let steps = [makeStep(index: 0), makeStep(index: 1)]
        let plan = TaskPlan(
            id: "test-id",
            taskDescription: "Open Safari",
            steps: steps,
            successCriteria: "Safari window visible",
            recoveryHint: "Try Cmd+Space first",
            targetApp: "Safari",
            createdAt: date
        )
        XCTAssertEqual(plan.id, "test-id")
        XCTAssertEqual(plan.taskDescription, "Open Safari")
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.successCriteria, "Safari window visible")
        XCTAssertEqual(plan.recoveryHint, "Try Cmd+Space first")
        XCTAssertEqual(plan.targetApp, "Safari")
        XCTAssertEqual(plan.createdAt, date)
    }

    func testTaskPlan_stepCount() {
        let plan = TaskPlan(
            taskDescription: "Test",
            steps: [makeStep(index: 0), makeStep(index: 1), makeStep(index: 2)],
            successCriteria: "Done"
        )
        XCTAssertEqual(plan.stepCount, 3)
    }

    func testTaskPlan_stepCount_empty() {
        let plan = TaskPlan(
            taskDescription: "Test",
            steps: [],
            successCriteria: "Done"
        )
        XCTAssertEqual(plan.stepCount, 0)
    }

    func testTaskPlan_sendable() {
        let plan = TaskPlan(
            taskDescription: "Test",
            steps: [],
            successCriteria: "Done"
        )
        let _: any Sendable = plan
        XCTAssertTrue(true)
    }

    func testTaskPlan_codable_roundtrip() throws {
        let steps = [
            makeStep(index: 0, actionType: .click, targetDescription: "AXButton 'Submit'"),
            makeStep(index: 1, actionType: .type, inputText: "Hello world"),
        ]
        let original = TaskPlan(
            id: "roundtrip-test",
            taskDescription: "Fill form",
            steps: steps,
            successCriteria: "Form submitted",
            recoveryHint: "Refresh page",
            targetApp: "Chrome",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TaskPlan.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.taskDescription, original.taskDescription)
        XCTAssertEqual(decoded.steps.count, original.steps.count)
        XCTAssertEqual(decoded.successCriteria, original.successCriteria)
        XCTAssertEqual(decoded.recoveryHint, original.recoveryHint)
        XCTAssertEqual(decoded.targetApp, original.targetApp)
    }

    func testTaskPlan_isValidated_mutable() {
        var plan = TaskPlan(
            taskDescription: "Test",
            steps: [],
            successCriteria: "Done"
        )
        XCTAssertFalse(plan.isValidated)
        plan.isValidated = true
        XCTAssertTrue(plan.isValidated)
    }

    // MARK: - Helper

    private func makeStep(
        index: Int,
        actionType: PlanActionType = .click,
        targetDescription: String? = "AXButton 'OK'",
        inputText: String? = nil
    ) -> PlanStep {
        PlanStep(
            index: index,
            description: "Step \(index)",
            actionType: actionType,
            targetDescription: targetDescription,
            inputText: inputText,
            keys: nil,
            waitCondition: nil,
            roleHint: nil,
            waitTimeoutSeconds: nil
        )
    }
}

// MARK: - PlanStep Tests

final class PlanStepTests: XCTestCase {

    func testPlanStep_init() {
        let step = PlanStep(
            index: 0,
            description: "Click Compose button",
            actionType: .click,
            targetDescription: "AXButton titled 'Compose'",
            inputText: nil,
            keys: nil,
            waitCondition: "elementExists: 'To recipients'",
            roleHint: "AXButton",
            waitTimeoutSeconds: 5.0
        )
        XCTAssertEqual(step.index, 0)
        XCTAssertEqual(step.description, "Click Compose button")
        XCTAssertEqual(step.actionType, .click)
        XCTAssertEqual(step.targetDescription, "AXButton titled 'Compose'")
        XCTAssertNil(step.inputText)
        XCTAssertNil(step.keys)
        XCTAssertEqual(step.waitCondition, "elementExists: 'To recipients'")
        XCTAssertEqual(step.roleHint, "AXButton")
        XCTAssertEqual(step.waitTimeoutSeconds, 5.0)
    }

    func testPlanStep_identifiable() {
        let step = PlanStep(
            index: 42,
            description: "Test",
            actionType: .wait,
            targetDescription: nil,
            inputText: nil,
            keys: nil,
            waitCondition: nil,
            roleHint: nil,
            waitTimeoutSeconds: nil
        )
        XCTAssertEqual(step.id, 42)
    }

    func testPlanStep_typeAction() {
        let step = PlanStep(
            index: 1,
            description: "Type email address",
            actionType: .type,
            targetDescription: "AXTextField 'To'",
            inputText: "user@example.com",
            keys: nil,
            waitCondition: nil,
            roleHint: "AXTextField",
            waitTimeoutSeconds: nil
        )
        XCTAssertEqual(step.actionType, .type)
        XCTAssertEqual(step.inputText, "user@example.com")
    }

    func testPlanStep_hotkeyAction() {
        let step = PlanStep(
            index: 2,
            description: "Send the email",
            actionType: .hotkey,
            targetDescription: nil,
            inputText: nil,
            keys: ["cmd", "return"],
            waitCondition: nil,
            roleHint: nil,
            waitTimeoutSeconds: nil
        )
        XCTAssertEqual(step.actionType, .hotkey)
        XCTAssertEqual(step.keys, ["cmd", "return"])
    }

    func testPlanStep_codable_roundtrip() throws {
        let step = PlanStep(
            index: 5,
            description: "Navigate to URL",
            actionType: .navigate,
            targetDescription: nil,
            inputText: "https://example.com",
            keys: nil,
            waitCondition: "elementExists: 'Example Domain'",
            roleHint: nil,
            waitTimeoutSeconds: 10.0
        )

        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(PlanStep.self, from: data)

        XCTAssertEqual(decoded.index, 5)
        XCTAssertEqual(decoded.actionType, .navigate)
        XCTAssertEqual(decoded.inputText, "https://example.com")
        XCTAssertEqual(decoded.waitTimeoutSeconds, 10.0)
    }

    func testPlanStep_sendable() {
        let step = PlanStep(
            index: 0,
            description: "Test",
            actionType: .click,
            targetDescription: nil,
            inputText: nil,
            keys: nil,
            waitCondition: nil,
            roleHint: nil,
            waitTimeoutSeconds: nil
        )
        let _: any Sendable = step
        XCTAssertTrue(true)
    }
}

// MARK: - PlanActionType Tests

final class PlanActionTypeTests: XCTestCase {

    func testPlanActionType_allRawValues() {
        XCTAssertEqual(PlanActionType.click.rawValue, "click")
        XCTAssertEqual(PlanActionType.type.rawValue, "type")
        XCTAssertEqual(PlanActionType.hotkey.rawValue, "hotkey")
        XCTAssertEqual(PlanActionType.navigate.rawValue, "navigate")
        XCTAssertEqual(PlanActionType.wait.rawValue, "wait")
        XCTAssertEqual(PlanActionType.focusApp.rawValue, "focusApp")
        XCTAssertEqual(PlanActionType.scroll.rawValue, "scroll")
        XCTAssertEqual(PlanActionType.keyPress.rawValue, "keyPress")
    }

    func testPlanActionType_codable_roundtrip() throws {
        let types: [PlanActionType] = [.click, .type, .hotkey, .navigate, .wait, .focusApp, .scroll, .keyPress]
        for actionType in types {
            let data = try JSONEncoder().encode(actionType)
            let decoded = try JSONDecoder().decode(PlanActionType.self, from: data)
            XCTAssertEqual(decoded, actionType, "Roundtrip failed for \(actionType)")
        }
    }

    func testPlanActionType_initFromRawValue() {
        XCTAssertEqual(PlanActionType(rawValue: "click"), .click)
        XCTAssertEqual(PlanActionType(rawValue: "type"), .type)
        XCTAssertEqual(PlanActionType(rawValue: "focusApp"), .focusApp)
        XCTAssertNil(PlanActionType(rawValue: "invalid"))
        XCTAssertNil(PlanActionType(rawValue: ""))
    }
}

// MARK: - PlanExecutionState Tests

final class PlanExecutionStateTests: XCTestCase {

    func testPlanExecutionState_init() {
        let plan = makeTestPlan(stepCount: 3)
        let state = PlanExecutionState(plan: plan)
        XCTAssertEqual(state.currentStepIndex, 0)
        XCTAssertTrue(state.stepResults.isEmpty)
        XCTAssertEqual(state.status, .pending)
        XCTAssertFalse(state.isComplete)
        XCTAssertEqual(state.completedSteps, 0)
        XCTAssertEqual(state.failedSteps, 0)
    }

    func testPlanExecutionState_isComplete_succeeded() {
        var state = PlanExecutionState(plan: makeTestPlan(stepCount: 1))
        state.status = .succeeded
        XCTAssertTrue(state.isComplete)
    }

    func testPlanExecutionState_isComplete_failed() {
        var state = PlanExecutionState(plan: makeTestPlan(stepCount: 1))
        state.status = .failed
        XCTAssertTrue(state.isComplete)
    }

    func testPlanExecutionState_isComplete_cancelled() {
        var state = PlanExecutionState(plan: makeTestPlan(stepCount: 1))
        state.status = .cancelled
        XCTAssertTrue(state.isComplete)
    }

    func testPlanExecutionState_isComplete_pendingExecutingEscalated() {
        var state = PlanExecutionState(plan: makeTestPlan(stepCount: 1))
        state.status = .pending
        XCTAssertFalse(state.isComplete)
        state.status = .executing
        XCTAssertFalse(state.isComplete)
        state.status = .escalated
        XCTAssertFalse(state.isComplete)
    }

    func testPlanExecutionState_completedSteps() {
        var state = PlanExecutionState(plan: makeTestPlan(stepCount: 3))
        state.stepResults = [
            makeStepResult(index: 0, status: .succeeded),
            makeStepResult(index: 1, status: .failed),
            makeStepResult(index: 2, status: .succeeded),
        ]
        XCTAssertEqual(state.completedSteps, 2)
    }

    func testPlanExecutionState_failedSteps() {
        var state = PlanExecutionState(plan: makeTestPlan(stepCount: 3))
        state.stepResults = [
            makeStepResult(index: 0, status: .failed),
            makeStepResult(index: 1, status: .failed),
            makeStepResult(index: 2, status: .succeeded),
        ]
        XCTAssertEqual(state.failedSteps, 2)
    }

    func testPlanExecutionState_mixedResults() {
        var state = PlanExecutionState(plan: makeTestPlan(stepCount: 4))
        state.stepResults = [
            makeStepResult(index: 0, status: .succeeded),
            makeStepResult(index: 1, status: .escalated),
            makeStepResult(index: 2, status: .skipped),
            makeStepResult(index: 3, status: .failed),
        ]
        XCTAssertEqual(state.completedSteps, 1) // Only .succeeded counts
        XCTAssertEqual(state.failedSteps, 1) // Only .failed counts
    }

    // MARK: - Helpers

    private func makeTestPlan(stepCount: Int) -> TaskPlan {
        let steps = (0..<stepCount).map { i in
            PlanStep(
                index: i,
                description: "Step \(i)",
                actionType: .click,
                targetDescription: nil,
                inputText: nil,
                keys: nil,
                waitCondition: nil,
                roleHint: nil,
                waitTimeoutSeconds: nil
            )
        }
        return TaskPlan(
            taskDescription: "Test task",
            steps: steps,
            successCriteria: "Done"
        )
    }

    private func makeStepResult(index: Int, status: StepExecutionStatus) -> StepResult {
        StepResult(
            stepIndex: index,
            status: status,
            message: "Test",
            durationMs: 100,
            groundingStrategy: nil,
            retryCount: 0
        )
    }
}

// MARK: - StepResult Tests

final class StepResultTests: XCTestCase {

    func testStepResult_init() {
        let result = StepResult(
            stepIndex: 3,
            status: .succeeded,
            message: "OK",
            durationMs: 250.5,
            groundingStrategy: .axExact,
            retryCount: 1
        )
        XCTAssertEqual(result.stepIndex, 3)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.message, "OK")
        XCTAssertEqual(result.durationMs, 250.5, accuracy: 0.001)
        XCTAssertEqual(result.groundingStrategy, .axExact)
        XCTAssertEqual(result.retryCount, 1)
    }

    func testStepResult_withoutGrounding() {
        let result = StepResult(
            stepIndex: 0,
            status: .failed,
            message: "Element not found",
            durationMs: 3000,
            groundingStrategy: nil,
            retryCount: 2
        )
        XCTAssertNil(result.groundingStrategy)
        XCTAssertEqual(result.status, .failed)
    }

    func testStepResult_sendable() {
        let result = StepResult(
            stepIndex: 0,
            status: .succeeded,
            message: "OK",
            durationMs: 0,
            groundingStrategy: nil,
            retryCount: 0
        )
        let _: any Sendable = result
        XCTAssertTrue(true)
    }
}

// MARK: - StepExecutionStatus Tests

final class StepExecutionStatusTests: XCTestCase {

    func testStepExecutionStatus_rawValues() {
        XCTAssertEqual(StepExecutionStatus.succeeded.rawValue, "succeeded")
        XCTAssertEqual(StepExecutionStatus.failed.rawValue, "failed")
        XCTAssertEqual(StepExecutionStatus.skipped.rawValue, "skipped")
        XCTAssertEqual(StepExecutionStatus.escalated.rawValue, "escalated")
    }
}

// MARK: - PlanExecutionStatus Tests

final class PlanExecutionStatusTests: XCTestCase {

    func testPlanExecutionStatus_rawValues() {
        XCTAssertEqual(PlanExecutionStatus.pending.rawValue, "pending")
        XCTAssertEqual(PlanExecutionStatus.executing.rawValue, "executing")
        XCTAssertEqual(PlanExecutionStatus.succeeded.rawValue, "succeeded")
        XCTAssertEqual(PlanExecutionStatus.failed.rawValue, "failed")
        XCTAssertEqual(PlanExecutionStatus.cancelled.rawValue, "cancelled")
        XCTAssertEqual(PlanExecutionStatus.escalated.rawValue, "escalated")
    }
}

// MARK: - EscalationRequest Tests

final class EscalationRequestTests: XCTestCase {

    func testEscalationRequest_init() {
        let plan = TaskPlan(
            taskDescription: "Test",
            steps: [],
            successCriteria: "Done"
        )
        let request = EscalationRequest(
            plan: plan,
            failedStepIndex: 2,
            failureReason: "Element not found: AXButton 'Submit'",
            currentAXState: "AXWindow: Main\n  AXButton: Cancel",
            retryCount: 2
        )
        XCTAssertEqual(request.failedStepIndex, 2)
        XCTAssertEqual(request.failureReason, "Element not found: AXButton 'Submit'")
        XCTAssertEqual(request.currentAXState, "AXWindow: Main\n  AXButton: Cancel")
        XCTAssertEqual(request.retryCount, 2)
    }

    func testEscalationRequest_nilAXState() {
        let plan = TaskPlan(
            taskDescription: "Test",
            steps: [],
            successCriteria: "Done"
        )
        let request = EscalationRequest(
            plan: plan,
            failedStepIndex: 0,
            failureReason: "No target app",
            currentAXState: nil,
            retryCount: 0
        )
        XCTAssertNil(request.currentAXState)
    }

    func testEscalationRequest_codable_roundtrip() throws {
        let plan = TaskPlan(
            id: "test",
            taskDescription: "Send email",
            steps: [
                PlanStep(
                    index: 0,
                    description: "Click compose",
                    actionType: .click,
                    targetDescription: "Compose button",
                    inputText: nil,
                    keys: nil,
                    waitCondition: nil,
                    roleHint: nil,
                    waitTimeoutSeconds: nil
                )
            ],
            successCriteria: "Email sent"
        )
        let request = EscalationRequest(
            plan: plan,
            failedStepIndex: 0,
            failureReason: "Button not found",
            currentAXState: "AXWindow: Gmail",
            retryCount: 1
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(EscalationRequest.self, from: data)

        XCTAssertEqual(decoded.failedStepIndex, 0)
        XCTAssertEqual(decoded.failureReason, "Button not found")
        XCTAssertEqual(decoded.retryCount, 1)
        XCTAssertEqual(decoded.plan.taskDescription, "Send email")
    }
}

// MARK: - EscalationResponse Tests

final class EscalationResponseTests: XCTestCase {

    func testEscalationResponse_resolved() {
        let response = EscalationResponse(
            resolved: true,
            revisedSteps: [
                PlanStep(
                    index: 0,
                    description: "Try alternative click",
                    actionType: .click,
                    targetDescription: "AXButton 'New Message'",
                    inputText: nil,
                    keys: nil,
                    waitCondition: nil,
                    roleHint: "AXButton",
                    waitTimeoutSeconds: nil
                )
            ],
            advice: "The compose button may have a different label",
            shouldAbort: false
        )
        XCTAssertTrue(response.resolved)
        XCTAssertEqual(response.revisedSteps?.count, 1)
        XCTAssertNotNil(response.advice)
        XCTAssertFalse(response.shouldAbort)
    }

    func testEscalationResponse_abort() {
        let response = EscalationResponse(
            resolved: false,
            revisedSteps: nil,
            advice: "Gmail is not open, cannot complete task",
            shouldAbort: true
        )
        XCTAssertFalse(response.resolved)
        XCTAssertNil(response.revisedSteps)
        XCTAssertTrue(response.shouldAbort)
    }

    func testEscalationResponse_codable_roundtrip() throws {
        let response = EscalationResponse(
            resolved: true,
            revisedSteps: nil,
            advice: "Just retry",
            shouldAbort: false
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(EscalationResponse.self, from: data)

        XCTAssertEqual(decoded.resolved, true)
        XCTAssertNil(decoded.revisedSteps)
        XCTAssertEqual(decoded.advice, "Just retry")
        XCTAssertFalse(decoded.shouldAbort)
    }
}

// MARK: - PlannerError Tests

final class PlannerErrorTests: XCTestCase {

    func testPlannerError_generationFailed() {
        let error = PlannerError.generationFailed("API timeout")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("API timeout"))
        XCTAssertTrue(error.errorDescription!.contains("generation failed"))
    }

    func testPlannerError_invalidPlanFormat() {
        let error = PlannerError.invalidPlanFormat("Missing steps array")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Missing steps array"))
        XCTAssertTrue(error.errorDescription!.contains("Invalid plan format"))
    }

    func testPlannerError_emptyPlan() {
        let error = PlannerError.emptyPlan
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("no steps"))
    }

    func testPlannerError_escalationFailed() {
        let error = PlannerError.escalationFailed("Network error")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Network error"))
        XCTAssertTrue(error.errorDescription!.contains("Escalation"))
    }
}

// MARK: - ExecutorError Tests

final class ExecutorErrorTests: XCTestCase {

    func testExecutorError_elementNotFound() {
        let error = ExecutorError.elementNotFound("AXButton 'Submit'")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("AXButton 'Submit'"))
        XCTAssertTrue(error.errorDescription!.contains("not found"))
    }

    func testExecutorError_missingTarget() {
        let error = ExecutorError.missingTarget("Click step has no target")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Missing target"))
    }

    func testExecutorError_missingInput() {
        let error = ExecutorError.missingInput("Type step has no inputText")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Missing input"))
    }

    func testExecutorError_noTargetApp() {
        let error = ExecutorError.noTargetApp
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("No target application"))
    }

    func testExecutorError_appNotFound() {
        let error = ExecutorError.appNotFound("TextEdit")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("TextEdit"))
    }

    func testExecutorError_waitConditionTimeout() {
        let error = ExecutorError.waitConditionTimeout("elementExists: 'Loading'")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("timed out"))
    }

    func testExecutorError_actionFailed() {
        let error = ExecutorError.actionFailed("Permission denied")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Permission denied"))
    }
}

// MARK: - CloudPlanner Tests

final class CloudPlannerTests: XCTestCase {

    func testCloudPlanner_init() async {
        let orchestrator = LLMOrchestrator(providers: [], mode: .cloudOnly)
        let planner = CloudPlanner(orchestrator: orchestrator)
        let generated = await planner.plansGenerated
        let escalations = await planner.escalationsHandled
        XCTAssertEqual(generated, 0)
        XCTAssertEqual(escalations, 0)
    }

    func testCloudPlanner_generatePlan_failsWithNoProvider() async {
        let orchestrator = LLMOrchestrator(providers: [], mode: .cloudOnly)
        let planner = CloudPlanner(orchestrator: orchestrator)

        do {
            _ = try await planner.generatePlan(
                task: "Send email to John",
                behavioralContext: "",
                procedures: "",
                axTreeSummary: "",
                targetApp: "Gmail"
            )
            XCTFail("Should have thrown")
        } catch {
            // Expected: no providers available
            XCTAssertTrue(error is PlannerError)
            if case PlannerError.generationFailed = error {
                // Expected
            } else {
                XCTFail("Expected generationFailed, got \(error)")
            }
        }
    }

    func testCloudPlanner_generatePlan_withMockProvider() async throws {
        let planJSON = """
        {
          "steps": [
            {
              "index": 0,
              "description": "Click Compose button",
              "action_type": "click",
              "target_description": "AXButton titled 'Compose'",
              "wait_condition": "elementExists: 'To'",
              "role_hint": "AXButton",
              "wait_timeout_seconds": 5
            },
            {
              "index": 1,
              "description": "Type recipient",
              "action_type": "type",
              "target_description": "AXTextField 'To'",
              "input_text": "john@example.com",
              "role_hint": "AXTextField"
            }
          ],
          "success_criteria": "Email sent confirmation",
          "recovery_hint": "Check if Gmail is loaded"
        }
        """

        let mockProvider = makeMockProvider(responseContent: planJSON)
        let orchestrator = LLMOrchestrator(providers: [mockProvider], mode: .cloudOnly)
        let planner = CloudPlanner(orchestrator: orchestrator)

        let plan = try await planner.generatePlan(
            task: "Send email to John",
            targetApp: "Gmail"
        )

        XCTAssertEqual(plan.taskDescription, "Send email to John")
        XCTAssertEqual(plan.stepCount, 2)
        XCTAssertEqual(plan.steps[0].actionType, .click)
        // CloudPlanner now cleans target_description through extractCleanLabel
        // and forces roleHint to nil (role filtering hurts web app grounding)
        XCTAssertEqual(plan.steps[0].targetDescription, "Compose")
        XCTAssertNil(plan.steps[0].roleHint)
        XCTAssertEqual(plan.steps[1].actionType, .type)
        XCTAssertEqual(plan.steps[1].inputText, "john@example.com")
        XCTAssertEqual(plan.successCriteria, "Email sent confirmation")
        XCTAssertEqual(plan.recoveryHint, "Check if Gmail is loaded")
        XCTAssertEqual(plan.targetApp, "Gmail")

        let generated = await planner.plansGenerated
        XCTAssertEqual(generated, 1)
    }

    func testCloudPlanner_generatePlan_markdownWrappedJSON() async throws {
        let wrappedJSON = """
        Here's the plan:

        ```json
        {
          "steps": [
            {
              "description": "Focus Safari",
              "action_type": "focusApp",
              "target_description": "Safari"
            }
          ],
          "success_criteria": "Safari focused"
        }
        ```
        """

        let mockProvider = makeMockProvider(responseContent: wrappedJSON)
        let orchestrator = LLMOrchestrator(providers: [mockProvider], mode: .cloudOnly)
        let planner = CloudPlanner(orchestrator: orchestrator)

        let plan = try await planner.generatePlan(task: "Open Safari")
        XCTAssertEqual(plan.stepCount, 1)
        XCTAssertEqual(plan.steps[0].actionType, .focusApp)
    }

    func testCloudPlanner_generatePlan_emptySteps_throws() async {
        let emptyPlanJSON = """
        {
          "steps": [],
          "success_criteria": "Nothing to do"
        }
        """

        let mockProvider = makeMockProvider(responseContent: emptyPlanJSON)
        let orchestrator = LLMOrchestrator(providers: [mockProvider], mode: .cloudOnly)
        let planner = CloudPlanner(orchestrator: orchestrator)

        do {
            _ = try await planner.generatePlan(task: "Do nothing")
            XCTFail("Should have thrown for empty plan")
        } catch {
            if case PlannerError.emptyPlan = error {
                // Expected
            } else {
                XCTFail("Expected emptyPlan error, got \(error)")
            }
        }
    }

    func testCloudPlanner_generatePlan_invalidJSON_throws() async {
        let mockProvider = makeMockProvider(responseContent: "not valid json at all")
        let orchestrator = LLMOrchestrator(providers: [mockProvider], mode: .cloudOnly)
        let planner = CloudPlanner(orchestrator: orchestrator)

        do {
            _ = try await planner.generatePlan(task: "Test")
            XCTFail("Should have thrown for invalid JSON")
        } catch {
            if case PlannerError.invalidPlanFormat = error {
                // Expected
            } else {
                XCTFail("Expected invalidPlanFormat error, got \(error)")
            }
        }
    }

    func testCloudPlanner_handleEscalation_withMock() async throws {
        let escalationJSON = """
        {
          "resolved": true,
          "revised_steps": [
            {
              "description": "Click alternative button",
              "action_type": "click",
              "target_description": "AXButton 'New Email'"
            }
          ],
          "advice": "The compose button label changed",
          "should_abort": false
        }
        """

        let mockProvider = makeMockProvider(responseContent: escalationJSON)
        let orchestrator = LLMOrchestrator(providers: [mockProvider], mode: .cloudOnly)
        let planner = CloudPlanner(orchestrator: orchestrator)

        let plan = TaskPlan(
            taskDescription: "Send email",
            steps: [
                PlanStep(
                    index: 0,
                    description: "Click Compose",
                    actionType: .click,
                    targetDescription: "AXButton 'Compose'",
                    inputText: nil,
                    keys: nil,
                    waitCondition: nil,
                    roleHint: nil,
                    waitTimeoutSeconds: nil
                )
            ],
            successCriteria: "Email sent"
        )
        let request = EscalationRequest(
            plan: plan,
            failedStepIndex: 0,
            failureReason: "Element not found",
            currentAXState: nil,
            retryCount: 2
        )

        let response = try await planner.handleEscalation(request)
        XCTAssertTrue(response.resolved)
        XCTAssertEqual(response.revisedSteps?.count, 1)
        XCTAssertEqual(response.advice, "The compose button label changed")
        XCTAssertFalse(response.shouldAbort)

        let escalations = await planner.escalationsHandled
        XCTAssertEqual(escalations, 1)
    }

    func testCloudPlanner_handleEscalation_abort() async throws {
        let abortJSON = """
        {
          "resolved": false,
          "advice": "Gmail is not open",
          "should_abort": true
        }
        """

        let mockProvider = makeMockProvider(responseContent: abortJSON)
        let orchestrator = LLMOrchestrator(providers: [mockProvider], mode: .cloudOnly)
        let planner = CloudPlanner(orchestrator: orchestrator)

        let plan = TaskPlan(
            taskDescription: "Send email",
            steps: [],
            successCriteria: "Email sent"
        )
        let request = EscalationRequest(
            plan: plan,
            failedStepIndex: 0,
            failureReason: "App not found",
            currentAXState: nil,
            retryCount: 2
        )

        let response = try await planner.handleEscalation(request)
        XCTAssertFalse(response.resolved)
        XCTAssertTrue(response.shouldAbort)
    }

    func testCloudPlanner_generatePlan_stepsReindexed() async throws {
        // Steps should be re-indexed regardless of what the LLM returns
        let planJSON = """
        {
          "steps": [
            {
              "index": 99,
              "description": "Step A",
              "action_type": "click",
              "target_description": "Button A"
            },
            {
              "index": 100,
              "description": "Step B",
              "action_type": "type",
              "input_text": "hello"
            }
          ],
          "success_criteria": "Done"
        }
        """

        let mockProvider = makeMockProvider(responseContent: planJSON)
        let orchestrator = LLMOrchestrator(providers: [mockProvider], mode: .cloudOnly)
        let planner = CloudPlanner(orchestrator: orchestrator)

        let plan = try await planner.generatePlan(task: "Test")

        // Steps should be re-indexed 0, 1 regardless of what the LLM returned
        XCTAssertEqual(plan.steps[0].index, 0)
        XCTAssertEqual(plan.steps[1].index, 1)
    }

    func testCloudPlanner_generatePlan_unknownActionType_defaultsToClick() async throws {
        let planJSON = """
        {
          "steps": [
            {
              "description": "Do something",
              "action_type": "unknown_action_type_xyz",
              "target_description": "Something"
            }
          ],
          "success_criteria": "Done"
        }
        """

        let mockProvider = makeMockProvider(responseContent: planJSON)
        let orchestrator = LLMOrchestrator(providers: [mockProvider], mode: .cloudOnly)
        let planner = CloudPlanner(orchestrator: orchestrator)

        let plan = try await planner.generatePlan(task: "Test")
        // Unknown action types should default to .click
        XCTAssertEqual(plan.steps[0].actionType, .click)
    }
}

// MARK: - LocalExecutor Tests

final class LocalExecutorTests: XCTestCase {

    func testLocalExecutor_init_defaults() async {
        let executor = LocalExecutor()
        let plansExecuted = await executor.plansExecuted
        let stepsExecuted = await executor.stepsExecuted
        let escalationCount = await executor.escalationCount
        XCTAssertEqual(plansExecuted, 0)
        XCTAssertEqual(stepsExecuted, 0)
        XCTAssertEqual(escalationCount, 0)
    }

    func testLocalExecutor_init_customRetry() async {
        let executor = LocalExecutor(
            groundingOracle: nil,
            maxRetriesPerStep: 5,
            retryDelay: 0.5
        )
        // Should initialize without error
        let plansExecuted = await executor.plansExecuted
        XCTAssertEqual(plansExecuted, 0)
    }
}

// MARK: - MimicryCoordinator Tests

final class MimicryCoordinatorTests: XCTestCase {

    func testMimicryCoordinator_init() async {
        let orchestrator = LLMOrchestrator(providers: [], mode: .cloudOnly)
        let planner = CloudPlanner(orchestrator: orchestrator)
        let executor = LocalExecutor()
        let coordinator = MimicryCoordinator(planner: planner, executor: executor)

        let completed = await coordinator.tasksCompleted
        let failed = await coordinator.tasksFailed
        XCTAssertEqual(completed, 0)
        XCTAssertEqual(failed, 0)
    }

    func testMimicryCoordinator_executeTask_planningFails() async {
        // No providers means planning will fail
        let orchestrator = LLMOrchestrator(providers: [], mode: .cloudOnly)
        let planner = CloudPlanner(orchestrator: orchestrator)
        let executor = LocalExecutor()
        let coordinator = MimicryCoordinator(planner: planner, executor: executor)

        let result = await coordinator.executeTask("Send email to John")
        XCTAssertEqual(result.status, .planningFailed)
        XCTAssertEqual(result.task, "Send email to John")
        XCTAssertNil(result.plan)
        XCTAssertNil(result.executionState)
        XCTAssertNotNil(result.error)
        XCTAssertGreaterThan(result.durationMs, 0)

        let failed = await coordinator.tasksFailed
        XCTAssertEqual(failed, 1)
    }

    func testMimicryCoordinator_progressCallback() async {
        let orchestrator = LLMOrchestrator(providers: [], mode: .cloudOnly)
        let planner = CloudPlanner(orchestrator: orchestrator)
        let executor = LocalExecutor()
        let coordinator = MimicryCoordinator(planner: planner, executor: executor)

        // Use an actor to collect progress updates safely
        let collector = ProgressCollector()
        await coordinator.setProgress { progress in
            await collector.append(progress)
        }

        // This will fail at planning, but should still send progress
        _ = await coordinator.executeTask("Test task")

        // Should have received at least the "planning" progress update
        let updates = await collector.updates
        XCTAssertGreaterThanOrEqual(updates.count, 1)
        XCTAssertEqual(updates[0].phase, .planning)
    }
}

// MARK: - MimicryProgress Tests

final class MimicryProgressTests: XCTestCase {

    func testMimicryProgress_init() {
        let progress = MimicryProgress(
            phase: .executing,
            message: "Step 3 of 5",
            stepIndex: 3,
            totalSteps: 5
        )
        XCTAssertEqual(progress.phase, .executing)
        XCTAssertEqual(progress.message, "Step 3 of 5")
        XCTAssertEqual(progress.stepIndex, 3)
        XCTAssertEqual(progress.totalSteps, 5)
    }

    func testMimicryProgress_sendable() {
        let progress = MimicryProgress(
            phase: .completed,
            message: "Done",
            stepIndex: nil,
            totalSteps: nil
        )
        let _: any Sendable = progress
        XCTAssertTrue(true)
    }
}

// MARK: - MimicryPhase Tests

final class MimicryPhaseTests: XCTestCase {

    func testMimicryPhase_rawValues() {
        XCTAssertEqual(MimicryPhase.planning.rawValue, "planning")
        XCTAssertEqual(MimicryPhase.executing.rawValue, "executing")
        XCTAssertEqual(MimicryPhase.escalating.rawValue, "escalating")
        XCTAssertEqual(MimicryPhase.completed.rawValue, "completed")
        XCTAssertEqual(MimicryPhase.failed.rawValue, "failed")
    }
}

// MARK: - MimicryResult Tests

final class MimicryResultTests: XCTestCase {

    func testMimicryResult_succeeded() {
        let result = MimicryResult(
            task: "Send email",
            status: .succeeded,
            plan: TaskPlan(
                taskDescription: "Send email",
                steps: [],
                successCriteria: "Done"
            ),
            executionState: nil,
            error: nil,
            durationMs: 5000
        )
        XCTAssertEqual(result.task, "Send email")
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertNotNil(result.plan)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.durationMs, 5000)
    }

    func testMimicryResult_planningFailed() {
        let result = MimicryResult(
            task: "Test",
            status: .planningFailed,
            plan: nil,
            executionState: nil,
            error: "No providers available",
            durationMs: 100
        )
        XCTAssertEqual(result.status, .planningFailed)
        XCTAssertNil(result.plan)
        XCTAssertEqual(result.error, "No providers available")
    }

    func testMimicryResult_sendable() {
        let result = MimicryResult(
            task: "Test",
            status: .cancelled,
            plan: nil,
            executionState: nil,
            error: nil,
            durationMs: 0
        )
        let _: any Sendable = result
        XCTAssertTrue(true)
    }
}

// MARK: - MimicryTaskStatus Tests

final class MimicryTaskStatusTests: XCTestCase {

    func testMimicryTaskStatus_rawValues() {
        XCTAssertEqual(MimicryTaskStatus.succeeded.rawValue, "succeeded")
        XCTAssertEqual(MimicryTaskStatus.planningFailed.rawValue, "planningFailed")
        XCTAssertEqual(MimicryTaskStatus.executionFailed.rawValue, "executionFailed")
        XCTAssertEqual(MimicryTaskStatus.cancelled.rawValue, "cancelled")
    }
}

// MARK: - MimicryContext Tests

final class MimicryContextTests: XCTestCase {

    func testMimicryContext_init() {
        let context = MimicryContext(
            behavioralContext: "App: Gmail | 15 actions",
            procedures: "Procedure: SendEmail (5 steps)",
            axTreeSummary: "AXWindow: Gmail\n  AXButton: Compose",
            targetApp: "Gmail"
        )
        XCTAssertEqual(context.behavioralContext, "App: Gmail | 15 actions")
        XCTAssertFalse(context.procedures.isEmpty)
        XCTAssertTrue(context.axTreeSummary.contains("AXButton"))
        XCTAssertEqual(context.targetApp, "Gmail")
    }

    func testMimicryContext_sendable() {
        let context = MimicryContext(
            behavioralContext: "",
            procedures: "",
            axTreeSummary: "",
            targetApp: nil
        )
        let _: any Sendable = context
        XCTAssertTrue(true)
    }
}

// MARK: - Progress Collector

private actor ProgressCollector {
    var updates: [MimicryProgress] = []

    func append(_ progress: MimicryProgress) {
        updates.append(progress)
    }
}

// MARK: - Mock LLM Provider Helper

/// Creates a MockLLMProvider (from LLMOrchestratorTests) configured with the given response content.
/// Named "cloud_mock" so LLMOrchestrator routes to it in cloudOnly mode.
private func makeMockProvider(responseContent: String) -> MockLLMProvider {
    let response = LLMResponse(
        content: responseContent,
        toolCalls: [],
        provider: "cloud_mock",
        modelId: "mock-model",
        inputTokens: 100,
        outputTokens: 200,
        latencyMs: 50
    )
    return MockLLMProvider(
        name: "cloud_mock",
        result: .success(response)
    )
}
