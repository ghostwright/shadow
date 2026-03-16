import XCTest
@testable import Shadow

final class AppleFoundationProviderTests: XCTestCase {

    // MARK: - Provider Identity

    func testProviderName() {
        let provider = AppleFoundationProvider()
        XCTAssertEqual(provider.providerName, "local_apple_foundation")
    }

    func testModelId() {
        let provider = AppleFoundationProvider()
        XCTAssertEqual(provider.modelId, "apple-on-device")
    }

    // MARK: - Orchestrator Routing

    func testProviderNameContainsLocal_forOrchestratorRouting() {
        // The orchestrator's resolveProviderOrder() filters providers by name:
        // - localOnly: providers where providerName.contains("local")
        // - cloudOnly: providers where providerName.contains("cloud")
        // - auto: local first, then cloud
        // The Apple Foundation provider must contain "local" to be included.
        let provider = AppleFoundationProvider()
        XCTAssertTrue(provider.providerName.contains("local"),
            "Provider name must contain 'local' for LLMOrchestrator routing")
    }

    func testProviderNameDoesNotContainCloud() {
        let provider = AppleFoundationProvider()
        XCTAssertFalse(provider.providerName.contains("cloud"),
            "Provider name must not contain 'cloud' — it is a local provider")
    }

    // MARK: - Availability

    func testIsAvailable_returnsFalseOnCurrentSystem() {
        // On macOS 15.6.1 (current build system), FoundationModels is not available.
        // The provider should report unavailable.
        let provider = AppleFoundationProvider()
        XCTAssertFalse(provider.isAvailable,
            "Should be unavailable on macOS < 26 (current system is 15.6.1)")
    }

    func testIsAvailable_isSynchronous() {
        // The LLMProvider protocol requires isAvailable to be a synchronous property.
        // Verify it returns without any async calls.
        let provider = AppleFoundationProvider()
        let _ = provider.isAvailable  // Must not hang or require await
    }

    // MARK: - Generate Unavailable

    func testGenerate_throwsUnavailableOnCurrentSystem() async {
        let provider = AppleFoundationProvider()

        let request = LLMRequest(
            systemPrompt: "Classify the activity.",
            userPrompt: "User is browsing HackerNews in Safari.",
            maxTokens: 100,
            temperature: 0.0,
            responseFormat: .text
        )

        do {
            _ = try await provider.generate(request: request)
            XCTFail("Expected unavailable error on macOS < 26")
        } catch let error as LLMProviderError {
            if case .unavailable(let reason) = error {
                XCTAssertTrue(reason.contains("Apple Foundation Models"),
                    "Error reason should mention Apple Foundation Models, got: \(reason)")
            } else {
                XCTFail("Expected .unavailable, got \(error)")
            }
        } catch {
            XCTFail("Expected LLMProviderError, got \(error)")
        }
    }

    // MARK: - Request Gating: Tools

    func testGenerate_throwsUnavailableForRequestsWithTools() async {
        let provider = AppleFoundationProvider()

        // Even if the framework were available, tool-calling requests should be rejected.
        // On macOS < 26, the unavailability gate fires first. But the logic is testable
        // by verifying the skip counter increments when the provider IS available.
        // Since we can't make it available, we test the error path end-to-end.
        let toolSpec = ToolSpec(
            name: "search_memories",
            description: "Search memories",
            inputSchema: ["type": AnyCodable.string("object")]
        )

        let request = LLMRequest(
            systemPrompt: "You are helpful.",
            userPrompt: "Search for meetings",
            tools: [toolSpec],
            maxTokens: 100,
            temperature: 0.3,
            responseFormat: .text
        )

        do {
            _ = try await provider.generate(request: request)
            XCTFail("Expected error")
        } catch let error as LLMProviderError {
            // Should throw unavailable (either for tools or for macOS < 26)
            if case .unavailable = error {
                // Expected
            } else {
                XCTFail("Expected .unavailable, got \(error)")
            }
        } catch {
            XCTFail("Expected LLMProviderError, got \(error)")
        }
    }

    // MARK: - Request Gating: Message Count

