import Foundation
import os.log
import CryptoKit

private let logger = Logger(subsystem: "com.shadow.app", category: "ToolResultCache")

/// Cache for tool results within a single agent session.
///
/// Prevents redundant tool calls for identical queries (e.g., multiple
/// AX tree queries for the same app during a procedure replay).
///
/// Thread-safe via actor isolation.
actor ToolResultCache {

    /// Cached entry with expiry.
    private struct CacheEntry: Sendable {
        let result: ToolResult
        let expiry: Date
    }

    private var cache: [String: CacheEntry] = [:]

    /// Retrieve a cached result, or nil if expired/missing.
    func get(key: String) -> ToolResult? {
        guard let entry = cache[key], entry.expiry > Date() else {
            if cache[key] != nil {
                // Expired — remove
                cache.removeValue(forKey: key)
            }
            return nil
        }
        DiagnosticsStore.shared.increment("tool_cache_hit_total")
        return entry.result
    }

    /// Store a result with a time-to-live.
    func set(key: String, result: ToolResult, ttl: TimeInterval = 30) {
        cache[key] = CacheEntry(result: result, expiry: Date().addingTimeInterval(ttl))
        DiagnosticsStore.shared.increment("tool_cache_set_total")
    }

    /// Clear all cached entries.
    func clear() {
        let count = cache.count
        cache.removeAll()
        if count > 0 {
            logger.info("Tool cache cleared: \(count) entries")
        }
    }

    /// Number of valid (non-expired) entries.
    var count: Int {
        let now = Date()
        return cache.values.filter { $0.expiry > now }.count
    }

    /// Total entries including expired (for diagnostics).
    var totalEntries: Int {
        cache.count
    }

    // MARK: - Cache Key Generation

    /// Generate a cache key from tool name and arguments.
    /// Uses SHA256 of the serialized tool call for deterministic keys.
    static func cacheKey(toolName: String, arguments: [String: AnyCodable]) -> String {
        var input = toolName
        // Sort keys for deterministic output
        for key in arguments.keys.sorted() {
            input += "|\(key)=\(arguments[key].map { String(describing: $0) } ?? "nil")"
        }
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// TTL for different tool categories.
    static func ttlForTool(_ toolName: String) -> TimeInterval {
        switch toolName {
        // AX tree queries change frequently
        case "ax_tree_query":
            return 15
        // Memory lookups are stable within a session
        case "get_knowledge", "get_directives", "get_procedures", "search_summaries":
            return 300
        // Search results might change if new events are indexed
        case "search_hybrid", "search_visual_memories":
            return 60
        // Timeline/activity are stable once fetched
        case "get_timeline_context", "get_day_summary", "get_activity_sequence", "get_transcript_window":
            return 300
        // Meeting resolution is stable
        case "resolve_latest_meeting":
            return 300
        // Screenshot inspection — never cache (always reflects current state)
        case "inspect_screenshots":
            return 0
        // Action tools — never cache
        case "ax_click", "ax_type", "ax_hotkey", "ax_scroll", "ax_wait", "ax_focus_app",
             "replay_procedure", "set_directive":
            return 0
        // Read text — may change if user scrolls or navigates
        case "ax_read_text":
            return 10
        default:
            return 30
        }
    }

    /// Whether a tool's results should be cached.
    static func isCacheable(_ toolName: String) -> Bool {
        ttlForTool(toolName) > 0
    }
}
