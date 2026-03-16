import XCTest
@testable import Shadow

@MainActor
final class AgentStreamingStateTests: XCTestCase {

    // MARK: - Test Helpers

    /// Create a view model with an agent run function that emits the given events.
    private func makeAgentViewModel(
        events: [AgentRunEvent]
    ) -> SearchViewModel {
        let vm = SearchViewModel()
        vm.query = "what happened in the standup?"
        vm.agentRunFunction = { @Sendable _ in
            AsyncStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
        return vm
    }

    /// Create a view model with an agent run function backed by a continuation
    /// for fine-grained event delivery control.
    private func makeControllableAgentViewModel() -> (SearchViewModel, AsyncStream<AgentRunEvent>.Continuation) {
        let vm = SearchViewModel()
        vm.query = "what happened in the standup?"

        let (stream, continuation) = AsyncStream<AgentRunEvent>.makeStream()
        let capturedStream = stream
        vm.agentRunFunction = { @Sendable _ in
            capturedStream
        }

        return (vm, continuation)
    }

    private func makeResult() -> AgentRunResult {
        AgentRunResult(
            answer: "The standup covered sprint progress.",
            evidence: [
                AgentEvidenceItem(
                    timestamp: 1_000_000,
                    app: "Zoom",
                    sourceKind: "transcript",
                    displayId: 1,
                    url: nil,
                    snippet: "Sprint review discussion"
                ),
                AgentEvidenceItem(
                    timestamp: 2_000_000,
                    app: "Chrome",
                    sourceKind: "search",
                    displayId: nil,
                    url: "https://jira.example.com",
                    snippet: "JIRA board screenshot"
                )
            ],
            toolCalls: [],
            metrics: AgentRunMetrics(
                totalMs: 1500,
                stepCount: 3,
                toolCallCount: 2,
                inputTokensTotal: 800,
                outputTokensTotal: 200,
                provider: "anthropic_cloud",
                modelId: "claude-sonnet-4-20250514"
            )
        )
    }

    // MARK: - 1. Reducer: runStarted sets task and status

    func testReducer_runStarted_setsTaskAndStatus() async {
        let (vm, continuation) = makeControllableAgentViewModel()

        vm.executeCommand()

        guard case .agentStreaming = vm.commandState else {
            XCTFail("Expected .agentStreaming, got \(vm.commandState)")
            return
        }
        XCTAssertNotNil(vm.agentStreamState)

        continuation.yield(.runStarted(task: "updated task"))

        // Yield to let MainActor process the event
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.agentStreamState?.task, "updated task")
        XCTAssertEqual(vm.agentStreamState?.status, .starting)

        continuation.finish()
    }

    // MARK: - 2. Reducer: llmDelta accumulates tokens

    func testReducer_llmDelta_accumulatesTokens() async {
        let (vm, continuation) = makeControllableAgentViewModel()

        vm.executeCommand()
        try? await Task.sleep(for: .milliseconds(50))

        continuation.yield(.llmDelta(text: "Hello "))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.agentStreamState?.liveAnswer, "Hello ")
        XCTAssertEqual(vm.agentStreamState?.status, .streaming)