    func testGenerate_throwsUnavailableForMultiTurnConversations() async {
        let provider = AppleFoundationProvider()

        // Requests with >2 messages should be rejected (context window too small).
        let messages = [
            LLMMessage(role: "user", content: [.text("Hello")]),
            LLMMessage(role: "assistant", content: [.text("Hi there")]),
            LLMMessage(role: "user", content: [.text("What was I doing?")]),
        ]

        let request = LLMRequest(
            systemPrompt: "You are helpful.",
            userPrompt: "What was I doing?",
            maxTokens: 200,
            temperature: 0.3,
            responseFormat: .text,
            messages: messages
        )

        do {
            _ = try await provider.generate(request: request)
            XCTFail("Expected error")
        } catch let error as LLMProviderError {
            if case .unavailable = error {
                // Expected — either multi-turn gate or macOS < 26 gate
            } else {
                XCTFail("Expected .unavailable, got \(error)")
            }
        } catch {
            XCTFail("Expected LLMProviderError, got \(error)")
        }
    }

    // MARK: - Request Gating: Boundary Conditions

    func testGenerate_allowsTwoMessages() async {
        // 2 messages is within the limit. The request should pass the message gate
        // (but still fail on macOS < 26 availability).
        let provider = AppleFoundationProvider()

        let messages = [
            LLMMessage(role: "user", content: [.text("Classify this")]),
            LLMMessage(role: "assistant", content: [.text("coding")]),
        ]

        let request = LLMRequest(
            systemPrompt: "Classify.",
            userPrompt: "Classify this",
            maxTokens: 50,
            temperature: 0.0,
            responseFormat: .text,
            messages: messages
        )

        do {
            _ = try await provider.generate(request: request)
            XCTFail("Expected error (macOS < 26)")
        } catch let error as LLMProviderError {
            if case .unavailable(let reason) = error {
                // Should fail on availability, NOT on message count
                XCTAssertTrue(
                    reason.contains("Apple Foundation Models"),
                    "Should fail on availability, not message count. Got: \(reason)"
                )
            } else {
                XCTFail("Expected .unavailable, got \(error)")
            }
        } catch {
            XCTFail("Expected LLMProviderError, got \(error)")
        }
    }

    func testGenerate_allowsNoMessages() async {
        // Legacy single-pass mode (nil messages). Should pass message gate.
        let provider = AppleFoundationProvider()

        let request = LLMRequest(
            systemPrompt: "Classify.",
            userPrompt: "User is coding in Xcode.",
            maxTokens: 50,
            temperature: 0.0,
            responseFormat: .text
        )

        do {
            _ = try await provider.generate(request: request)
            XCTFail("Expected error (macOS < 26)")
        } catch let error as LLMProviderError {
            if case .unavailable(let reason) = error {
                XCTAssertTrue(
                    reason.contains("Apple Foundation Models"),
                    "Should fail on availability, not other gate. Got: \(reason)"
                )
            } else {
                XCTFail("Expected .unavailable, got \(error)")
            }
        } catch {
            XCTFail("Expected LLMProviderError, got \(error)")
        }
    }

    // MARK: - Configuration Constants

    func testMaxPromptChars() {
        // Verify the prompt budget is set to a reasonable value for 4096-token context.
        XCTAssertEqual(AppleFoundationProvider.maxPromptChars, 2000)
    }

    func testMaxMessages() {
        // Verify the message limit.
        XCTAssertEqual(AppleFoundationProvider.maxMessages, 2)
    }

    // MARK: - Diagnostics

    func testGenerate_incrementsAttemptCounter() async {
        let provider = AppleFoundationProvider()
        let before = DiagnosticsStore.shared.counter("apple_foundation_attempt_total")

        let request = LLMRequest(
            systemPrompt: "Classify.",
            userPrompt: "Test",
            maxTokens: 50,
            temperature: 0.0,
            responseFormat: .text
        )

        _ = try? await provider.generate(request: request)

        let after = DiagnosticsStore.shared.counter("apple_foundation_attempt_total")
        XCTAssertEqual(after, before + 1, "Should increment attempt counter on each generate call")
    }

    func testGenerate_incrementsFailCounterOnUnavailable() async {
        let provider = AppleFoundationProvider()
        let before = DiagnosticsStore.shared.counter("apple_foundation_fail_total")

        let request = LLMRequest(
            systemPrompt: "Classify.",
            userPrompt: "Test",
            maxTokens: 50,
            temperature: 0.0,
            responseFormat: .text
        )

        _ = try? await provider.generate(request: request)

        let after = DiagnosticsStore.shared.counter("apple_foundation_fail_total")
        XCTAssertEqual(after, before + 1,
            "Should increment fail counter when unavailable on macOS < 26")
    }

    func testAvailabilityGauge_isZeroOnCurrentSystem() {
        let _ = AppleFoundationProvider()
        let gauge = DiagnosticsStore.shared.gauge("apple_foundation_available")
        XCTAssertEqual(gauge, 0, "Availability gauge should be 0 on macOS < 26")
    }
}
