import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "PatternMatcher")

/// Matches incoming agent queries against stored patterns and manages pattern lifecycle.
///
/// Used in two places:
/// 1. **Before a run**: `findRelevantPatterns()` retrieves matching patterns for prompt injection
/// 2. **After a run**: `recordOutcome()` updates success/failure counts and triggers decay
enum PatternMatcher {

    /// Find relevant patterns for a query and format them for prompt injection.
    /// Returns a prompt section string (empty if no patterns match).
    static func findAndFormat(
        query: String,
        store: PatternStore,
        targetApp: String? = nil
    ) -> String {
        let patterns = store.findRelevant(query: query, targetApp: targetApp, limit: 3)
        guard !patterns.isEmpty else { return "" }

        logger.info("Found \(patterns.count) relevant patterns for query")
        DiagnosticsStore.shared.increment("pattern_match_hit_total")

        return PatternStore.formatPatternsForPrompt(patterns)
    }

    /// Record the outcome of a run that used patterns.
    ///
    /// - If successful: increment `successCount` and update `lastUsedAt`
    /// - If failed: increment `failureCount` and check decay threshold
    ///
    /// - Parameters:
    ///   - patternIds: IDs of patterns that were injected into the prompt
    ///   - success: Whether the run completed successfully
    ///   - store: The pattern store to update
    static func recordOutcome(
        patternIds: [String],
        success: Bool,
        store: PatternStore
    ) {
        let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)

        for id in patternIds {
            guard var pattern = store.get(id) else { continue }

            if success {
                pattern.successCount += 1
                pattern.lastUsedAt = nowUs
                store.update(pattern)
                DiagnosticsStore.shared.increment("pattern_reuse_success_total")
                logger.debug("Pattern '\(pattern.taskDescription)' success count: \(pattern.successCount)")
            } else {
                pattern.failureCount += 1
                pattern.lastUsedAt = nowUs
                store.update(pattern)
                DiagnosticsStore.shared.increment("pattern_reuse_fail_total")

                // Decay: archive patterns with too many failures relative to successes
                if pattern.failureCount > pattern.successCount * 2 && pattern.failureCount > 2 {
                    store.archive(id)
                    DiagnosticsStore.shared.increment("pattern_archived_total")
                    logger.info("Pattern '\(pattern.taskDescription)' archived due to decay (success: \(pattern.successCount), fail: \(pattern.failureCount))")
                }
            }
        }
    }

    /// Trigger async pattern extraction after a successful run.
    ///
    /// This is fire-and-forget — it does not block the user or the agent pipeline.
    /// If extraction fails, it's silently logged.
    ///
    /// - Parameters:
    ///   - task: The original user query
    ///   - result: The successful run result
    ///   - store: Pattern store to save into
    ///   - orchestrator: LLM orchestrator for extraction (optional — falls back to heuristic)
    static func extractAndSaveAsync(
        task: String,
        result: AgentRunResult,
        store: PatternStore,
        orchestrator: LLMOrchestrator?
    ) {
        guard PatternExtractor.isEligible(result) else {
            logger.debug("Run not eligible for pattern extraction (too few AX tool calls)")
            return
        }

        Task.detached(priority: .utility) {
            let pattern: AgentPattern?

            if let orchestrator {
                pattern = await PatternExtractor.extract(
                    task: task,
                    result: result,
                    orchestrator: orchestrator
                )
            } else {
                pattern = PatternExtractor.extractHeuristic(task: task, result: result)
            }

            if let pattern {
                store.save(pattern)
                DiagnosticsStore.shared.increment("pattern_saved_total")
            }
        }
    }
}
