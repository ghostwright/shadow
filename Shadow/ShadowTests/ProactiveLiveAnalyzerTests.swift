import XCTest
@testable import Shadow

// MARK: - Mock Provider

/// Returns different responses on successive generate() calls.
private final class MockSequencedProvider: LLMProvider, @unchecked Sendable {
    let providerName = "mock_provider"
    let modelId = "mock-model"
    var isAvailable: Bool = true
    private var responses: [Result<LLMResponse, LLMProviderError>]
    private var callIndex = 0
    var generateCallCount: Int { callIndex }

    init(responses: [Result<LLMResponse, LLMProviderError>]) {
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

// MARK: - Helpers

private func makeResponse(
    content: String,
    toolCalls: [ToolCall] = []
) -> LLMResponse {
    LLMResponse(
        content: content,
        toolCalls: toolCalls,
        provider: "mock",
        modelId: "mock-model",
        inputTokens: 50,
        outputTokens: 30,
        latencyMs: 100
    )
}

private func makeToolCall(id: String = "tc_1", name: String, args: [String: AnyCodable] = [:]) -> ToolCall {
    ToolCall(id: id, name: name, arguments: args)
}

private func echoRegistry() -> AgentToolRegistry {
    let tool = RegisteredTool(
        spec: ToolSpec(
            name: "echo",
            description: "Echo tool",
            inputSchema: ["type": .string("object"), "properties": .dictionary([:]), "required": .array([])]
        ),
        handler: { args in
            let text = args["text"]?.stringValue ?? "echoed"
            return "{\"ts\":1708300000000000,\"app\":\"TestApp\",\"snippet\":\"\(text)\",\"displayId\":1}"
        }
    )
    return AgentToolRegistry(tools: ["echo": tool])
}

private func emptyRegistry() -> AgentToolRegistry {
    AgentToolRegistry(tools: [:])
}

private func makeLiveContext(
    app: String = "Xcode",
    window: String = "MyProject.swift",
    url: String? = nil,
    displayId: UInt32? = 1,
    activeSeconds: Int = 120,
    recentApps: [ProactiveLiveAnalyzer.RecentAppEntry] = []
) -> ProactiveLiveAnalyzer.LiveContextSnapshot {
    ProactiveLiveAnalyzer.LiveContextSnapshot(
        currentApp: app,
        windowTitle: window,
        url: url,
        displayId: displayId,
        activeSeconds: activeSeconds,
        recentApps: recentApps
    )
}

// MARK: - Tests

final class ProactiveLiveAnalyzerTests: XCTestCase {

    private var tempDir: String!
    private var proactiveStore: ProactiveStore!
    private var trustTuner: TrustTuner!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "LiveAnalyzer-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        proactiveStore = ProactiveStore(baseDir: tempDir)
        trustTuner = TrustTuner(baseDir: tempDir)
        DiagnosticsStore.shared.resetCounters()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Fast Tick

    func testFastTick_emptyResponseReturnsEmpty() async throws {
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: "{\"suggestions\": []}"))
        ])

        let results = try await ProactiveLiveAnalyzer.fastTick(
            toolRegistry: emptyRegistry(),
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { try await provider.generate(request: $0) },
            liveContext: makeLiveContext(),
            screenshot: nil,
            lastPushState: nil
        )

        XCTAssertTrue(results.isEmpty, "Empty suggestions array should return empty")
    }

    func testFastTick_parsesValidSuggestion() async throws {
        let json = """
        {"suggestions": [{"type": "followup", "title": "Review PR from Alice", \
        "body": "Alice opened PR #42 an hour ago.", "whyNow": "You switched to GitHub", \
        "confidence": 0.85, "evidence": [{"timestamp": 1708300000000000, "app": "Safari", \
        "sourceKind": "search_hybrid", "snippet": "PR #42 opened"}]}]}
        """
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: json))
        ])

        let results = try await ProactiveLiveAnalyzer.fastTick(
            toolRegistry: emptyRegistry(),
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { try await provider.generate(request: $0) },
            liveContext: makeLiveContext(app: "Safari", window: "GitHub"),
            screenshot: nil,
            lastPushState: nil
        )

        XCTAssertFalse(results.isEmpty, "Should parse and persist the suggestion")
        XCTAssertEqual(results.first?.title, "Review PR from Alice")
        XCTAssertEqual(results.first?.type, .followup)
    }

    func testFastTick_evidenceFromToolOutputs() async throws {
        // Step 1: LLM requests a tool call
        // Step 2: LLM returns suggestion using tool data
        let toolCallResponse = makeResponse(
            content: "",
            toolCalls: [makeToolCall(name: "echo", args: ["text": .string("pr_data")])]
        )
        let finalResponse = makeResponse(content: """
        {"suggestions": [{"type": "reminder", "title": "Follow up on PR", \
        "body": "Tool found relevant context.", "whyNow": "Context match", \
        "confidence": 0.80, "evidence": []}]}
        """)

        let provider = MockSequencedProvider(responses: [
            .success(toolCallResponse),
            .success(finalResponse)
        ])

        let results = try await ProactiveLiveAnalyzer.fastTick(
            toolRegistry: echoRegistry(),
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { try await provider.generate(request: $0) },
            liveContext: makeLiveContext(),
            screenshot: nil,
            lastPushState: nil
        )

        // Should use fallback evidence from tool outputs since LLM returned empty evidence
        XCTAssertFalse(results.isEmpty)
        if let first = results.first {
            XCTAssertFalse(first.evidence.isEmpty, "Should have evidence from tool outputs")
            XCTAssertEqual(first.evidence.first?.app, "TestApp")
        }
    }

    func testFastTick_budgetEnforced() async throws {
        // LLM keeps requesting tool calls — should stop at budget limit
        let toolCallResponse = makeResponse(
            content: "",
            toolCalls: [makeToolCall(name: "echo", args: ["text": .string("loop")])]
        )
        // Return tool call many times — but fast tick budget is 5 steps / 10 tool calls
        let provider = MockSequencedProvider(responses: [
            .success(toolCallResponse),
            .success(toolCallResponse),
            .success(toolCallResponse),
            .success(toolCallResponse),
            .success(toolCallResponse),
            .success(toolCallResponse),
            .success(makeResponse(content: "{\"suggestions\": []}"))
        ])

        let results = try await ProactiveLiveAnalyzer.fastTick(
            toolRegistry: echoRegistry(),
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { try await provider.generate(request: $0) },
            liveContext: makeLiveContext(),
            screenshot: nil,
            lastPushState: nil
        )

        // Should have stopped at budget, not crashed
        XCTAssertEqual(provider.generateCallCount, 5, "Should stop at maxSteps=5")
        XCTAssertTrue(results.isEmpty)
    }

    func testFastTick_policyScoreFilters() async throws {
        // Low confidence → should be dropped by policy
        let json = """
        {"suggestions": [{"type": "followup", "title": "Weak suggestion", \
        "body": "Not very confident.", "whyNow": "Maybe?", \
        "confidence": 0.15, "evidence": [{"timestamp": 1708300000000000, "app": "Xcode", \
        "sourceKind": "search", "snippet": "weak"}]}]}
        """
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: json))
        ])

        let results = try await ProactiveLiveAnalyzer.fastTick(
            toolRegistry: emptyRegistry(),
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { try await provider.generate(request: $0) },
            liveContext: makeLiveContext(),
            screenshot: nil,
            lastPushState: nil
        )

        // 0.15 confidence → score will be very low → dropped
        XCTAssertTrue(results.isEmpty, "Low-confidence suggestion should be dropped by policy")
    }

    func testFastTick_noEvidenceDropped() async throws {
        // No evidence at all → hard gate blocks
        let json = """
        {"suggestions": [{"type": "followup", "title": "No evidence", \
        "body": "Made this up.", "whyNow": "Just because", \
        "confidence": 0.95}]}
        """
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: json))
        ])

        let results = try await ProactiveLiveAnalyzer.fastTick(
            toolRegistry: emptyRegistry(),
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { try await provider.generate(request: $0) },
            liveContext: makeLiveContext(),
            screenshot: nil,
            lastPushState: nil
        )

        XCTAssertTrue(results.isEmpty, "Suggestion without evidence should be dropped")
    }

    func testFastTick_maxOneSuggestion() async throws {
        // LLM returns 3 suggestions — fast tick should cap at 1
        let json = """
        {"suggestions": [
            {"type": "followup", "title": "First", "body": "A", "whyNow": "A", "confidence": 0.85, \
             "evidence": [{"timestamp": 1708300000000000, "app": "Xcode", "sourceKind": "s", "snippet": "a"}]},
            {"type": "reminder", "title": "Second", "body": "B", "whyNow": "B", "confidence": 0.80, \
             "evidence": [{"timestamp": 1708300000000000, "app": "Xcode", "sourceKind": "s", "snippet": "b"}]},
            {"type": "meeting_prep", "title": "Third", "body": "C", "whyNow": "C", "confidence": 0.75, \
             "evidence": [{"timestamp": 1708300000000000, "app": "Xcode", "sourceKind": "s", "snippet": "c"}]}
        ]}
        """
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: json))
        ])

        let results = try await ProactiveLiveAnalyzer.fastTick(
            toolRegistry: emptyRegistry(),
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { try await provider.generate(request: $0) },
            liveContext: makeLiveContext(),
            screenshot: nil,
            lastPushState: nil
        )

        XCTAssertLessThanOrEqual(results.count, 1, "Fast tick should produce at most 1 suggestion")
    }

    // MARK: - Deep Tick

    func testDeepTick_emptyResponseReturnsEmpty() async throws {
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: "{\"suggestions\": []}"))
        ])
        let contextStore = ContextStore(baseDir: tempDir)

        let results = try await ProactiveLiveAnalyzer.deepTick(
            toolRegistry: emptyRegistry(),
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { try await provider.generate(request: $0) },
            liveContext: makeLiveContext()
        )

        XCTAssertTrue(results.isEmpty)
    }

    func testDeepTick_multipleSuggestions() async throws {
        let json = """
        {"suggestions": [
            {"type": "workload_pattern", "title": "Long coding session", "body": "4 hours without a break.", \
             "whyNow": "Pattern detected", "confidence": 0.75, \
             "evidence": [{"timestamp": 1708300000000000, "app": "Xcode", "sourceKind": "activity", "snippet": "4h continuous"}]},
            {"type": "followup", "title": "Respond to Alice", "body": "She messaged 2h ago.", \
             "whyNow": "Unread message", "confidence": 0.70, \
             "evidence": [{"timestamp": 1708290000000000, "app": "Slack", "sourceKind": "transcript", "snippet": "Alice: hey"}]}
        ]}
        """
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: json))
        ])
        let contextStore = ContextStore(baseDir: tempDir)

        let results = try await ProactiveLiveAnalyzer.deepTick(
            toolRegistry: emptyRegistry(),
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { try await provider.generate(request: $0) },
            liveContext: makeLiveContext()
        )

        XCTAssertEqual(results.count, 2, "Deep tick can produce multiple suggestions")
    }

    func testDeepTick_maxThreeSuggestions() async throws {
        let json = """
        {"suggestions": [
            {"type": "followup", "title": "A", "body": "A", "whyNow": "A", "confidence": 0.80, \
             "evidence": [{"timestamp": 1, "app": "X", "sourceKind": "s", "snippet": "a"}]},
            {"type": "followup", "title": "B", "body": "B", "whyNow": "B", "confidence": 0.80, \
             "evidence": [{"timestamp": 2, "app": "X", "sourceKind": "s", "snippet": "b"}]},
            {"type": "followup", "title": "C", "body": "C", "whyNow": "C", "confidence": 0.80, \
             "evidence": [{"timestamp": 3, "app": "X", "sourceKind": "s", "snippet": "c"}]},
            {"type": "followup", "title": "D", "body": "D", "whyNow": "D", "confidence": 0.80, \
             "evidence": [{"timestamp": 4, "app": "X", "sourceKind": "s", "snippet": "d"}]}
        ]}
        """
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: json))
        ])
        let contextStore = ContextStore(baseDir: tempDir)

        let results = try await ProactiveLiveAnalyzer.deepTick(
            toolRegistry: emptyRegistry(),
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { try await provider.generate(request: $0) },
            liveContext: makeLiveContext()
        )

        XCTAssertLessThanOrEqual(results.count, 3, "Deep tick should cap at 3 suggestions")
    }

    // MARK: - Pre-Filter

    func testPreFilter_firstRun_alwaysRuns() {
        let result = ProactiveLiveAnalyzer.shouldRunFastTick(
            liveContext: makeLiveContext(),
            lastApp: nil,
            lastWindowTitle: nil
        )
        XCTAssertTrue(result, "First run should always trigger")
    }

    func testPreFilter_sameContext_skips() {
        let result = ProactiveLiveAnalyzer.shouldRunFastTick(
            liveContext: makeLiveContext(app: "Xcode", window: "File.swift", activeSeconds: 300),
            lastApp: "Xcode",
            lastWindowTitle: "File.swift"
        )
        XCTAssertFalse(result, "Same app + same window + not stuck should skip")
    }

    func testPreFilter_differentApp_runs() {
        let result = ProactiveLiveAnalyzer.shouldRunFastTick(
            liveContext: makeLiveContext(app: "Safari", window: "Google"),
            lastApp: "Xcode",
            lastWindowTitle: "File.swift"
        )
        XCTAssertTrue(result, "Different app should trigger")
    }

    func testPreFilter_differentWindow_runs() {
        let result = ProactiveLiveAnalyzer.shouldRunFastTick(
            liveContext: makeLiveContext(app: "Xcode", window: "OtherFile.swift"),
            lastApp: "Xcode",
            lastWindowTitle: "File.swift"
        )
        XCTAssertTrue(result, "Different window title should trigger")
    }

    func testPreFilter_highSignalApp_alwaysRuns() {
        let result = ProactiveLiveAnalyzer.shouldRunFastTick(
            liveContext: makeLiveContext(app: "Slack", window: "#general", activeSeconds: 60),
            lastApp: "Slack",
            lastWindowTitle: "#general"
        )
        XCTAssertTrue(result, "High-signal app should always trigger even if nothing changed")
    }

    func testPreFilter_stuckOver30min_runs() {
        let result = ProactiveLiveAnalyzer.shouldRunFastTick(
            liveContext: makeLiveContext(app: "Xcode", window: "File.swift", activeSeconds: 2000),
            lastApp: "Xcode",
            lastWindowTitle: "File.swift"
        )
        XCTAssertTrue(result, "Over 30 min in same context should trigger (stuck signal)")
    }

    // MARK: - Scoring with Reweighted Formula

    func testReweightedFormula_reachesInbox() {
        // conf=0.8, evidence=0.8 → 0.40*0.8 + 0.30*0.8 + 0.10*0.7 + 0 - 0 = 0.63
        let input = PolicyInput(
            suggestionType: .followup,
            confidence: 0.8,
            evidenceQuality: 0.8,
            noveltyScore: 0.7,
            interruptionCost: 0,
            preferenceAffinity: 0
        )
        let score = ProactivePolicyEngine.computeScore(input, tuner: trustTuner)
        XCTAssertGreaterThan(score, 0.35, "With reweighted formula, moderate inputs should reach inbox threshold")
    }

    func testReweightedFormula_reachesPush() {
        // Perfect inputs: 0.40*1 + 0.30*1 + 0.10*1 + 0.10*0.5 - 0.10*0 = 0.85
        let input = PolicyInput(
            suggestionType: .followup,
            confidence: 1.0,
            evidenceQuality: 1.0,
            noveltyScore: 1.0,
            interruptionCost: 0,
            preferenceAffinity: 0.5
        )
        let score = ProactivePolicyEngine.computeScore(input, tuner: trustTuner)
        XCTAssertGreaterThan(score, 0.60, "Perfect inputs should exceed push threshold")
    }

    // MARK: - JSON Parsing Edge Cases

    func testParsing_markdownCodeFence() async throws {
        // LLM wraps JSON in ```json ... ```
        let content = """
        ```json
        {"suggestions": [{"type": "reminder", "title": "Test", "body": "Body.", \
        "whyNow": "Now", "confidence": 0.8, "evidence": [{"timestamp": 1708300000000000, \
        "app": "X", "sourceKind": "s", "snippet": "test"}]}]}
        ```
        """
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: content))
        ])

        let results = try await ProactiveLiveAnalyzer.fastTick(
            toolRegistry: emptyRegistry(),
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { try await provider.generate(request: $0) },
            liveContext: makeLiveContext(),
            screenshot: nil,
            lastPushState: nil
        )

        XCTAssertFalse(results.isEmpty, "Should handle markdown-wrapped JSON")
    }

    func testParsing_invalidJSON() async throws {
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: "This is not JSON at all"))
        ])

        let results = try await ProactiveLiveAnalyzer.fastTick(
            toolRegistry: emptyRegistry(),
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { try await provider.generate(request: $0) },
            liveContext: makeLiveContext(),
            screenshot: nil,
            lastPushState: nil
        )

        XCTAssertTrue(results.isEmpty, "Invalid JSON should return empty, not crash")
    }

    // MARK: - Diagnostics

    func testDiagnosticsCountersIncremented() async throws {
        let json = """
        {"suggestions": [{"type": "followup", "title": "Test", "body": "Body.", \
        "whyNow": "Now", "confidence": 0.85, "evidence": [{"timestamp": 1708300000000000, \
        "app": "Xcode", "sourceKind": "search", "snippet": "test"}]}]}
        """
        let provider = MockSequencedProvider(responses: [
            .success(makeResponse(content: json))
        ])

        _ = try await ProactiveLiveAnalyzer.fastTick(
            toolRegistry: emptyRegistry(),
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { try await provider.generate(request: $0) },
            liveContext: makeLiveContext(),
            screenshot: nil,
            lastPushState: nil
        )

        let candidateCount = DiagnosticsStore.shared.counter("proactive_candidate_total")
        XCTAssertGreaterThan(candidateCount, 0, "Should increment candidate counter")
    }
}
