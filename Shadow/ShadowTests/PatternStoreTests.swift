import XCTest
@testable import Shadow

final class PatternStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: PatternStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatternStoreTests-\(UUID().uuidString)")
        store = PatternStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makePattern(
        id: String = UUID().uuidString,
        task: String = "Test task",
        app: String = "TestApp",
        urlPattern: String? = nil,
        steps: [PatternStep] = [],
        notes: [String] = [],
        successCount: Int = 1,
        failureCount: Int = 0
    ) -> AgentPattern {
        let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        return AgentPattern(
            id: id,
            taskDescription: task,
            targetApp: app,
            urlPattern: urlPattern,
            toolSequence: steps,
            notes: notes,
            successCount: successCount,
            failureCount: failureCount,
            createdAt: nowUs,
            lastUsedAt: nowUs,
            archived: false
        )
    }

    // MARK: - CRUD Tests

    func testSaveAndGet() {
        let pattern = makePattern(id: "p1", task: "Add to cart")
        store.save(pattern)

        let retrieved = store.get("p1")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.taskDescription, "Add to cart")
    }

    func testSavePersistsToDisk() {
        let pattern = makePattern(id: "p-disk")
        store.save(pattern)

        // Create a new store pointing at the same directory
        let store2 = PatternStore(directory: tempDir)
        store2.loadIfNeeded()
        let retrieved = store2.get("p-disk")
        XCTAssertNotNil(retrieved)
    }

    func testAllPatterns() {
        store.save(makePattern(id: "a", task: "Task A", app: "AppA"))
        store.save(makePattern(id: "b", task: "Task B", app: "AppB"))
        store.save(makePattern(id: "c", task: "Task C", app: "AppC"))

        XCTAssertEqual(store.allPatterns.count, 3)
        XCTAssertEqual(store.count, 3)
    }

    func testUpdate() {
        var pattern = makePattern(id: "p-update", task: "Original")
        store.save(pattern)

        pattern.successCount = 5
        store.update(pattern)

        let retrieved = store.get("p-update")
        XCTAssertEqual(retrieved?.successCount, 5)
    }

    func testArchive() {
        store.save(makePattern(id: "p-arch"))
        XCTAssertEqual(store.count, 1)

        store.archive("p-arch")
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.get("p-arch"))

        // Verify archived pattern persists on disk (as archived)
        let store2 = PatternStore(directory: tempDir)
        store2.loadIfNeeded()
        XCTAssertEqual(store2.count, 0) // Archived patterns not loaded into index
    }

    // MARK: - Deduplication

    func testDeduplicatesBySimilarTask() {
        store.save(makePattern(id: "p1", task: "Add item to Amazon cart", app: "Chrome"))
        store.save(makePattern(id: "p2", task: "Add item to Amazon cart page", app: "Chrome"))

        // Second pattern should be deduplicated (same app, >70% word overlap)
        XCTAssertEqual(store.count, 1)
        XCTAssertNotNil(store.get("p1"))
        XCTAssertNil(store.get("p2"))
    }

    func testDoesNotDeduplicateDifferentApps() {
        store.save(makePattern(id: "p1", task: "Open settings page", app: "Chrome"))
        store.save(makePattern(id: "p2", task: "Open settings page", app: "Safari"))

        XCTAssertEqual(store.count, 2)
    }

    // MARK: - Search Tests

    func testFindRelevantByKeyword() {
        store.save(makePattern(id: "p1", task: "Add item to Amazon cart", app: "Chrome"))
        store.save(makePattern(id: "p2", task: "Send email via Gmail", app: "Chrome"))

        let results = store.findRelevant(query: "add something to my Amazon cart")
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.id, "p1")
    }

    func testFindRelevantWithAppFilter() {
        store.save(makePattern(id: "p1", task: "Open page", app: "Chrome"))
        store.save(makePattern(id: "p2", task: "Open page", app: "Safari"))

        let results = store.findRelevant(query: "open page", targetApp: "Safari")
        XCTAssertFalse(results.isEmpty)
        // Safari should rank higher due to app match bonus
        XCTAssertEqual(results.first?.id, "p2")
    }

    func testFindRelevantSkipsDecayed() {
        store.save(makePattern(
            id: "p-decayed",
            task: "Test task with keywords",
            app: "Chrome",
            successCount: 1,
            failureCount: 5 // failureCount > successCount * 2 && > 2
        ))

        let results = store.findRelevant(query: "test task keywords")
        XCTAssertTrue(results.isEmpty)
    }

    func testFindRelevantReturnsMax3() {
        for i in 0..<10 {
            store.save(makePattern(
                id: "p\(i)",
                task: "Common search task \(i)",
                app: "App\(i)"
            ))
        }

        let results = store.findRelevant(query: "common search task")
        XCTAssertLessThanOrEqual(results.count, 3)
    }

    func testFindRelevantEmptyQuery() {
        store.save(makePattern(id: "p1", task: "Test"))
        let results = store.findRelevant(query: "")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Prompt Formatting

    func testFormatPatternsForPromptEmpty() {
        let text = PatternStore.formatPatternsForPrompt([])
        XCTAssertEqual(text, "")
    }

    func testFormatPatternsForPromptIncludesKey() {
        let pattern = makePattern(
            task: "Add to cart",
            app: "Chrome",
            steps: [
                PatternStep(
                    toolName: "ax_focus_app",
                    purpose: "Focus Chrome",
                    keyArguments: ["app": "Chrome"],
                    expectedOutcome: "Chrome focused"
                )
            ],
            notes: ["Use direct URL navigation"]
        )
        let text = PatternStore.formatPatternsForPrompt([pattern])
        XCTAssertTrue(text.contains("Relevant Patterns"))
        XCTAssertTrue(text.contains("Add to cart"))
        XCTAssertTrue(text.contains("Chrome"))
        XCTAssertTrue(text.contains("ax_focus_app"))
        XCTAssertTrue(text.contains("direct URL navigation"))
    }
}
