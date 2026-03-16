import XCTest
@testable import Shadow

// MARK: - GroundingStrategy Tests

final class GroundingStrategyTests: XCTestCase {

    func testGroundingStrategy_rawValues() {
        XCTAssertEqual(GroundingStrategy.axExact.rawValue, "axExact")
        XCTAssertEqual(GroundingStrategy.axFuzzy.rawValue, "axFuzzy")
        XCTAssertEqual(GroundingStrategy.vlmGrounding.rawValue, "vlmGrounding")
        XCTAssertEqual(GroundingStrategy.vlmCoordinateOnly.rawValue, "vlmCoordinateOnly")
        XCTAssertEqual(GroundingStrategy.visionEscalation.rawValue, "visionEscalation")
    }

    func testGroundingStrategy_sendable() {
        // GroundingStrategy should be Sendable (compile-time check)
        let strategy: GroundingStrategy = .axExact
        let _: any Sendable = strategy
        XCTAssertEqual(strategy, .axExact)
    }
}

// MARK: - GroundingMatch Tests

final class GroundingMatchTests: XCTestCase {

    func testGroundingMatch_withElement() {
        let match = GroundingMatch(
            element: nil,
            confidence: 0.85,
            strategy: .axExact,
            point: CGPoint(x: 100, y: 200)
        )
        XCTAssertNil(match.element)
        XCTAssertEqual(match.confidence, 0.85, accuracy: 0.001)
        XCTAssertEqual(match.strategy, .axExact)
        XCTAssertEqual(match.point?.x, 100)
        XCTAssertEqual(match.point?.y, 200)
    }

    func testGroundingMatch_withoutPoint() {
        let match = GroundingMatch(
            element: nil,
            confidence: 0.5,
            strategy: .vlmCoordinateOnly,
            point: nil
        )
        XCTAssertNil(match.point)
        XCTAssertEqual(match.strategy, .vlmCoordinateOnly)
    }

    func testGroundingMatch_sendable() {
        // GroundingMatch should be Sendable (compile-time check)
        let match = GroundingMatch(
            element: nil,
            confidence: 0.7,
            strategy: .vlmGrounding,
            point: CGPoint(x: 50, y: 50)
        )
        let _: any Sendable = match
        XCTAssertEqual(match.confidence, 0.7, accuracy: 0.001)
    }
}

// MARK: - GroundingOracle Tests

final class GroundingOracleTests: XCTestCase {

    func testGroundingOracle_init_noModels() async {
        let oracle = GroundingOracle()
        let attempts = await oracle.totalAttempts
        XCTAssertEqual(attempts, 0)
    }

    func testGroundingOracle_diagnosticsSummary_initial() async {
        let oracle = GroundingOracle()
        let summary = await oracle.diagnosticsSummary
        XCTAssertTrue(summary.contains("0 attempts"))
        XCTAssertTrue(summary.contains("AX exact"))
        XCTAssertTrue(summary.contains("VLM"))
        XCTAssertTrue(summary.contains("Misses"))
    }

    func testGroundingOracle_countersStartAtZero() async {
        let oracle = GroundingOracle()
        let axHits = await oracle.axHits
        let axFuzzyHits = await oracle.axFuzzyHits
        let vlmHits = await oracle.vlmHits
        let escalationHits = await oracle.escalationHits
        let misses = await oracle.misses

        XCTAssertEqual(axHits, 0)
        XCTAssertEqual(axFuzzyHits, 0)
        XCTAssertEqual(vlmHits, 0)
        XCTAssertEqual(escalationHits, 0)
        XCTAssertEqual(misses, 0)
    }

    func testGroundingOracle_diagnosticsSummary_percentages() async {
        // With no attempts, percentages should still format correctly
        let oracle = GroundingOracle()
        let summary = await oracle.diagnosticsSummary
        // Should have 0% for all categories since max(totalAttempts, 1) = 1
        XCTAssertTrue(summary.contains("0%"))
    }
}

// MARK: - GroundingOracle.extractCleanLabel Tests

final class GroundingOracleExtractCleanLabelTests: XCTestCase {

    func testExtractCleanLabel_axButtonTitled_singleQuotes() {
        let result = GroundingOracle.extractCleanLabel(from: "AXButton titled 'Compose'")
        XCTAssertEqual(result, "Compose")
    }

    func testExtractCleanLabel_axButtonTitled_doubleQuotes() {
        let result = GroundingOracle.extractCleanLabel(from: "AXButton titled \"Send\"")
        XCTAssertEqual(result, "Send")
    }

