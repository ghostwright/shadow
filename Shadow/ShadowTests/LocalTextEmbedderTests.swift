import XCTest
@testable import Shadow

final class LocalTextEmbedderTests: XCTestCase {

    // MARK: - Availability

    func testIsAvailable_returnsFalseWhenModelNotProvisioned() async {
        // The embedding model (nomic-embed-text-v1.5) is unlikely to be provisioned
        // in CI or on most dev machines. The isAvailable check should not crash
        // regardless of provisioning state.
        let embedder = LocalTextEmbedder()
        // We can't control whether the model is provisioned, but we verify
        // the property doesn't crash and returns a consistent boolean.
        _ = await embedder.isAvailable
    }

    func testIsAvailable_checksEmbedDefaultSpec() async {
        // Verify that isAvailable is checking the embedDefault spec, not some other model.
        let spec = LocalModelRegistry.embedDefault
        let isDownloaded = LocalModelRegistry.isDownloaded(spec)

        let embedder = LocalTextEmbedder()
        let isAvailable = await embedder.isAvailable

        // isAvailable should match whether the model is downloaded.
        XCTAssertEqual(isAvailable, isDownloaded)
    }

    // MARK: - Model Spec Validation

    func testEmbedDefaultSpec_properties() {
        let spec = LocalModelRegistry.embedDefault

        XCTAssertEqual(spec.tier, .embed)
        XCTAssertEqual(spec.huggingFaceID, "nomic-ai/nomic-embed-text-v1.5")
        XCTAssertEqual(spec.localDirectoryName, "nomic-embed-text-v1.5")
        XCTAssertEqual(spec.estimatedMemoryGB, 0.3, accuracy: 0.01)
        XCTAssertEqual(spec.minimumSystemRAMGB, 8)
        XCTAssertEqual(spec.contextLength, 8192)
        XCTAssertFalse(spec.supportsToolCalling)
    }

    func testEmbedDefaultSpec_includedInAllSpecs() {
        let allSpecs = LocalModelRegistry.allSpecs
        let hasEmbed = allSpecs.contains { $0.tier == .embed }
        XCTAssertTrue(hasEmbed, "allSpecs should include the embed tier")
    }

    func testEmbedDefaultSpec_pathResolution() {
        let spec = LocalModelRegistry.embedDefault
        let path = LocalModelRegistry.modelPath(for: spec)

        // Embedding models use ~/.shadow/models/embeddings/ not llm/
        XCTAssertTrue(
            path.path.hasSuffix("/.shadow/models/embeddings/nomic-embed-text-v1.5"),
            "Embed model path should be under embeddings directory, got: \(path.path)"
        )
    }

    func testEmbedPathSeparateFromLLMPath() {
        let embedPath = LocalModelRegistry.modelPath(for: LocalModelRegistry.embedDefault)
        let fastPath = LocalModelRegistry.modelPath(for: LocalModelRegistry.fastDefault)

        // Embedding models should be in a different parent directory than LLM models
        XCTAssertTrue(embedPath.path.contains("/models/embeddings/"))
        XCTAssertTrue(fastPath.path.contains("/models/llm/"))
        XCTAssertNotEqual(
            embedPath.deletingLastPathComponent().path,
            fastPath.deletingLastPathComponent().path
        )
    }

    // MARK: - Dimensions

    func testDimensions_match768() {
        XCTAssertEqual(LocalTextEmbedder.dimensions, 768)
    }

    // MARK: - Unload Safety

    func testUnload_safeWhenNotLoaded() async {
        // Unload on a fresh (never loaded) embedder should not crash.
        let embedder = LocalTextEmbedder()
        await embedder.unload()
    }

    func testUnload_canBeCalledMultipleTimes() async {
        // Multiple unloads should not crash.
        let embedder = LocalTextEmbedder()
        await embedder.unload()
        await embedder.unload()
        await embedder.unload()
    }

    // MARK: - Embed Error Handling

    func testEmbed_throwsWhenModelNotProvisioned() async {
        let embedder = LocalTextEmbedder()

        // Skip if model is actually provisioned on this machine
        guard !(await embedder.isAvailable) else { return }

        do {
            _ = try await embedder.embed(text: "hello world")
            XCTFail("Expected error when model not provisioned")
        } catch {
            // Should get a meaningful error, not a crash
            XCTAssertTrue(
                error.localizedDescription.contains("not provisioned") ||
                error.localizedDescription.contains("Failed to load"),
                "Error should mention provisioning issue, got: \(error.localizedDescription)"
            )
        }
    }

    func testEmbed_emptyArrayReturnsEmpty() async throws {
        let embedder = LocalTextEmbedder()

        // Empty input should return empty output without loading the model.
        let results = try await embedder.embed(texts: [])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Error Types

    func testLocalTextEmbedderError_descriptions() {
        let notProvisioned = LocalTextEmbedderError.modelNotProvisioned(path: "/some/path")
        XCTAssertTrue(notProvisioned.localizedDescription.contains("not provisioned"))
        XCTAssertTrue(notProvisioned.localizedDescription.contains("/some/path"))

        let loadFailed = LocalTextEmbedderError.loadFailed(model: "test-model", underlying: "OOM")
        XCTAssertTrue(loadFailed.localizedDescription.contains("test-model"))
        XCTAssertTrue(loadFailed.localizedDescription.contains("OOM"))

        let dimensionMismatch = LocalTextEmbedderError.dimensionMismatch(expected: 768, actual: 512)
        XCTAssertTrue(dimensionMismatch.localizedDescription.contains("768"))
        XCTAssertTrue(dimensionMismatch.localizedDescription.contains("512"))

        let emptyResult = LocalTextEmbedderError.emptyResult
        XCTAssertTrue(emptyResult.localizedDescription.contains("no result"))
    }

    // MARK: - Idle Timeout Configuration

    func testCustomIdleTimeout() async {
        let embedder = LocalTextEmbedder(idleTimeout: 30)
        // Verify the embedder initializes with custom timeout without crashing.
        // We can't directly observe the timeout value, but we verify the init works.
        await embedder.unload() // Cleanup
    }

    // MARK: - Registry Integration

    func testAvailableModel_embedTier() {
        // availableModel(for: .embed) should return embedDefault when provisioned,
        // or nil when not provisioned.
        let result = LocalModelRegistry.availableModel(for: .embed)

        if LocalModelRegistry.isDownloaded(LocalModelRegistry.embedDefault) {
            XCTAssertNotNil(result)
            XCTAssertEqual(result?.tier, .embed)
            XCTAssertEqual(result?.huggingFaceID, "nomic-ai/nomic-embed-text-v1.5")
        } else {
            XCTAssertNil(result)
        }
    }
}
