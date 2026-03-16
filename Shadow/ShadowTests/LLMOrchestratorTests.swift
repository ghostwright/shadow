import XCTest
@testable import Shadow

// MARK: - Mock LLM Provider

final class MockLLMProvider: LLMProvider, @unchecked Sendable {
    let providerName: String
    let modelId: String
    var isAvailable: Bool
    var result: Result<LLMResponse, LLMProviderError>
    var generateCallCount = 0

    init(
        name: String,
        modelId: String = "mock-model",
        available: Bool = true,
        result: Result<LLMResponse, LLMProviderError> = .success(MockLLMProvider.defaultResponse(provider: "mock"))
    ) {
        self.providerName = name
        self.modelId = modelId
        self.isAvailable = available
        self.result = result
    }

    func generate(request: LLMRequest) async throws -> LLMResponse {
        generateCallCount += 1
        switch result {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }

    static func defaultResponse(provider: String = "mock", model: String = "mock-model") -> LLMResponse {
        LLMResponse(
            content: "test content",
            toolCalls: [],
            provider: provider,
            modelId: model,
            inputTokens: 100,
            outputTokens: 50,
            latencyMs: 150
        )
    }
}

// MARK: - Orchestrator Tests

final class LLMOrchestratorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DiagnosticsStore.shared.resetCounters()
    }

    private func makeRequest() -> LLMRequest {
        LLMRequest(
            systemPrompt: "You are a test assistant.",
            userPrompt: "Say hello.",
            tools: [],
            maxTokens: 100,
            temperature: 0.3,
            responseFormat: .text
        )
    }

    // MARK: - 1. localOnly uses local and never cloud

    func testLocalOnly_usesLocal_neverCloud() async throws {
        let local = MockLLMProvider(
            name: "local_mlx",
            result: .success(MockLLMProvider.defaultResponse(provider: "local_mlx"))
        )
        let cloud = MockLLMProvider(
            name: "cloud_claude",
            result: .success(MockLLMProvider.defaultResponse(provider: "cloud_claude"))
        )
        let orchestrator = LLMOrchestrator(providers: [local, cloud], mode: .localOnly)

        let response = try await orchestrator.generate(request: makeRequest())

        XCTAssertEqual(response.provider, "local_mlx")
        XCTAssertEqual(local.generateCallCount, 1)
        XCTAssertEqual(cloud.generateCallCount, 0)

        let snap = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(snap.counters["summary_local_attempt_total"], 1)
        XCTAssertEqual(snap.counters["summary_local_success_total"], 1)
        XCTAssertEqual(snap.counters["summary_cloud_attempt_total", default: 0], 0)
    }

    // MARK: - 2. cloudOnly uses cloud

    func testCloudOnly_usesCloud() async throws {
        let local = MockLLMProvider(
            name: "local_mlx",
            result: .success(MockLLMProvider.defaultResponse(provider: "local_mlx"))
        )
        let cloud = MockLLMProvider(
            name: "cloud_claude",
            result: .success(MockLLMProvider.defaultResponse(provider: "cloud_claude"))
        )
        let orchestrator = LLMOrchestrator(providers: [local, cloud], mode: .cloudOnly)

        let response = try await orchestrator.generate(request: makeRequest())

        XCTAssertEqual(response.provider, "cloud_claude")
        XCTAssertEqual(local.generateCallCount, 0)
        XCTAssertEqual(cloud.generateCallCount, 1)

        let snap = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(snap.counters["summary_cloud_attempt_total"], 1)
        XCTAssertEqual(snap.counters["summary_cloud_success_total"], 1)
    }

    // MARK: - 3. auto prefers local, falls back cloud

    func testAuto_prefersLocal_fallsBackCloud() async throws {
        let local = MockLLMProvider(
            name: "local_mlx",
            result: .failure(.unavailable(reason: "Model not loaded"))
        )
        let cloud = MockLLMProvider(
            name: "cloud_claude",
            result: .success(MockLLMProvider.defaultResponse(provider: "cloud_claude"))
        )
        let orchestrator = LLMOrchestrator(providers: [local, cloud], mode: .auto)

        let response = try await orchestrator.generate(request: makeRequest())

        XCTAssertEqual(response.provider, "cloud_claude")
        XCTAssertEqual(local.generateCallCount, 1)
        XCTAssertEqual(cloud.generateCallCount, 1)

        let snap = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(snap.counters["summary_local_attempt_total"], 1)
        XCTAssertEqual(snap.counters["summary_local_fail_total"], 1)
        XCTAssertEqual(snap.counters["summary_cloud_attempt_total"], 1)
        XCTAssertEqual(snap.counters["summary_cloud_success_total"], 1)
    }

    // MARK: - 4. cloud blocked without consent

    func testCloudBlockedWithoutConsent() async {
        let cloud = MockLLMProvider(
            name: "cloud_claude",
            result: .failure(.consentRequired)
        )
        let orchestrator = LLMOrchestrator(providers: [cloud], mode: .cloudOnly)

        do {
            _ = try await orchestrator.generate(request: makeRequest())
            XCTFail("Expected error to be thrown")
        } catch let error as LLMProviderError {
            guard case .unavailable = error else {
                XCTFail("Expected .unavailable, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        let snap = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(snap.counters["summary_cloud_blocked_no_consent_total"], 1)
    }

    // MARK: - 5. timeout propagates (terminal)

    func testTimeout_propagates() async {
        let local = MockLLMProvider(
            name: "local_mlx",
            result: .failure(.timeout)
        )
        let cloud = MockLLMProvider(
            name: "cloud_claude",
            result: .success(MockLLMProvider.defaultResponse(provider: "cloud_claude"))
        )
        let orchestrator = LLMOrchestrator(providers: [local, cloud], mode: .auto)

        do {
            _ = try await orchestrator.generate(request: makeRequest())
            XCTFail("Expected timeout error to propagate")
        } catch let error as LLMProviderError {
            guard case .timeout = error else {
                XCTFail("Expected .timeout, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Cloud should NOT have been tried (timeout is terminal)
        XCTAssertEqual(cloud.generateCallCount, 0)
    }

    // MARK: - 6. both unavailable → typed error

    func testBothUnavailable_typedError() async {
        let local = MockLLMProvider(
            name: "local_mlx",
            available: false
        )
        let cloud = MockLLMProvider(
            name: "cloud_claude",
            available: false
        )
        let orchestrator = LLMOrchestrator(providers: [local, cloud], mode: .auto)

        do {
            _ = try await orchestrator.generate(request: makeRequest())
            XCTFail("Expected error to be thrown")
        } catch let error as LLMProviderError {
            guard case .unavailable = error else {
                XCTFail("Expected .unavailable, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        let snap = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(snap.counters["summary_fail_total"], 1)
    }

    // MARK: - 7. Consent blocked — reachable in runtime (Fix 1 verification)

    /// Cloud provider with API key (isAvailable=true) but consent=false.
    /// generate() throws .consentRequired → orchestrator catches → counter increments → exhausts providers.
    func testConsentBlocked_reachableInRuntime() async {
        let cloud = MockLLMProvider(
            name: "cloud_claude",
            available: true,  // isAvailable=true (API key exists)
            result: .failure(.consentRequired)  // but consent denied
        )
        let orchestrator = LLMOrchestrator(providers: [cloud], mode: .cloudOnly)

        do {
            _ = try await orchestrator.generate(request: makeRequest())
            XCTFail("Expected error to be thrown")
        } catch let error as LLMProviderError {
            guard case .unavailable = error else {
                XCTFail("Expected .unavailable (all providers exhausted), got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // The consent-blocked counter MUST increment (this is what Fix 1 enables)
        let snap = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(snap.counters["summary_cloud_blocked_no_consent_total"], 1)
        // generate() was called (not skipped by isAvailable check)
        XCTAssertEqual(cloud.generateCallCount, 1)
    }

    // MARK: - 8. Malformed output → tries next provider

    func testMalformedOutput_triesNextProvider() async throws {
        let local = MockLLMProvider(
            name: "local_mlx",
            result: .failure(.malformedOutput(detail: "invalid JSON"))
        )
        let cloud = MockLLMProvider(
            name: "cloud_claude",
            result: .success(MockLLMProvider.defaultResponse(provider: "cloud_claude", model: "haiku"))
        )
        let orchestrator = LLMOrchestrator(providers: [local, cloud], mode: .auto)

        let response = try await orchestrator.generate(request: makeRequest())

        XCTAssertEqual(response.provider, "cloud_claude")
        XCTAssertEqual(local.generateCallCount, 1)
        XCTAssertEqual(cloud.generateCallCount, 1)

        let snap = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(snap.counters["summary_schema_invalid_total"], 1)
    }

    // MARK: - 9. Provider attribution matches response

    func testProviderAttribution_matchesResponse() async throws {
        let customResponse = LLMResponse(
            content: "summary text",
            toolCalls: [],
            provider: "cloud_claude",
            modelId: "claude-opus-4-6",
            inputTokens: 500,
            outputTokens: 200,
            latencyMs: 1200
        )
        let cloud = MockLLMProvider(
            name: "cloud_claude",
            modelId: "claude-opus-4-6",
            result: .success(customResponse)
        )
        let orchestrator = LLMOrchestrator(providers: [cloud], mode: .cloudOnly)

        let response = try await orchestrator.generate(request: makeRequest())

        // The response carries the actual provider/model that generated it
        XCTAssertEqual(response.provider, "cloud_claude")
        XCTAssertEqual(response.modelId, "claude-opus-4-6")
        // These should match exactly what the provider returned
        XCTAssertEqual(response.inputTokens, 500)
        XCTAssertEqual(response.outputTokens, 200)
    }

    // MARK: - 10. Provider gauge set on success (Fix 3 verification)

    func testProviderGauge_setOnSuccess() async throws {
        let cloud = MockLLMProvider(
            name: "cloud_claude",
            modelId: "claude-haiku-4-5",
            result: .success(LLMResponse(
                content: "ok",
                toolCalls: [],
                provider: "cloud_claude",
                modelId: "claude-haiku-4-5",
                inputTokens: 10,
                outputTokens: 5,
                latencyMs: 100
            ))
        )
        let orchestrator = LLMOrchestrator(providers: [cloud], mode: .cloudOnly)

        _ = try await orchestrator.generate(request: makeRequest())

        let snap = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(snap.stringGauges["llm_active_provider"], "cloud_claude")
        XCTAssertEqual(snap.stringGauges["llm_active_model_id"], "claude-haiku-4-5")
    }
}