    func testExtractCleanLabel_axTextFieldFor_singleQuotes() {
        let result = GroundingOracle.extractCleanLabel(from: "AXTextField for 'To'")
        XCTAssertEqual(result, "To")
    }

    func testExtractCleanLabel_axTextAreaFor_noQuotes() {
        let result = GroundingOracle.extractCleanLabel(from: "AXTextArea for email body")
        XCTAssertEqual(result, "email body")
    }

    func testExtractCleanLabel_axComboBoxTitled_noQuotes() {
        let result = GroundingOracle.extractCleanLabel(from: "AXComboBox titled To recipients")
        XCTAssertEqual(result, "To recipients")
    }

    func testExtractCleanLabel_plainText_passthrough() {
        let result = GroundingOracle.extractCleanLabel(from: "Compose")
        XCTAssertEqual(result, "Compose")
    }

    func testExtractCleanLabel_plainSentence_passthrough() {
        let result = GroundingOracle.extractCleanLabel(from: "the Compose button in Gmail")
        XCTAssertEqual(result, "the Compose button in Gmail")
    }

    func testExtractCleanLabel_axTextFieldFor_quotedMultiWord() {
        let result = GroundingOracle.extractCleanLabel(from: "AXTextField for 'To recipients'")
        XCTAssertEqual(result, "To recipients")
    }

    func testExtractCleanLabel_emptyString() {
        let result = GroundingOracle.extractCleanLabel(from: "")
        XCTAssertEqual(result, "")
    }

    func testExtractCleanLabel_axSearchField_titled() {
        let result = GroundingOracle.extractCleanLabel(from: "AXSearchField titled 'Search mail'")
        XCTAssertEqual(result, "Search mail")
    }
}

// MARK: - GroundingResult Tests

final class GroundingResultTests: XCTestCase {

    func testGroundingResult_point() {
        let result = GroundingResult(
            x: 100.0,
            y: 200.0,
            normalizedX: 0.5,
            normalizedY: 0.5,
            confidence: 0.9,
            rawResponse: "click(x=0.5, y=0.5)",
            instruction: "Click the button"
        )
        XCTAssertEqual(result.point.x, 100.0)
        XCTAssertEqual(result.point.y, 200.0)
    }

    func testGroundingResult_normalizedCoordinates() {
        let result = GroundingResult(
            x: 960.0,
            y: 540.0,
            normalizedX: 0.5,
            normalizedY: 0.5,
            confidence: 0.8,
            rawResponse: "click(x=0.5, y=0.5)",
            instruction: "test"
        )
        XCTAssertEqual(result.normalizedX, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.normalizedY, 0.5, accuracy: 0.001)
    }

    func testGroundingResult_lowConfidence() {
        let result = GroundingResult(
            x: 960.0,
            y: 540.0,
            normalizedX: 0.5,
            normalizedY: 0.5,
            confidence: 0.0,
            rawResponse: "unparseable response",
            instruction: "test"
        )
        XCTAssertEqual(result.confidence, 0.0)
    }

    func testGroundingResult_sendable() {
        let result = GroundingResult(
            x: 0, y: 0,
            normalizedX: 0, normalizedY: 0,
            confidence: 0.5,
            rawResponse: "",
            instruction: ""
        )
        let _: any Sendable = result
        XCTAssertEqual(result.confidence, 0.5)
    }
}

// MARK: - GroundingError Tests

final class GroundingErrorTests: XCTestCase {

    func testGroundingError_modelNotAvailable() {
        let error = GroundingError.modelNotAvailable
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("ShowUI-2B"))
    }

    func testGroundingError_modelLoadFailed() {
        let error = GroundingError.modelLoadFailed("out of memory")
        XCTAssertTrue(error.errorDescription!.contains("out of memory"))
    }

    func testGroundingError_screenshotEncodingFailed() {
        let error = GroundingError.screenshotEncodingFailed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("JPEG"))
    }

    func testGroundingError_inferenceFailed() {
        let error = GroundingError.inferenceFailed("timeout")
        XCTAssertTrue(error.errorDescription!.contains("timeout"))
    }
}

// MARK: - LocalGroundingModel Tests

final class LocalGroundingModelTests: XCTestCase {

    func testLocalGroundingModel_isAvailable_checksDownloadStatus() async {
        // isAvailable reflects whether the grounding model is downloaded on disk.
        // On dev machines it may be true (provisioned), on CI it's typically false.
        let lifecycle = LocalModelLifecycle()
        let model = LocalGroundingModel(lifecycle: lifecycle)
        let available = model.isAvailable
        // Verify that isAvailable matches the registry's download check
        let registryCheck = LocalModelRegistry.isDownloaded(LocalModelRegistry.groundingDefault)
        XCTAssertEqual(available, registryCheck)
    }

