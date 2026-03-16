import XCTest
@testable import Shadow

// MARK: - Mock Provider

/// Configurable mock transcription provider for deterministic orchestrator tests.
final class MockTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    let providerName: String
    var isAvailable: Bool
    var result: Result<[TranscribedWord], TranscriptionProviderError>

    init(
        name: String,
        available: Bool = true,
        result: Result<[TranscribedWord], TranscriptionProviderError> = .success([])
    ) {
        self.providerName = name
        self.isAvailable = available
        self.result = result
    }

    func transcribe(audioFileURL: URL) async throws -> [TranscribedWord] {
        switch result {
        case .success(let words): return words
        case .failure(let error): throw error
        }
    }
}

// MARK: - Orchestrator Tests

final class TranscriptionOrchestratorTests: XCTestCase {
    private let dummyURL = URL(fileURLWithPath: "/tmp/test.m4a")

    override func setUp() {
        super.setUp()
        DiagnosticsStore.shared.resetCounters()
    }

    // MARK: - 1. Whisper success -> no fallback

    func testWhisperSuccess_noFallback() async {
        let words = [TranscribedWord(text: "hello", startSeconds: 0, durationSeconds: 0.5, confidence: 0.9)]
        let whisper = MockTranscriptionProvider(name: "whisper", result: .success(words))
        let apple = MockTranscriptionProvider(name: "apple_speech", result: .success([]))
        let orchestrator = TranscriptionOrchestrator(providers: [whisper, apple])

        let outcome = await orchestrator.transcribe(audioFileURL: dummyURL)

        guard case .success(let resultWords, let provider) = outcome else {
            XCTFail("Expected .success, got \(outcome)")
            return
        }
        XCTAssertEqual(resultWords.count, 1)
        XCTAssertEqual(resultWords[0].text, "hello")
        XCTAssertEqual(provider, "whisper")

        let snap = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(snap.counters["transcript_provider_whisper_attempt_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_whisper_success_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_apple_speech_attempt_total", default: 0], 0)
        XCTAssertEqual(snap.counters["transcript_provider_fallback_to_apple_total", default: 0], 0)
    }

    // MARK: - 2. Whisper unavailable -> Apple success -> fallback increments

    func testWhisperUnavailable_appleFallbackSuccess() async {
        let words = [TranscribedWord(text: "world", startSeconds: 0, durationSeconds: 0.3, confidence: 0.8)]
        let whisper = MockTranscriptionProvider(
            name: "whisper",
            result: .failure(.unavailable(reason: "model not loaded"))
        )
        let apple = MockTranscriptionProvider(name: "apple_speech", result: .success(words))
        let orchestrator = TranscriptionOrchestrator(providers: [whisper, apple])

        let outcome = await orchestrator.transcribe(audioFileURL: dummyURL)

        guard case .success(let resultWords, let provider) = outcome else {
            XCTFail("Expected .success, got \(outcome)")
            return
        }
        XCTAssertEqual(resultWords.count, 1)
        XCTAssertEqual(provider, "apple_speech")

        let snap = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(snap.counters["transcript_provider_whisper_attempt_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_whisper_fail_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_whisper_unavailable_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_apple_speech_attempt_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_apple_speech_success_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_fallback_to_apple_total"], 1)
    }

    // MARK: - 3. Whisper transient + Apple fail -> no false fallback

    func testWhisperTransient_appleFail_noFalseFallback() async {
        let whisper = MockTranscriptionProvider(
            name: "whisper",
            result: .failure(.transientFailure(underlying: NSError(domain: "test", code: 1)))
        )
        let apple = MockTranscriptionProvider(
            name: "apple_speech",
            result: .failure(.transientFailure(underlying: NSError(domain: "test", code: 2)))
        )
        let orchestrator = TranscriptionOrchestrator(providers: [whisper, apple])

        let outcome = await orchestrator.transcribe(audioFileURL: dummyURL)

        guard case .transientFailure = outcome else {
            XCTFail("Expected .transientFailure, got \(outcome)")
            return
        }

        let snap = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(snap.counters["transcript_provider_whisper_attempt_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_whisper_fail_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_whisper_transient_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_apple_speech_attempt_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_apple_speech_fail_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_fallback_to_apple_total", default: 0], 0)
    }

    // MARK: - 4. badInput -> terminal path

    func testBadInput_terminal() async {
        let whisper = MockTranscriptionProvider(
            name: "whisper",
            result: .failure(.badInput(reason: "corrupt audio"))
        )
        let apple = MockTranscriptionProvider(name: "apple_speech", result: .success([]))
        let orchestrator = TranscriptionOrchestrator(providers: [whisper, apple])

        let outcome = await orchestrator.transcribe(audioFileURL: dummyURL)

        guard case .badInput = outcome else {
            XCTFail("Expected .badInput, got \(outcome)")
            return
        }

        let snap = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(snap.counters["transcript_provider_whisper_attempt_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_whisper_fail_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_apple_speech_attempt_total", default: 0], 0)
        XCTAssertEqual(snap.counters["transcript_provider_fallback_to_apple_total", default: 0], 0)
    }

    // MARK: - 5. Silence -> success([]), no fallback

