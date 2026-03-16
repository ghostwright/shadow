import XCTest
@testable import Shadow

final class ProcedureStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: ProcedureStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ProcedureStore(directory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Save and Load

    /// Save and load a procedure.
    func testSaveAndLoad() async throws {
        let template = makeTemplate(id: "test-1", name: "Test Procedure")
        try await store.save(template)

        let loaded = try await store.load(id: "test-1")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, "test-1")
        XCTAssertEqual(loaded?.name, "Test Procedure")
    }

    /// Load non-existent procedure returns nil.
    func testLoadNonExistent() async throws {
        let loaded = try await store.load(id: "does-not-exist")
        XCTAssertNil(loaded)
    }

    // MARK: - Delete

    /// Delete removes the procedure.
    func testDelete() async throws {
        let template = makeTemplate(id: "test-del", name: "Delete Me")
        try await store.save(template)

        try await store.delete(id: "test-del")

        let loaded = try await store.load(id: "test-del")
        XCTAssertNil(loaded)
    }

    /// Delete non-existent is silent.
    func testDeleteNonExistent() async throws {
        try await store.delete(id: "nope")
        // Should not throw
    }

    // MARK: - List All

    /// List returns all saved procedures.
    func testListAll() async throws {
        try await store.save(makeTemplate(id: "a", name: "Alpha"))
        try await store.save(makeTemplate(id: "b", name: "Beta"))
        try await store.save(makeTemplate(id: "c", name: "Charlie"))

        let all = await store.listAll()
        XCTAssertEqual(all.count, 3)
    }

    /// Empty directory returns empty list.
    func testListAllEmpty() async {
        let all = await store.listAll()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Search

    /// Search by name.
    func testSearchByName() async throws {
        try await store.save(makeTemplate(id: "1", name: "Send Email"))
        try await store.save(makeTemplate(id: "2", name: "Book Meeting"))

        let results = await store.search(query: "email")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "Send Email")
    }

    /// Search by tag.
    func testSearchByTag() async throws {
        var template = makeTemplate(id: "1", name: "Deploy App")
        template.tags = ["devops", "deployment"]
        try await store.save(template)

        let results = await store.search(query: "devops")
        XCTAssertEqual(results.count, 1)
    }

    /// Search with no matches returns empty.
    func testSearchNoMatches() async throws {
        try await store.save(makeTemplate(id: "1", name: "Alpha"))

        let results = await store.search(query: "nonexistent")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Execution Count

    /// Record execution increments count.
    func testRecordExecution() async throws {
        let template = makeTemplate(id: "exec-1", name: "Repeat Me")
        try await store.save(template)

        try await store.recordExecution(id: "exec-1")

        let loaded = try await store.load(id: "exec-1")
        XCTAssertEqual(loaded?.executionCount, 1)
        XCTAssertNotNil(loaded?.lastExecutedAt)
    }

    // MARK: - Codable Persistence

    /// Verify the file is valid JSON.
    func testFileIsValidJSON() async throws {
        let template = makeTemplate(id: "json-test", name: "JSON Check")
        try await store.save(template)

        let fileURL = tempDir.appendingPathComponent("json-test.json")
        let data = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [String: Any])
    }

    // MARK: - Helpers

    private func makeTemplate(id: String, name: String) -> ProcedureTemplate {
        ProcedureTemplate(
            id: id,
            name: name,
            description: "A test procedure",
            parameters: [],
            steps: [
                ProcedureStep(
                    index: 0,
                    intent: "Test step",
                    actionType: .click(x: 100, y: 100, button: "left", count: 1),
                    targetLocator: nil,
                    targetDescription: "Test button",
                    parameterSubstitutions: [:],
                    expectedPostCondition: nil,
                    maxRetries: 2,
                    timeoutSeconds: 5.0
                )
            ],
            createdAt: CaptureSessionClock.wallMicros(),
            updatedAt: CaptureSessionClock.wallMicros(),
            sourceApp: "TestApp",
            sourceBundleId: "com.test.app",
            tags: [],
            executionCount: 0,
            lastExecutedAt: nil
        )
    }
}
