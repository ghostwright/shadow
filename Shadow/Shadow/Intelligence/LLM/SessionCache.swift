import CryptoKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "SessionCache")

/// Manages reusable `ChatSession` instances to avoid redundant KV-cache computation.
///
/// The ChatSession from mlx-swift-lm accumulates KV-cache state across `respond(to:)` calls.
/// This means subsequent turns in a conversation reuse the KV-cache from prior turns,
/// avoiding reprocessing the system prompt + entire history from scratch.
///
/// **Multi-turn optimization:** When the agent runtime calls `generate()` repeatedly
/// with an incrementally extending message history (same system prompt, prior history
/// is a prefix of current history), the SessionCache detects this and reuses the existing
/// ChatSession. Only the new user message needs KV-cache computation — the prior turns
/// are already cached.
///
/// **Single-pass requests** (no messages array) always get a fresh session because
/// there is no prior conversation to continue.
///
/// **Eviction:** Sessions are evicted when:
/// - The system prompt changes for a tier
/// - The tier's model is unloaded
/// - The cache exceeds `maxSessions` (LRU eviction)
/// - A new request's history does NOT extend the cached session's history (conversation diverged)
///
/// **Thread safety:** This class is NOT thread-safe on its own. It must be accessed
/// exclusively within the `LocalLLMProvider` actor's isolation context. ChatSession
/// is not Sendable, so it cannot be returned across actor boundaries — keeping
/// SessionCache as a non-actor class within the provider's actor avoids this issue.
final class SessionCache {

    /// A cached session with metadata for reuse detection.
    struct CachedSession {
        /// The live ChatSession with accumulated KV-cache state.
        let session: AnyObject

        /// The tier this session was created for.
        let tier: LocalModelTier

        /// SHA256 hash of the system prompt (with tool definitions baked in).
        let promptHash: String

        /// Number of messages that have been processed by this session.
        /// Used to detect multi-turn continuation: if the new request has
        /// messageCount == cachedMessageCount + 2 (assistant response + new user message)
        /// and the system prompt hash matches, this is a continuation.
        var processedMessageCount: Int

        /// Last time this session was used. For LRU eviction.
        var lastUsed: Date
    }

    // MARK: - State

    /// Active sessions keyed by cache key (tier.rawValue + promptHash).
    private var sessions: [String: CachedSession] = [:]

    /// Maximum number of cached sessions before LRU eviction.
    let maxSessions: Int

    // MARK: - Init

    init(maxSessions: Int = 4) {
        self.maxSessions = maxSessions
    }

    // MARK: - Public API

    /// Attempt to retrieve a reusable session for a multi-turn continuation.
    ///
    /// Returns the cached session if ALL of these conditions hold:
    /// 1. A session exists for this tier + system prompt hash
    /// 2. The new request's message count indicates a continuation
    ///    (new count = cached count + 2, for the assistant response + new user message)
    ///
    /// If conditions are not met, returns nil (caller should create a fresh session).
    ///
    /// The returned AnyObject must be cast to ChatSession by the caller.
    ///
    /// - Parameters:
    ///   - tier: The model tier.
    ///   - systemPrompt: The full system prompt (with tool definitions).
    ///   - messageCount: Number of messages in the new request.
    /// - Returns: `(session, isReused)` — the session object and whether it was reused from cache.
    func getSession(
        tier: LocalModelTier,
        systemPrompt: String,
        messageCount: Int
    ) -> (session: AnyObject, isReused: Bool)? {
        let hash = Self.hashPrompt(systemPrompt)
        let key = Self.cacheKey(tier: tier, promptHash: hash)

        guard let cached = sessions[key] else {
            return nil
        }

        // Multi-turn continuation check:
        // The agent runtime sends full history each call. After the LLM responds,
        // the runtime appends the assistant response + new user message.
        // So new messageCount should be old messageCount + 2.
        let expectedCount = cached.processedMessageCount + 2

        guard messageCount == expectedCount else {
            // History diverged — cannot reuse. Remove stale session.
            logger.info("Session cache miss: history diverged (cached=\(cached.processedMessageCount), new=\(messageCount))")
            sessions.removeValue(forKey: key)
            updateSizeGauge()
            return nil
        }

        // Reuse the session
        sessions[key]?.lastUsed = Date()
        DiagnosticsStore.shared.increment("llm_local_session_cache_hit_total")
        logger.info("Session cache hit: tier=\(tier.rawValue), reusing session with \(cached.processedMessageCount) processed messages")
        return (session: cached.session, isReused: true)
    }

    /// Store a session after a successful generation for potential future reuse.
    ///
    /// - Parameters:
    ///   - session: The session object (ChatSession in production, any class in tests).
    ///   - tier: The model tier.
    ///   - systemPrompt: The full system prompt.
    ///   - messageCount: Total number of messages processed by this session
    ///     (the request's message count).
    func store(
        session: AnyObject,
        tier: LocalModelTier,
        systemPrompt: String,
        messageCount: Int
    ) {
        let hash = Self.hashPrompt(systemPrompt)
        let key = Self.cacheKey(tier: tier, promptHash: hash)

        // Evict if at capacity
        if sessions.count >= maxSessions && sessions[key] == nil {
            evictLRU()
        }

        sessions[key] = CachedSession(
            session: session,
            tier: tier,
            promptHash: hash,
            processedMessageCount: messageCount,
            lastUsed: Date()
        )

        updateSizeGauge()
        logger.debug("Session stored: tier=\(tier.rawValue), messages=\(messageCount)")
    }

    /// Invalidate all sessions for a specific tier.
    /// Called when a model is unloaded.
    func invalidate(tier: LocalModelTier) {
        let keysToRemove = sessions.keys.filter { key in
            sessions[key]?.tier == tier
        }
        for key in keysToRemove {
            sessions.removeValue(forKey: key)
        }
        if !keysToRemove.isEmpty {
            updateSizeGauge()
            logger.info("Invalidated \(keysToRemove.count) session(s) for tier=\(tier.rawValue)")
        }
    }

    /// Invalidate all cached sessions.
    /// Called during shutdown.
    func invalidateAll() {
        let count = sessions.count
        sessions.removeAll()
        updateSizeGauge()
        if count > 0 {
            logger.info("Invalidated all \(count) cached session(s)")
        }
    }

    /// Number of currently cached sessions.
    var count: Int {
        sessions.count
    }

    // MARK: - Internal

    /// Evict the least recently used session.
    private func evictLRU() {
        guard let (oldestKey, _) = sessions.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else {
            return
        }
        sessions.removeValue(forKey: oldestKey)
        DiagnosticsStore.shared.increment("llm_local_session_cache_evict_total")
        logger.debug("Evicted LRU session: \(oldestKey)")
    }

    /// Update the diagnostics gauge for cache size.
    private func updateSizeGauge() {
        DiagnosticsStore.shared.setGauge("llm_local_session_cache_size", value: Double(sessions.count))
    }

    // MARK: - Hashing

    /// Compute a stable SHA256 hash of the system prompt for cache keying.
    static func hashPrompt(_ prompt: String) -> String {
        let data = Data(prompt.utf8)
        let digest = SHA256.hash(data: data)
        // Use first 16 hex chars (64 bits) — sufficient for collision avoidance
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Build a cache key from tier + prompt hash.
    static func cacheKey(tier: LocalModelTier, promptHash: String) -> String {
        "\(tier.rawValue):\(promptHash)"
    }
}