    func testSilence_successEmpty_noFallback() async {
        let whisper = MockTranscriptionProvider(name: "whisper", result: .success([]))
        let apple = MockTranscriptionProvider(name: "apple_speech", result: .success([]))
        let orchestrator = TranscriptionOrchestrator(providers: [whisper, apple])

        let outcome = await orchestrator.transcribe(audioFileURL: dummyURL)

        guard case .success(let resultWords, let provider) = outcome else {
            XCTFail("Expected .success, got \(outcome)")
            return
        }
        XCTAssertTrue(resultWords.isEmpty, "Silence should return empty array")
        XCTAssertEqual(provider, "whisper")

        let snap = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(snap.counters["transcript_provider_whisper_attempt_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_whisper_success_total"], 1)
        XCTAssertEqual(snap.counters["transcript_provider_apple_speech_attempt_total", default: 0], 0)
        XCTAssertEqual(snap.counters["transcript_provider_fallback_to_apple_total", default: 0], 0)
    }

    // MARK: - 6. No available providers

    func testNoAvailableProviders_transientFailure() async {
        let whisper = MockTranscriptionProvider(name: "whisper", available: false, result: .success([]))
        let apple = MockTranscriptionProvider(name: "apple_speech", available: false, result: .success([]))
        let orchestrator = TranscriptionOrchestrator(providers: [whisper, apple])

        let outcome = await orchestrator.transcribe(audioFileURL: dummyURL)

        guard case .transientFailure = outcome else {
            XCTFail("Expected .transientFailure, got \(outcome)")
            return
        }

        let snap = DiagnosticsStore.shared.snapshot()
        XCTAssertEqual(snap.counters["transcript_provider_whisper_attempt_total", default: 0], 0)
        XCTAssertEqual(snap.counters["transcript_provider_apple_speech_attempt_total", default: 0], 0)
    }
}

// MARK: - Profile Discovery Tests

final class WhisperProfileDiscoveryTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    /// Create a structurally valid model directory (config.json + 3 .mlmodelc dirs).
    private func createValidModelDir(for profile: WhisperProfile) throws {
        let dir = tmpDir.appendingPathComponent(profile.rawValue)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".data(using: .utf8)!.write(to: dir.appendingPathComponent("config.json"))
        for mlmodelc in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
            let subdir = dir.appendingPathComponent(mlmodelc)
            try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            // Put a dummy file inside so the directory is non-empty
            try Data([0x00]).write(to: subdir.appendingPathComponent("model.mlmodel"))
        }
    }

    // MARK: - 7. Discovery returns balanced first when multiple valid

    func testDiscovery_balancedPreferredOverFast() throws {
        try createValidModelDir(for: .balanced)
        try createValidModelDir(for: .fast)

        let candidates = WhisperProfile.discoverProvisionedCandidates(in: tmpDir.path)
        XCTAssertEqual(candidates, [.balanced, .fast])
        XCTAssertEqual(candidates.first, .balanced, "balanced must be first in preference order")
    }

    // MARK: - 8. Discovery skips incomplete profiles (missing .mlmodelc)

    func testDiscovery_skipsIncompleteProfile() throws {
        // balanced: has config.json but missing TextDecoder.mlmodelc
        let balancedDir = tmpDir.appendingPathComponent(WhisperProfile.balanced.rawValue)
        try FileManager.default.createDirectory(at: balancedDir, withIntermediateDirectories: true)
        try "{}".data(using: .utf8)!.write(to: balancedDir.appendingPathComponent("config.json"))
        try FileManager.default.createDirectory(
            at: balancedDir.appendingPathComponent("AudioEncoder.mlmodelc"),
            withIntermediateDirectories: true
        )
        // Missing TextDecoder.mlmodelc and MelSpectrogram.mlmodelc

        // fast: fully valid
        try createValidModelDir(for: .fast)

        let candidates = WhisperProfile.discoverProvisionedCandidates(in: tmpDir.path)
        XCTAssertEqual(candidates, [.fast], "Incomplete balanced should be skipped")
    }

    // MARK: - 9. Discovery returns empty when no valid profiles

    func testDiscovery_emptyWhenNoneValid() {
        let candidates = WhisperProfile.discoverProvisionedCandidates(in: tmpDir.path)
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - 10. Discovery rejects .mlmodelc as file (not directory)

    func testDiscovery_rejectsFileInsteadOfDirectory() throws {
        let dir = tmpDir.appendingPathComponent(WhisperProfile.balanced.rawValue)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".data(using: .utf8)!.write(to: dir.appendingPathComponent("config.json"))
        // AudioEncoder as file instead of directory
        try Data([0x00]).write(to: dir.appendingPathComponent("AudioEncoder.mlmodelc"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("TextDecoder.mlmodelc"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("MelSpectrogram.mlmodelc"),
            withIntermediateDirectories: true
        )

        let candidates = WhisperProfile.discoverProvisionedCandidates(in: tmpDir.path)
        XCTAssertTrue(candidates.isEmpty, "Should reject profile where .mlmodelc is a file")
    }

    // MARK: - 11. Discovery preference order: balanced > fast > accurate

    func testDiscovery_preferenceOrder() throws {
        try createValidModelDir(for: .accurate)
        try createValidModelDir(for: .fast)
        try createValidModelDir(for: .balanced)

        let candidates = WhisperProfile.discoverProvisionedCandidates(in: tmpDir.path)
        XCTAssertEqual(candidates, [.balanced, .fast, .accurate])
    }

    // MARK: - 12. Discovery with only accurate provisioned

    func testDiscovery_singleProfileAccurate() throws {
        try createValidModelDir(for: .accurate)

        let candidates = WhisperProfile.discoverProvisionedCandidates(in: tmpDir.path)
        XCTAssertEqual(candidates, [.accurate])
    }
}
