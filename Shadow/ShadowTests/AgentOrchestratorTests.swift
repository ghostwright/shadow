import XCTest
@testable import Shadow

final class AgentOrchestratorTests: XCTestCase {

    // MARK: - Fast Path

    /// Simple question uses fast path.
    func testShouldUseFastPathSimpleQuestion() {
        let classification = IntentClassifier.ClassificationResult(
            intent: .simpleQuestion,
            confidence: 0.85,
            method: .llm
        )
        XCTAssertTrue(AgentOrchestrator.shouldUseFastPath(classification))
    }

    /// Ambiguous intent uses fast path.
    func testShouldUseFastPathAmbiguous() {
        let classification = IntentClassifier.ClassificationResult(
            intent: .ambiguous,
            confidence: 0.3,
            method: .defaultFallback
        )
        XCTAssertTrue(AgentOrchestrator.shouldUseFastPath(classification))
    }

    /// Procedure replay now uses fast path (agent has get_procedures + replay_procedure tools).
    func testShouldUseFastPathProcedureReplay() {
        let classification = IntentClassifier.ClassificationResult(
            intent: .procedureReplay,
            confidence: 0.8,
            method: .llm
        )
        XCTAssertTrue(AgentOrchestrator.shouldUseFastPath(classification))
    }

    /// Complex reasoning now uses fast path (agent has all tools for deep analysis).
    func testShouldUseFastPathComplexReasoning() {
        let classification = IntentClassifier.ClassificationResult(
            intent: .complexReasoning,
            confidence: 0.7,
            method: .heuristic
        )
        XCTAssertTrue(AgentOrchestrator.shouldUseFastPath(classification))
    }

    /// Directive creation uses fast path (agent has set_directive tool).
    func testShouldUseFastPathDirectiveCreation() {
        let classification = IntentClassifier.ClassificationResult(
            intent: .directiveCreation,
            confidence: 0.7,
            method: .heuristic
        )
        XCTAssertTrue(AgentOrchestrator.shouldUseFastPath(classification))
    }

    /// Memory search uses fast path (agent chains search tools effectively).
    func testFastPathMemorySearch() {
        let classification = IntentClassifier.ClassificationResult(
            intent: .memorySearch,
            confidence: 0.5,
            method: .heuristic
        )
        XCTAssertTrue(AgentOrchestrator.shouldUseFastPath(classification))
    }

    /// High-confidence memory search also uses fast path.
    func testFastPathHighConfidenceMemorySearch() {
        let classification = IntentClassifier.ClassificationResult(
            intent: .memorySearch,
            confidence: 0.8,
            method: .llm
        )
        XCTAssertTrue(AgentOrchestrator.shouldUseFastPath(classification))
    }

    /// UI action uses fast path.
    func testShouldUseFastPathUIAction() {
        let classification = IntentClassifier.ClassificationResult(
            intent: .uiAction,
            confidence: 0.8,
            method: .llm
        )
        XCTAssertTrue(AgentOrchestrator.shouldUseFastPath(classification))
    }

    /// Procedure learning now uses fast path (all intents route through general agent).
    func testShouldUseFastPathProcedureLearning() {
        let classification = IntentClassifier.ClassificationResult(
            intent: .procedureLearning,
            confidence: 0.8,
            method: .llm
        )
        XCTAssertTrue(AgentOrchestrator.shouldUseFastPath(classification))
    }

    // MARK: - OrchestratorResult

    /// OrchestratorResult captures all fields.
    func testOrchestratorResult() {
        let result = AgentOrchestrator.OrchestratorResult(
            answer: "The answer",
            subTaskResults: [
                SubTaskResult(taskId: "t1", role: .observer, output: "Screen shows Safari"),
                SubTaskResult(taskId: "t2", role: .general, output: "You were browsing"),
            ],
            intent: .simpleQuestion,
            totalMs: 1500,
            metrics: nil
        )
        XCTAssertEqual(result.answer, "The answer")
        XCTAssertEqual(result.subTaskResults.count, 2)
        XCTAssertEqual(result.intent, .simpleQuestion)
        XCTAssertEqual(result.totalMs, 1500)
        XCTAssertNil(result.metrics)
    }

