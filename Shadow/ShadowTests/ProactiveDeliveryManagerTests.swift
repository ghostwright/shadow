import XCTest
@testable import Shadow

final class ProactiveDeliveryManagerTests: XCTestCase {

    private var tempDir: String!
    private var proactiveStore: ProactiveStore!
    private var trustTuner: TrustTuner!

    override func setUp() {
        super.setUp()
        let base = NSTemporaryDirectory() + "DeliveryManagerTests_\(UUID().uuidString)"
        tempDir = base
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        proactiveStore = ProactiveStore(baseDir: base + "/proactive")
        trustTuner = TrustTuner(baseDir: base + "/trust")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSuggestion(
        decision: SuggestionDecision,
        title: String = "Test suggestion",
        confidence: Double = 0.85
    ) -> ProactiveSuggestion {
        let suggestion = ProactiveSuggestion(
            id: UUID(),
            createdAt: Date(),
            type: .followup,
            title: title,
            body: "Test body",
            whyNow: "Test reason",
            confidence: confidence,
            decision: decision,
            evidence: [
                SuggestionEvidence(timestamp: 1_000_000, app: "Xcode", sourceKind: "timeline", displayId: nil, url: nil, snippet: "test")
            ],
            sourceRecordIds: ["ep-1"],
            status: .active
        )
        proactiveStore.saveSuggestion(suggestion)
        return suggestion
    }

    @MainActor
    private func makeManager() -> ProactiveDeliveryManager {
        ProactiveDeliveryManager(proactiveStore: proactiveStore, trustTuner: trustTuner)
    }

    // MARK: - Delivery Routing

    @MainActor
    func test_pushNow_overlayEnabled_countsDelivery() {
        let manager = makeManager()
        let suggestion = makeSuggestion(decision: .pushNow)

        // No overlay controller wired — but counter should still increment if push is enabled
        UserDefaults.standard.set(true, forKey: ProactiveDeliveryManager.pushEnabledKey)
        UserDefaults.standard.set(true, forKey: ProactiveDeliveryManager.overlayEnabledKey)
        defer {
            UserDefaults.standard.removeObject(forKey: ProactiveDeliveryManager.pushEnabledKey)
            UserDefaults.standard.removeObject(forKey: ProactiveDeliveryManager.overlayEnabledKey)
        }

        manager.deliverSuggestions([suggestion])
        // Overlay controller is nil, so show() is a no-op, but the routing logic runs
        // Verify the manager doesn't crash with nil overlay
    }

    @MainActor
    func test_pushNow_overlayDisabled_noOverlayCall() {
        let manager = makeManager()
        let suggestion = makeSuggestion(decision: .pushNow)

        UserDefaults.standard.set(true, forKey: ProactiveDeliveryManager.pushEnabledKey)
        UserDefaults.standard.set(false, forKey: ProactiveDeliveryManager.overlayEnabledKey)
        defer {
            UserDefaults.standard.removeObject(forKey: ProactiveDeliveryManager.pushEnabledKey)
            UserDefaults.standard.removeObject(forKey: ProactiveDeliveryManager.overlayEnabledKey)
        }

        // Should not crash, overlay is suppressed
        manager.deliverSuggestions([suggestion])

        // Suggestion still in store as push_now (no downgrade)
        let stored = proactiveStore.findSuggestion(id: suggestion.id)
        XCTAssertEqual(stored?.decision, .pushNow)
    }

    @MainActor
    func test_pushDisabled_noOverlay() {
        let manager = makeManager()
        let suggestion = makeSuggestion(decision: .pushNow)

        UserDefaults.standard.set(false, forKey: ProactiveDeliveryManager.pushEnabledKey)
        defer {
            UserDefaults.standard.removeObject(forKey: ProactiveDeliveryManager.pushEnabledKey)
        }

        manager.deliverSuggestions([suggestion])

        // Still in store, decision preserved
        let stored = proactiveStore.findSuggestion(id: suggestion.id)
        XCTAssertEqual(stored?.decision, .pushNow)
        XCTAssertEqual(stored?.status, .active)
    }

    @MainActor
    func test_inboxOnly_neverShowsOverlay() {
        let manager = makeManager()
        let suggestion = makeSuggestion(decision: .inboxOnly)

        // Inbox-only should never trigger overlay, just increment counter
        manager.deliverSuggestions([suggestion])

        let stored = proactiveStore.findSuggestion(id: suggestion.id)
        XCTAssertEqual(stored?.decision, .inboxOnly)
    }

    @MainActor
    func test_dropDecision_ignored() {
        // Drop suggestions should never reach delivery manager, but verify graceful handling
        let suggestion = ProactiveSuggestion(
            id: UUID(),
            createdAt: Date(),
            type: .followup,
            title: "Dropped",
            body: "body",
            whyNow: "reason",
            confidence: 0.3,
            decision: .drop,
            evidence: [],
            sourceRecordIds: [],
            status: .active
        )

        let manager = makeManager()
        manager.deliverSuggestions([suggestion])
        // Should not crash
    }

    @MainActor
    func test_multipleSuggestions_eachProcessed() {
        let manager = makeManager()
        let s1 = makeSuggestion(decision: .pushNow, title: "Push 1")
        let s2 = makeSuggestion(decision: .inboxOnly, title: "Inbox 1")
        let s3 = makeSuggestion(decision: .pushNow, title: "Push 2")

        manager.deliverSuggestions([s1, s2, s3])

        // All should still be in store
        XCTAssertNotNil(proactiveStore.findSuggestion(id: s1.id))
        XCTAssertNotNil(proactiveStore.findSuggestion(id: s2.id))
        XCTAssertNotNil(proactiveStore.findSuggestion(id: s3.id))
    }

    // MARK: - Feedback

    @MainActor
    func test_recordFeedback_thumbsUp_statusActed() {
        let suggestion = makeSuggestion(decision: .pushNow)
        let manager = makeManager()

        manager.recordFeedback(suggestionId: suggestion.id, eventType: .thumbsUp)

        let stored = proactiveStore.findSuggestion(id: suggestion.id)
        XCTAssertEqual(stored?.status, .acted)
    }

    @MainActor
    func test_recordFeedback_thumbsDown_statusDismissed() {
        let suggestion = makeSuggestion(decision: .pushNow)
        let manager = makeManager()

        manager.recordFeedback(suggestionId: suggestion.id, eventType: .thumbsDown)

        let stored = proactiveStore.findSuggestion(id: suggestion.id)
        XCTAssertEqual(stored?.status, .dismissed)
    }

    @MainActor
    func test_recordFeedback_dismiss_statusDismissed() {
        let suggestion = makeSuggestion(decision: .inboxOnly)
        let manager = makeManager()

        manager.recordFeedback(suggestionId: suggestion.id, eventType: .dismiss)

        let stored = proactiveStore.findSuggestion(id: suggestion.id)
        XCTAssertEqual(stored?.status, .dismissed)
    }

    @MainActor
    func test_recordFeedback_snooze_statusSnoozed() {
        let suggestion = makeSuggestion(decision: .inboxOnly)
        let manager = makeManager()

        manager.recordFeedback(suggestionId: suggestion.id, eventType: .snooze)

        let stored = proactiveStore.findSuggestion(id: suggestion.id)
        XCTAssertEqual(stored?.status, .snoozed)
    }

    @MainActor
    func test_recordFeedback_persistsFeedbackToStore() {
        let suggestion = makeSuggestion(decision: .pushNow)
        let manager = makeManager()

        manager.recordFeedback(suggestionId: suggestion.id, eventType: .thumbsUp)

        let feedback = proactiveStore.feedbackForSuggestion(id: suggestion.id)
        XCTAssertEqual(feedback.count, 1)
        XCTAssertEqual(feedback[0].eventType, .thumbsUp)
        XCTAssertEqual(feedback[0].suggestionId, suggestion.id)
    }

    @MainActor
    func test_recordFeedback_appliesTunerFeedback() {
        let suggestion = makeSuggestion(decision: .pushNow)
        let manager = makeManager()

        let paramsBefore = trustTuner.effectiveParameters()
        manager.recordFeedback(suggestionId: suggestion.id, eventType: .thumbsUp)
        let paramsAfter = trustTuner.effectiveParameters()

        // Thumbs up should lower confidence threshold (make more permissive)
        XCTAssertLessThan(paramsAfter.confidenceThreshold, paramsBefore.confidenceThreshold)
    }

    @MainActor
    func test_recordFeedback_incrementsDiagnostics() {
        let suggestion = makeSuggestion(decision: .pushNow)
        let manager = makeManager()

        let before = DiagnosticsStore.shared.counter("proactive_feedback_thumbs_up_total")
        manager.recordFeedback(suggestionId: suggestion.id, eventType: .thumbsUp)
        let after = DiagnosticsStore.shared.counter("proactive_feedback_thumbs_up_total")

        XCTAssertEqual(after, before + 1)
    }
}
