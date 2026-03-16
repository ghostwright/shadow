import XCTest
@testable import Shadow

/// Tests for speculative decoding infrastructure: configuration, draft model spec,
/// readiness checks, and diagnostics metrics.
///
/// These tests validate the configuration layer and infrastructure. The actual
/// speculative generation loop is not tested because mlx-swift-lm v2.30.0 does
/// not expose the required API — `speculativeGenerate()` always returns nil.
final class SpeculativeDecoderTests: XCTestCase {

    // MARK: - Draft Model Spec

    func testDraftModelSpec_tier() {
        let spec = LocalModelRegistry.draftDefault
        XCTAssertEqual(spec.tier, .fast, "Draft model should use fast tier for path resolution")
    }

    func testDraftModelSpec_huggingFaceID() {
        let spec = LocalModelRegistry.draftDefault
        XCTAssertEqual(spec.huggingFaceID, "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
    }

    func testDraftModelSpec_localDirectoryName() {
        let spec = LocalModelRegistry.draftDefault
        XCTAssertEqual(spec.localDirectoryName, "Qwen2.5-1.5B-Instruct-4bit")
    }

    func testDraftModelSpec_estimatedMemory() {
        let spec = LocalModelRegistry.draftDefault
        XCTAssertEqual(spec.estimatedMemoryGB, 1.0,
            "Draft model should be ~1 GB — small enough to always co-provision with 7B")
    }

    func testDraftModelSpec_minimumRAM() {
        let spec = LocalModelRegistry.draftDefault
        XCTAssertEqual(spec.minimumSystemRAMGB, 8,
            "Draft model should work on machines with as little as 8 GB RAM")
    }

    func testDraftModelSpec_contextLength() {
        let spec = LocalModelRegistry.draftDefault
        XCTAssertEqual(spec.contextLength, 32768,
            "Draft model should match verifier's context length")
    }

    func testDraftModelSpec_noToolCalling() {
        let spec = LocalModelRegistry.draftDefault
        XCTAssertFalse(spec.supportsToolCalling,
            "Draft model does not need tool calling — it just proposes tokens")
    }

    func testDraftModelSpec_smallerThanFast() {
        let draft = LocalModelRegistry.draftDefault
        let fast = LocalModelRegistry.fastDefault
        XCTAssertLessThan(draft.estimatedMemoryGB, fast.estimatedMemoryGB,
            "Draft model must be smaller than the fast (verifier) model")
    }

    func testDraftModelSpec_sameModelFamily() {
        let draft = LocalModelRegistry.draftDefault
        let fast = LocalModelRegistry.fastDefault
        // Both should be Qwen2.5 family — shared tokenizer is critical for speculative decoding
        XCTAssertTrue(draft.localDirectoryName.hasPrefix("Qwen2.5"),
            "Draft model should be from the Qwen2.5 family")
        XCTAssertTrue(fast.localDirectoryName.hasPrefix("Qwen2.5"),
            "Verifier model should be from the Qwen2.5 family")
    }

    func testDraftModelSpec_notInAllSpecs() {
        // Draft is intentionally excluded from allSpecs — it's a speculative decoding
        // assistant, not a standalone tier model
        let allNames = LocalModelRegistry.allSpecs.map(\.localDirectoryName)
        XCTAssertFalse(allNames.contains("Qwen2.5-1.5B-Instruct-4bit"),
            "Draft model should NOT be in allSpecs — it's not a standalone tier")
    }

    func testDraftModelSpec_pathResolution() {
        let spec = LocalModelRegistry.draftDefault
        let path = LocalModelRegistry.modelPath(for: spec)
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(path.path, "\(homeDir)/.shadow/models/llm/Qwen2.5-1.5B-Instruct-4bit")
    }

    // MARK: - Configuration Defaults

    func testDefaultConfig_isDisabled() {
        let config = SpeculativeDecodingConfig.default
        XCTAssertFalse(config.enabled,
            "Speculative decoding should be disabled by default — API not yet available")
    }

    func testDefaultConfig_draftLength() {
        let config = SpeculativeDecodingConfig.default
        XCTAssertEqual(config.draftLength, 5,
            "Default draft length should be 5 tokens per speculative round")
    }

    func testDefaultConfig_draftSpec() {
        let config = SpeculativeDecodingConfig.default
        XCTAssertEqual(config.draftSpec.localDirectoryName, "Qwen2.5-1.5B-Instruct-4bit")
    }

    func testDefaultConfig_verifierSpec() {
        let config = SpeculativeDecodingConfig.default
        XCTAssertEqual(config.verifierSpec.localDirectoryName, "Qwen2.5-7B-Instruct-4bit")
    }

    func testDefaultConfig_notReady_becauseDisabled() {
        let config = SpeculativeDecodingConfig.default
        XCTAssertFalse(config.isReady,
            "Default config should not be ready — it is disabled")
    }

    // MARK: - Configuration Enabled States

    func testConfig_enabledButNotProvisioned_notReady() {
        // Even when enabled, if models aren't downloaded, isReady is false
        let config = SpeculativeDecodingConfig(
            draftSpec: LocalModelRegistry.draftDefault,
            verifierSpec: LocalModelRegistry.fastDefault,
            draftLength: 5,
            enabled: true
        )
        // On CI/dev machines where models aren't provisioned, this should be false
        // The check uses isDownloaded which checks for .safetensors files
        if !LocalModelRegistry.isDownloaded(LocalModelRegistry.draftDefault) {
            XCTAssertFalse(config.isReady,
                "Config should not be ready when draft model is not provisioned")
        }
    }

    func testConfig_customDraftLength() {
        let config = SpeculativeDecodingConfig(
            draftSpec: LocalModelRegistry.draftDefault,
            verifierSpec: LocalModelRegistry.fastDefault,
            draftLength: 8,
            enabled: false
        )
        XCTAssertEqual(config.draftLength, 8)
    }

    func testConfig_isDraftProvisioned_checksFileSystem() {
        let config = SpeculativeDecodingConfig.default
        // Just verify it doesn't crash — result depends on machine state
        _ = config.isDraftProvisioned
    }

    func testConfig_isVerifierProvisioned_checksFileSystem() {
        let config = SpeculativeDecodingConfig.default
        // Just verify it doesn't crash — result depends on machine state
        _ = config.isVerifierProvisioned
    }

    // MARK: - SpeculativeDecoder Actor

    func testDecoder_isReady_matchesConfig() async {
        let config = SpeculativeDecodingConfig.default
        let lifecycle = LocalModelLifecycle()
        let decoder = SpeculativeDecoder(config: config, lifecycle: lifecycle)
        let ready = await decoder.isReady
        XCTAssertEqual(ready, config.isReady,
            "Decoder readiness should match config readiness")
    }

    func testDecoder_acceptanceRate_nilWhenNoRounds() async {
        let lifecycle = LocalModelLifecycle()
        let decoder = SpeculativeDecoder(config: .default, lifecycle: lifecycle)
        let rate = await decoder.acceptanceRate
        XCTAssertNil(rate, "Acceptance rate should be nil when no rounds attempted")
    }

    func testDecoder_recordRound_updatesAcceptanceRate() async {
        let lifecycle = LocalModelLifecycle()
        let decoder = SpeculativeDecoder(config: .default, lifecycle: lifecycle)

        await decoder.recordRound(accepted: 4, rejected: 1)
        let rate = await decoder.acceptanceRate
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate!, 0.8, accuracy: 0.001,
            "4 accepted / 5 total = 0.8 acceptance rate")
    }

