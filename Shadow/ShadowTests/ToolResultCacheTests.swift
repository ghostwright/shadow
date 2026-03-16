import XCTest
@testable import Shadow

final class ToolResultCacheTests: XCTestCase {

    // MARK: - Basic Operations

    /// Set and get a cached result.
    func testSetAndGet() async {
        let cache = ToolResultCache()
        let result = ToolResult(toolCallId: "tc-1", content: "test output", isError: false)

        await cache.set(key: "key1", result: result, ttl: 60)
        let retrieved = await cache.get(key: "key1")

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.content, "test output")
        XCTAssertFalse(retrieved?.isError ?? true)
    }

    /// Get returns nil for missing key.
    func testGetMissing() async {
        let cache = ToolResultCache()
        let result = await cache.get(key: "nonexistent")
        XCTAssertNil(result)
    }

    /// Expired entries return nil.
    func testExpiredEntry() async {
        let cache = ToolResultCache()
        let result = ToolResult(toolCallId: "tc-1", content: "test", isError: false)

        // Set with very short TTL
        await cache.set(key: "key1", result: result, ttl: 0.001)

        // Wait for expiry
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms

        let retrieved = await cache.get(key: "key1")
        XCTAssertNil(retrieved)
    }

    /// Clear removes all entries.
    func testClear() async {
        let cache = ToolResultCache()
        let result = ToolResult(toolCallId: "tc-1", content: "test", isError: false)

        await cache.set(key: "key1", result: result, ttl: 60)
        await cache.set(key: "key2", result: result, ttl: 60)

        let beforeClear = await cache.totalEntries
        XCTAssertEqual(beforeClear, 2)

        await cache.clear()

        let afterClear = await cache.totalEntries
        XCTAssertEqual(afterClear, 0)
        let afterGet = await cache.get(key: "key1")
        XCTAssertNil(afterGet)
    }

    /// Count returns only non-expired entries.
    func testCount() async {
        let cache = ToolResultCache()
        let result = ToolResult(toolCallId: "tc-1", content: "test", isError: false)

        await cache.set(key: "key1", result: result, ttl: 60)
        await cache.set(key: "key2", result: result, ttl: 60)

        let count = await cache.count
        XCTAssertEqual(count, 2)
    }

    /// Multiple sets for same key overwrites.
    func testOverwrite() async {
        let cache = ToolResultCache()

        let result1 = ToolResult(toolCallId: "tc-1", content: "first", isError: false)
        let result2 = ToolResult(toolCallId: "tc-1", content: "second", isError: false)

        await cache.set(key: "key1", result: result1, ttl: 60)
        await cache.set(key: "key1", result: result2, ttl: 60)

        let retrieved = await cache.get(key: "key1")
        XCTAssertEqual(retrieved?.content, "second")
    }

    // MARK: - Cache Key Generation

    /// Cache keys are deterministic.
    func testCacheKeyDeterministic() {
        let key1 = ToolResultCache.cacheKey(toolName: "search_hybrid", arguments: ["query": .string("test")])
        let key2 = ToolResultCache.cacheKey(toolName: "search_hybrid", arguments: ["query": .string("test")])
        XCTAssertEqual(key1, key2)
    }

    /// Different arguments produce different keys.
    func testCacheKeyDifferentArgs() {
        let key1 = ToolResultCache.cacheKey(toolName: "search_hybrid", arguments: ["query": .string("test1")])
        let key2 = ToolResultCache.cacheKey(toolName: "search_hybrid", arguments: ["query": .string("test2")])
        XCTAssertNotEqual(key1, key2)
    }

    /// Different tool names produce different keys.
    func testCacheKeyDifferentTools() {
        let key1 = ToolResultCache.cacheKey(toolName: "search_hybrid", arguments: ["query": .string("test")])
        let key2 = ToolResultCache.cacheKey(toolName: "get_knowledge", arguments: ["query": .string("test")])
        XCTAssertNotEqual(key1, key2)
    }

    /// Key argument order is normalized.
    func testCacheKeyOrderIndependent() {
        let key1 = ToolResultCache.cacheKey(
            toolName: "test",
            arguments: ["a": .string("1"), "b": .string("2")]
        )
        let key2 = ToolResultCache.cacheKey(
            toolName: "test",
            arguments: ["b": .string("2"), "a": .string("1")]
        )
        XCTAssertEqual(key1, key2)
    }

    // MARK: - TTL Configuration

    /// AX tree queries have short TTL.
    func testTTLAxTreeQuery() {
        XCTAssertEqual(ToolResultCache.ttlForTool("ax_tree_query"), 15)
    }

    /// Memory lookups have long TTL.
    func testTTLMemoryLookup() {
        XCTAssertEqual(ToolResultCache.ttlForTool("get_knowledge"), 300)
        XCTAssertEqual(ToolResultCache.ttlForTool("get_directives"), 300)
    }

    /// Action tools have zero TTL (not cached).
    func testTTLActionTools() {
        XCTAssertEqual(ToolResultCache.ttlForTool("ax_click"), 0)
        XCTAssertEqual(ToolResultCache.ttlForTool("ax_type"), 0)
        XCTAssertEqual(ToolResultCache.ttlForTool("ax_hotkey"), 0)
        XCTAssertEqual(ToolResultCache.ttlForTool("ax_scroll"), 0)
    }

    /// inspect_screenshots has zero TTL.
    func testTTLInspectScreenshots() {
        XCTAssertEqual(ToolResultCache.ttlForTool("inspect_screenshots"), 0)
    }

    /// Search tools have moderate TTL.
    func testTTLSearchTools() {
        XCTAssertEqual(ToolResultCache.ttlForTool("search_hybrid"), 60)
        XCTAssertEqual(ToolResultCache.ttlForTool("search_visual_memories"), 60)
    }

    /// Unknown tools get default TTL.
    func testTTLUnknownTool() {
        XCTAssertEqual(ToolResultCache.ttlForTool("future_tool"), 30)
    }

    // MARK: - Cacheability

    /// isCacheable returns true for query tools.
    func testIsCacheableQueryTools() {
        XCTAssertTrue(ToolResultCache.isCacheable("search_hybrid"))
        XCTAssertTrue(ToolResultCache.isCacheable("get_knowledge"))
        XCTAssertTrue(ToolResultCache.isCacheable("ax_tree_query"))
    }

    /// isCacheable returns false for action tools.
    func testIsCacheableActionTools() {
        XCTAssertFalse(ToolResultCache.isCacheable("ax_click"))
        XCTAssertFalse(ToolResultCache.isCacheable("ax_type"))
        XCTAssertFalse(ToolResultCache.isCacheable("inspect_screenshots"))
        XCTAssertFalse(ToolResultCache.isCacheable("set_directive"))
        XCTAssertFalse(ToolResultCache.isCacheable("replay_procedure"))
    }
}
