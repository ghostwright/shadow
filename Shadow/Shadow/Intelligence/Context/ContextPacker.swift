import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ContextPacker")

/// Assembles context memory records into a bounded text pack for the agent runtime.
///
/// Stateless enum (same pattern as `MeetingResolver`, `ContextSynthesizer`).
///
/// Pipeline:
/// 1. Deterministic selector: picks candidate records sorted by recency under hard budget.
/// 2. Assembles formatted text with section headers and evidence refs.
/// 3. Validates budget and truncates with summary if exceeded.
/// 4. Falls back to empty pack if no records available.
///
/// The output `ContextPack` is consumed by `AgentRuntime` and prepended to the LLM context.
enum ContextPacker {

    /// Default configuration for context packing.
    struct Config: Sendable {
        /// Maximum character budget for the entire pack text.
        /// Roughly: 4 chars ≈ 1 token. Default 8000 chars ≈ 2000 tokens.
        var maxPackChars: Int = 8000

        /// Maximum number of episode records to include.
        var maxEpisodes: Int = 6

        /// Maximum number of daily records to include.
        var maxDailies: Int = 3

        /// Maximum number of weekly records to include.
        var maxWeeklies: Int = 1

        /// Maximum evidence refs to carry forward.
        var maxEvidenceRefs: Int = 20

        static let `default` = Config()
    }

    private static let header = "--- User Context Memory ---"

    // MARK: - Pack Assembly

