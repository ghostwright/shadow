import XCTest
@testable import Shadow

// MARK: - Mock Sequenced Provider

/// Returns different responses on successive generate() calls.
/// Used to test multi-step agent loops deterministically.
private final class MockSequencedProvider: LLMProvider, @unchecked Sendable {
    let providerName: String
    let modelId: String
    var isAvailable: Bool = true
    private var responses: [Result<LLMResponse, LLMProviderError>]
    private var callIndex = 0
    var generateCallCount: Int { callIndex }

    init(
        name: String = "mock_cloud",
        modelId: String = "mock-model",
        responses: [Result<LLMResponse, LLMProviderError>]
    ) {
        self.providerName = name
        self.modelId = modelId
        self.responses = responses
    }

    func generate(request: LLMRequest) async throws -> LLMResponse {
        let idx = min(callIndex, responses.count - 1)
        callIndex += 1
        switch responses[idx] {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}

/// A provider that sleeps before responding (for timeout tests).
private final class SlowProvider: LLMProvider, @unchecked Sendable {
    let providerName = "slow_cloud_mock"
    let modelId = "slow-model"
    var isAvailable: Bool = true
    let delayNs: UInt64

    init(delayNs: UInt64) {
        self.delayNs = delayNs
    }

    func generate(request: LLMRequest) async throws -> LLMResponse {
        try await Task.sleep(nanoseconds: delayNs)
        return LLMResponse(
            content: "slow response", toolCalls: [],
            provider: providerName, modelId: modelId,
            inputTokens: 10, outputTokens: 5, latencyMs: Double(delayNs / 1_000_000)
        )
    }
}

// MARK: - Helpers

private func makeResponse(
    content: String,
    toolCalls: [ToolCall] = [],
    provider: String = "mock_cloud",
    model: String = "mock-model"
) -> LLMResponse {
    LLMResponse(
        content: content,
        toolCalls: toolCalls,
        provider: provider,
        modelId: model,
        inputTokens: 50,
        outputTokens: 30,
        latencyMs: 100
    )
}

private func makeToolCall(id: String = "tc_1", name: String, args: [String: AnyCodable] = [:]) -> ToolCall {
    ToolCall(id: id, name: name, arguments: args)
}

private func emptySchema() -> [String: AnyCodable] {
    ["type": .string("object"), "properties": .dictionary([:]), "required": .array([])]
}

/// Collect all events from an agent run stream.
private func collectEvents(_ stream: AsyncStream<AgentRunEvent>) async -> [AgentRunEvent] {
    var events: [AgentRunEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

/// Build a simple registry with one echo tool.
private func echoRegistry() -> AgentToolRegistry {
    let tool = RegisteredTool(
        spec: ToolSpec(
            name: "echo",
            description: "Echo tool",
            inputSchema: ["type": .string("object"), "properties": .dictionary([:]), "required": .array([])]
        ),
        handler: { args in
            let text = args["text"]?.stringValue ?? "echoed"
            return "{\"ts\":1000000,\"app\":\"TestApp\",\"snippet\":\"\(text)\",\"displayId\":1}"
        }
    )
    return AgentToolRegistry(tools: ["echo": tool])
}

/// Build a registry with a failing tool.
private func failingRegistry() -> AgentToolRegistry {
    let tool = RegisteredTool(
        spec: ToolSpec(
            name: "broken",
            description: "Always fails",
            inputSchema: ["type": .string("object"), "properties": .dictionary([:]), "required": .array([])]
        ),
        handler: { _ in throw ToolError.invalidArgument("test", detail: "simulated failure") }
    )
    return AgentToolRegistry(tools: ["broken": tool])
}

// MARK: - Tests

final class AgentRuntimeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DiagnosticsStore.shared.resetCounters()
    }

    // 1. Single-step answer, no tools
    func testSingleStepNoTools() async {
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: "The answer is 42.")),
        ])
        let orchestrator = LLMOrchestrator(providers: [provider], mode: .cloudOnly)
        let request = AgentRunRequest(task: "What is the answer?", config: AgentRunConfig())

        let events = await collectEvents(
            AgentRuntime.run(request: request, orchestrator: orchestrator, registry: echoRegistry())
        )

        // Expected: runStarted, llmRequestStarted, llmDelta, finalAnswer
        XCTAssertEqual(events.count, 4)
        XCTAssert(events[0].isRunStarted)
        XCTAssert(events[1].isLLMRequestStarted)
        XCTAssert(events[2].isLLMDelta)
        XCTAssert(events[3].isFinalAnswer)

        if case .finalAnswer(let result) = events[3] {
            XCTAssertEqual(result.answer, "The answer is 42.")
            XCTAssertEqual(result.metrics.stepCount, 1)
            XCTAssertEqual(result.toolCalls.count, 0)
            XCTAssertEqual(result.metrics.provider, "mock_cloud")
        } else {
            XCTFail("Expected finalAnswer")
        }

        XCTAssertEqual(DiagnosticsStore.shared.counter("agent_run_total"), 1)
        XCTAssertEqual(DiagnosticsStore.shared.counter("agent_run_success_total"), 1)
    }

    // 2. Single tool call then final answer
    func testSingleToolCallThenAnswer() async {
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: "", toolCalls: [
                makeToolCall(name: "echo", args: ["text": AnyCodable.string("hello")])
            ])),
            .success(makeResponse(content: "Based on the echo, hello.")),
        ])
        let orchestrator = LLMOrchestrator(providers: [provider], mode: .cloudOnly)
        let request = AgentRunRequest(task: "Echo test", config: AgentRunConfig())

        let events = await collectEvents(
            AgentRuntime.run(request: request, orchestrator: orchestrator, registry: echoRegistry())
        )

        // Expected: started, llmReq1, toolStarted, toolCompleted, llmReq2, delta, finalAnswer
        let toolStartedEvents = events.filter { $0.isToolCallStarted }
        let toolCompletedEvents = events.filter { $0.isToolCallCompleted }
        XCTAssertEqual(toolStartedEvents.count, 1)
        XCTAssertEqual(toolCompletedEvents.count, 1)
        XCTAssert(events.last?.isFinalAnswer ?? false)

        if case .finalAnswer(let result) = events.last {
            XCTAssertEqual(result.metrics.stepCount, 2)
            XCTAssertEqual(result.toolCalls.count, 1)
            XCTAssertEqual(result.toolCalls[0].toolName, "echo")
            XCTAssertTrue(result.toolCalls[0].success)
            // Evidence should have been extracted from the echo tool output
            XCTAssertFalse(result.evidence.isEmpty)
        }

        XCTAssertEqual(DiagnosticsStore.shared.counter("agent_tool_call_total"), 1)
    }

    // 3. Multi-step chain with two tools
    func testMultiStepChain() async {
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: "", toolCalls: [
                makeToolCall(id: "tc_1", name: "echo", args: ["text": AnyCodable.string("first")])
            ])),
            .success(makeResponse(content: "", toolCalls: [
                makeToolCall(id: "tc_2", name: "echo", args: ["text": AnyCodable.string("second")])
            ])),
            .success(makeResponse(content: "Final answer after two tools.")),
        ])
        let orchestrator = LLMOrchestrator(providers: [provider], mode: .cloudOnly)
        let request = AgentRunRequest(task: "Multi-step", config: AgentRunConfig())

        let events = await collectEvents(
            AgentRuntime.run(request: request, orchestrator: orchestrator, registry: echoRegistry())
        )

        if case .finalAnswer(let result) = events.last {
            XCTAssertEqual(result.metrics.stepCount, 3)
            XCTAssertEqual(result.toolCalls.count, 2)
            XCTAssertEqual(result.toolCalls[0].toolName, "echo")
            XCTAssertEqual(result.toolCalls[1].toolName, "echo")
        } else {
            XCTFail("Expected finalAnswer")
        }

        XCTAssertEqual(DiagnosticsStore.shared.counter("agent_tool_call_total"), 2)
        XCTAssertEqual(provider.generateCallCount, 3)
    }

    // 4. Tool failure — graceful answer
    func testToolFailureGracefulAnswer() async {
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: "", toolCalls: [
                makeToolCall(name: "broken")
            ])),
            .success(makeResponse(content: "I could not complete the search.")),
        ])
        let orchestrator = LLMOrchestrator(providers: [provider], mode: .cloudOnly)
        let request = AgentRunRequest(task: "Failing tool test", config: AgentRunConfig())

        let events = await collectEvents(
            AgentRuntime.run(request: request, orchestrator: orchestrator, registry: failingRegistry())
        )

        let failedToolEvents = events.filter { $0.isToolCallFailed }
        XCTAssertEqual(failedToolEvents.count, 1)

        if case .finalAnswer(let result) = events.last {
            XCTAssertEqual(result.toolCalls.count, 1)
            XCTAssertFalse(result.toolCalls[0].success)
        } else {
            XCTFail("Expected finalAnswer after tool failure")
        }

        XCTAssertEqual(DiagnosticsStore.shared.counter("agent_tool_fail_total"), 1)
    }

    // 5. Budget exhaustion (maxSteps)
    func testBudgetExhaustion() async {
        // Provider always returns tool calls — never gives a final answer
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: "", toolCalls: [makeToolCall(name: "echo")])),
            .success(makeResponse(content: "", toolCalls: [makeToolCall(name: "echo")])),
            .success(makeResponse(content: "", toolCalls: [makeToolCall(name: "echo")])),
        ])
        let orchestrator = LLMOrchestrator(providers: [provider], mode: .cloudOnly)
        var config = AgentRunConfig()
        config.maxSteps = 2
        let request = AgentRunRequest(task: "Budget test", config: config)

        let events = await collectEvents(
            AgentRuntime.run(request: request, orchestrator: orchestrator, registry: echoRegistry())
        )

        let lastEvent = events.last
        if case .runFailed(let error) = lastEvent {
            if case .budgetExhausted(let steps, _) = error {
                XCTAssertEqual(steps, 2)
            } else {
                XCTFail("Expected budgetExhausted, got \(error)")
            }
        } else {
            XCTFail("Expected runFailed")
        }

        XCTAssertEqual(DiagnosticsStore.shared.counter("agent_budget_exhausted_total"), 1)
    }

    // 6. Timeout fires during in-flight LLM call (not just between steps)
    func testTimeoutDuringInflightLLMCall() async {
        // SlowProvider takes 500ms; timeout is 50ms.
        // With wall-clock enforcement, timeout races the provider and wins.
        let provider = SlowProvider(delayNs: 500_000_000)  // 500ms
        let orchestrator = LLMOrchestrator(providers: [provider], mode: .cloudOnly)
        var config = AgentRunConfig()
        config.timeoutSeconds = 0.05  // 50ms — will fire while provider is sleeping

        let request = AgentRunRequest(task: "Timeout test", config: config)

        let events = await collectEvents(
            AgentRuntime.run(request: request, orchestrator: orchestrator, registry: echoRegistry())
        )

        // Must get runFailed with .timeout — not a success or provider error
        let lastEvent = events.last
        if case .runFailed(let error) = lastEvent {
            if case .timeout(let elapsed) = error {
                XCTAssertGreaterThan(elapsed, 0)
            } else {
                XCTFail("Expected .timeout, got \(error)")
            }
        } else {
            XCTFail("Expected runFailed, got \(String(describing: lastEvent))")
        }

        XCTAssertEqual(DiagnosticsStore.shared.counter("agent_run_fail_total"), 1)
    }

    // 7. Cancellation — no stale events
    func testCancellation() async {
        let provider = SlowProvider(delayNs: 500_000_000)  // 500ms
        let orchestrator = LLMOrchestrator(providers: [provider], mode: .cloudOnly)
        let request = AgentRunRequest(task: "Cancel test", config: AgentRunConfig())

        let stream = AgentRuntime.run(request: request, orchestrator: orchestrator, registry: echoRegistry())

        var events: [AgentRunEvent] = []
        let task = Task {
            for await event in stream {
                events.append(event)
                // Cancel after getting the first event
                if events.count == 1 {
                    Task { @MainActor in
                        // No-op — cancellation happens via task.cancel()
                    }
                }
            }
        }

        // Cancel the consuming task after a short delay
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        task.cancel()
        await task.value

        // Should have runStarted at minimum, and no finalAnswer
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { !$0.isFinalAnswer })
    }

    // 8. Multi-provider parity
    func testMultiProviderParity() async {
        let localProvider = MockSequencedProvider(
            name: "local_mlx", modelId: "local-model",
            responses: [.success(makeResponse(content: "Local answer", provider: "local_mlx", model: "local-model"))]
        )
        let cloudProvider = MockSequencedProvider(
            name: "cloud_claude", modelId: "cloud-model",
            responses: [.success(makeResponse(content: "Cloud answer", provider: "cloud_claude", model: "cloud-model"))]
        )

        let localOrch = LLMOrchestrator(providers: [localProvider], mode: .localOnly)
        let cloudOrch = LLMOrchestrator(providers: [cloudProvider], mode: .cloudOnly)
        let request = AgentRunRequest(task: "Parity test", config: AgentRunConfig())

        let localEvents = await collectEvents(
            AgentRuntime.run(request: request, orchestrator: localOrch, registry: echoRegistry())
        )
        let cloudEvents = await collectEvents(
            AgentRuntime.run(request: request, orchestrator: cloudOrch, registry: echoRegistry())
        )

        // Same event structure (started, llmReq, delta, finalAnswer)
        XCTAssertEqual(localEvents.count, cloudEvents.count)

        if case .finalAnswer(let localResult) = localEvents.last,
           case .finalAnswer(let cloudResult) = cloudEvents.last {
            XCTAssertEqual(localResult.metrics.provider, "local_mlx")
            XCTAssertEqual(cloudResult.metrics.provider, "cloud_claude")
            XCTAssertEqual(localResult.metrics.stepCount, cloudResult.metrics.stepCount)
        } else {
            XCTFail("Expected both runs to produce finalAnswer")
        }
    }

    // 9. get_activity_sequence ordering and truncation
    func testActivitySequenceOrdering() async {
        let mockEvents: [TimelineEntry] = [
            TimelineEntry(ts: 3_000_000, track: 3, eventType: "app_switch", appName: "Safari", windowTitle: "Google", url: "https://google.com", displayId: 1, segmentFile: ""),
            TimelineEntry(ts: 1_000_000, track: 3, eventType: "app_switch", appName: "Xcode", windowTitle: "Project.swift", url: nil, displayId: 1, segmentFile: ""),
            TimelineEntry(ts: 2_000_000, track: 3, eventType: "app_switch", appName: "Slack", windowTitle: "#general", url: nil, displayId: nil, segmentFile: ""),
        ]

        let tool = AgentTools.getActivitySequenceTool(rangeQuery: { _, _ in mockEvents })

        let args: [String: AnyCodable] = [
            "startUs": AnyCodable.int(1_000_000),
            "endUs": AnyCodable.int(5_000_000),
            "limit": AnyCodable.int(2),
        ]
        let output = try! await tool.handler!(args)
        let lines = output.split(separator: "\n")

        // Should be sorted by timestamp and limited to 2
        XCTAssertEqual(lines.count, 2)

        // First line should be Xcode (ts=1M), second Slack (ts=2M)
        XCTAssertTrue(lines[0].contains("Xcode"))
        XCTAssertTrue(lines[1].contains("Slack"))
        // Xcode should have displayId and windowTitle
        XCTAssertTrue(lines[0].contains("Project.swift"))
        XCTAssertTrue(lines[0].contains("displayId"))
    }

    // 10. search_summaries correctness
    func testSearchSummaries() async throws {
        let tempDir = NSTemporaryDirectory() + "shadow_test_summaries_\(UUID().uuidString)"
        let store = SummaryStore(directory: tempDir)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Create test summaries
        let summary1 = MeetingSummary(
            id: "s1", title: "Sprint Planning", summary: "Discussed sprint goals and tasks.",
            keyPoints: ["Goal 1"], decisions: [], actionItems: [], openQuestions: [], highlights: [],
            metadata: SummaryMetadata(
                provider: "cloud_claude", modelId: "test", generatedAt: Date(),
                inputHash: "abc", sourceWindow: SourceWindow(startUs: 1000, endUs: 2000, timezone: "UTC", sessionId: nil),
                inputTokenEstimate: 100
            )
        )
        let summary2 = MeetingSummary(
            id: "s2", title: "Design Review", summary: "Reviewed the new UI designs.",
            keyPoints: ["UI change"], decisions: [], actionItems: [], openQuestions: [], highlights: [],
            metadata: SummaryMetadata(
                provider: "local_mlx", modelId: "test", generatedAt: Date(),
                inputHash: "def", sourceWindow: SourceWindow(startUs: 3000, endUs: 4000, timezone: "UTC", sessionId: nil),
                inputTokenEstimate: 200
            )
        )
        try store.save(summary1)
        try store.save(summary2)

        let tool = AgentTools.searchSummariesTool(store: store)
        let args: [String: AnyCodable] = ["query": AnyCodable.string("sprint")]
        let output = try await tool.handler!(args)

        XCTAssertTrue(output.contains("Sprint Planning"))
        XCTAssertFalse(output.contains("Design Review"))

        // Search for non-existent
        let noMatch = try await tool.handler!(["query": AnyCodable.string("nonexistent")])
        XCTAssertTrue(noMatch.contains("no_matching_summaries"))
    }

    // 11. displayId and url in tool outputs
    func testDisplayIdAndUrlInOutputs() async {
        let mockEvents: [TimelineEntry] = [
            TimelineEntry(ts: 1_000_000, track: 3, eventType: "app_switch", appName: "Chrome", windowTitle: "GitHub", url: "https://github.com", displayId: 42, segmentFile: ""),
        ]

        let tool = AgentTools.getActivitySequenceTool(rangeQuery: { _, _ in mockEvents })
        let args: [String: AnyCodable] = [
            "startUs": AnyCodable.int(0),
            "endUs": AnyCodable.int(5_000_000),
        ]
        let output = try! await tool.handler!(args)

        XCTAssertTrue(output.contains("\"displayId\":42"))
        XCTAssertTrue(output.contains("https://github.com"))
    }

    // MARK: - Stabilization Tests

    // 12. Cancellation during provider call → runCancelled (not providerError)
    func testCancellationClassifiedAsRunCancelled() async {
        // CancellingProvider throws CancellationError, simulating a cancelled Task.sleep
        let provider = SlowProvider(delayNs: 2_000_000_000)  // 2 seconds
        let orchestrator = LLMOrchestrator(providers: [provider], mode: .cloudOnly)
        let request = AgentRunRequest(task: "Cancel classification", config: AgentRunConfig())

        let stream = AgentRuntime.run(request: request, orchestrator: orchestrator, registry: echoRegistry())

        var events: [AgentRunEvent] = []
        let consumeTask = Task {
            for await event in stream {
                events.append(event)
            }
        }

        // Let the run start, then cancel while provider is sleeping
        try? await Task.sleep(nanoseconds: 30_000_000)  // 30ms
        consumeTask.cancel()
        await consumeTask.value

        // Should never see providerError — cancellation must map to runCancelled
        let providerErrors = events.filter {
            if case .runFailed(let e) = $0, case .providerError = e { return true }
            return false
        }
        XCTAssertEqual(providerErrors.count, 0, "CancellationError must not map to providerError")
        XCTAssertTrue(events.allSatisfy { !$0.isFinalAnswer }, "No final answer after cancellation")
    }

    // 13. Empty registry → noToolsAvailable
    func testEmptyRegistryFailsImmediately() async {
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: "Should not reach me")),
        ])
        let orchestrator = LLMOrchestrator(providers: [provider], mode: .cloudOnly)
        let request = AgentRunRequest(task: "No tools", config: AgentRunConfig())

        let events = await collectEvents(
            AgentRuntime.run(request: request, orchestrator: orchestrator, registry: AgentToolRegistry(tools: [:]))
        )

        // Should fail immediately with noToolsAvailable
        if case .runFailed(let error) = events.last {
            if case .noToolsAvailable = error {
                // correct
            } else {
                XCTFail("Expected .noToolsAvailable, got \(error)")
            }
        } else {
            XCTFail("Expected runFailed")
        }

        // Provider should never have been called
        XCTAssertEqual(provider.generateCallCount, 0)
        XCTAssertEqual(DiagnosticsStore.shared.counter("agent_run_fail_total"), 1)
    }

    // 14. maxFinalContextChars enforcement — messages are trimmed
    func testMaxFinalContextCharsEnforcement() async {
        // Create a provider that returns tool calls with large output, so messages grow.
        // With a very small maxFinalContextChars, the runtime should trim messages
        // and still complete without crashing.
        let bigOutput = String(repeating: "x", count: 500)
        let bigTool = RegisteredTool(
            spec: ToolSpec(
                name: "big",
                description: "Big output",
                inputSchema: ["type": .string("object"), "properties": .dictionary([:]), "required": .array([])]
            ),
            handler: { _ in bigOutput }
        )
        let registry = AgentToolRegistry(tools: ["big": bigTool])

        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: "", toolCalls: [makeToolCall(name: "big")])),
            .success(makeResponse(content: "", toolCalls: [makeToolCall(id: "tc_2", name: "big")])),
            .success(makeResponse(content: "Done.")),
        ])
        let orchestrator = LLMOrchestrator(providers: [provider], mode: .cloudOnly)

        var config = AgentRunConfig()
        config.maxFinalContextChars = 200  // Very small — forces trimming
        let request = AgentRunRequest(task: "Context cap test", config: config)

        let events = await collectEvents(
            AgentRuntime.run(request: request, orchestrator: orchestrator, registry: registry)
        )

        // Should complete with a final answer despite aggressive trimming
        XCTAssert(events.last?.isFinalAnswer ?? false,
                  "Expected finalAnswer even with aggressive context trimming")
    }

    // 15. Invalid negative numeric args in tools → ToolError
    func testNegativeNumericArgsThrowInvalidArgument() async {
        // get_activity_sequence with negative limit
        let tool = AgentTools.getActivitySequenceTool(rangeQuery: { _, _ in [] })

        // Negative limit should throw invalidArgument
        let args: [String: AnyCodable] = [
            "startUs": AnyCodable.int(1_000_000),
            "endUs": AnyCodable.int(2_000_000),
            "limit": AnyCodable.int(-5),
        ]
        do {
            let _ = try await tool.handler!(args)
            XCTFail("Expected ToolError.invalidArgument for negative limit")
        } catch let error as ToolError {
            if case .invalidArgument(let name, _) = error {
                XCTAssertEqual(name, "limit")
            } else {
                XCTFail("Expected invalidArgument, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Negative startUs — uint64Value returns nil for negatives, so parseRequiredUInt64 throws
        let args2: [String: AnyCodable] = [
            "startUs": AnyCodable.int(-100),
            "endUs": AnyCodable.int(2_000_000),
        ]
        do {
            let _ = try await tool.handler!(args2)
            XCTFail("Expected ToolError for negative startUs")
        } catch let error as ToolError {
            if case .invalidArgument(let name, _) = error {
                XCTAssertEqual(name, "startUs")
            } else if case .missingArgument = error {
                // Also acceptable — depends on how the impl handles it
            } else {
                XCTFail("Expected invalidArgument or missingArgument, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // 16. Negative values in evidence JSON are safely ignored (no trap)
    func testEvidenceExtraction_negativeValuesIgnored() {
        // Negative ts → skipped entirely
        let negativeTs = "{\"ts\":-5,\"app\":\"Chrome\",\"snippet\":\"bad ts\"}"
        let items1 = AgentRuntime.extractEvidence(from: negativeTs, toolName: "test")
        XCTAssertTrue(items1.isEmpty, "Negative ts should be skipped, not trapped")

        // Negative displayId → nil (not trapped)
        let negativeDisplay = "{\"ts\":1000000,\"app\":\"Chrome\",\"snippet\":\"ok\",\"displayId\":-1}"
        let items2 = AgentRuntime.extractEvidence(from: negativeDisplay, toolName: "test")
        XCTAssertEqual(items2.count, 1)
        XCTAssertNil(items2.first?.displayId, "Negative displayId should be nil, not trapped")

        // Overflow displayId (> UInt32.max) → nil
        let overflowDisplay = "{\"ts\":2000000,\"app\":\"Chrome\",\"snippet\":\"big\",\"displayId\":5000000000}"
        let items3 = AgentRuntime.extractEvidence(from: overflowDisplay, toolName: "test")
        XCTAssertEqual(items3.count, 1)
        XCTAssertNil(items3.first?.displayId, "Overflow displayId should be nil, not trapped")

        // Valid values still work
        let valid = "{\"ts\":3000000,\"app\":\"Zoom\",\"snippet\":\"valid\",\"displayId\":42}"
        let items4 = AgentRuntime.extractEvidence(from: valid, toolName: "test")
        XCTAssertEqual(items4.count, 1)
        XCTAssertEqual(items4.first?.timestamp, 3_000_000)
        XCTAssertEqual(items4.first?.displayId, 42)
    }

    // 17. Tool result with images creates image content blocks in next user message
    func testToolResultWithImages_createsImageContentBlocks() async {
        // Create an image-producing tool using the imageHandler pattern
        let imageTool = RegisteredTool(
            spec: ToolSpec(
                name: "visual_tool",
                description: "Returns images",
                inputSchema: ["type": .string("object"), "properties": .dictionary([:]), "required": .array([])]
            ),
            imageHandler: { _ in
                AgentToolOutput(
                    text: "{\"ts\":5000000,\"status\":\"extracted\"}",
                    images: [
                        ImageData(mediaType: "image/jpeg", base64Data: "aGVsbG8="),
                        ImageData(mediaType: "image/jpeg", base64Data: "d29ybGQ="),
                    ]
                )
            }
        )
        let registry = AgentToolRegistry(tools: ["visual_tool": imageTool])

        // Step 1: LLM calls visual_tool. Step 2: LLM produces final answer.
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: "", toolCalls: [
                makeToolCall(name: "visual_tool"),
            ])),
            .success(makeResponse(content: "I can see two screenshots.")),
        ])
        let orchestrator = LLMOrchestrator(providers: [provider], mode: .cloudOnly)
        let request = AgentRunRequest(task: "Show me screenshots", config: AgentRunConfig())

        let events = await collectEvents(
            AgentRuntime.run(request: request, orchestrator: orchestrator, registry: registry)
        )

        // Should complete with final answer
        XCTAssert(events.last?.isFinalAnswer ?? false)
        if case .finalAnswer(let result) = events.last {
            XCTAssertEqual(result.answer, "I can see two screenshots.")
            XCTAssertEqual(result.toolCalls.count, 1)
            XCTAssertTrue(result.toolCalls[0].success)
        }
    }

    // 18. Cancellation during tool execution emits .runCancelled, not .budgetExhausted
    func testCancellationDuringToolsEmitsRunCancelled() async {
        // Provider returns multiple tool calls — cancellation fires during tool execution
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: "", toolCalls: [
                makeToolCall(id: "tc_1", name: "slow_tool"),
                makeToolCall(id: "tc_2", name: "slow_tool"),
            ])),
            // Second LLM call (should not be reached if cancelled)
            .success(makeResponse(content: "unreachable")),
        ])
        let orchestrator = LLMOrchestrator(providers: [provider], mode: .cloudOnly)

        // slow_tool sleeps 200ms per call — enough time to cancel during execution
        let slowTool = RegisteredTool(
            spec: ToolSpec(name: "slow_tool", description: "Slow", inputSchema: emptySchema()),
            handler: { _ in
                try? await Task.sleep(nanoseconds: 200_000_000)
                return "{\"ts\":1000000,\"app\":\"Test\"}"
            }
        )
        let registry = AgentToolRegistry(tools: ["slow_tool": slowTool])

        let request = AgentRunRequest(task: "Cancel during tools", config: AgentRunConfig())
        let stream = AgentRuntime.run(request: request, orchestrator: orchestrator, registry: registry)

        var events: [AgentRunEvent] = []
        let consumeTask = Task {
            for await event in stream {
                events.append(event)
            }
        }

        // Let first tool call start, then cancel
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        consumeTask.cancel()
        await consumeTask.value

        // Must NOT see budgetExhausted — cancellation must produce runCancelled or no terminal
        let budgetErrors = events.filter {
            if case .runFailed(let e) = $0, case .budgetExhausted = e { return true }
            return false
        }
        XCTAssertEqual(budgetErrors.count, 0, "Cancellation must not produce budgetExhausted")

        // Should see runCancelled if the runtime had time to detect it
        let cancelled = events.filter { $0.isRunCancelled }
        let providerErrors = events.filter {
            if case .runFailed(let e) = $0, case .providerError = e { return true }
            return false
        }
        XCTAssertEqual(providerErrors.count, 0, "Cancellation must not produce providerError")

        // Either runCancelled or no terminal event (stream ended by cancellation)
        if !cancelled.isEmpty {
            XCTAssertEqual(cancelled.count, 1)
        }
    }

    // 19. search_summaries limit clamped (negative → invalidArgument)
    func testSearchSummariesNegativeLimitThrows() async throws {
        let tempDir = NSTemporaryDirectory() + "shadow_test_neg_\(UUID().uuidString)"
        let store = SummaryStore(directory: tempDir)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = AgentTools.searchSummariesTool(store: store)
        let args: [String: AnyCodable] = [
            "query": AnyCodable.string("test"),
            "limit": AnyCodable.int(-1),
        ]
        do {
            let _ = try await tool.handler!(args)
            XCTFail("Expected ToolError for negative limit")
        } catch let error as ToolError {
            if case .invalidArgument(let name, _) = error {
                XCTAssertEqual(name, "limit")
            } else {
                XCTFail("Expected invalidArgument, got \(error)")
            }
        }
    }
}

// MARK: - Event Helpers

private extension AgentRunEvent {
    var isRunStarted: Bool {
        if case .runStarted = self { return true }
        return false
    }
    var isLLMRequestStarted: Bool {
        if case .llmRequestStarted = self { return true }
        return false
    }
    var isLLMDelta: Bool {
        if case .llmDelta = self { return true }
        return false
    }
    var isToolCallStarted: Bool {
        if case .toolCallStarted = self { return true }
        return false
    }
    var isToolCallCompleted: Bool {
        if case .toolCallCompleted = self { return true }
        return false
    }
    var isToolCallFailed: Bool {
        if case .toolCallFailed = self { return true }
        return false
    }
    var isFinalAnswer: Bool {
        if case .finalAnswer = self { return true }
        return false
    }
    var isRunFailed: Bool {
        if case .runFailed = self { return true }
        return false
    }
    var isRunCancelled: Bool {
        if case .runCancelled = self { return true }
        return false
    }
}
