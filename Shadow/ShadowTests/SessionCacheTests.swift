import XCTest
@testable import Shadow

/// Tests for `SessionCache` — the KV-cache session pool for multi-turn optimization.
///
/// Uses lightweight `NSObject` instances as mock sessions since `ChatSession`
/// requires a real `ModelContainer`. The cache stores sessions as `AnyObject`
/// and never calls generation methods during bookkeeping — only the provider
/// casts back to `ChatSession` at the call site.
final class SessionCacheTests: XCTestCase {

    // MARK: - Hash Stability

    func testHashPrompt_sameInput_sameOutput() {
        let hash1 = SessionCache.hashPrompt("You are a helpful assistant.")
        let hash2 = SessionCache.hashPrompt("You are a helpful assistant.")
        XCTAssertEqual(hash1, hash2, "Same prompt must produce same hash")
    }

    func testHashPrompt_differentInput_differentOutput() {
        let hash1 = SessionCache.hashPrompt("You are a helpful assistant.")
        let hash2 = SessionCache.hashPrompt("You are a concise assistant.")
        XCTAssertNotEqual(hash1, hash2, "Different prompts must produce different hashes")
    }

    func testHashPrompt_lengthIs16Hex() {
        let hash = SessionCache.hashPrompt("test prompt")
        XCTAssertEqual(hash.count, 16, "Hash should be 16 hex characters (8 bytes)")
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit }, "Hash should be all hex digits")
    }

    func testHashPrompt_emptyString() {
        let hash = SessionCache.hashPrompt("")
        XCTAssertEqual(hash.count, 16, "Empty string hash should still be 16 hex chars")
    }

    // MARK: - Cache Key

    func testCacheKey_combinesTierAndHash() {
        let key = SessionCache.cacheKey(tier: .fast, promptHash: "abcdef0123456789")
        XCTAssertEqual(key, "fast:abcdef0123456789")
    }

    func testCacheKey_differentTiers_differentKeys() {
        let hash = "abcdef0123456789"
        let fastKey = SessionCache.cacheKey(tier: .fast, promptHash: hash)
        let deepKey = SessionCache.cacheKey(tier: .deep, promptHash: hash)
        XCTAssertNotEqual(fastKey, deepKey, "Different tiers must produce different cache keys")
    }

    // MARK: - Cache Miss on Empty

    func testGetSession_emptyCache_returnsNil() {
        let cache = SessionCache()
        let result = cache.getSession(
            tier: .fast,
            systemPrompt: "test",
            messageCount: 3
        )
        XCTAssertNil(result, "Empty cache should return nil")
    }

    // MARK: - Store and Retrieve

    func testStoreAndGet_matchingContinuation_returnsSession() {
        let cache = SessionCache()
        let prompt = "You are helpful."

        // Simulate: first call has 3 messages, we store the session
        let mockSession = NSObject()
        cache.store(
            session: mockSession,
            tier: .fast,
            systemPrompt: prompt,
            messageCount: 3
        )

        // Next call has 5 messages (3 + assistant response + new user message = continuation)
        let result = cache.getSession(
            tier: .fast,
            systemPrompt: prompt,
            messageCount: 5
        )

        XCTAssertNotNil(result, "Should return cached session for continuation")
        XCTAssertTrue(result?.isReused ?? false, "Should report as reused")
        XCTAssertTrue(result?.session === mockSession, "Should return the same session object")
    }

    func testStoreAndGet_differentPrompt_returnsNil() {
        let cache = SessionCache()

        cache.store(
            session: NSObject(),
            tier: .fast,
            systemPrompt: "Prompt A",
            messageCount: 3
        )

        // Different prompt = different cache key, no hit
        let result = cache.getSession(
            tier: .fast,
            systemPrompt: "Prompt B",
            messageCount: 5
        )

        XCTAssertNil(result, "Different prompt should miss cache")
    }

    func testStoreAndGet_differentTier_returnsNil() {
        let cache = SessionCache()

        cache.store(
            session: NSObject(),
            tier: .fast,
            systemPrompt: "test",
            messageCount: 3
        )

        // Different tier = different cache key, no hit
        let result = cache.getSession(
            tier: .deep,
            systemPrompt: "test",
            messageCount: 5
        )

        XCTAssertNil(result, "Different tier should miss cache")
    }

    func testStoreAndGet_nonContinuationMessageCount_returnsNilAndEvicts() {
        let cache = SessionCache()
        let prompt = "test"

        cache.store(
            session: NSObject(),
            tier: .fast,
            systemPrompt: prompt,
            messageCount: 3
        )

        // Expected continuation = 3 + 2 = 5 messages.
        // Asking for 7 messages means history diverged.
        let result = cache.getSession(
            tier: .fast,
            systemPrompt: prompt,
            messageCount: 7
        )

        XCTAssertNil(result, "Non-continuation message count should miss cache")

        // Verify the stale entry was removed
        XCTAssertEqual(cache.count, 0, "Stale session should have been removed on divergence")
    }

    func testStoreAndGet_sameMessageCount_returnsNil() {
        let cache = SessionCache()
        let prompt = "test"

        cache.store(
            session: NSObject(),
            tier: .fast,
            systemPrompt: prompt,
            messageCount: 3
        )

        // Same count = not a continuation (expected 5 = 3 + 2)
        let result = cache.getSession(
            tier: .fast,
            systemPrompt: prompt,
            messageCount: 3
        )

        XCTAssertNil(result, "Same message count is not a continuation")
    }

    func testStoreAndGet_fewerMessages_returnsNil() {
        let cache = SessionCache()
        let prompt = "test"

        cache.store(
            session: NSObject(),
            tier: .fast,
            systemPrompt: prompt,
            messageCount: 5
        )

        // Fewer messages than stored = not a continuation
        let result = cache.getSession(
            tier: .fast,
            systemPrompt: prompt,
            messageCount: 3
        )

        XCTAssertNil(result, "Fewer messages than stored is not a continuation")
    }

    // MARK: - LRU Eviction

    func testEviction_exceedsMaxSessions_evictsLRU() {
        let cache = SessionCache(maxSessions: 2)

        let session1 = NSObject()
        let session2 = NSObject()
        let session3 = NSObject()

        // Store two sessions (fills capacity)
        cache.store(session: session1, tier: .fast, systemPrompt: "prompt1", messageCount: 1)

        // Use Thread.sleep to ensure different lastUsed timestamps
        Thread.sleep(forTimeInterval: 0.01)

        cache.store(session: session2, tier: .fast, systemPrompt: "prompt2", messageCount: 1)

        XCTAssertEqual(cache.count, 2, "Should have 2 sessions")

        // Store a third — should evict the LRU (session1 for prompt1)
        cache.store(session: session3, tier: .fast, systemPrompt: "prompt3", messageCount: 1)

        XCTAssertEqual(cache.count, 2, "Should still have 2 sessions after eviction")

        // prompt1 should be gone (evicted as LRU)
        let result1 = cache.getSession(tier: .fast, systemPrompt: "prompt1", messageCount: 3)
        XCTAssertNil(result1, "LRU session (prompt1) should have been evicted")

        // prompt2 should still be present
        let result2 = cache.getSession(tier: .fast, systemPrompt: "prompt2", messageCount: 3)
        XCTAssertNotNil(result2, "prompt2 should still be cached")

        // prompt3 should still be present
        let result3 = cache.getSession(tier: .fast, systemPrompt: "prompt3", messageCount: 3)
        XCTAssertNotNil(result3, "prompt3 should still be cached")
    }

    func testEviction_overwriteSameKey_doesNotEvict() {
        let cache = SessionCache(maxSessions: 2)

        cache.store(session: NSObject(), tier: .fast, systemPrompt: "p1", messageCount: 1)
        cache.store(session: NSObject(), tier: .fast, systemPrompt: "p2", messageCount: 1)

        // Overwrite p1 — should NOT trigger eviction since the key already exists
        cache.store(session: NSObject(), tier: .fast, systemPrompt: "p1", messageCount: 3)

        XCTAssertEqual(cache.count, 2, "Overwriting existing key should not trigger eviction")
    }

    // MARK: - Invalidate by Tier

    func testInvalidate_tier_clearsThatTierOnly() {
        let cache = SessionCache()

        cache.store(session: NSObject(), tier: .fast, systemPrompt: "fast1", messageCount: 1)
        cache.store(session: NSObject(), tier: .deep, systemPrompt: "deep1", messageCount: 1)

        XCTAssertEqual(cache.count, 2, "Should have 2 sessions")

        cache.invalidate(tier: .fast)

        XCTAssertEqual(cache.count, 1, "Should have 1 session after invalidating fast tier")

        // fast should be gone
        let resultFast = cache.getSession(tier: .fast, systemPrompt: "fast1", messageCount: 3)
        XCTAssertNil(resultFast, "Fast tier session should be gone")

        // deep should remain
        let resultDeep = cache.getSession(tier: .deep, systemPrompt: "deep1", messageCount: 3)
        XCTAssertNotNil(resultDeep, "Deep tier session should remain")
    }

    func testInvalidate_tier_noopWhenEmpty() {
        let cache = SessionCache()
        cache.invalidate(tier: .fast) // Should not crash
        XCTAssertEqual(cache.count, 0)
    }

    func testInvalidate_tier_multipleSameTier() {
        let cache = SessionCache()

        cache.store(session: NSObject(), tier: .fast, systemPrompt: "p1", messageCount: 1)
        cache.store(session: NSObject(), tier: .fast, systemPrompt: "p2", messageCount: 1)
        cache.store(session: NSObject(), tier: .deep, systemPrompt: "p3", messageCount: 1)

        XCTAssertEqual(cache.count, 3)

        cache.invalidate(tier: .fast)

        XCTAssertEqual(cache.count, 1, "Both fast tier sessions should be gone, deep remains")
    }

    // MARK: - Invalidate All

    func testInvalidateAll_clearsEverything() {
        let cache = SessionCache()

        cache.store(session: NSObject(), tier: .fast, systemPrompt: "p1", messageCount: 1)
        cache.store(session: NSObject(), tier: .deep, systemPrompt: "p2", messageCount: 1)

        XCTAssertEqual(cache.count, 2, "Should have 2 sessions before invalidateAll")

        cache.invalidateAll()

        XCTAssertEqual(cache.count, 0, "Should have 0 sessions after invalidateAll")
    }

    func testInvalidateAll_noopWhenEmpty() {
        let cache = SessionCache()
        cache.invalidateAll() // Should not crash
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: - Overwrite Same Key

    func testStore_sameKey_overwritesPrevious() {
        let cache = SessionCache()
        let prompt = "same prompt"

        let session1 = NSObject()
        let session2 = NSObject()

        cache.store(session: session1, tier: .fast, systemPrompt: prompt, messageCount: 3)
        cache.store(session: session2, tier: .fast, systemPrompt: prompt, messageCount: 5)

        XCTAssertEqual(cache.count, 1, "Storing to same key should overwrite, not duplicate")

        // The updated session has messageCount 5, so continuation expects 7
        let result = cache.getSession(tier: .fast, systemPrompt: prompt, messageCount: 7)
        XCTAssertNotNil(result, "Updated session should be retrievable at new message count")
        XCTAssertTrue(result?.session === session2, "Should return the newer session")
    }

    // MARK: - Multi-turn Continuation Sequence

    func testMultiTurnSequence_threeTurns() {
        let cache = SessionCache()
        let prompt = "You are a coding assistant."

        // Turn 1: user sends 1 message
        let session = NSObject()
        cache.store(session: session, tier: .fast, systemPrompt: prompt, messageCount: 1)

        // Turn 2: agent runtime sends 3 messages (1 + assistant + user)
        let result2 = cache.getSession(tier: .fast, systemPrompt: prompt, messageCount: 3)
        XCTAssertNotNil(result2, "Turn 2 should hit cache (1 + 2 = 3)")
        XCTAssertTrue(result2?.session === session)

        // Update stored count to 3
        cache.store(session: session, tier: .fast, systemPrompt: prompt, messageCount: 3)

        // Turn 3: agent runtime sends 5 messages (3 + assistant + user)
        let result3 = cache.getSession(tier: .fast, systemPrompt: prompt, messageCount: 5)
        XCTAssertNotNil(result3, "Turn 3 should hit cache (3 + 2 = 5)")
        XCTAssertTrue(result3?.session === session)
    }

    // MARK: - Diagnostics Integration

    func testDiagnostics_cacheHitIncrementsCounter() {
        let cache = SessionCache()
        let prompt = "test prompt for hit counter"

        cache.store(session: NSObject(), tier: .fast, systemPrompt: prompt, messageCount: 3)

        let hitsBefore = DiagnosticsStore.shared.counter("llm_local_session_cache_hit_total")

        // Trigger a hit
        let result = cache.getSession(tier: .fast, systemPrompt: prompt, messageCount: 5)
        XCTAssertNotNil(result)

        let hitsAfter = DiagnosticsStore.shared.counter("llm_local_session_cache_hit_total")
        XCTAssertEqual(hitsAfter, hitsBefore + 1, "Cache hit should increment counter")
    }

    func testDiagnostics_evictionIncrementsCounter() {
        let cache = SessionCache(maxSessions: 1)

        // Fill to capacity
        cache.store(session: NSObject(), tier: .fast, systemPrompt: "p_evict_1", messageCount: 1)

        let evictsBefore = DiagnosticsStore.shared.counter("llm_local_session_cache_evict_total")

        // Store another — triggers eviction
        cache.store(session: NSObject(), tier: .fast, systemPrompt: "p_evict_2", messageCount: 1)

        let evictsAfter = DiagnosticsStore.shared.counter("llm_local_session_cache_evict_total")
        XCTAssertEqual(evictsAfter, evictsBefore + 1, "Eviction should increment counter")
    }

    func testDiagnostics_sizeGaugeUpdated() {
        let cache = SessionCache()

        cache.store(session: NSObject(), tier: .fast, systemPrompt: "unique_\(UUID())", messageCount: 1)

        let size = DiagnosticsStore.shared.gauge("llm_local_session_cache_size")
        XCTAssertGreaterThanOrEqual(size, 1.0, "Size gauge should reflect at least 1 cached session")

        cache.invalidateAll()

        let sizeAfter = DiagnosticsStore.shared.gauge("llm_local_session_cache_size")
        XCTAssertEqual(sizeAfter, 0.0, "Size gauge should be 0 after invalidateAll")
    }

    // MARK: - Max Sessions Configuration

    func testMaxSessions_defaultIsFour() {
        let cache = SessionCache()
        XCTAssertEqual(cache.maxSessions, 4, "Default maxSessions should be 4")
    }

    func testMaxSessions_customValue() {
        let cache = SessionCache(maxSessions: 8)
        XCTAssertEqual(cache.maxSessions, 8, "Custom maxSessions should be respected")
    }
}
