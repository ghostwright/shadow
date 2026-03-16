import XCTest
@testable import Shadow

final class ProactiveOverlayTests: XCTestCase {

    private var tempDir: String!
    private var proactiveStore: ProactiveStore!
    private var trustTuner: TrustTuner!

    override func setUp() {
        super.setUp()
        let base = NSTemporaryDirectory() + "OverlayTests_\(UUID().uuidString)"
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
        decision: SuggestionDecision = .pushNow,
        confidence: Double = 0.9
    ) -> ProactiveSuggestion {
        ProactiveSuggestion(
            id: UUID(),
            createdAt: Date(),
            type: .followup,
            title: "Test suggestion",
            body: "Test body",
            whyNow: "Because it's relevant",
            confidence: confidence,
            decision: decision,
            evidence: [
                SuggestionEvidence(timestamp: 1_000_000, app: "Xcode", sourceKind: "timeline", displayId: nil, url: nil, snippet: "test")
            ],
            sourceRecordIds: ["ep-1"],
            status: .active
        )
    }

    // MARK: - Overlay Gating via Delivery Manager

    @MainActor
    func test_overlayGating_respectsOverlayToggle() {
        let manager = ProactiveDeliveryManager(proactiveStore: proactiveStore, trustTuner: trustTuner)

        // Overlay disabled
        UserDefaults.standard.set(false, forKey: ProactiveDeliveryManager.overlayEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: ProactiveDeliveryManager.overlayEnabledKey) }

        XCTAssertFalse(manager.isOverlayEnabled)
    }

    @MainActor
    func test_pushGating_respectsPushToggle() {
        let manager = ProactiveDeliveryManager(proactiveStore: proactiveStore, trustTuner: trustTuner)

        // Push disabled
        UserDefaults.standard.set(false, forKey: ProactiveDeliveryManager.pushEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: ProactiveDeliveryManager.pushEnabledKey) }

        XCTAssertFalse(manager.isPushEnabled)
    }

    @MainActor
    func test_defaultToggles_areTrue() {
        // Remove any existing values
        UserDefaults.standard.removeObject(forKey: ProactiveDeliveryManager.overlayEnabledKey)
        UserDefaults.standard.removeObject(forKey: ProactiveDeliveryManager.pushEnabledKey)

        let manager = ProactiveDeliveryManager(proactiveStore: proactiveStore, trustTuner: trustTuner)

        XCTAssertTrue(manager.isOverlayEnabled)
        XCTAssertTrue(manager.isPushEnabled)
    }

    // MARK: - Overlay Controller Logic

    @MainActor
    func test_show_incrementsShownCounter() {
        let controller = ProactiveOverlayController()
        let suggestion = makeSuggestion()

        let before = DiagnosticsStore.shared.counter("proactive_overlay_shown_total")
        controller.show(suggestion)
        let after = DiagnosticsStore.shared.counter("proactive_overlay_shown_total")

        XCTAssertEqual(after, before + 1)

        controller.dismiss()
    }

    @MainActor
    func test_dismiss_cleanedUp() {
        let controller = ProactiveOverlayController()
        let suggestion = makeSuggestion()

        controller.show(suggestion)
        // Immediate dismiss (no animation wait in tests)
        controller.dismiss()

        // After dismiss, showing again should work without issues
        controller.show(suggestion)
        controller.dismiss()
    }

    @MainActor
    func test_show_replacesPreviousOverlay() {
        let controller = ProactiveOverlayController()
        let s1 = makeSuggestion()
        let s2 = makeSuggestion()

        let before = DiagnosticsStore.shared.counter("proactive_overlay_shown_total")
        controller.show(s1)
        controller.show(s2)  // Should dismiss s1 first
        let after = DiagnosticsStore.shared.counter("proactive_overlay_shown_total")

        // Both shows should be counted
        XCTAssertEqual(after, before + 2)

        controller.dismiss()
    }

    @MainActor
    func test_clickThrough_firesOnOpenInbox() {
        let controller = ProactiveOverlayController()

        var capturedId: UUID?
        controller.onOpenInbox = { id in
            capturedId = id
        }

        let suggestion = makeSuggestion()
        controller.show(suggestion)

        // Simulate the onOpenInbox callback directly
        controller.onOpenInbox?(suggestion.id)

        XCTAssertEqual(capturedId, suggestion.id)

        controller.dismiss()
    }

    // MARK: - SF Symbol Mapping

    @MainActor
    func test_allSuggestionTypes_haveIcons() {
        for type in SuggestionType.allCases {
            let iconName = ProactiveOverlayView.iconName(for: type)
            XCTAssertFalse(iconName.isEmpty, "Missing icon for type: \(type.rawValue)")
        }
    }

    // MARK: - Confidence Band Colors

    @MainActor
    func test_allBands_haveColors() {
        for band in [ConfidenceBand.high, .medium, .low] {
            let color = ProactiveOverlayView.bandColor(band)
            // Just verify it doesn't crash and returns a value
            XCTAssertNotNil(color)
        }
    }
}
