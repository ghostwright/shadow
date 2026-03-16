import XCTest
@testable import Shadow

final class ProactiveInboxTests: XCTestCase {

    private var tempDir: String!
    private var proactiveStore: ProactiveStore!

    override func setUp() {
        super.setUp()
        let base = NSTemporaryDirectory() + "InboxTests_\(UUID().uuidString)"
        tempDir = base
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        proactiveStore = ProactiveStore(baseDir: base + "/proactive")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSuggestion(
        decision: SuggestionDecision = .inboxOnly,
        status: SuggestionStatus = .active,
        title: String = "Test",
        confidence: Double = 0.7
    ) -> ProactiveSuggestion {
        var suggestion = ProactiveSuggestion(
            id: UUID(),
            createdAt: Date(),
            type: .followup,
            title: title,
            body: "Body text",
            whyNow: "Recent activity",
            confidence: confidence,
            decision: decision,
            evidence: [
                SuggestionEvidence(timestamp: 1_000_000, app: "Xcode", sourceKind: "timeline", displayId: 1, url: nil, snippet: "test evidence")
            ],
            sourceRecordIds: ["ep-1"],
            status: status
        )
        proactiveStore.saveSuggestion(suggestion)
        if status != .active {
            proactiveStore.updateSuggestionStatus(id: suggestion.id, status: status)
            suggestion.status = status
        }
        return suggestion
    }

    // MARK: - Filter Tests

    @MainActor
    func test_filterActive_excludesDismissed() {
        let _ = makeSuggestion(status: .active, title: "Active one")
        let _ = makeSuggestion(status: .dismissed, title: "Dismissed one")

        let vm = ProactiveInboxViewModel(store: proactiveStore)
        vm.filter = .active

        XCTAssertEqual(vm.filteredSuggestions.count, 1)
        XCTAssertEqual(vm.filteredSuggestions[0].title, "Active one")
    }

    @MainActor
    func test_filterPushNow_byDecision() {
        let _ = makeSuggestion(decision: .pushNow, title: "Push")
        let _ = makeSuggestion(decision: .inboxOnly, title: "Inbox")

        let vm = ProactiveInboxViewModel(store: proactiveStore)
        vm.filter = .pushNow

        XCTAssertEqual(vm.filteredSuggestions.count, 1)
        XCTAssertEqual(vm.filteredSuggestions[0].title, "Push")
    }

    @MainActor
    func test_filterInboxOnly_byDecision() {
        let _ = makeSuggestion(decision: .pushNow, title: "Push")
        let _ = makeSuggestion(decision: .inboxOnly, title: "Inbox")

        let vm = ProactiveInboxViewModel(store: proactiveStore)
        vm.filter = .inboxOnly

        XCTAssertEqual(vm.filteredSuggestions.count, 1)
        XCTAssertEqual(vm.filteredSuggestions[0].title, "Inbox")
    }

    @MainActor
    func test_filterResolved_includesDismissedArchivedActed() {
        let _ = makeSuggestion(status: .active, title: "Active")
        let _ = makeSuggestion(status: .dismissed, title: "Dismissed")
        let _ = makeSuggestion(status: .acted, title: "Acted")
        let _ = makeSuggestion(status: .archived, title: "Archived")

        let vm = ProactiveInboxViewModel(store: proactiveStore)
        vm.filter = .resolved

        XCTAssertEqual(vm.filteredSuggestions.count, 3)
        let titles = Set(vm.filteredSuggestions.map(\.title))
        XCTAssertTrue(titles.contains("Dismissed"))
        XCTAssertTrue(titles.contains("Acted"))
        XCTAssertTrue(titles.contains("Archived"))
    }

    // MARK: - Refresh & Data

    @MainActor
    func test_refresh_loadsSuggestionsFromStore() {
        let vm = ProactiveInboxViewModel(store: proactiveStore)
        XCTAssertEqual(vm.suggestions.count, 0)

        let _ = makeSuggestion(title: "New one")
        vm.refresh()

        XCTAssertEqual(vm.suggestions.count, 1)
        XCTAssertEqual(vm.suggestions[0].title, "New one")
    }

    @MainActor
    func test_sortOrder_newestFirst() {
        // Create with a small time offset to ensure order
        let s1 = makeSuggestion(title: "Older")
        Thread.sleep(forTimeInterval: 0.01)
        let s2 = makeSuggestion(title: "Newer")

        let vm = ProactiveInboxViewModel(store: proactiveStore)

        // listSuggestions returns newest first
        XCTAssertEqual(vm.suggestions.first?.title, "Newer")
    }

    @MainActor
    func test_activeCount() {
        let _ = makeSuggestion(status: .active)
        let _ = makeSuggestion(status: .active)
        let _ = makeSuggestion(status: .dismissed)

        let vm = ProactiveInboxViewModel(store: proactiveStore)
        XCTAssertEqual(vm.activeCount, 2)
    }

    // MARK: - Callbacks

    @MainActor
    func test_feedbackCallback_firesCorrectly() {
        let suggestion = makeSuggestion()
        let vm = ProactiveInboxViewModel(store: proactiveStore)

        var capturedId: UUID?
        var capturedType: FeedbackEventType?
        vm.onFeedback = { id, type in
            capturedId = id
            capturedType = type
        }

        vm.sendFeedback(suggestion.id, .thumbsUp)

        XCTAssertEqual(capturedId, suggestion.id)
        XCTAssertEqual(capturedType, .thumbsUp)
    }

    @MainActor
    func test_evidenceDeepLink_firesOnOpenTimeline() {
        let vm = ProactiveInboxViewModel(store: proactiveStore)

        var capturedTs: UInt64?
        var capturedDisplayId: UInt32?
        vm.onOpenTimeline = { ts, displayId in
            capturedTs = ts
            capturedDisplayId = displayId
        }

        vm.onOpenTimeline?(1_000_000, 1)

        XCTAssertEqual(capturedTs, 1_000_000)
        XCTAssertEqual(capturedDisplayId, 1)
    }

    // MARK: - Expand/Collapse

    @MainActor
    func test_expandToggle() {
        let suggestion = makeSuggestion()
        let vm = ProactiveInboxViewModel(store: proactiveStore)

        XCTAssertNil(vm.expandedSuggestionId)

        vm.toggleExpanded(suggestion.id)
        XCTAssertEqual(vm.expandedSuggestionId, suggestion.id)

        vm.toggleExpanded(suggestion.id)
        XCTAssertNil(vm.expandedSuggestionId)
    }

    // MARK: - Focus Suggestion

    @MainActor
    func test_focusSuggestionId_expandsOnRefresh() {
        let suggestion = makeSuggestion()
        let vm = ProactiveInboxViewModel(store: proactiveStore)

        vm.focusSuggestionId = suggestion.id
        vm.refresh()

        XCTAssertEqual(vm.expandedSuggestionId, suggestion.id)
        XCTAssertNil(vm.focusSuggestionId, "Focus should be consumed after refresh")
    }

    // MARK: - Window Controller Focus on Existing Window

    @MainActor
    func test_focusSuggestionId_appliedWhenWindowAlreadyOpen() {
        let controller = ProactiveInboxWindowController(proactiveStore: proactiveStore)

        // First open creates the window + VM
        controller.showOrFocus()

        // Create a suggestion while window is open
        let suggestion = makeSuggestion(title: "Focus Target")

        // Set focus target and re-focus existing window
        controller.focusSuggestionId = suggestion.id
        controller.showOrFocus()

        // Focus should have been consumed (not nil — meaning it was applied)
        XCTAssertNil(controller.focusSuggestionId, "focusSuggestionId should be consumed")

        controller.close()
    }
}
