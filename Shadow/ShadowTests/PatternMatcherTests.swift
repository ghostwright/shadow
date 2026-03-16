import XCTest
@testable import Shadow

final class PatternMatcherTests: XCTestCase {

    private var tempDir: URL!
    private var store: PatternStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatternMatcherTests-\(UUID().uuidString)")
        store = PatternStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makePattern(
        id: String = UUID().uuidString,
        task: String,
        app: String,
        successCount: Int = 1,
        failureCount: Int = 0,
        notes: [String] = []
    ) -> AgentPattern {
        let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        return AgentPattern(
            id: id,
            taskDescription: task,
            targetApp: app,
            urlPattern: nil,
            toolSequence: [
                PatternStep(toolName: "ax_focus_app", purpose: "Focus app", keyArguments: ["app": app], expectedOutcome: nil)
            ],
            notes: notes,
            successCount: successCount,
            failureCount: failureCount,
            createdAt: nowUs,
            lastUsedAt: nowUs,
            archived: false
        )
    }

    // MARK: - findAndFormat Tests

    func testFindAndFormatReturnsEmptyWhenNoPatterns() {
        let result = PatternMatcher.findAndFormat(query: "anything", store: store)
        XCTAssertEqual(result, "")
    }

    func testFindAndFormatReturnsFormattedPatterns() {
        store.save(makePattern(task: "Add item to Amazon cart", app: "Chrome"))
        let result = PatternMatcher.findAndFormat(query: "add to Amazon cart", store: store)
        XCTAssertTrue(result.contains("Relevant Patterns"))
        XCTAssertTrue(result.contains("Amazon cart"))
    }

    func testFindAndFormatNoMatchReturnsEmpty() {
        store.save(makePattern(task: "Send email via Gmail", app: "Chrome"))
        let result = PatternMatcher.findAndFormat(query: "play music on Spotify", store: store)
        XCTAssertEqual(result, "")
    }

    // MARK: - recordOutcome Tests

    func testRecordOutcomeSuccess() {
        let pattern = makePattern(id: "p1", task: "Test", app: "App", successCount: 1)
        store.save(pattern)

        PatternMatcher.recordOutcome(patternIds: ["p1"], success: true, store: store)

        let updated = store.get("p1")
        XCTAssertEqual(updated?.successCount, 2)
    }

    func testRecordOutcomeFailure() {
        let pattern = makePattern(id: "p1", task: "Test", app: "App", successCount: 1, failureCount: 0)
        store.save(pattern)

        PatternMatcher.recordOutcome(patternIds: ["p1"], success: false, store: store)

        let updated = store.get("p1")
        XCTAssertEqual(updated?.failureCount, 1)
    }

    func testRecordOutcomeDecayArchives() {
        // Pattern with high failure-to-success ratio
        let pattern = makePattern(id: "p-decay", task: "Flaky task", app: "App",
                                  successCount: 1, failureCount: 2)
        store.save(pattern)

        // One more failure should trigger archive (3 > 1*2 && 3 > 2)
        PatternMatcher.recordOutcome(patternIds: ["p-decay"], success: false, store: store)

        XCTAssertNil(store.get("p-decay"), "Pattern should be archived after decay threshold")
    }

    func testRecordOutcomeIgnoresUnknownIds() {
        // Should not crash when pattern ID is not found
        PatternMatcher.recordOutcome(patternIds: ["nonexistent"], success: true, store: store)
        XCTAssertEqual(store.count, 0)
    }

    func testRecordOutcomeMultiplePatterns() {
        store.save(makePattern(id: "p1", task: "Task one", app: "App"))
        store.save(makePattern(id: "p2", task: "Task two", app: "Other"))

        PatternMatcher.recordOutcome(patternIds: ["p1", "p2"], success: true, store: store)

        XCTAssertEqual(store.get("p1")?.successCount, 2)
        XCTAssertEqual(store.get("p2")?.successCount, 2)
    }

    // MARK: - Integration

    func testPatternLifecycle_extractMatchReuse() {
        // 1. Save a pattern (simulating extraction)
        let pattern = makePattern(
            id: "p-lifecycle",
            task: "Add item to Amazon cart",
            app: "Chrome",
            notes: ["Use direct URL for faster navigation"]
        )
        store.save(pattern)

        // 2. Find it via query
        let matched = store.findRelevant(query: "add product to Amazon")
        XCTAssertFalse(matched.isEmpty)
        XCTAssertEqual(matched.first?.id, "p-lifecycle")

        // 3. Record successful reuse
        PatternMatcher.recordOutcome(patternIds: ["p-lifecycle"], success: true, store: store)
        XCTAssertEqual(store.get("p-lifecycle")?.successCount, 2)

        // 4. Pattern still matchable
        let matched2 = store.findRelevant(query: "add to Amazon cart")
        XCTAssertFalse(matched2.isEmpty)
    }
}
