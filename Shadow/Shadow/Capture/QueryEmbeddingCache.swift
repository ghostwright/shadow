import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "QueryEmbeddingCache")

/// In-memory LRU cache for CLIP text query embeddings.
///
/// Cache key: normalized query text + model version.
/// Eviction: drops oldest entry when capacity is exceeded.
///
/// Thread-safe: all access is protected by NSLock.
final class QueryEmbeddingCache: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private let modelId: String

    /// Ordered from oldest to newest access.
    private var keys: [String] = []
    private var cache: [String: [Float]] = [:]

    init(capacity: Int = 128, modelId: String) {
        self.capacity = capacity
        self.modelId = modelId
    }

    /// Look up a cached query embedding.
    /// Returns the embedding vector if found, nil otherwise.
    func get(query: String) -> [Float]? {
        let key = cacheKey(query)

        lock.lock()
        defer { lock.unlock() }

        guard let vector = cache[key] else {
            DiagnosticsStore.shared.increment("vector_query_cache_miss_total")
            return nil
        }

        // Move to end (most recently used)
        if let idx = keys.firstIndex(of: key) {
            keys.remove(at: idx)
            keys.append(key)
        }

        DiagnosticsStore.shared.increment("vector_query_cache_hit_total")
        return vector
    }

    /// Store a query embedding in the cache.
    func put(query: String, vector: [Float]) {
        let key = cacheKey(query)

        lock.lock()
        defer { lock.unlock() }

        if cache[key] != nil {
            // Already cached — update access order
            if let idx = keys.firstIndex(of: key) {
                keys.remove(at: idx)
            }
        } else if keys.count >= capacity {
            // Evict oldest
            let oldest = keys.removeFirst()
            cache.removeValue(forKey: oldest)
        }

        cache[key] = vector
        keys.append(key)
    }

    /// Number of entries currently cached.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    // MARK: - Key Construction

    /// Build cache key from normalized query + model version.
    private func cacheKey(_ query: String) -> String {
        let normalized = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "\(modelId):\(normalized)"
    }
}
