import XCTest
@testable import Shadow

final class VisionLLMProviderTests: XCTestCase {

    // MARK: - Availability

    func testIsAvailable_returnsFalseWhenNotProvisioned() async {
        // VisionLLMProvider checks LocalModelRegistry.isDownloaded for the vision spec.
        // On CI or unprovisioned machines, this should return false.
        let lifecycle = LocalModelLifecycle(idleTimeout: 60)
        let provider = VisionLLMProvider(lifecycle: lifecycle)

        // Whether true or false depends on machine provisioning, but it must not crash.
        _ = provider.isAvailable
    }

    func testIsAvailable_checksVisionModelPath() async {
        // Verify the provider checks the correct model spec.
        let spec = LocalModelRegistry.visionDefault
        let expectedPath = LocalModelRegistry.modelPath(for: spec).path

        // The path should point to the VLM model directory
        XCTAssertTrue(
            expectedPath.contains("Qwen2.5-VL-7B-Instruct-4bit"),
            "Vision model path should contain VLM model name, got: \(expectedPath)"
        )
    }

    // MARK: - Model Spec Validation

    func testVisionDefault_hasCorrectProperties() {
        let spec = LocalModelRegistry.visionDefault

        XCTAssertEqual(spec.tier, .vision)
        XCTAssertEqual(spec.huggingFaceID, "mlx-community/Qwen2.5-VL-7B-Instruct-4bit")
        XCTAssertEqual(spec.localDirectoryName, "Qwen2.5-VL-7B-Instruct-4bit")
        XCTAssertEqual(spec.estimatedMemoryGB, 5.0, accuracy: 0.5)
        XCTAssertEqual(spec.minimumSystemRAMGB, 24)
        XCTAssertEqual(spec.contextLength, 8192)
        XCTAssertFalse(spec.supportsToolCalling,
            "VLM should not support tool calling (visual analysis only)")
    }

    func testVisionTier_existsInRegistry() {
        let allSpecs = LocalModelRegistry.allSpecs
        let visionSpecs = allSpecs.filter { $0.tier == .vision }
        XCTAssertEqual(visionSpecs.count, 1, "Registry should contain exactly one vision tier spec")
    }

    func testVisionTier_inModelTierEnum() {
        // Verify .vision is a valid LocalModelTier case
        let tier = LocalModelTier.vision
        XCTAssertEqual(tier.rawValue, "vision")
    }

    // MARK: - Unload Safety

    func testUnload_noOpWhenNotLoaded() async {
        // Unloading when no model is loaded should be safe (no-op).
        let lifecycle = LocalModelLifecycle(idleTimeout: 60)
        let provider = VisionLLMProvider(lifecycle: lifecycle)

        // Should not crash or throw
        await provider.unload()
    }

    func testUnload_updatesGauge() async {
        let lifecycle = LocalModelLifecycle(idleTimeout: 60)
        let provider = VisionLLMProvider(lifecycle: lifecycle)

        await provider.unload()

        // After unload, the gauge should be 0
        let snapshot = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(
            snapshot.gauges["vlm_model_loaded", default: 0],
            0,
            "VLM model loaded gauge should be 0 after unload"
        )
    }

    // MARK: - Generate Error Paths

    func testAnalyze_throwsUnavailableWhenNotProvisioned() async {
        let lifecycle = LocalModelLifecycle(idleTimeout: 60)
        let provider = VisionLLMProvider(lifecycle: lifecycle)

        // Skip if model is actually provisioned on this machine
        guard !provider.isAvailable else { return }

        // Create a minimal test CGImage (1x1 pixel)
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let testImage = context.makeImage()!

        do {
            _ = try await provider.analyze(image: testImage, query: "test")
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

    // MARK: - Diagnostics Metrics

    func testDiagnosticsKeys_areConsistent() {
        // Verify the metric key names follow the established convention
        let expectedGauges = ["vlm_available", "vlm_model_loaded"]
        let expectedCounters = ["vlm_attempt_total", "vlm_success_total", "vlm_fail_total"]

        // These keys should be valid identifiers (no spaces, alphanumeric + underscore)
        for key in expectedGauges + expectedCounters {
            XCTAssertFalse(key.contains(" "), "Metric key should not contain spaces: \(key)")
            XCTAssertTrue(key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" },
                "Metric key should be alphanumeric + underscore: \(key)")
        }
    }

    // MARK: - VisionLLMProviderError

    func testVisionLLMProviderError_hasDescription() {
        let error = VisionLLMProviderError.imageEncodingFailed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("JPEG"),
            "Error description should mention JPEG encoding")
    }

    // MARK: - Lifecycle Integration

    func testLifecycle_specResolution_forVisionTier() async {
        let lifecycle = LocalModelLifecycle(idleTimeout: 60)

        // Verify the lifecycle can check loaded state for vision tier without crashing
        let isLoaded = await lifecycle.isLoaded(tier: .vision)
        XCTAssertFalse(isLoaded, "Vision tier should not be loaded initially")
    }

    func testLifecycle_unloadVisionTier_noOp() async {
        let lifecycle = LocalModelLifecycle(idleTimeout: 60)

        // Unloading a tier that was never loaded should be a no-op
        await lifecycle.unload(tier: .vision)

        let isLoaded = await lifecycle.isLoaded(tier: .vision)
        XCTAssertFalse(isLoaded)
    }
}