    /// OrchestratorResult with metrics.
    func testOrchestratorResultWithMetrics() {
        let metrics = AgentRunMetrics(
            totalMs: 2000,
            stepCount: 3,
            toolCallCount: 5,
            inputTokensTotal: 1000,
            outputTokensTotal: 500,
            provider: "cloud",
            modelId: "claude-sonnet-4-6"
        )
        let result = AgentOrchestrator.OrchestratorResult(
            answer: "test",
            subTaskResults: [],
            intent: .simpleQuestion,
            totalMs: 2000,
            metrics: metrics
        )
        XCTAssertEqual(result.metrics?.provider, "cloud")
        XCTAssertEqual(result.metrics?.toolCallCount, 5)
    }

    // MARK: - Orchestration Events

    /// OrchestratorEvent covers all cases.
    func testOrchestratorEventCases() {
        // Verify all event types can be constructed
        let events: [AgentOrchestrator.OrchestratorEvent] = [
            .intentClassified(intent: .simpleQuestion, confidence: 0.85, method: "llm"),
            .taskDecomposed(subTaskCount: 3, intent: .memorySearch),
            .phaseStarted(phaseIndex: 0, taskCount: 2),
            .subTaskStarted(taskId: "t1", role: .observer, instruction: "Capture screen"),
            .subTaskCompleted(taskId: "t1", role: .observer, durationMs: 100, success: true),
            .agentEvent(.runStarted(task: "test")),
            .orchestrationComplete(AgentOrchestrator.OrchestratorResult(
                answer: "done", subTaskResults: [], intent: .ambiguous, totalMs: 0, metrics: nil
            )),
            .orchestrationFailed("test error"),
        ]
        XCTAssertEqual(events.count, 8)
    }

    // MARK: - Orchestrated Run with Injectable Runner

    /// All intents now use the fast path. Verify procedureReplay goes through fast path
    /// and emits intentClassified + agentEvent (forwarded from AgentRuntime).
    func testProcedureReplayUsesFastPath() async {
        let orchestrator = LLMOrchestrator(providers: [], mode: .cloudOnly)

        let classifyFn: @Sendable (String) async throws -> String = { _ in
            "procedureReplay"
        }

        let registry = AgentToolRegistry(tools: [:])

        var events: [AgentOrchestrator.OrchestratorEvent] = []
        let stream = AgentOrchestrator.run(
            query: "File my expense report",
            orchestrator: orchestrator,
            registry: registry,
            classifyFn: classifyFn
        )

        for await event in stream {
            events.append(event)
        }

        // Should have intentClassified as procedureReplay
        let intentEvents = events.compactMap { event -> IntentClassifier.UserIntent? in
            if case .intentClassified(let intent, _, _) = event { return intent }
            return nil
        }
        XCTAssertEqual(intentEvents.count, 1)
        XCTAssertEqual(intentEvents[0], .procedureReplay)

        // Should go through fast path (agentEvent forwarded, no taskDecomposed)
        let decomposeEvents = events.compactMap { event -> Int? in
            if case .taskDecomposed(let count, _) = event { return count }
            return nil
        }
        XCTAssertEqual(decomposeEvents.count, 0, "Fast path should not decompose")

        // Should have agentEvent (forwarded from AgentRuntime) — fast path runs the runtime
        let hasAgentEvents = events.contains { event in
            if case .agentEvent = event { return true }
            return false
        }
        XCTAssertTrue(hasAgentEvents, "Fast path should forward agent events")
    }

