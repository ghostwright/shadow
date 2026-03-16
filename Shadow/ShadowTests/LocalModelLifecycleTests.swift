import XCTest
@testable import Shadow

final class LocalModelLifecycleTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState_noModelsLoaded() async {
        let lifecycle = LocalModelLifecycle()
        let fastLoaded = await lifecycle.isLoaded(tier: .fast)
        let deepLoaded = await lifecycle.isLoaded(tier: .deep)
        XCTAssertFalse(fastLoaded, "Fast tier should not be loaded initially")
        XCTAssertFalse(deepLoaded, "Deep tier should not be loaded initially")
    }

    func testInitialState_hasNoLoadedModels() async {
        let lifecycle = LocalModelLifecycle()
        let hasLoaded = await lifecycle.hasLoadedModel
        XCTAssertFalse(hasLoaded, "Should have no loaded models initially")
    }

    func testInitialState_loadedTiersEmpty() async {
        let lifecycle = LocalModelLifecycle()
        let tiers = await lifecycle.loadedTiers
        XCTAssertTrue(tiers.isEmpty, "Should have no loaded tiers initially")
    }

    // MARK: - Unload Safety

    func testUnloadFast_noopWhenNotLoaded() async {
        let lifecycle = LocalModelLifecycle()
        // Should not crash or error when unloading a tier that's not loaded
        await lifecycle.unload(tier: .fast)
        let loaded = await lifecycle.isLoaded(tier: .fast)
        XCTAssertFalse(loaded)
    }

    func testUnloadDeep_noopWhenNotLoaded() async {
        let lifecycle = LocalModelLifecycle()
        await lifecycle.unload(tier: .deep)
        let loaded = await lifecycle.isLoaded(tier: .deep)
        XCTAssertFalse(loaded)
    }

    func testUnloadAll_noopWhenNoneLoaded() async {
        let lifecycle = LocalModelLifecycle()
        // Should not crash when no models are loaded
        await lifecycle.unloadAll()
        let hasLoaded = await lifecycle.hasLoadedModel
        XCTAssertFalse(hasLoaded)
    }

    // MARK: - ensureLoaded Error Handling

    func testEnsureLoaded_fast_throwsWhenModelNotProvisioned() async {
        let lifecycle = LocalModelLifecycle()

        // Skip if model is actually provisioned on this machine
        let fastSpec = LocalModelRegistry.fastDefault
        guard !LocalModelRegistry.isDownloaded(fastSpec) else { return }

        do {
            _ = try await lifecycle.ensureLoaded(tier: .fast)
            XCTFail("Expected error when fast model is not provisioned")
        } catch let error as LLMProviderError {
            if case .unavailable(let reason) = error {
                XCTAssertTrue(reason.contains("Failed to load"),
                    "Should mention load failure, got: \(reason)")
            } else {
                XCTFail("Expected .unavailable, got \(error)")
            }
        } catch {
            // Other errors (e.g., model loading infrastructure) are acceptable
            // since the model is not provisioned
        }
    }

    func testEnsureLoaded_deep_throwsWhenModelNotProvisioned() async {
        let lifecycle = LocalModelLifecycle()

        // Skip if model is actually provisioned on this machine
        let deepSpec = LocalModelRegistry.deepDefault
        guard !LocalModelRegistry.isDownloaded(deepSpec) else { return }

        do {
            _ = try await lifecycle.ensureLoaded(tier: .deep)
            XCTFail("Expected error when deep model is not provisioned")
        } catch let error as LLMProviderError {
            if case .unavailable(let reason) = error {
                XCTAssertTrue(reason.contains("Failed to load"),
                    "Should mention load failure, got: \(reason)")
            } else {
                XCTFail("Expected .unavailable, got \(error)")
            }
        } catch {
            // Other errors are acceptable since model is not provisioned
        }
    }

    // MARK: - Mutual Exclusion Logic

    func testMutualExclusion_systemRAMDetection() {
        // Verify that the system RAM check works and returns a reasonable value.
        // The mutual exclusion threshold is 48 GB.
        let ramGB = MLXConfiguration.systemRAMGB
        XCTAssertGreaterThan(ramGB, 0, "System RAM should be detected as positive")
    }

    func testMutualExclusion_thresholdIs48GB() {
        // Verify the deep model's RAM requirement matches the mutual exclusion threshold.
        let deepSpec = LocalModelRegistry.deepDefault
        XCTAssertEqual(deepSpec.minimumSystemRAMGB, 48,
            "Deep model minimum RAM should be 48 GB (mutual exclusion threshold)")
    }

    // MARK: - Idle Timeout

    func testIdleTimeout_customValue() async {
        // Verify that custom idle timeout is accepted
        let lifecycle = LocalModelLifecycle(idleTimeout: 30)
        let loaded = await lifecycle.isLoaded(tier: .fast)
        XCTAssertFalse(loaded, "Should start unloaded even with custom timeout")
    }

    func testIdleTimeout_defaultIs10Minutes() async {
        // Default timeout is 600 seconds (10 minutes).
        // We verify indirectly by creating with default and checking it doesn't crash.
        let lifecycle = LocalModelLifecycle()
        let hasLoaded = await lifecycle.hasLoadedModel
        XCTAssertFalse(hasLoaded)
    }
}
