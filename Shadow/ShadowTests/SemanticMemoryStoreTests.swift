import XCTest
@testable import Shadow

/// Thread-safe box for capturing values in @Sendable closures during tests.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class SemanticMemoryStoreTests: XCTestCase {

    // MARK: - SemanticKnowledge Type

    /// SemanticKnowledge is Identifiable via its id.
    func testIdentifiable() {
        let k = makeKnowledge(id: "test-1", category: "fact", key: "editor")
        XCTAssertEqual(k.id, "test-1")
    }

    /// SemanticKnowledge is Equatable.
    func testEquatable() {
        let k1 = makeKnowledge(id: "a", category: "fact", key: "editor")
        let k2 = makeKnowledge(id: "a", category: "fact", key: "editor")
        XCTAssertEqual(k1, k2)
    }

    /// SemanticKnowledge round-trips through Codable.
    func testCodableRoundTrip() throws {
        let k = makeKnowledge(id: "test", category: "preference", key: "theme", value: "dark mode")
        let data = try JSONEncoder().encode(k)
        let decoded = try JSONDecoder().decode(SemanticKnowledge.self, from: data)
        XCTAssertEqual(k, decoded)
    }

    // MARK: - Stable ID Generation

    /// stableId combines category and key.
    func testStableId() {
        let id = SemanticMemoryStore.stableId(category: "preference", key: "theme")
        XCTAssertEqual(id, "preference:theme")
    }

    /// stableId is deterministic.
    func testStableIdDeterministic() {
        let id1 = SemanticMemoryStore.stableId(category: "fact", key: "editor")
        let id2 = SemanticMemoryStore.stableId(category: "fact", key: "editor")
        XCTAssertEqual(id1, id2)
    }

    /// Different keys produce different IDs.
    func testStableIdUnique() {
        let id1 = SemanticMemoryStore.stableId(category: "fact", key: "editor")
        let id2 = SemanticMemoryStore.stableId(category: "fact", key: "browser")
        XCTAssertNotEqual(id1, id2)
    }

    // MARK: - Save

    /// Save calls the upsert function with correct parameters.
    func testSaveCallsUpsert() throws {
        let captured = Box<(String, String, String, String, Double, String, UInt64, UInt64)?>(nil)

        let upsertFn: SemanticMemoryStore.UpsertFn = { id, cat, key, val, conf, eps, created, updated in
            captured.value = (id, cat, key, val, conf, eps, created, updated)
        }

        let k = makeKnowledge(
            id: "test-1", category: "preference", key: "theme",
            value: "dark", confidence: 0.85, sourceEpisodeIds: ["ep-1", "ep-2"]
        )
        try SemanticMemoryStore.save(k, upsertFn: upsertFn)

        XCTAssertNotNil(captured.value)
        XCTAssertEqual(captured.value?.0, "test-1")
        XCTAssertEqual(captured.value?.1, "preference")
        XCTAssertEqual(captured.value?.2, "theme")
        XCTAssertEqual(captured.value?.3, "dark")
        XCTAssertEqual(captured.value?.4 ?? 0, 0.85, accuracy: 0.001)
        XCTAssertEqual(captured.value?.5, "ep-1,ep-2")
    }

    /// Save propagates errors from the upsert function.
    func testSavePropagatesError() {
        let upsertFn: SemanticMemoryStore.UpsertFn = { _, _, _, _, _, _, _, _ in
            throw TestError.simulated
        }

        let k = makeKnowledge(id: "test", category: "fact", key: "test")
        XCTAssertThrowsError(try SemanticMemoryStore.save(k, upsertFn: upsertFn))
    }

    // MARK: - Query

    /// Query returns mapped records.
    func testQueryReturnsRecords() throws {
        let queryFn: SemanticMemoryStore.QueryFn = { _, _ in
            [
                SemanticKnowledgeRecord(
                    id: "sk-1", category: "fact", key: "editor", value: "VS Code",
                    confidence: 0.9, sourceEpisodeIds: "ep-1,ep-2",
                    createdAt: 1000000, updatedAt: 2000000,
                    accessCount: 3, lastAccessedAt: 1500000
                )
            ]
        }

        let results = try SemanticMemoryStore.query(category: "fact", queryFn: queryFn)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "sk-1")
        XCTAssertEqual(results[0].category, "fact")
        XCTAssertEqual(results[0].key, "editor")
        XCTAssertEqual(results[0].value, "VS Code")
        XCTAssertEqual(results[0].sourceEpisodeIds, ["ep-1", "ep-2"])
        XCTAssertEqual(results[0].accessCount, 3)
        XCTAssertEqual(results[0].lastAccessedAt, 1500000)
    }

    /// Query with empty source_episode_ids returns empty array.
    func testQueryEmptyEpisodeIds() throws {
        let queryFn: SemanticMemoryStore.QueryFn = { _, _ in
            [
                SemanticKnowledgeRecord(
                    id: "sk-1", category: "fact", key: "test", value: "val",
                    confidence: 0.5, sourceEpisodeIds: "",
                    createdAt: 1000000, updatedAt: 1000000,
                    accessCount: 0, lastAccessedAt: nil
                )
            ]
        }

        let results = try SemanticMemoryStore.query(queryFn: queryFn)
        XCTAssertEqual(results[0].sourceEpisodeIds, [])
    }

    /// Query passes category and limit to the query function.
    func testQueryPassesParameters() throws {
        let capturedCategory = Box<String?>(nil)
        let capturedLimit = Box<UInt32?>(nil)

        let queryFn: SemanticMemoryStore.QueryFn = { cat, lim in
            capturedCategory.value = cat
            capturedLimit.value = lim
            return []
        }

        _ = try SemanticMemoryStore.query(category: "preference", limit: 25, queryFn: queryFn)
        XCTAssertEqual(capturedCategory.value, "preference")
        XCTAssertEqual(capturedLimit.value, 25)
    }

    // MARK: - Touch

    /// Touch calls the touch function with correct ID and timestamp.
    func testTouchCallsFunction() throws {
        let capturedId = Box<String?>(nil)
        let capturedNowUs = Box<UInt64?>(nil)

        let touchFn: SemanticMemoryStore.TouchFn = { id, nowUs in
            capturedId.value = id
            capturedNowUs.value = nowUs
        }

        try SemanticMemoryStore.touch(id: "sk-1", nowUs: 5000000, touchFn: touchFn)
        XCTAssertEqual(capturedId.value, "sk-1")
        XCTAssertEqual(capturedNowUs.value, 5000000)
    }

    // MARK: - Delete

    /// Delete calls the delete function with the correct ID.
    func testDeleteCallsFunction() throws {
        let capturedId = Box<String?>(nil)

        let deleteFn: SemanticMemoryStore.DeleteFn = { id in
            capturedId.value = id
        }

        try SemanticMemoryStore.delete(id: "sk-1", deleteFn: deleteFn)
        XCTAssertEqual(capturedId.value, "sk-1")
    }

    // MARK: - Helpers

    private func makeKnowledge(
        id: String = "test",
        category: String = "fact",
        key: String = "test",
        value: String = "test value",
        confidence: Double = 0.8,
        sourceEpisodeIds: [String] = ["ep-1"]
    ) -> SemanticKnowledge {
        SemanticKnowledge(
            id: id,
            category: category,
            key: key,
            value: value,
            confidence: confidence,
            sourceEpisodeIds: sourceEpisodeIds,
            createdAt: 1000000,
            updatedAt: 1000000,
            accessCount: 0,
            lastAccessedAt: nil
        )
    }

    private enum TestError: Error {
        case simulated
    }
}