    /// Simple question goes through fast path.
    func testFastPathRun() async {
        let orchestrator = LLMOrchestrator(providers: [], mode: .cloudOnly)

        let classifyFn: @Sendable (String) async throws -> String = { _ in
            "simpleQuestion"
        }

        let registry = AgentToolRegistry(tools: [:])

        var events: [AgentOrchestrator.OrchestratorEvent] = []
        let stream = AgentOrchestrator.run(
            query: "What time is it?",
            orchestrator: orchestrator,
            registry: registry,
            classifyFn: classifyFn
        )

        for await event in stream {
            events.append(event)
        }

        // Should have intentClassified (simpleQuestion triggers fast path)
        let intentEvents = events.compactMap { event -> IntentClassifier.UserIntent? in
            if case .intentClassified(let intent, _, _) = event { return intent }
            return nil
        }
        XCTAssertEqual(intentEvents.count, 1)
        XCTAssertEqual(intentEvents[0], .simpleQuestion)

        // Should have agentEvent (forwarded from AgentRuntime)
        // or orchestrationFailed (no providers available)
        let hasAgentEvents = events.contains { event in
            if case .agentEvent = event { return true }
            return false
        }
        let hasFailed = events.contains { event in
            if case .agentEvent(.runFailed) = event { return true }
            return false
        }
        // Either the agent forwarded events, or it failed (no providers) — both are valid
        XCTAssertTrue(hasAgentEvents || hasFailed || events.contains { event in
            if case .orchestrationComplete = event { return true }
            return false
        })
    }

    /// Heuristic fallback when no LLM classify function.
    func testHeuristicFallbackClassification() async {
        let orchestrator = LLMOrchestrator(providers: [], mode: .cloudOnly)
        let registry = AgentToolRegistry(tools: [:])

        // Use injectable sub-task runner to avoid needing real LLM
        let subTaskRunner: AgentOrchestrator.SubTaskRunnerFn = { subTask, _, _ in
            SubTaskResult(
                taskId: subTask.id,
                role: subTask.agent,
                output: "done",
                success: true,
                durationMs: 5
            )
        }

        var events: [AgentOrchestrator.OrchestratorEvent] = []
        let stream = AgentOrchestrator.run(
            query: "Analyze my time allocation this week",
            orchestrator: orchestrator,
            registry: registry,
            subTaskRunner: subTaskRunner
        )

        for await event in stream {
            events.append(event)
        }

        // Should classify via heuristic (no classifyFn provided, no providers)
        let intentEvents = events.compactMap { event -> (IntentClassifier.UserIntent, String)? in
            if case .intentClassified(let intent, _, let method) = event { return (intent, method) }
            return nil
        }
        XCTAssertEqual(intentEvents.count, 1)
        XCTAssertEqual(intentEvents[0].0, .complexReasoning) // "analyze" keyword
        XCTAssertEqual(intentEvents[0].1, "heuristic")
    }

    /// All intents use fast path -- verify procedureReplay goes through fast path
    /// (no decomposition, forwards agent events).
    func testProcedureReplayGoesViaFastPath() async {
        let orchestrator = LLMOrchestrator(providers: [], mode: .cloudOnly)
        let registry = AgentToolRegistry(tools: [:])

        let classifyFn: @Sendable (String) async throws -> String = { _ in
            "procedureReplay"
        }

        var events: [AgentOrchestrator.OrchestratorEvent] = []
        let stream = AgentOrchestrator.run(
            query: "File my expense report",
            orchestrator: orchestrator,
            registry: registry,
            classifyFn: classifyFn
        )

        for await event in stream {
            events.append(event)
        }

        // Should have intentClassified as procedureReplay
        let intentEvents = events.compactMap { event -> IntentClassifier.UserIntent? in
            if case .intentClassified(let intent, _, _) = event { return intent }
            return nil
        }
        XCTAssertEqual(intentEvents.count, 1)
        XCTAssertEqual(intentEvents[0], .procedureReplay)

        // Fast path should not decompose
        let decomposeEvents = events.compactMap { event -> Int? in
            if case .taskDecomposed(let count, _) = event { return count }
            return nil
        }
        XCTAssertEqual(decomposeEvents.count, 0, "Fast path should not decompose")

        // Should have agent events (empty registry produces runFailed)
        let hasAgentEvents = events.contains { event in
            if case .agentEvent = event { return true }
            return false
        }
        XCTAssertTrue(hasAgentEvents, "Fast path should forward agent events")
    }
}
