import XCTest
@testable import Shadow

final class ProactivePolicyEngineTests: XCTestCase {

    private var tempDir: String!
    private var tuner: TrustTuner!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "PolicyTests-\(UUID().uuidString)"
        tuner = TrustTuner(baseDir: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Scoring Determinism

    func testIdenticalInputsProduceIdenticalScores() {
        let input = PolicyInput(
            suggestionType: .followup,
            confidence: 0.85,
            evidenceQuality: 0.90,
            noveltyScore: 0.70,
            interruptionCost: 0.10,
            preferenceAffinity: 0.50
        )

        let score1 = ProactivePolicyEngine.computeScore(input, tuner: tuner)
        let score2 = ProactivePolicyEngine.computeScore(input, tuner: tuner)
        XCTAssertEqual(score1, score2, accuracy: 1e-10, "Same inputs must produce same scores")
    }

    // MARK: - Decision Thresholds

    func testPushNowDecision() {
        let output = ProactivePolicyEngine.decide(score: 0.75, tuner: tuner)
        XCTAssertEqual(output.decision, .pushNow)
    }

    func testInboxOnlyDecision() {
        let output = ProactivePolicyEngine.decide(score: 0.50, tuner: tuner)
        XCTAssertEqual(output.decision, .inboxOnly)
    }

    func testDropDecision() {
        let output = ProactivePolicyEngine.decide(score: 0.20, tuner: tuner)
        XCTAssertEqual(output.decision, .drop)
    }

    func testBoundaryPushThreshold() {
        let output = ProactivePolicyEngine.decide(score: 0.60, tuner: tuner)
        XCTAssertEqual(output.decision, .pushNow, "Exactly at push threshold should push")
    }

    func testBoundaryInboxThreshold() {
        let output = ProactivePolicyEngine.decide(score: 0.35, tuner: tuner)
        XCTAssertEqual(output.decision, .inboxOnly, "Exactly at inbox threshold should go to inbox")
    }

    func testJustBelowInboxThreshold() {
        let output = ProactivePolicyEngine.decide(score: 0.349, tuner: tuner)
        XCTAssertEqual(output.decision, .drop)
    }

    // MARK: - Score Range

    func testScoreClampedToZeroOne() {
        let lowInput = PolicyInput(
            suggestionType: .followup,
            confidence: 0,
            evidenceQuality: 0,
            noveltyScore: 0,
            interruptionCost: 1.0,
            preferenceAffinity: 0
        )
        let score = ProactivePolicyEngine.computeScore(lowInput, tuner: tuner)
        XCTAssertGreaterThanOrEqual(score, 0)
        XCTAssertLessThanOrEqual(score, 1)
    }

    // MARK: - Cooldown

    func testCooldownActive() {
        let now = Date()
        let lastPush = now.addingTimeInterval(-100) // 100s ago, default cooldown is 300s

        let result = ProactivePolicyEngine.checkCooldown(
            type: .followup,
            lastPushTime: lastPush,
            now: now,
            tuner: tuner
        )
        XCTAssertNotNil(result, "Should be on cooldown")
        XCTAssert(result!.contains("remaining"))
    }

    func testCooldownExpired() {
        let now = Date()
        let lastPush = now.addingTimeInterval(-400) // 400s ago, default cooldown is 300s

        let result = ProactivePolicyEngine.checkCooldown(
            type: .followup,
            lastPushTime: lastPush,
            now: now,
            tuner: tuner
        )
        XCTAssertNil(result, "Cooldown should have expired")
    }

    func testCooldownNoLastPush() {
        let result = ProactivePolicyEngine.checkCooldown(
            type: .followup,
            lastPushTime: nil,
            now: Date(),
            tuner: tuner
        )
        XCTAssertNil(result, "No prior push means no cooldown")
    }

    // MARK: - Evidence Gate

    func testEvidenceRequiredForSuggestion() {
        let result = ProactivePolicyEngine.validateEvidence([])
        XCTAssertNotNil(result, "Empty evidence should fail validation")
    }

    func testEvidencePresent() {
        let evidence = [SuggestionEvidence(
            timestamp: 1_000_000, app: "Xcode", sourceKind: "search",
            displayId: 1, url: nil, snippet: "test"
        )]
        let result = ProactivePolicyEngine.validateEvidence(evidence)
        XCTAssertNil(result, "Non-empty evidence should pass")
    }

    // MARK: - Full Gate Check

    func testFullScreenSuppression() {
        let evidence = [SuggestionEvidence(
            timestamp: 1_000_000, app: "Keynote", sourceKind: "search",
            displayId: 1, url: nil, snippet: "slide"
        )]
        let result = ProactivePolicyEngine.checkGates(
            type: .followup,
            evidence: evidence,
            lastPushTime: nil,
            isFullScreen: true,
            isActiveTyping: false,
            now: Date(),
            tuner: tuner
        )
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("full-screen"))
    }

    func testActiveTypingSuppression() {
        let evidence = [SuggestionEvidence(
            timestamp: 1_000_000, app: "Xcode", sourceKind: "search",
            displayId: 1, url: nil, snippet: "code"
        )]
        let result = ProactivePolicyEngine.checkGates(
            type: .followup,
            evidence: evidence,
            lastPushTime: nil,
            isFullScreen: false,
            isActiveTyping: true,
            now: Date(),
            tuner: tuner
        )
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("typing"))
    }

    func testAllGatesPass() {
        let evidence = [SuggestionEvidence(
            timestamp: 1_000_000, app: "Xcode", sourceKind: "search",
            displayId: 1, url: nil, snippet: "code"
        )]
        let result = ProactivePolicyEngine.checkGates(
            type: .followup,
            evidence: evidence,
            lastPushTime: nil,
            isFullScreen: false,
            isActiveTyping: false,
            now: Date(),
            tuner: tuner
        )
        XCTAssertNil(result, "All gates should pass")
    }

    // MARK: - Repetition Penalty

    func testRepetitionPenaltyLowersScore() {
        let input = PolicyInput(
            suggestionType: .followup,
            confidence: 0.85,
            evidenceQuality: 0.90,
            noveltyScore: 0.70,
            interruptionCost: 0.10,
            preferenceAffinity: 0.50
        )

        let scoreNoRepetition = ProactivePolicyEngine.computeScore(input, tuner: tuner)

        // Apply some thumbsDown feedback to increase repetition penalty
        let feedback = ProactiveFeedback(
            id: UUID(), suggestionId: UUID(), eventType: .thumbsDown,
            timestamp: Date(), foregroundApp: nil, displayId: nil
        )
        tuner.applyFeedback(feedback, suggestionType: .followup)

        let scoreWithRepetition = ProactivePolicyEngine.computeScore(input, tuner: tuner)
        XCTAssertLessThan(scoreWithRepetition, scoreNoRepetition, "Repetition penalty should lower score")
    }
}