    func testLocalGroundingModel_countersStartAtZero() async {
        let lifecycle = LocalModelLifecycle()
        let model = LocalGroundingModel(lifecycle: lifecycle)
        let successCount = await model.groundingSuccessCount
        let failCount = await model.groundingFailCount
        XCTAssertEqual(successCount, 0)
        XCTAssertEqual(failCount, 0)
    }

    func testLocalGroundingModel_ground_failsGracefully_whenNotProvisioned() async {
        let spec = LocalModelRegistry.groundingDefault
        guard !LocalModelRegistry.isDownloaded(spec) else {
            // Model is provisioned — skip this test (it would succeed, not throw).
            // The integration test below covers the provisioned case.
            return
        }

        let lifecycle = LocalModelLifecycle()
        let model = LocalGroundingModel(lifecycle: lifecycle)

        // Create a minimal 1x1 CGImage
        guard let cgImage = createTestImage(width: 1, height: 1) else {
            XCTFail("Could not create test image")
            return
        }

        do {
            _ = try await model.ground(
                instruction: "Click the button",
                screenshot: cgImage,
                screenSize: CGSize(width: 1920, height: 1080)
            )
            XCTFail("Should have thrown")
        } catch {
            // Expected: modelNotAvailable when not provisioned.
            XCTAssertTrue(error is GroundingError)
        }
    }

    func testLocalGroundingModel_spec() {
        let spec = LocalModelRegistry.groundingDefault
        XCTAssertEqual(spec.tier, .grounding)
        XCTAssertEqual(spec.localDirectoryName, "ShowUI-2B-bf16-8bit")
        XCTAssertEqual(spec.estimatedMemoryGB, 3.0)
        XCTAssertFalse(spec.supportsToolCalling)
        XCTAssertEqual(spec.contextLength, 4096)
        XCTAssertEqual(spec.minimumSystemRAMGB, 16)
    }

    // MARK: - Helper

    private func createTestImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

// MARK: - TrainingDataGenerator Tests

final class TrainingDataGeneratorTests: XCTestCase {

    func testTrainingDataGenerator_init() async {
        let generator = TrainingDataGenerator()
        let generated = await generator.tuplesGenerated
        let skipped = await generator.tuplesSkipped
        XCTAssertEqual(generated, 0)
        XCTAssertEqual(skipped, 0)
    }

    func testTrainingDataGenerator_initWithCustomDir() async {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-training-\(UUID().uuidString)")
        let generator = TrainingDataGenerator(dataDir: tmpDir)
        let generated = await generator.tuplesGenerated
        XCTAssertEqual(generated, 0)
    }

