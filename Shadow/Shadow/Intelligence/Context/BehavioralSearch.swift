import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "BehavioralSearch")

/// Wrapper around the Rust behavioral search FFI.
///
/// Searches Shadow's event index for past interaction sequences matching
/// an app and query. Returns formatted context for injection into the
/// agent system prompt. This gives the agent knowledge of how the user
/// has performed similar tasks before.
///
/// Mimicry Phase A: Retrieval-Augmented Agent Context.
enum BehavioralSearch {

    /// Search for past interaction sequences and format for prompt injection.
    ///
    /// - Parameters:
    ///   - query: Natural language task description (e.g., "send email")
    ///   - targetApp: App name to search in (e.g., "Google Chrome")
    ///   - maxResults: Maximum number of sequences to return
    /// - Returns: Formatted string for system prompt injection, empty if no results
    static func searchAndFormat(
        query: String,
        targetApp: String,
        maxResults: UInt32 = 3
    ) -> String {
        do {
            let sequences = try searchBehavioralContext(
                query: query,
                targetApp: targetApp,
                maxResults: maxResults
            )

            guard !sequences.isEmpty else { return "" }

            return formatForPrompt(sequences)
        } catch {
            logger.warning("Behavioral search failed: \(error, privacy: .public)")
            return ""
        }
    }

    /// Raw search without formatting. Returns behavioral sequences from the Rust index.
    static func search(
        query: String,
        targetApp: String,
        maxResults: UInt32 = 5
    ) -> [BehavioralSequence] {
        do {
            return try searchBehavioralContext(
                query: query,
                targetApp: targetApp,
                maxResults: maxResults
            )
        } catch {
            logger.warning("Behavioral search failed: \(error, privacy: .public)")
            return []
        }
    }

    /// Get diagnostics about enriched click capture.
    static func enrichedClickCount(lastHours: Int = 24) -> UInt64 {
        let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let startUs = nowUs - UInt64(lastHours) * 3_600_000_000
        do {
            return try countEnrichedClicks(startUs: startUs, endUs: nowUs)
        } catch {
            return 0
        }
    }

    /// Get the most frequently interacted elements for an app.
    static func topInteractions(app: String, limit: UInt32 = 10) -> [InteractionSummary] {
        do {
            return try topAppInteractions(appName: app, limit: limit)
        } catch {
            logger.warning("Top interactions query failed: \(error, privacy: .public)")
            return []
        }
    }

    // MARK: - Formatting

    /// Format behavioral sequences for injection into the agent system prompt.
    private static func formatForPrompt(_ sequences: [BehavioralSequence]) -> String {
        var lines: [String] = [
            "# Your User's Past Behavior (from Shadow's recordings)",
            "",
            "The following shows how this user has performed similar tasks before.",
            "Use this as guidance -- adapt to the current situation, don't follow blindly.",
            ""
        ]

        for (i, seq) in sequences.enumerated() {
            let ageStr = formatAge(seq.endTs)
            let actionCount = seq.actions.count

            lines.append("PAST INTERACTION \(i + 1): \"\(seq.windowTitle)\" (\(ageStr), \(actionCount) steps)")

            for (j, action) in seq.actions.enumerated() {
                var desc = "[\(action.actionType)]"

                if let role = action.axRole, let title = action.axTitle {
                    desc += " \(role) \"\(title)\""
                } else if let role = action.axRole {
                    desc += " \(role)"
                }

                if let chars = action.keyChars, !chars.isEmpty {
                    desc += " \"\(chars)\""
                }

                if let x = action.x, let y = action.y {
                    desc += " at (\(x), \(y))"
                }

                lines.append("  \(j + 1). \(desc)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Format a timestamp as relative age (e.g., "2 hours ago", "yesterday").
    private static func formatAge(_ timestampUs: UInt64) -> String {
        let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let ageSeconds = Double(nowUs - timestampUs) / 1_000_000

        if ageSeconds < 60 {
            return "just now"
        } else if ageSeconds < 3600 {
            let minutes = Int(ageSeconds / 60)
            return "\(minutes) min ago"
        } else if ageSeconds < 86400 {
            let hours = Int(ageSeconds / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(ageSeconds / 86400)
            return "\(days)d ago"
        }
    }
}
