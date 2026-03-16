import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "DirectiveMemoryStore")

/// A directive that instructs the agent to take action when conditions are met.
///
/// Directives are temporal instructions with trigger patterns and optional expiry.
/// Types:
/// - `reminder`: Time or context-triggered reminders ("remind me to X when I open Y")
/// - `habit`: Recurring behavioral nudges ("suggest a break after 2h focus")
/// - `automation`: Trigger procedure replay on context match
/// - `watch`: Monitor for conditions and alert ("tell me when Z happens")
struct Directive: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let directiveType: String
    let triggerPattern: String
    let actionDescription: String
    let priority: Int32
    let createdAt: UInt64
    let expiresAt: UInt64?
    var isActive: Bool
    var executionCount: UInt32
    var lastTriggeredAt: UInt64?
    let sourceContext: String
}

/// Bridges the Rust SQLite-backed directives table.
///
/// Directives are TTL-based: they have optional expiry timestamps.
/// Active queries automatically exclude expired directives.
/// Thread-safe: no mutable state, all operations are function calls.
enum DirectiveMemoryStore {

    /// Injectable UniFFI function types for testing.
    typealias UpsertFn = @Sendable (
        String, String, String, String, Int32, UInt64, UInt64?, String
    ) throws -> Void

    typealias QueryActiveFn = @Sendable (UInt64, UInt32) throws -> [DirectiveRecord]
    typealias RecordTriggerFn = @Sendable (String, UInt64) throws -> Void
    typealias DeactivateFn = @Sendable (String) throws -> Void
    typealias DeleteFn = @Sendable (String) throws -> Void

    // MARK: - Save

    /// Insert or update a directive.
    ///
    /// New directives are active by default. Upsert replaces existing directives with the same ID.
    static func save(
        _ directive: Directive,
        upsertFn: UpsertFn = { id, dirType, trigger, action, priority, created, expires, ctx in
            try upsertDirective(
                id: id, directiveType: dirType, triggerPattern: trigger,
                actionDescription: action, priority: priority,
                createdAt: created, expiresAt: expires, sourceContext: ctx
            )
        }
    ) throws {
        try upsertFn(
            directive.id,
            directive.directiveType,
            directive.triggerPattern,
            directive.actionDescription,
            directive.priority,
            directive.createdAt,
            directive.expiresAt,
            directive.sourceContext
        )

        DiagnosticsStore.shared.increment("directive_upsert_total")
        logger.debug("Upserted directive: \(directive.directiveType)/\(directive.id)")
    }

    // MARK: - Query Active

    /// Query active, non-expired directives.
    ///
    /// Results are sorted by priority DESC, then created_at DESC.
    /// Expired directives (expires_at < nowUs) are automatically excluded.
    static func queryActive(
        nowUs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000_000),
        limit: UInt32 = 50,
        queryFn: QueryActiveFn = { nowUs, lim in try queryActiveDirectives(nowUs: nowUs, limit: lim) }
    ) throws -> [Directive] {
        let records = try queryFn(nowUs, limit)
        DiagnosticsStore.shared.increment("directive_query_total")
        return records.map { mapRecord($0) }
    }

    // MARK: - Record Trigger

    /// Record that a directive was triggered (increments execution_count).
    ///
    /// Called by the agent when a directive's trigger pattern matches the current context.
    static func recordTrigger(
        id: String,
        nowUs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000_000),
        triggerFn: RecordTriggerFn = { id, nowUs in try recordDirectiveTrigger(id: id, nowUs: nowUs) }
    ) throws {
        try triggerFn(id, nowUs)
        DiagnosticsStore.shared.increment("directive_trigger_total")
        logger.debug("Recorded trigger for directive: \(id)")
    }

    // MARK: - Deactivate

    /// Deactivate a directive (soft delete — keeps record but sets is_active=false).
    ///
    /// Use this instead of delete when you want to preserve execution history.
    static func deactivate(
        id: String,
        deactivateFn: DeactivateFn = { id in try deactivateDirective(id: id) }
    ) throws {
        try deactivateFn(id)
        DiagnosticsStore.shared.increment("directive_deactivate_total")
        logger.debug("Deactivated directive: \(id)")
    }

    // MARK: - Delete

    /// Permanently delete a directive.
    static func delete(
        id: String,
        deleteFn: DeleteFn = { id in try deleteDirective(id: id) }
    ) throws {
        try deleteFn(id)
        DiagnosticsStore.shared.increment("directive_delete_total")
        logger.debug("Deleted directive: \(id)")
    }

    // MARK: - Trigger Matching

    /// Check if any active directives match the given context.
    ///
    /// This is a simple substring match against trigger patterns.
    /// For production use, the agent should use LLM-based matching
    /// via MemoryQueryPlanner for semantic trigger evaluation.
    static func matchingDirectives(
        app: String,
        windowTitle: String?,
        url: String?,
        nowUs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000_000),
        queryFn: QueryActiveFn = { nowUs, lim in try queryActiveDirectives(nowUs: nowUs, limit: lim) }
    ) throws -> [Directive] {
        let active = try queryActive(nowUs: nowUs, queryFn: queryFn)

        let context = [
            app.lowercased(),
            windowTitle?.lowercased() ?? "",
            url?.lowercased() ?? "",
        ].joined(separator: " ")

        return active.filter { directive in
            let pattern = directive.triggerPattern.lowercased()
            // Simple substring match — the LLM-based planner does semantic matching
            return context.contains(pattern) || pattern.split(separator: " ").allSatisfy { word in
                context.contains(word)
            }
        }
    }

    // MARK: - Helpers

    /// Map a Rust UniFFI record to a Swift Directive struct.
    private static func mapRecord(_ record: DirectiveRecord) -> Directive {
        Directive(
            id: record.id,
            directiveType: record.directiveType,
            triggerPattern: record.triggerPattern,
            actionDescription: record.actionDescription,
            priority: record.priority,
            createdAt: record.createdAt,
            expiresAt: record.expiresAt,
            isActive: record.isActive,
            executionCount: record.executionCount,
            lastTriggeredAt: record.lastTriggeredAt,
            sourceContext: record.sourceContext
        )
    }
}