    /// Build a context pack from available memory records.
    ///
    /// Deterministic: same records + same config = same output.
    /// No LLM calls — this is a pure selection + formatting pass.
    ///
    /// - Parameters:
    ///   - contextStore: Source of episode/daily/weekly records.
    ///   - config: Budget and limit configuration.
    ///   - nowUs: Current time in Unix microseconds (for recency scoring). Injectable for testing.
    /// - Returns: A bounded `ContextPack` ready for agent runtime injection.
    static func pack(
        contextStore: ContextStore,
        config: Config = .default,
        nowUs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000_000)
    ) -> ContextPack {
        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. Load candidates sorted by recency
        let episodes = Array(contextStore.listEpisodes().prefix(config.maxEpisodes))
        let dailies = Array(contextStore.listDailies().prefix(config.maxDailies))
        let weeklies = Array(contextStore.listWeeklies().prefix(config.maxWeeklies))

        // 2. Assemble sections under budget
        //    Account for header ("--- User Context Memory ---\n") and "\n\n" separators
        //    in the budget so final packText.count never exceeds maxPackChars.
        let headerOverhead = header.count + 1  // header + "\n"
        let separatorOverhead = 2  // "\n\n" between each section

        var sections: [String] = []
        var includedRecords: [IncludedRecord] = []
        var allEvidence: [ContextEvidence] = []
        var totalChars = headerOverhead  // reserve header upfront
        var wasTruncated = false
        var truncatedSections: [String] = []

        // Weekly context (broadest, included first as stable background)
        for weekly in weeklies {
            let section = formatWeeklySection(weekly)
            let cost = section.count + (sections.isEmpty ? 0 : separatorOverhead)
            if totalChars + cost <= config.maxPackChars {
                sections.append(section)
                totalChars += cost
                includedRecords.append(IncludedRecord(id: weekly.weekId, layer: .week))
                allEvidence.append(contentsOf: weekly.evidence)
            } else {
                wasTruncated = true
                truncatedSections.append("weekly:\(weekly.weekId)")
            }
        }

        // Daily context (operational memory)
        for daily in dailies {
            let section = formatDailySection(daily)
            let cost = section.count + (sections.isEmpty ? 0 : separatorOverhead)
            if totalChars + cost <= config.maxPackChars {
                sections.append(section)
                totalChars += cost
                includedRecords.append(IncludedRecord(id: daily.date, layer: .day))
                allEvidence.append(contentsOf: daily.evidence)
            } else {
                wasTruncated = true
                truncatedSections.append("daily:\(daily.date)")
            }
        }

        // Semantic knowledge (durable facts and preferences)
        let knowledge: [SemanticKnowledge]
        do {
            knowledge = try SemanticMemoryStore.query(limit: 10)
        } catch {
            knowledge = []
        }
        if !knowledge.isEmpty {
            let section = formatKnowledgeSection(knowledge)
            let cost = section.count + (sections.isEmpty ? 0 : separatorOverhead)
            if totalChars + cost <= config.maxPackChars {
                sections.append(section)
                totalChars += cost
                for k in knowledge {
                    includedRecords.append(IncludedRecord(id: k.id, layer: .episode))
                }
            } else {
                wasTruncated = true
                truncatedSections.append("knowledge:\(knowledge.count) entries")
            }
        }

        // Active directives (reminders, habits, watches)
        let directives: [Directive]
        do {
            directives = try DirectiveMemoryStore.queryActive(limit: 10)
        } catch {
            directives = []
        }
        if !directives.isEmpty {
            let section = formatDirectivesSection(directives)
            let cost = section.count + (sections.isEmpty ? 0 : separatorOverhead)
            if totalChars + cost <= config.maxPackChars {
                sections.append(section)
                totalChars += cost
                for d in directives {
                    includedRecords.append(IncludedRecord(id: d.id, layer: .episode))
                }
            } else {
                wasTruncated = true
                truncatedSections.append("directives:\(directives.count) entries")
            }
        }

        // Episode context (most recent, highest detail)
        for episode in episodes {
            let section = formatEpisodeSection(episode)
            let cost = section.count + (sections.isEmpty ? 0 : separatorOverhead)
            if totalChars + cost <= config.maxPackChars {
                sections.append(section)
                totalChars += cost
                includedRecords.append(IncludedRecord(id: episode.id.uuidString, layer: .episode))
                allEvidence.append(contentsOf: episode.evidence)
            } else {
                wasTruncated = true
                truncatedSections.append("episode:\(episode.id.uuidString.prefix(8))")
            }
        }

        // 3. Cap evidence refs
        let cappedEvidence = Array(allEvidence.prefix(config.maxEvidenceRefs))

        // 4. Build final pack text
        var packText: String
        if sections.isEmpty {
            packText = ""
        } else {
            packText = header + "\n" + sections.joined(separator: "\n\n")
        }

        // 5. Hard trim: guarantee packText.count <= maxPackChars regardless of rounding
        if packText.count > config.maxPackChars {
            packText = String(packText.prefix(config.maxPackChars))
            wasTruncated = true
        }

        // Truncation summary
        let truncationSummary: String?
        if wasTruncated {
            truncationSummary = "Truncated \(truncatedSections.count) record(s): \(truncatedSections.joined(separator: ", "))"
        } else {
            truncationSummary = nil
        }

        let estimatedTokens = packText.count / 4  // conservative estimate

        // 6. Diagnostics
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        DiagnosticsStore.shared.increment("context_pack_total")
        DiagnosticsStore.shared.recordLatency("context_pack_ms", ms: elapsed)
        DiagnosticsStore.shared.setGauge("context_pack_estimated_tokens", value: Double(estimatedTokens))
        if wasTruncated {
            DiagnosticsStore.shared.increment("context_pack_truncation_total")
        }

        if !packText.isEmpty {
            logger.info("Context pack: \(includedRecords.count) records, \(packText.count) chars, \(estimatedTokens) est. tokens, \(String(format: "%.1f", elapsed))ms")
        }

        return ContextPack(
            packText: packText,
            includedRecords: includedRecords,
            rawEvidenceRefs: cappedEvidence,
            estimatedTokens: estimatedTokens,
            truncationSummary: truncationSummary
        )
    }

    // MARK: - Section Formatting

    private static func formatWeeklySection(_ weekly: WeeklyRecord) -> String {
        var lines: [String] = []
        lines.append("[Week: \(weekly.weekId)]")
        lines.append(weekly.summary)
        if !weekly.majorThemes.isEmpty {
            lines.append("Themes: \(weekly.majorThemes.joined(separator: ", "))")
        }
        if !weekly.carryOverItems.isEmpty {
            lines.append("Carry-over: \(weekly.carryOverItems.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatDailySection(_ daily: DailyRecord) -> String {
        var lines: [String] = []
        lines.append("[Day: \(daily.date)]")
        lines.append(daily.summary)
        if !daily.wins.isEmpty {
            lines.append("Wins: \(daily.wins.joined(separator: "; "))")
        }
        if !daily.openLoops.isEmpty {
            lines.append("Open loops: \(daily.openLoops.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatEpisodeSection(_ episode: EpisodeRecord) -> String {
        var lines: [String] = []
        let startStr = formatTimestamp(episode.startUs)
        let endStr = formatTimestamp(episode.endUs)
        lines.append("[Episode: \(startStr) – \(endStr)]")
        lines.append(episode.summary)
        if !episode.topicTags.isEmpty {
            lines.append("Topics: \(episode.topicTags.joined(separator: ", "))")
        }
        if !episode.apps.isEmpty {
            lines.append("Apps: \(episode.apps.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatKnowledgeSection(_ knowledge: [SemanticKnowledge]) -> String {
        var lines: [String] = []
        lines.append("[Semantic Knowledge]")
        for k in knowledge {
            lines.append("- [\(k.category)] \(k.key): \(k.value)")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatDirectivesSection(_ directives: [Directive]) -> String {
        var lines: [String] = []
        lines.append("[Active Directives]")
        for d in directives {
            var line = "- [\(d.directiveType)] When: \(d.triggerPattern) -> \(d.actionDescription)"
            if let expires = d.expiresAt {
                let hours = Double(expires - UInt64(Date().timeIntervalSince1970 * 1_000_000)) / 3_600_000_000
                if hours > 0 {
                    line += " (expires in \(String(format: "%.1f", hours))h)"
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Format a Unix microsecond timestamp as "HH:mm".
    private static func formatTimestamp(_ us: UInt64) -> String {
        let date = Date(timeIntervalSince1970: Double(us) / 1_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
