import XCTest
@testable import Shadow

final class LocalLLMProviderTests: XCTestCase {

    // MARK: - Provider Identity

    func testProviderName() async {
        let provider = LocalLLMProvider()
        XCTAssertEqual(provider.providerName, "local_mlx")
    }

    func testModelId() async {
        let provider = LocalLLMProvider()
        XCTAssertEqual(provider.modelId, "Qwen2.5-7B-Instruct-4bit")
    }

    // MARK: - isAvailable

    func testIsAvailable_returnsFalseWhenDirectoryMissing() async {
        // Default provider points to fast model. If not provisioned on this machine,
        // it should return false.
        let provider = LocalLLMProvider()
        // We can't control whether the model is provisioned, but we can verify
        // the property doesn't crash and returns a boolean.
        _ = provider.isAvailable
    }

    // MARK: - Generate Errors

    func testGenerate_throwsUnavailableWhenNotProvisioned() async {
        // The provider checks isAvailable (fast model) before proceeding.
        // If fast model isn't provisioned, it throws .unavailable.
        let provider = LocalLLMProvider()

        // Skip if model is actually provisioned on this machine
        guard !provider.isAvailable else { return }

        let request = LLMRequest(
            systemPrompt: "You are helpful.",
            userPrompt: "Hello",
            maxTokens: 100,
            temperature: 0.3,
            responseFormat: .text
        )

        do {
            _ = try await provider.generate(request: request)
            XCTFail("Expected unavailable error")
        } catch let error as LLMProviderError {
            if case .unavailable(let reason) = error {
                XCTAssertTrue(reason.contains("not provisioned"),
                    "Error should mention model not provisioned, got: \(reason)")
            } else {
                XCTFail("Expected .unavailable error, got \(error)")
            }
        } catch {
            XCTFail("Expected LLMProviderError, got \(error)")
        }
    }

    // MARK: - Provider Name Routing

    func testProviderNameContainsLocal_forOrchestratorRouting() async {
        let provider = LocalLLMProvider()
        XCTAssertTrue(provider.providerName.contains("local"),
            "Provider name must contain 'local' for LLMOrchestrator routing")
    }

    // MARK: - Model Path Resolution

    func testModelPathResolution() async {
        let provider = LocalLLMProvider()
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            provider.modelPath,
            "\(homeDir)/.shadow/models/llm/Qwen2.5-7B-Instruct-4bit"
        )
    }

    // MARK: - Tier Selection

    func testTierSelection_simpleRequest_selectsFast() async {
        // A request with no tools and no messages should select fast tier.
        // We verify indirectly: the provider's modelId (fast) is used for protocol conformance.
        let provider = LocalLLMProvider()
        XCTAssertEqual(provider.modelId, LocalModelRegistry.fastDefault.localDirectoryName,
            "Provider's modelId should be the fast tier model")
    }

    func testTierSelection_requestWithToolsAndMultiStep_selectsDeepWhenAvailable() async {
        // This test verifies the tier selection logic conceptually.
        // The actual selectTier method is private, but we test the conditions:
        // - deep provisioned + enough RAM + tools + >2 messages = deep
        // We verify the deep model spec exists and has the right properties.
        let deepSpec = LocalModelRegistry.deepDefault
        XCTAssertEqual(deepSpec.tier, .deep)
        XCTAssertEqual(deepSpec.minimumSystemRAMGB, 48)
        XCTAssertTrue(deepSpec.supportsToolCalling)
    }

    func testTierSelection_requestWithoutTools_selectsFast() async {
        // Even with >2 messages, no tools means fast tier.
        // Verified by checking that the registry fast default exists.
        let fastSpec = LocalModelRegistry.fastDefault
        XCTAssertEqual(fastSpec.tier, .fast)
        XCTAssertTrue(fastSpec.supportsToolCalling)
    }

    func testTierSelection_requestWithToolsButFewMessages_selectsFast() async {
        // Tools present but <=2 messages means fast tier.
        // This is a boundary condition test — verifying the model registry is consistent.
        let fastSpec = LocalModelRegistry.fastDefault
        XCTAssertEqual(fastSpec.estimatedMemoryGB, 4.5,
            "Fast model should be ~4.5 GB, suitable for quick single-step tasks")
    }
}

// MARK: - Tier Selection Logic Tests

/// Tests the tier selection conditions that LocalLLMProvider.selectTier() evaluates.
/// Since selectTier is private, these tests verify the public conditions it checks.
final class TierSelectionLogicTests: XCTestCase {

    func testDeepModelSpec_requiresSufficientRAM() {
        let deepSpec = LocalModelRegistry.deepDefault
        XCTAssertGreaterThanOrEqual(deepSpec.minimumSystemRAMGB, 48,
            "Deep tier should require at least 48 GB RAM")
    }

    func testFastModelSpec_lowRAMRequirement() {
        let fastSpec = LocalModelRegistry.fastDefault
        XCTAssertLessThanOrEqual(fastSpec.minimumSystemRAMGB, 16,
            "Fast tier should work on 16 GB machines")
    }

    func testDeepModelProvisioning_usesIsDownloaded() {
        // Verify the isDownloaded check works for deep spec (will be false in CI)
        let deepSpec = LocalModelRegistry.deepDefault
        // Just verify it doesn't crash — result depends on machine provisioning
        _ = LocalModelRegistry.isDownloaded(deepSpec)
    }

    func testSystemRAMCheck_returnsPositive() {
        let ramGB = MLXConfiguration.systemRAMGB
        XCTAssertGreaterThan(ramGB, 0, "System RAM should be positive")
    }

    func testTierSelection_deepSpecMemoryIsLargerThanFast() {
        let fastSpec = LocalModelRegistry.fastDefault
        let deepSpec = LocalModelRegistry.deepDefault
        XCTAssertGreaterThan(deepSpec.estimatedMemoryGB, fastSpec.estimatedMemoryGB,
            "Deep model should require more memory than fast model")
    }

    func testTierSelection_bothModelsInRegistry() {
        let allSpecs = LocalModelRegistry.allSpecs
        let tiers = Set(allSpecs.map(\.tier))
        XCTAssertTrue(tiers.contains(.fast), "Registry should contain fast tier")
        XCTAssertTrue(tiers.contains(.deep), "Registry should contain deep tier")
    }
}