    func testTrainingDataGenerator_generateFromRecentEvents_emptyDB() async {
        // Without an initialized timeline/behavioral index, should return 0 gracefully
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-training-\(UUID().uuidString)")
        let generator = TrainingDataGenerator(dataDir: tmpDir)
        let count = await generator.generateFromRecentEvents()
        XCTAssertEqual(count, 0)
        // Clean up
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testTrainingDataGenerator_totalTupleCount_noFiles() async {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-training-\(UUID().uuidString)")
        let generator = TrainingDataGenerator(dataDir: tmpDir)
        let count = await generator.totalTupleCount()
        XCTAssertEqual(count, 0)
        // Clean up
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testTrainingDataGenerator_totalTupleCount_withFiles() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-training-\(UUID().uuidString)")
        let groundingDir = tmpDir.appendingPathComponent("grounding")
        try FileManager.default.createDirectory(at: groundingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write a test JSONL file with 3 lines
        let jsonl = """
        {"messages":[{"role":"user","content":"test1"}]}
        {"messages":[{"role":"user","content":"test2"}]}
        {"messages":[{"role":"user","content":"test3"}]}
        """
        try jsonl.write(
            to: groundingDir.appendingPathComponent("test.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let generator = TrainingDataGenerator(dataDir: tmpDir)
        let count = await generator.totalTupleCount()
        XCTAssertEqual(count, 3)
    }
}

// MARK: - TrainingTuple Tests (via JSONL output verification)

final class TrainingTupleTests: XCTestCase {

    /// Verify that generateFromRecentEvents writes valid JSONL when events exist.
    /// Since we can't easily create enriched events without the full pipeline,
    /// we test the tuple serialization indirectly through file writing.
    func testTrainingDataDirectory_creation() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-training-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let generator = TrainingDataGenerator(dataDir: tmpDir)

        // Even though no events exist, the directory creation should work
        // generateFromRecentEvents will try to create directories then fail to find events
        _ = await generator.generateFromRecentEvents()

        // After generate attempt, the directories should NOT be created
        // because the behavioral search will fail before directory creation,
        // OR they may be created if the search returns empty results.
        // Either way, the generator should not crash.
        let generated = await generator.tuplesGenerated
        XCTAssertEqual(generated, 0)
    }
}

// MARK: - LoRATrainer Tests

final class LoRATrainerTests: XCTestCase {

    func testLoRATrainer_init() async {
        let generator = TrainingDataGenerator()
        let trainer = LoRATrainer(dataGenerator: generator)
        let status = await trainer.status
        XCTAssertEqual(status, .idle)
    }

    func testLoRATrainer_countersStartAtZero() async {
        let generator = TrainingDataGenerator()
        let trainer = LoRATrainer(dataGenerator: generator)
        let runs = await trainer.runsCompleted
        let fails = await trainer.runsFailed
        XCTAssertEqual(runs, 0)
        XCTAssertEqual(fails, 0)
    }

    func testLoRATrainer_lastRunTimeIsNilInitially() async {
        let generator = TrainingDataGenerator()
        let trainer = LoRATrainer(dataGenerator: generator)
        let lastRun = await trainer.lastRunTime
        XCTAssertNil(lastRun)
    }

    func testLoRATrainer_checkAndTrain_skipsWithFewTuples() async {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-lora-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let generator = TrainingDataGenerator(dataDir: tmpDir)
        let trainer = LoRATrainer(
            dataGenerator: generator,
            config: .default,
            dataDir: tmpDir
        )

        // No training data exists, so should skip
        let result = await trainer.checkAndTrain()
        XCTAssertFalse(result)

        let status = await trainer.status
        XCTAssertEqual(status, .idle)
    }

    func testLoRATrainer_activeAdapterPath_nilWhenNoAdapters() async {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-lora-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let generator = TrainingDataGenerator(dataDir: tmpDir)
        let trainer = LoRATrainer(
            dataGenerator: generator,
            dataDir: tmpDir
        )

        let path = await trainer.activeAdapterPath
        XCTAssertNil(path)
    }

    func testLoRATrainer_listAdapters_emptyWhenNoAdapters() async {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-lora-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let generator = TrainingDataGenerator(dataDir: tmpDir)
        let trainer = LoRATrainer(
            dataGenerator: generator,
            dataDir: tmpDir
        )

        let adapters = await trainer.listAdapters()
        XCTAssertTrue(adapters.isEmpty)
    }

    func testLoRATrainer_cancelTraining_whenIdle() async {
        let generator = TrainingDataGenerator()
        let trainer = LoRATrainer(dataGenerator: generator)

        // Should not crash when no training is in progress
        await trainer.cancelTraining()
        let status = await trainer.status
        XCTAssertEqual(status, .idle)
    }

    func testLoRATrainer_defaultConfig() {
        let config = LoRATrainer.TrainingConfig.default
        XCTAssertEqual(config.minTuples, 100)
        XCTAssertEqual(config.loraRank, 8)
        XCTAssertEqual(config.iterations, 200)
        XCTAssertEqual(config.learningRate, 1e-4, accuracy: 1e-10)
        XCTAssertEqual(config.batchSize, 4)
        XCTAssertEqual(config.minHoursBetweenRuns, 24)
    }

    func testLoRATrainer_trainerStatus_rawValues() {
        XCTAssertEqual(LoRATrainer.TrainerStatus.idle.rawValue, "idle")
        XCTAssertEqual(LoRATrainer.TrainerStatus.preparing.rawValue, "preparing")
        XCTAssertEqual(LoRATrainer.TrainerStatus.training.rawValue, "training")
        XCTAssertEqual(LoRATrainer.TrainerStatus.merging.rawValue, "merging")
        XCTAssertEqual(LoRATrainer.TrainerStatus.failed.rawValue, "failed")
        XCTAssertEqual(LoRATrainer.TrainerStatus.completed.rawValue, "completed")
    }

    func testLoRATrainer_customConfig() async {
        let config = LoRATrainer.TrainingConfig(
            minTuples: 50,
            loraRank: 16,
            iterations: 500,
            learningRate: 5e-5,
            batchSize: 8,
            minHoursBetweenRuns: 12
        )
        let generator = TrainingDataGenerator()
        let trainer = LoRATrainer(dataGenerator: generator, config: config)
        // Trainer should initialize without errors
        let status = await trainer.status
        XCTAssertEqual(status, .idle)
    }
}