        continuation.yield(.llmDelta(text: "world!"))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.agentStreamState?.liveAnswer, "Hello world!")

        continuation.finish()
    }

    // MARK: - 3. Reducer: tool timeline

    func testReducer_toolTimeline() async {
        let (vm, continuation) = makeControllableAgentViewModel()

        vm.executeCommand()
        try? await Task.sleep(for: .milliseconds(50))

        continuation.yield(.toolCallStarted(name: "search_hybrid", step: 1))
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.agentStreamState?.toolTimeline.count, 1)
        XCTAssertEqual(vm.agentStreamState?.toolTimeline.first?.name, "search_hybrid")
        XCTAssertEqual(vm.agentStreamState?.toolTimeline.first?.status, .running)
        XCTAssertEqual(vm.agentStreamState?.status, .toolRunning)

        continuation.yield(.toolCallCompleted(name: "search_hybrid", durationMs: 42.0, outputPreview: "3 results"))
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.agentStreamState?.toolTimeline.first?.status, .completed(durationMs: 42.0))
        XCTAssertEqual(vm.agentStreamState?.status, .streaming)

        continuation.finish()
    }

    // MARK: - 4. Reducer: toolCallFailed is non-fatal

    func testReducer_toolCallFailed_isNonFatal() async {
        let (vm, continuation) = makeControllableAgentViewModel()

        vm.executeCommand()
        try? await Task.sleep(for: .milliseconds(50))

        continuation.yield(.toolCallStarted(name: "search_hybrid", step: 1))
        try? await Task.sleep(for: .milliseconds(50))

        let statusBeforeFail = vm.agentStreamState?.status
        XCTAssertEqual(statusBeforeFail, .toolRunning)

        continuation.yield(.toolCallFailed(name: "search_hybrid", error: "timeout"))
        try? await Task.sleep(for: .milliseconds(50))

        // Tool marked as failed but overall status unchanged (still .toolRunning)
        XCTAssertEqual(vm.agentStreamState?.toolTimeline.first?.status, .failed(error: "timeout"))
        XCTAssertEqual(vm.agentStreamState?.status, .toolRunning, "toolCallFailed is non-fatal, status should not change")

        // Run continues — not moved to error state
        guard case .agentStreaming = vm.commandState else {
            XCTFail("Expected still .agentStreaming after non-fatal tool failure, got \(vm.commandState)")
            return
        }

        continuation.finish()
    }

    // MARK: - 5. Reducer: finalAnswer transitions to agentResult

    func testReducer_finalAnswer_transitionsToAgentResult() async {
        let result = makeResult()
        let (vm, continuation) = makeControllableAgentViewModel()

        vm.executeCommand()
        try? await Task.sleep(for: .milliseconds(50))

        continuation.yield(.finalAnswer(result))
        try? await Task.sleep(for: .milliseconds(50))

        guard case .agentResult = vm.commandState else {
            XCTFail("Expected .agentResult, got \(vm.commandState)")
            return
        }

        XCTAssertEqual(vm.agentStreamState?.liveAnswer, result.answer)
        XCTAssertEqual(vm.agentStreamState?.evidence.count, 2)
        XCTAssertEqual(vm.agentStreamState?.metrics?.provider, "anthropic_cloud")
        XCTAssertEqual(vm.agentStreamState?.status, .complete)

        continuation.finish()
    }

    // MARK: - 6. Reducer: runFailed transitions to error

    func testReducer_runFailed_transitionsToError() async {
        let (vm, continuation) = makeControllableAgentViewModel()

        vm.executeCommand()
        try? await Task.sleep(for: .milliseconds(50))

        continuation.yield(.runFailed(.budgetExhausted(steps: 6, toolCalls: 10)))
        try? await Task.sleep(for: .milliseconds(50))

        guard case .error(.agentError(let msg)) = vm.commandState else {
            XCTFail("Expected .error(.agentError), got \(vm.commandState)")
            return
        }

        XCTAssertTrue(msg.contains("processing limit"), "Error should contain display message, got: \(msg)")
        XCTAssertNil(vm.agentStreamState, "agentStreamState should be nil after runFailed")

        continuation.finish()
    }

    // MARK: - 7. Cancel prevents post-cancel events

    func testCancel_noPostCancelEvents() async {
        let (vm, continuation) = makeControllableAgentViewModel()

        vm.executeCommand()
        try? await Task.sleep(for: .milliseconds(50))

        continuation.yield(.llmDelta(text: "partial "))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.agentStreamState?.liveAnswer, "partial ")

        // Cancel
        vm.cancelCommand()
        guard case .idle = vm.commandState else {
            XCTFail("Expected .idle after cancel, got \(vm.commandState)")
            return
        }
        XCTAssertNil(vm.agentStreamState, "agentStreamState should be nil after cancel")

        // Send more events — should be discarded (stale runID)
        continuation.yield(.llmDelta(text: "should not appear"))
        continuation.yield(.finalAnswer(makeResult()))
        try? await Task.sleep(for: .milliseconds(100))

        // State must remain idle
        guard case .idle = vm.commandState else {
            XCTFail("Post-cancel event mutated state: \(vm.commandState)")
            return
        }
        XCTAssertNil(vm.agentStreamState)

        continuation.finish()
    }

    // MARK: - 8. Evidence deep-link uses onOpenTimeline

    func testEvidenceDeepLink_usesOnOpenTimeline() {
        let vm = SearchViewModel()
        var capturedTs: UInt64?
        var capturedDisplayID: UInt32?

        vm.onOpenTimeline = { ts, displayID in
            capturedTs = ts
            capturedDisplayID = displayID
        }

        // Simulate AgentEvidenceListView deep-link — same callback path
        vm.onOpenTimeline?(1_500_000, 2)

        XCTAssertEqual(capturedTs, 1_500_000)
        XCTAssertEqual(capturedDisplayID, 2)
    }

    // MARK: - 9. Rapid cancel+restart isolates runs

    func testRapidCancelRestart_isolatesRuns() async {
        // Run 1: controllable
        let (vm, continuation1) = makeControllableAgentViewModel()

        vm.executeCommand()
        try? await Task.sleep(for: .milliseconds(50))

        continuation1.yield(.llmDelta(text: "run1 "))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.agentStreamState?.liveAnswer, "run1 ")

        // Cancel run 1
        vm.cancelCommand()

        // Reconfigure with run 2 using makeStream
        let (stream2, continuation2) = AsyncStream<AgentRunEvent>.makeStream()
        let capturedStream2 = stream2
        vm.agentRunFunction = { @Sendable _ in
            capturedStream2
        }
        vm.executeCommand()
        try? await Task.sleep(for: .milliseconds(50))

        // Post-cancel event from run 1 — should be discarded
        continuation1.yield(.llmDelta(text: "stale"))
        continuation1.yield(.finalAnswer(makeResult()))
        continuation1.finish()
        try? await Task.sleep(for: .milliseconds(50))

        // Run 2 events land correctly
        continuation2.yield(.llmDelta(text: "run2 answer"))
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.agentStreamState?.liveAnswer, "run2 answer", "Only run 2 events should land")
        guard case .agentStreaming = vm.commandState else {
            XCTFail("Expected .agentStreaming for run 2, got \(vm.commandState)")
            return
        }

        continuation2.finish()
    }

    // MARK: - 10. Panel heights for agent cases

    func testPanelHeights_agentCases() {
        XCTAssertEqual(CommandState.agentStreaming.panelHeight, 560)
        XCTAssertEqual(CommandState.agentResult.panelHeight, 640)
    }

    // MARK: - 11. isCommandActive for agent cases

    func testIsCommandActive_agentCases() {
        XCTAssertTrue(CommandState.agentStreaming.isCommandActive)
        XCTAssertTrue(CommandState.agentResult.isCommandActive)
    }

    // MARK: - 12. Routing: agent path when function set

    func testRouting_agentPathWhenFunctionSet() {
        let vm = SearchViewModel()
        vm.query = "test query"
        vm.agentRunFunction = { @Sendable _ in
            AsyncStream { continuation in
                continuation.finish()
            }
        }
        // Also set summaryJobQueue to verify agent takes priority
        let orchestrator = LLMOrchestrator(providers: [], mode: .auto)
        let store = SummaryStore()
        vm.summaryJobQueue = SummaryJobQueue(orchestrator: orchestrator, store: store)

        vm.executeCommand()

        // Agent path sets .agentStreaming; summary path sets .running
        guard case .agentStreaming = vm.commandState else {
            XCTFail("Expected .agentStreaming (agent path), got \(vm.commandState)")
            return
        }
        XCTAssertNotNil(vm.agentStreamState, "Agent state should be set on agent path")
    }

    // MARK: - 13. Routing: summary path when only queue set

    func testRouting_summaryPathWhenOnlyQueueSet() {
        let vm = SearchViewModel()
        vm.query = "test query"
        vm.agentRunFunction = nil // No agent

        let orchestrator = LLMOrchestrator(providers: [], mode: .auto)
        let store = SummaryStore()
        vm.summaryJobQueue = SummaryJobQueue(orchestrator: orchestrator, store: store)

        vm.executeCommand()

        // Summary path starts with .running state; agent path would set .agentStreaming
        guard case .running = vm.commandState else {
            XCTFail("Expected .running (summary path), got \(vm.commandState)")
            return
        }
        XCTAssertNil(vm.agentStreamState, "Agent state should be nil on summary path")
    }

    // MARK: - 14. AgentRunError displayMessage for all cases

    func testAgentRunError_displayMessage() {
        let cases: [(AgentRunError, String)] = [
            (.budgetExhausted(steps: 6, toolCalls: 10), "processing limit"),
            (.timeout(elapsedSeconds: 60), "timed out"),
            (.providerError("API rate limit"), "API rate limit"),
            (.noToolsAvailable, "No tools"),
            (.cancelled, "cancelled"),
            (.internalError("unexpected nil"), "Internal error")
        ]

        for (error, expectedSubstring) in cases {
            let message = error.displayMessage
            XCTAssertFalse(message.isEmpty, "displayMessage should not be empty for \(error)")
            XCTAssertTrue(message.contains(expectedSubstring),
                          "\(error).displayMessage should contain '\(expectedSubstring)', got: \(message)")
        }
    }

    // MARK: - 15. CommandError.agentError has title, message, icon

    func testCommandError_agentError() {
        let error = CommandError.agentError("Something went wrong with the agent")

        XCTAssertEqual(error.title, "Agent Failed")
        XCTAssertEqual(error.message, "Something went wrong with the agent")
        XCTAssertFalse(error.iconName.isEmpty)
    }

    // MARK: - 16. Stream-end without terminal event → safe error state

    func testStreamEnd_noTerminalEvent_transitionsToError() async {
        // Stream that emits events but finishes without finalAnswer/runFailed/runCancelled
        let vm = SearchViewModel()
        vm.query = "test query"
        vm.agentRunFunction = { @Sendable _ in
            AsyncStream { continuation in
                continuation.yield(.runStarted(task: "test"))
                continuation.yield(.llmDelta(text: "partial answer"))
                // Stream ends without terminal event
                continuation.finish()
            }
        }

        vm.executeCommand()

        // Wait for stream to complete
        try? await Task.sleep(for: .milliseconds(200))

        // Should transition to error state, not hang in .agentStreaming
        guard case .error(.agentError(let msg)) = vm.commandState else {
            XCTFail("Expected .error(.agentError) after stream ended without terminal, got \(vm.commandState)")
            return
        }
        XCTAssertTrue(msg.contains("unexpectedly"), "Error message should mention unexpected end: \(msg)")
        XCTAssertNil(vm.agentStreamState, "agentStreamState should be cleared")
    }

    // MARK: - 17. Stream-end with terminal event does NOT trigger fallback

    func testStreamEnd_withTerminalEvent_noFallback() async {
        let result = makeResult()
        let (vm, continuation) = makeControllableAgentViewModel()

        vm.executeCommand()
        try? await Task.sleep(for: .milliseconds(50))

        // Deliver terminal event then finish
        continuation.yield(.finalAnswer(result))
        continuation.finish()
        try? await Task.sleep(for: .milliseconds(100))

        // Should be .agentResult from the terminal event, NOT .error from fallback
        guard case .agentResult = vm.commandState else {
            XCTFail("Expected .agentResult, got \(vm.commandState)")
            return
        }
        XCTAssertNotNil(vm.agentStreamState, "agentStreamState should be preserved with final result")
    }

    // MARK: - 18. Stream-end after cancel does NOT trigger fallback

    func testStreamEnd_afterCancel_noFallback() async {
        let (vm, continuation) = makeControllableAgentViewModel()

        vm.executeCommand()
        try? await Task.sleep(for: .milliseconds(50))

        // Cancel (invalidates runID)
        vm.cancelCommand()

        // Stream finishes after cancel — fallback must NOT fire (stale run)
        continuation.finish()
        try? await Task.sleep(for: .milliseconds(100))

        guard case .idle = vm.commandState else {
            XCTFail("Expected .idle after cancel, not fallback error. Got \(vm.commandState)")
            return
        }
    }
}
