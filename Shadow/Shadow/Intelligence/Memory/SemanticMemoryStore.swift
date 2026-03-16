import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "SemanticMemoryStore")

/// A semantic knowledge entry in the agent's long-term memory.
///
/// Categories organize knowledge into semantic domains:
/// - `preference`: User preferences (theme, font size, etc.)
/// - `fact`: Learned facts about the user's environment (editor, tools, repos)
/// - `pattern`: Behavioral patterns (daily routines, workflows)
/// - `relationship`: Connections between entities (project -> repo, tool -> usage)
/// - `skill`: Procedural knowledge (how user does X in app Y)
struct SemanticKnowledge: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let category: String
    let key: String
    let value: String
    let confidence: Double
    let sourceEpisodeIds: [String]
    let createdAt: UInt64
    var updatedAt: UInt64
    var accessCount: UInt32
    var lastAccessedAt: UInt64?
}

/// Bridges the Rust SQLite-backed semantic_knowledge table.
///
/// All methods use injected UniFFI functions for testability.
/// Thread-safe: no mutable state, all operations are function calls.
enum SemanticMemoryStore {

    /// Injectable UniFFI function types for testing.
    typealias UpsertFn = @Sendable (
        String, String, String, String, Double, String, UInt64, UInt64
    ) throws -> Void

    typealias QueryFn = @Sendable (String?, UInt32) throws -> [SemanticKnowledgeRecord]
    typealias TouchFn = @Sendable (String, UInt64) throws -> Void
    typealias DeleteFn = @Sendable (String) throws -> Void

    // MARK: - Save

    /// Insert or update a semantic knowledge entry.
    ///
    /// Upsert semantics: if an entry with the same ID exists, it is replaced.
    /// The caller is responsible for generating stable IDs (e.g., `category:key` hash).
    static func save(
        _ knowledge: SemanticKnowledge,
        upsertFn: UpsertFn = { id, cat, key, val, conf, eps, created, updated in
            try upsertSemanticKnowledge(
                id: id, category: cat, key: key, value: val,
                confidence: conf, sourceEpisodeIds: eps,
                createdAt: created, updatedAt: updated
            )
        }
    ) throws {
        let episodeIdsStr = knowledge.sourceEpisodeIds.joined(separator: ",")
        try upsertFn(
            knowledge.id,
            knowledge.category,
            knowledge.key,
            knowledge.value,
            knowledge.confidence,
            episodeIdsStr,
            knowledge.createdAt,
            knowledge.updatedAt
        )

        DiagnosticsStore.shared.increment("semantic_knowledge_upsert_total")
        logger.debug("Upserted knowledge: \(knowledge.category)/\(knowledge.key)")
    }

    // MARK: - Query

    /// Query semantic knowledge, optionally filtered by category.
    ///
    /// Returns entries sorted by updatedAt descending (most recently updated first).
    static func query(
        category: String? = nil,
        limit: UInt32 = 50,
        queryFn: QueryFn = { cat, lim in try querySemanticKnowledge(category: cat, limit: lim) }
    ) throws -> [SemanticKnowledge] {
        let records = try queryFn(category, limit)
        DiagnosticsStore.shared.increment("semantic_knowledge_query_total")
        return records.map { mapRecord($0) }
    }

    // MARK: - Touch (Record Access)

    /// Increment the access count and update last_accessed_at for a knowledge entry.
    ///
    /// Called when the agent retrieves knowledge during context packing or query planning.
    /// Access frequency helps prioritize which knowledge to include in bounded context.
    static func touch(
        id: String,
        nowUs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000_000),
        touchFn: TouchFn = { id, nowUs in try touchSemanticKnowledge(id: id, nowUs: nowUs) }
    ) throws {
        try touchFn(id, nowUs)
        DiagnosticsStore.shared.increment("semantic_knowledge_touch_total")
    }

    // MARK: - Delete

    /// Delete a semantic knowledge entry by ID.
    static func delete(
        id: String,
        deleteFn: DeleteFn = { id in try deleteSemanticKnowledge(id: id) }
    ) throws {
        try deleteFn(id)
        DiagnosticsStore.shared.increment("semantic_knowledge_delete_total")
        logger.debug("Deleted knowledge: \(id)")
    }

    // MARK: - Helpers

    /// Generate a stable ID from category and key.
    ///
    /// Ensures upsert semantics: same (category, key) always maps to the same ID.
    static func stableId(category: String, key: String) -> String {
        "\(category):\(key)"
    }

    /// Map a Rust UniFFI record to a Swift SemanticKnowledge struct.
    private static func mapRecord(_ record: SemanticKnowledgeRecord) -> SemanticKnowledge {
        let episodeIds: [String]
        if record.sourceEpisodeIds.isEmpty {
            episodeIds = []
        } else {
            episodeIds = record.sourceEpisodeIds.split(separator: ",").map(String.init)
        }
        return SemanticKnowledge(
            id: record.id,
            category: record.category,
            key: record.key,
            value: record.value,
            confidence: record.confidence,
            sourceEpisodeIds: episodeIds,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            accessCount: record.accessCount,
            lastAccessedAt: record.lastAccessedAt
        )
    }
}
