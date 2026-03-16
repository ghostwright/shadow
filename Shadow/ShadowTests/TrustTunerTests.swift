import XCTest
@testable import Shadow

final class TrustTunerTests: XCTestCase {

    private var tempDir: String!
    private var tuner: TrustTuner!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "TrustTunerTests-\(UUID().uuidString)"
        tuner = TrustTuner(baseDir: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Defaults

    func testDefaultParameters() {
        let params = tuner.effectiveParameters()
        XCTAssertEqual(params.confidenceThreshold, 0.60)
        XCTAssertEqual(params.inboxThreshold, 0.35)
        XCTAssertEqual(params.repetitionPenalty, 0.0)
        XCTAssertEqual(params.defaultCooldownSeconds, 300)
        XCTAssertTrue(params.cooldownByType.isEmpty)
        XCTAssertTrue(params.preferredSuggestionTypes.isEmpty)
    }

    // MARK: - Feedback Updates

    func testThumbsUpLowersConfidenceThreshold() {
        let before = tuner.effectiveParameters().confidenceThreshold
        let fb = makeFeedback(.thumbsUp)
        tuner.applyFeedback(fb, suggestionType: .followup)

        let after = tuner.effectiveParameters().confidenceThreshold
        XCTAssertLessThan(after, before, "Thumbs up should lower push threshold")
        XCTAssertEqual(after, before - TrustTuner.maxConfidenceStep, accuracy: 1e-10)
    }

    func testThumbsDownRaisesConfidenceThreshold() {
        let before = tuner.effectiveParameters().confidenceThreshold
        let fb = makeFeedback(.thumbsDown)
        tuner.applyFeedback(fb, suggestionType: .followup)

        let after = tuner.effectiveParameters().confidenceThreshold
        XCTAssertGreaterThan(after, before, "Thumbs down should raise push threshold")
    }

    func testThumbsDownIncreasesRepetitionPenalty() {
        let before = tuner.effectiveParameters().repetitionPenalty
        let fb = makeFeedback(.thumbsDown)
        tuner.applyFeedback(fb, suggestionType: .followup)

        let after = tuner.effectiveParameters().repetitionPenalty
        XCTAssertGreaterThan(after, before)
    }

    func testDismissIncreasesCooldown() {
        let fb = makeFeedback(.dismiss)
        tuner.applyFeedback(fb, suggestionType: .followup)

        let params = tuner.effectiveParameters()
        let cooldown = params.cooldownByType[.followup]
        XCTAssertNotNil(cooldown)
        XCTAssertGreaterThan(cooldown!, params.defaultCooldownSeconds,
                             "Dismiss should increase type-specific cooldown above default")
    }

    func testSnoozeIncreasesCooldownMoreThanDismiss() {
        let dismissTuner = TrustTuner(baseDir: tempDir + "/dismiss")
        let snoozeTuner = TrustTuner(baseDir: tempDir + "/snooze")

        dismissTuner.applyFeedback(makeFeedback(.dismiss), suggestionType: .followup)
        snoozeTuner.applyFeedback(makeFeedback(.snooze), suggestionType: .followup)

        let dismissCooldown = dismissTuner.effectiveParameters().cooldownByType[.followup] ?? 0
        let snoozeCooldown = snoozeTuner.effectiveParameters().cooldownByType[.followup] ?? 0
        XCTAssertGreaterThan(snoozeCooldown, dismissCooldown,
                             "Snooze should increase cooldown more than dismiss")
    }

    func testThumbsUpBoostsPreference() {
        let fb = makeFeedback(.thumbsUp)
        tuner.applyFeedback(fb, suggestionType: .meetingPrep)

        let pref = tuner.effectiveParameters().preferredSuggestionTypes[.meetingPrep]
        XCTAssertNotNil(pref)
        XCTAssertGreaterThan(pref!, 0, "Thumbs up should boost preference")
    }

    func testThumbsDownPenalizesPreference() {
        let fb = makeFeedback(.thumbsDown)
        tuner.applyFeedback(fb, suggestionType: .meetingPrep)

        let pref = tuner.effectiveParameters().preferredSuggestionTypes[.meetingPrep]
        XCTAssertNotNil(pref)
        XCTAssertLessThan(pref!, 0, "Thumbs down should penalize preference")
    }

    // MARK: - Bounded Step Sizes

    func testConfidenceCannotExceedUpperBound() {
        // Apply many thumbs_down to push threshold up
        for _ in 0..<100 {
            tuner.applyFeedback(makeFeedback(.thumbsDown), suggestionType: .followup)
        }

        let threshold = tuner.effectiveParameters().confidenceThreshold
        XCTAssertLessThanOrEqual(threshold, TrustTuner.confidenceRange.upperBound)
    }

    func testConfidenceCannotGoBelowLowerBound() {
        // Apply many thumbs_up to push threshold down
        for _ in 0..<100 {
            tuner.applyFeedback(makeFeedback(.thumbsUp), suggestionType: .followup)
        }

        let threshold = tuner.effectiveParameters().confidenceThreshold
        XCTAssertGreaterThanOrEqual(threshold, TrustTuner.confidenceRange.lowerBound)
    }

    func testRepetitionPenaltyBounded() {
        for _ in 0..<100 {
            tuner.applyFeedback(makeFeedback(.thumbsDown), suggestionType: .followup)
        }

        let penalty = tuner.effectiveParameters().repetitionPenalty
        XCTAssertLessThanOrEqual(penalty, TrustTuner.repetitionRange.upperBound)
    }

    func testCooldownBounded() {
        for _ in 0..<100 {
            tuner.applyFeedback(makeFeedback(.snooze), suggestionType: .followup)
        }

        let cooldown = tuner.effectiveParameters().cooldownByType[.followup] ?? 0
        XCTAssertLessThanOrEqual(cooldown, TrustTuner.cooldownRange.upperBound)
    }

    // MARK: - Persistence

    func testPersistenceAcrossInstances() {
        tuner.applyFeedback(makeFeedback(.thumbsUp), suggestionType: .followup)

        let params1 = tuner.effectiveParameters()

        // Create new tuner instance from same directory
        let tuner2 = TrustTuner(baseDir: tempDir)
        let params2 = tuner2.effectiveParameters()

        XCTAssertEqual(params1.confidenceThreshold, params2.confidenceThreshold, accuracy: 1e-10)
    }

    // MARK: - Reset

    func testResetRestoresDefaults() {
        tuner.applyFeedback(makeFeedback(.thumbsDown), suggestionType: .followup)
        tuner.applyFeedback(makeFeedback(.thumbsDown), suggestionType: .followup)

        let modified = tuner.effectiveParameters()
        XCTAssertNotEqual(modified.confidenceThreshold, TrustParameters.defaults.confidenceThreshold)

        tuner.reset()

        let reset = tuner.effectiveParameters()
        XCTAssertEqual(reset.confidenceThreshold, TrustParameters.defaults.confidenceThreshold)
        XCTAssertEqual(reset.repetitionPenalty, TrustParameters.defaults.repetitionPenalty)
    }

    // MARK: - Threshold Invariant

    func testConfidenceNeverDropsBelowInbox() {
        // Apply 100 thumbsUp to push confidence as low as possible
        for _ in 0..<100 {
            tuner.applyFeedback(makeFeedback(.thumbsUp), suggestionType: .followup)
        }

        let params = tuner.effectiveParameters()
        XCTAssertGreaterThanOrEqual(
            params.confidenceThreshold,
            params.inboxThreshold + TrustTuner.thresholdGap,
            "confidenceThreshold must stay above inboxThreshold + gap"
        )
    }

    func testThresholdInvariantEnforcedOnLoad() {
        // Manually write corrupt parameters where confidence < inbox + gap
        let corruptParams = TrustParameters(
            confidenceThreshold: 0.50,  // below inbox(0.55) + gap(0.05)
            inboxThreshold: 0.55,
            repetitionPenalty: 0.0,
            cooldownByType: [:],
            defaultCooldownSeconds: 300,
            preferredSuggestionTypes: [:]
        )

        // Write directly to file
        let filePath = (tempDir as NSString).appendingPathComponent("trust_parameters.json")
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(corruptParams) {
            try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        }

        // Load from disk — invariant should be enforced
        let loadedTuner = TrustTuner(baseDir: tempDir)
        let params = loadedTuner.effectiveParameters()
        XCTAssertGreaterThanOrEqual(
            params.confidenceThreshold,
            params.inboxThreshold + TrustTuner.thresholdGap,
            "Invariant should be enforced on load from disk"
        )
    }

    func testThresholdInvariantAfterReset() {
        tuner.reset()
        let params = tuner.effectiveParameters()
        XCTAssertGreaterThanOrEqual(
            params.confidenceThreshold,
            params.inboxThreshold + TrustTuner.thresholdGap,
            "Invariant should hold after reset"
        )
    }

    // MARK: - Helpers

    private func makeFeedback(_ eventType: FeedbackEventType) -> ProactiveFeedback {
        ProactiveFeedback(
            id: UUID(),
            suggestionId: UUID(),
            eventType: eventType,
            timestamp: Date(),
            foregroundApp: nil,
            displayId: nil
        )
    }
}