    func testDecoder_recordRound_accumulatesAcrossRounds() async {
        let lifecycle = LocalModelLifecycle()
        let decoder = SpeculativeDecoder(config: .default, lifecycle: lifecycle)

        await decoder.recordRound(accepted: 3, rejected: 2)  // 3/5 = 0.6
        await decoder.recordRound(accepted: 5, rejected: 0)  // Cumulative: 8/10 = 0.8
        let rate = await decoder.acceptanceRate
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate!, 0.8, accuracy: 0.001,
            "Cumulative: 8 accepted / 10 total = 0.8")
    }

    func testDecoder_recordRound_updatesDiagnostics() async {
        let lifecycle = LocalModelLifecycle()
        let decoder = SpeculativeDecoder(config: .default, lifecycle: lifecycle)

        let store = DiagnosticsStore.shared
        let beforeAttempts = store.counter("speculative_attempt_total")
        let beforeAccepted = store.counter("speculative_accepted_tokens_total")
        let beforeRejected = store.counter("speculative_rejected_tokens_total")

        await decoder.recordRound(accepted: 3, rejected: 2)

        XCTAssertEqual(store.counter("speculative_attempt_total"), beforeAttempts + 1)
        XCTAssertEqual(store.counter("speculative_accepted_tokens_total"), beforeAccepted + 3)
        XCTAssertEqual(store.counter("speculative_rejected_tokens_total"), beforeRejected + 2)
    }

    func testDecoder_updateDiagnostics_setsGauges() async {
        let config = SpeculativeDecodingConfig.default
        let lifecycle = LocalModelLifecycle()
        let decoder = SpeculativeDecoder(config: config, lifecycle: lifecycle)

        await decoder.updateDiagnostics()

        let store = DiagnosticsStore.shared
        // Disabled by default
        XCTAssertEqual(store.gauge("speculative_enabled"), 0.0,
            "speculative_enabled gauge should be 0 when config is disabled")
        XCTAssertEqual(store.gauge("speculative_ready"), 0.0,
            "speculative_ready gauge should be 0 when not ready")
    }

    func testDecoder_speculativeGenerate_returnsNil_whenNotReady() async throws {
        let config = SpeculativeDecodingConfig.default  // disabled
        let lifecycle = LocalModelLifecycle()
        let decoder = SpeculativeDecoder(config: config, lifecycle: lifecycle)

        let result = try await decoder.speculativeGenerate(
            prompt: "Hello",
            systemPrompt: "You are helpful.",
            maxTokens: 100,
            temperature: 0.3
        )
        XCTAssertNil(result, "speculativeGenerate should return nil when not ready")
    }

    // MARK: - LocalLLMProvider Integration

    func testProvider_hasSpeculativeConfig() async {
        let provider = LocalLLMProvider()
        let config = await provider.speculativeConfig
        XCTAssertFalse(config.enabled, "Default provider should have speculative decoding disabled")
    }

    func testProvider_customSpeculativeConfig() async {
        let customConfig = SpeculativeDecodingConfig(
            draftSpec: LocalModelRegistry.draftDefault,
            verifierSpec: LocalModelRegistry.fastDefault,
            draftLength: 3,
            enabled: false
        )
        let provider = LocalLLMProvider(speculativeConfig: customConfig)
        let config = await provider.speculativeConfig
        XCTAssertEqual(config.draftLength, 3, "Provider should accept custom speculative config")
    }
}
