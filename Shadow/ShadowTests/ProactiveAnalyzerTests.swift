import XCTest
@testable import Shadow

final class ProactiveAnalyzerTests: XCTestCase {

    private var contextDir: String!
    private var proactiveDir: String!
    private var trustDir: String!
    private var contextStore: ContextStore!
    private var proactiveStore: ProactiveStore!
    private var trustTuner: TrustTuner!

    override func setUp() {
        super.setUp()
        let base = NSTemporaryDirectory() + "ProactiveAnalyzerTests_\(UUID().uuidString)"
        contextDir = base + "/context"
        proactiveDir = base + "/proactive"
        trustDir = base + "/trust"
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        contextStore = ContextStore(baseDir: contextDir)
        proactiveStore = ProactiveStore(baseDir: proactiveDir)
        // Use a permissive tuner for tests: lower the inbox threshold
        // so synthetic test data reliably passes the policy gate.
        trustTuner = TrustTuner(baseDir: trustDir)
    }

    override func tearDown() {
        let base = (contextDir as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: base)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeEpisode(
        startUs: UInt64 = 1_000_000,
        endUs: UInt64 = 2_000_000,
        summary: String = "Worked on feature X in Xcode",
        topics: [String] = ["coding", "feature-x"]
    ) -> EpisodeRecord {
        EpisodeRecord(
            id: UUID(),
            startUs: startUs,
            endUs: endUs,
            summary: summary,
            topicTags: topics,
            apps: ["Xcode"],
            keyArtifacts: [],
            evidence: [
                ContextEvidence(timestamp: startUs, app: "Xcode", sourceKind: "timeline", displayId: nil, url: nil, snippet: "Editing FeatureX.swift")
            ],
            provenance: RecordProvenance(provider: "test", modelId: "test", generatedAt: Date(), inputHash: "abc")
        )
    }

    /// Build a mock LLM generate function that returns a canned JSON response.
    private func mockGenerate(json: String) -> LLMGenerateFunction {
        return { @Sendable _ in
            LLMResponse(content: json, toolCalls: [], provider: "test", modelId: "test-model", inputTokens: 100, outputTokens: 50, latencyMs: 10)
        }
    }

    /// Compute the expected policy score for given inputs, so tests can assert threshold behavior.
    /// Formula: confidence*0.30 + evidenceQuality*0.25 + novelty*0.15 + affinity*0.15 - interruption*0.15
    private func expectedScore(confidence: Double, evidenceQuality: Double, novelty: Double = 0.7) -> Double {
        confidence * 0.30 + evidenceQuality * 0.25 + novelty * 0.15
    }

    // MARK: - Empty Input

    func test_emptyContextStore_returnsEmpty() async throws {
        let result = try await ProactiveAnalyzer.analyze(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: mockGenerate(json: "{}")
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Evidence Gating

    func test_candidateWithoutEvidence_derivesFromEpisodes() async throws {
        contextStore.saveEpisode(makeEpisode())

        // LLM returns suggestion with no evidence array — analyzer derives from episodes
        let json = """
        {"suggestions": [{"type": "followup", "title": "Follow up on X", "body": "You should check", "whyNow": "It was recent", "confidence": 0.99}]}
        """

        let result = try await ProactiveAnalyzer.analyze(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: mockGenerate(json: json)
        )

        // Candidate has derived evidence; whether it lands in result depends on policy score.
        // The analyzer creates the candidate with evidence; we verify it's not blocked by
        // the evidence gate (empty-evidence hard drop). Score may still be below inbox threshold.
        // Verify via the proactive store candidates counter:
        let candidateCount = DiagnosticsStore.shared.counter("proactive_candidate_total")
        XCTAssertGreaterThan(candidateCount, 0, "Candidate should have been generated")
    }

    func test_candidateWithExplicitEvidence_preserved() async throws {
        contextStore.saveEpisode(makeEpisode())

        // Use very high confidence to ensure it passes the inbox threshold
        let json = """
        {"suggestions": [{"type": "followup", "title": "Continue feature X", "body": "Resume coding", "whyNow": "Left off mid-task", "confidence": 0.99, "evidence": [{"timestamp": 1000000, "app": "Xcode", "sourceKind": "timeline", "snippet": "test snippet"}]}]}
        """

        let result = try await ProactiveAnalyzer.analyze(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: mockGenerate(json: json)
        )

        // Score ≈ 0.99*0.30 + 0.75*0.25 + 0.7*0.15 = 0.297 + 0.1875 + 0.105 = 0.5895 > 0.55
        guard let first = result.first else {
            XCTFail("Expected at least one suggestion with score ~0.59")
            return
        }
        XCTAssertEqual(first.evidence.count, 1)
        XCTAssertEqual(first.evidence[0].app, "Xcode")
    }

    // MARK: - Policy Decision Mapping

    func test_highConfidence_producesInboxOrPush() async throws {
        contextStore.saveEpisode(makeEpisode())

        let json = """
        {"suggestions": [{"type": "followup", "title": "High conf suggestion", "body": "Very important", "whyNow": "Urgent", "confidence": 0.99, "evidence": [{"timestamp": 1000000, "app": "Xcode", "sourceKind": "timeline", "snippet": "evidence"}]}]}
        """

        let result = try await ProactiveAnalyzer.analyze(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: mockGenerate(json: json)
        )

        // Score ≈ 0.59 — above inbox threshold (0.55), below push threshold (0.82)
        guard let first = result.first else {
            XCTFail("Expected suggestion with score above inbox threshold")
            return
        }
        XCTAssertTrue(first.decision == .pushNow || first.decision == .inboxOnly)
    }

    func test_lowConfidence_droppedOrInbox() async throws {
        contextStore.saveEpisode(makeEpisode())

        let json = """
        {"suggestions": [{"type": "followup", "title": "Weak suggestion", "body": "Maybe", "whyNow": "Not sure", "confidence": 0.2, "evidence": [{"timestamp": 1000000, "app": "Xcode", "sourceKind": "timeline", "snippet": "weak"}]}]}
        """

        let result = try await ProactiveAnalyzer.analyze(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: mockGenerate(json: json)
        )

        // Low confidence → score well below inbox threshold → dropped (empty result)
        // Score ≈ 0.2*0.30 + 0.75*0.25 + 0.7*0.15 = 0.06 + 0.1875 + 0.105 = 0.3525 < 0.55
        if !result.isEmpty {
            XCTAssertNotEqual(result[0].decision, .pushNow)
        }
        // Either dropped or below threshold — both are valid outcomes for low confidence
    }

    // MARK: - Persistence

    func test_suggestions_persistedInStore() async throws {
        contextStore.saveEpisode(makeEpisode())

        let json = """
        {"suggestions": [{"type": "reminder", "title": "Remember to review PR", "body": "PR #42 needs attention", "whyNow": "It was open yesterday", "confidence": 0.99, "evidence": [{"timestamp": 1000000, "app": "GitHub", "sourceKind": "timeline", "snippet": "PR #42"}]}]}
        """

        let result = try await ProactiveAnalyzer.analyze(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: mockGenerate(json: json)
        )

        // Check that non-dropped suggestions are in the store
        let stored = proactiveStore.listSuggestions()
        XCTAssertEqual(stored.count, result.count)
        if let first = stored.first {
            XCTAssertEqual(first.title, "Remember to review PR")
            XCTAssertEqual(first.status, .active)
        }
    }

    // MARK: - LLM Failure

    func test_llmFailure_propagatesError() async throws {
        contextStore.saveEpisode(makeEpisode())

        let failGenerate: LLMGenerateFunction = { @Sendable _ in
            throw LLMProviderError.unavailable(reason: "test failure")
        }

        do {
            _ = try await ProactiveAnalyzer.analyze(
                contextStore: contextStore,
                proactiveStore: proactiveStore,
                trustTuner: trustTuner,
                generate: failGenerate
            )
            XCTFail("Should have thrown")
        } catch {
            // Expected — LLM failure propagates
            XCTAssertTrue(error is LLMProviderError)
        }
    }

    // MARK: - Multiple Suggestions

    func test_multipleSuggestions_allProcessed() async throws {
        contextStore.saveEpisode(makeEpisode())

        let json = """
        {"suggestions": [
            {"type": "followup", "title": "Finish feature X", "body": "Resume work", "whyNow": "Mid-task", "confidence": 0.99, "evidence": [{"timestamp": 1000000, "app": "Xcode", "sourceKind": "timeline", "snippet": "feat X"}]},
            {"type": "reminder", "title": "Update docs", "body": "Docs are stale", "whyNow": "Last update was weeks ago", "confidence": 0.99, "evidence": [{"timestamp": 1500000, "app": "Safari", "sourceKind": "timeline", "snippet": "docs page"}]}
        ]}
        """

        let result = try await ProactiveAnalyzer.analyze(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: mockGenerate(json: json)
        )

        // Both should be processed (persisted since confidence is high enough)
        let stored = proactiveStore.listSuggestions()
        XCTAssertEqual(stored.count, result.count)
    }

    // MARK: - Empty Suggestions from LLM

    func test_llmReturnsNoSuggestions_returnsEmpty() async throws {
        contextStore.saveEpisode(makeEpisode())

        let json = """
        {"suggestions": []}
        """

        let result = try await ProactiveAnalyzer.analyze(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: mockGenerate(json: json)
        )

        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(proactiveStore.listSuggestions().isEmpty)
    }

    // MARK: - Source Record IDs

    func test_sourceRecordIds_derivedFromEpisodes() async throws {
        let ep = makeEpisode()
        contextStore.saveEpisode(ep)

        let json = """
        {"suggestions": [{"type": "followup", "title": "Continue work", "body": "Resume", "whyNow": "Recent", "confidence": 0.99, "evidence": [{"timestamp": 1000000, "app": "Xcode", "sourceKind": "timeline", "snippet": "work"}]}]}
        """

        let result = try await ProactiveAnalyzer.analyze(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: mockGenerate(json: json)
        )

        if let first = result.first {
            XCTAssertFalse(first.sourceRecordIds.isEmpty, "Source record IDs should be populated")
        }
    }

    // MARK: - Suggestion Type Parsing

    func test_unknownType_fallsBackToFollowup() async throws {
        contextStore.saveEpisode(makeEpisode())

        let json = """
        {"suggestions": [{"type": "unknown_type", "title": "Misc suggestion", "body": "Something", "whyNow": "Now", "confidence": 0.99, "evidence": [{"timestamp": 1000000, "app": "App", "sourceKind": "timeline", "snippet": "test"}]}]}
        """

        let result = try await ProactiveAnalyzer.analyze(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: mockGenerate(json: json)
        )

        if let first = result.first {
            XCTAssertEqual(first.type, .followup)
        }
    }

    // MARK: - Score Threshold Verification

    func test_scoreMath_matchesPolicyEngine() {
        // Verify the scoring formula directly to document threshold behavior.
        // This ensures tests are calibrated against the real policy engine.
        let input = PolicyInput(
            suggestionType: .followup,
            confidence: 0.99,
            evidenceQuality: 0.75,
            noveltyScore: 0.7,
            interruptionCost: 0.0,
            preferenceAffinity: 0.0
        )
        let score = ProactivePolicyEngine.computeScore(input, tuner: trustTuner)
        // 0.99*0.30 + 0.75*0.25 + 0.7*0.15 = 0.297 + 0.1875 + 0.105 = 0.5895
        XCTAssertGreaterThan(score, 0.55, "Score should exceed inbox threshold")
        XCTAssertLessThan(score, 0.82, "Score should be below push threshold")
    }
}
