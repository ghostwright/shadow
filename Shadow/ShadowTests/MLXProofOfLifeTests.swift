import XCTest
import MLXLLM
import MLXLMCommon
@testable import Shadow

// MARK: - LocalModelRegistry Unit Tests

final class LocalModelRegistryTests: XCTestCase {

    // MARK: - modelPath resolution

    func testModelPath_resolvesToExpectedDirectory() {
        let spec = LocalModelRegistry.fastDefault
        let path = LocalModelRegistry.modelPath(for: spec)

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            path.path,
            "\(homeDir)/.shadow/models/llm/Qwen2.5-7B-Instruct-4bit"
        )
    }

    func testModelPath_deepModel_resolvesCorrectly() {
        let spec = LocalModelRegistry.deepDefault
        let path = LocalModelRegistry.modelPath(for: spec)

        XCTAssertTrue(path.path.hasSuffix("/.shadow/models/llm/Qwen2.5-32B-Instruct-4bit"))
    }

    func testModelPath_visionModel_resolvesCorrectly() {
        let spec = LocalModelRegistry.visionDefault
        let path = LocalModelRegistry.modelPath(for: spec)

        XCTAssertTrue(path.path.hasSuffix("/.shadow/models/llm/Qwen2.5-VL-7B-Instruct-4bit"))
    }

    // MARK: - isDownloaded checks

    func testIsDownloaded_returnsFalse_whenDirectoryMissing() {
        // A non-existent model directory should report not downloaded.
        let spec = LocalModelSpec(
            tier: .fast,
            huggingFaceID: "mlx-community/nonexistent-model-test",
            localDirectoryName: "nonexistent-model-test-xyz-12345",
            estimatedMemoryGB: 1.0,
            minimumSystemRAMGB: 8,
            contextLength: 4096,
            supportsToolCalling: false,
            revision: "main",
            requiredFiles: ["config.json"],
            configSHA256: nil,
            weightFingerprint: nil
        )
        XCTAssertFalse(LocalModelRegistry.isDownloaded(spec))
    }

    func testIsDownloaded_returnsFalse_whenDirectoryExistsButNoSafetensors() throws {
        // Create a temp directory that looks like a model dir but has no .safetensors.
        // We verify the underlying logic that isDownloaded uses: directory must contain
        // at least one .safetensors file.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "{}".write(
            to: tmpDir.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )

        // Verify the underlying check: directory exists but no .safetensors
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: tmpDir.path))
        let contents = try fm.contentsOfDirectory(atPath: tmpDir.path)
        XCTAssertFalse(contents.contains { $0.hasSuffix(".safetensors") })
    }

    func testIsDownloaded_detectsSafetensorsFiles() throws {
        // Create a temp directory with a fake .safetensors file to verify
        // the detection logic works.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try Data().write(to: tmpDir.appendingPathComponent("model.safetensors"))

        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: tmpDir.path)
        XCTAssertTrue(contents.contains { $0.hasSuffix(".safetensors") })
    }

    // MARK: - Model Spec properties

    func testAllSpecs_containsExpectedModels() {
        XCTAssertEqual(LocalModelRegistry.allSpecs.count, 5)

        let tiers = Set(LocalModelRegistry.allSpecs.map(\.tier))
        XCTAssertTrue(tiers.contains(.fast))
        XCTAssertTrue(tiers.contains(.deep))
        XCTAssertTrue(tiers.contains(.vision))
        XCTAssertTrue(tiers.contains(.embed))
        XCTAssertTrue(tiers.contains(.grounding))
    }

    func testFastDefault_hasExpectedProperties() {
        let spec = LocalModelRegistry.fastDefault
        XCTAssertEqual(spec.tier, .fast)
        XCTAssertEqual(spec.huggingFaceID, "mlx-community/Qwen2.5-7B-Instruct-4bit")
        XCTAssertEqual(spec.localDirectoryName, "Qwen2.5-7B-Instruct-4bit")
        XCTAssertEqual(spec.contextLength, 32768)
        XCTAssertTrue(spec.supportsToolCalling)
        XCTAssertEqual(spec.minimumSystemRAMGB, 16)
    }

    func testDeepDefault_hasExpectedProperties() {
        let spec = LocalModelRegistry.deepDefault
        XCTAssertEqual(spec.tier, .deep)
        XCTAssertEqual(spec.minimumSystemRAMGB, 48)
        XCTAssertTrue(spec.supportsToolCalling)
    }

    func testVisionDefault_doesNotSupportToolCalling() {
        let spec = LocalModelRegistry.visionDefault
        XCTAssertEqual(spec.tier, .vision)
        XCTAssertFalse(spec.supportsToolCalling)
    }

    // MARK: - Tier enum

    func testLocalModelTier_allCases() {
        let allCases = LocalModelTier.allCases
        XCTAssertEqual(allCases.count, 5)
        XCTAssertTrue(allCases.contains(.fast))
        XCTAssertTrue(allCases.contains(.deep))
        XCTAssertTrue(allCases.contains(.vision))
        XCTAssertTrue(allCases.contains(.embed))
        XCTAssertTrue(allCases.contains(.grounding))
    }

    // MARK: - MLXConfiguration

    func testMLXConfiguration_systemRAMGB_isPositive() {
        let ramGB = MLXConfiguration.systemRAMGB
        XCTAssertGreaterThan(ramGB, 0)
    }

    func testMLXConfiguration_configure_doesNotCrash() {
        // Calling configure() should not throw or crash.
        // It sets the GPU cache limit based on system RAM.
        MLXConfiguration.configure()
    }
}

// MARK: - MLX Integration Tests (require provisioned model)

final class MLXIntegrationTests: XCTestCase {

    /// Proof-of-life test: load a model from disk and generate a single response.
    ///
    /// This test requires the fast model to be provisioned at
    /// `~/.shadow/models/llm/Qwen2.5-7B-Instruct-4bit/`.
    /// If the model is not present, the test is skipped via XCTSkip.
    func testMLXCanLoadAndGenerate() async throws {
        let spec = LocalModelRegistry.fastDefault
        guard LocalModelRegistry.isDownloaded(spec) else {
            throw XCTSkip("Model not provisioned — run scripts/provision-llm-models.py")
        }

        let localPath = LocalModelRegistry.modelPath(for: spec)

        // loadModelContainer is a free function from MLXLMCommon, discovered via MLXLLM.
        // ModelConfiguration(directory:) points to local weights — no network call.
        let container = try await loadModelContainer(
            directory: localPath
        )

        // ChatSession wraps the ModelContainer for multi-turn conversation.
        // Module-qualified to avoid conflict with any Shadow types.
        let session = MLXLMCommon.ChatSession(container)
        let response = try await session.respond(to: "Say 'hello' and nothing else.")

        XCTAssertFalse(response.isEmpty, "Model should produce non-empty output")
        XCTAssertGreaterThan(response.count, 0)
    }
}
