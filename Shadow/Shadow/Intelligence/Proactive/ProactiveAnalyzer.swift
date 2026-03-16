import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ProactiveAnalyzer")

/// Generates proactive suggestions from context memory records.
///
/// Stateless enum (same pattern as `ContextSynthesizer`, `MeetingResolver`).
///
/// Pipeline:
/// 1. Load recent context records (episodes, dailies) from ContextStore.
/// 2. Build a candidate analysis prompt for the LLM.
/// 3. Parse LLM output into candidate ProactiveSuggestion(s).
/// 4. Validate evidence (hard gate: no empty-evidence suggestions).
/// 5. Score via ProactivePolicyEngine for decision (push_now / inbox_only / drop).
/// 6. Persist non-dropped suggestions via ProactiveStore.
///
/// Does NOT surface suggestions to UI in this slice — inbox inspection only.
enum ProactiveAnalyzer {

    /// Configuration for the analyzer.
    struct Config: Sendable {
        /// Maximum recent episodes to feed to the LLM.
        var maxRecentEpisodes: Int = 5
        /// Maximum recent dailies to feed to the LLM.
        var maxRecentDailies: Int = 2
        /// Maximum suggestions to generate per analysis pass.
        var maxSuggestionsPerPass: Int = 3

        static let `default` = Config()
    }

    // MARK: - Analysis

    /// Run one analysis pass. Generates and persists suggestions.
    ///
    /// - Parameters:
    ///   - contextStore: Source of episode/daily records.
    ///   - proactiveStore: Persistence target for suggestions.
    ///   - trustTuner: Policy parameter source.
    ///   - generate: LLM generate function (injectable for testing).
    ///   - config: Analysis configuration.
    /// - Returns: Suggestions that were persisted (inbox_only or push_now). Empty if no candidates.
    static func analyze(
        contextStore: ContextStore,
        proactiveStore: ProactiveStore,
        trustTuner: TrustTuner,
        generate: LLMGenerateFunction,
        config: Config = .default
    ) async throws -> [ProactiveSuggestion] {
        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. Load recent context
        let episodes = Array(contextStore.listEpisodes().prefix(config.maxRecentEpisodes))
        let dailies = Array(contextStore.listDailies().prefix(config.maxRecentDailies))

        // Need at least some context to analyze
        if episodes.isEmpty && dailies.isEmpty {
            logger.debug("No context records available for analysis")
            return []
        }

        // 2. Build analysis prompt
        let context = formatAnalysisContext(episodes: episodes, dailies: dailies)

        let request = LLMRequest(
            systemPrompt: analysisSystemPrompt,
            userPrompt: context,
            tools: [],
            maxTokens: 2048,
            temperature: 0.4,
            responseFormat: .json
        )

        // 3. Call LLM
        let response = try await generate(request)

        // 4. Parse candidates
        let candidates = parseCandidates(from: response.content, episodes: episodes)

        DiagnosticsStore.shared.increment("proactive_candidate_total", by: Int64(candidates.count))

        // 5. Score and gate each candidate
        var persisted: [ProactiveSuggestion] = []

        for candidate in candidates.prefix(config.maxSuggestionsPerPass) {
            // Hard gate: evidence must be non-empty
            if let gateError = ProactivePolicyEngine.validateEvidence(candidate.evidence) {
                logger.debug("Candidate dropped: \(gateError)")
                DiagnosticsStore.shared.increment("proactive_drop_total")
                continue
            }

            // Score via policy engine
            let policyInput = PolicyInput(
                suggestionType: candidate.type,
                confidence: candidate.confidence,
                evidenceQuality: evidenceQuality(candidate.evidence),
                noveltyScore: 0.7,  // v1: default novelty (no history-based dedup yet)
                interruptionCost: 0.0,  // v1: no interruption context yet
                preferenceAffinity: trustTuner.effectiveParameters().preferredSuggestionTypes[candidate.type] ?? 0.0
            )

            let policyOutput = ProactivePolicyEngine.evaluate(policyInput, tuner: trustTuner)

            // Build final suggestion with policy decision
            let suggestion = ProactiveSuggestion(
                id: UUID(),
                createdAt: Date(),
                type: candidate.type,
                title: candidate.title,
                body: candidate.body,
                whyNow: candidate.whyNow,
                confidence: policyOutput.score,
                decision: policyOutput.decision,
                evidence: candidate.evidence,
                sourceRecordIds: candidate.sourceRecordIds,
                status: .active
            )

            switch policyOutput.decision {
            case .pushNow:
                proactiveStore.saveSuggestion(suggestion)
                persisted.append(suggestion)
                DiagnosticsStore.shared.increment("proactive_push_total")
                logger.info("Suggestion push_now: \(suggestion.title)")

            case .inboxOnly:
                proactiveStore.saveSuggestion(suggestion)
                persisted.append(suggestion)
                DiagnosticsStore.shared.increment("proactive_inbox_only_total")
                logger.info("Suggestion inbox_only: \(suggestion.title)")

            case .drop:
                DiagnosticsStore.shared.increment("proactive_drop_total")
                logger.debug("Suggestion dropped (low score): \(suggestion.title) (\(String(format: "%.3f", policyOutput.score)))")
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.info("Analysis complete: \(candidates.count) candidates, \(persisted.count) persisted, \(String(format: "%.0f", elapsed))ms")

        return persisted
    }

    // MARK: - Context Formatting

    private static func formatAnalysisContext(
        episodes: [EpisodeRecord],
        dailies: [DailyRecord]
    ) -> String {
        var lines: [String] = []

        if !dailies.isEmpty {
            lines.append("--- Recent Days ---")
            for daily in dailies {
                lines.append("[\(daily.date)] \(daily.summary)")
                if !daily.openLoops.isEmpty {
                    lines.append("  Open loops: \(daily.openLoops.joined(separator: "; "))")
                }
            }
            lines.append("")
        }

        if !episodes.isEmpty {
            lines.append("--- Recent Episodes ---")
            for ep in episodes {
                let startStr = formatTimestamp(ep.startUs)
                let endStr = formatTimestamp(ep.endUs)
                lines.append("[\(startStr)-\(endStr)] \(ep.summary)")
                lines.append("  Topics: \(ep.topicTags.joined(separator: ", "))")
                lines.append("  Apps: \(ep.apps.joined(separator: ", "))")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Response Parsing

    /// Parsed candidate from LLM output (before policy scoring).
    private struct Candidate {
        let type: SuggestionType
        let title: String
        let body: String
        let whyNow: String
        let confidence: Double
        let evidence: [SuggestionEvidence]
        let sourceRecordIds: [String]
    }

    private static func parseCandidates(
        from content: String,
        episodes: [EpisodeRecord]
    ) -> [Candidate] {
        let cleaned = cleanJSONContent(content)
        guard let data = cleaned.data(using: .utf8) else { return [] }

        // Expect {"suggestions": [...]}
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let suggestions = root["suggestions"] as? [[String: Any]] else {
            // Try as a bare array
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return arr.compactMap { parseSingleCandidate($0, episodes: episodes) }
            }
            return []
        }

        return suggestions.compactMap { parseSingleCandidate($0, episodes: episodes) }
    }

    private static func parseSingleCandidate(
        _ dict: [String: Any],
        episodes: [EpisodeRecord]
    ) -> Candidate? {
        guard let title = dict["title"] as? String, !title.isEmpty,
              let body = dict["body"] as? String, !body.isEmpty else {
            return nil
        }

        let typeStr = dict["type"] as? String ?? "followup"
        let type = SuggestionType(rawValue: typeStr) ?? .followup
        let whyNow = dict["whyNow"] as? String ?? ""
        let confidence = (dict["confidence"] as? Double) ?? 0.5

        // Parse evidence from LLM output
        let evidenceArray = dict["evidence"] as? [[String: Any]] ?? []
        var evidence: [SuggestionEvidence] = evidenceArray.compactMap { parseEvidence($0) }

        // If LLM didn't produce evidence, derive from source episodes
        if evidence.isEmpty {
            evidence = deriveEvidenceFromEpisodes(episodes)
        }

        // Source record IDs
        let sourceRecordIds = dict["sourceRecordIds"] as? [String]
            ?? episodes.prefix(3).map { $0.id.uuidString }

        return Candidate(
            type: type,
            title: title,
            body: body,
            whyNow: whyNow,
            confidence: confidence,
            evidence: evidence,
            sourceRecordIds: sourceRecordIds
        )
    }

    private static func parseEvidence(_ dict: [String: Any]) -> SuggestionEvidence? {
        guard let tsNumber = dict["timestamp"] as? NSNumber,
              let timestamp = ContextSynthesizer.safeUInt64(tsNumber) else { return nil }
        let displayId: UInt32? = (dict["displayId"] as? NSNumber).flatMap { ContextSynthesizer.safeUInt32($0) }
        return SuggestionEvidence(
            timestamp: timestamp,
            app: dict["app"] as? String,
            sourceKind: dict["sourceKind"] as? String ?? "episode",
            displayId: displayId,
            url: dict["url"] as? String,
            snippet: dict["snippet"] as? String ?? ""
        )
    }

    /// Derive evidence anchors from the most recent episodes when LLM doesn't provide them.
    private static func deriveEvidenceFromEpisodes(_ episodes: [EpisodeRecord]) -> [SuggestionEvidence] {
        episodes.prefix(3).compactMap { ep -> SuggestionEvidence? in
            guard !ep.evidence.isEmpty else { return nil }
            let ctx = ep.evidence[0]
            return SuggestionEvidence(
                timestamp: ctx.timestamp,
                app: ctx.app,
                sourceKind: "episode",
                displayId: ctx.displayId,
                url: ctx.url,
                snippet: String(ep.summary.prefix(100))
            )
        }
    }

    /// Compute evidence quality score [0, 1] based on richness.
    private static func evidenceQuality(_ evidence: [SuggestionEvidence]) -> Double {
        guard !evidence.isEmpty else { return 0 }
        let count = min(Double(evidence.count), 5.0)
        let hasApps = evidence.contains { $0.app != nil }
        let hasSnippets = evidence.contains { !$0.snippet.isEmpty }
        return min(1.0, (count / 5.0) * 0.5 + (hasApps ? 0.25 : 0) + (hasSnippets ? 0.25 : 0))
    }

    // MARK: - Prompt

    private static let analysisSystemPrompt = """
    You are a proactive assistant analyzing a user's recent computer activity. Based on the context \
    provided, generate actionable suggestions that could help the user.

    Output ONLY valid JSON matching this exact schema (no markdown, no explanation, no code fences):

    {
      "suggestions": [
        {
          "type": "followup|meeting_prep|workload_pattern|reminder|context_switch|daily_digest",
          "title": "Short actionable title (under 60 chars)",
          "body": "1-2 sentence explanation of what to do and why",
          "whyNow": "Brief reason why this is relevant right now",
          "confidence": 0.75,
          "evidence": [
            {
              "timestamp": 1708300000000000,
              "app": "AppName",
              "sourceKind": "episode",
              "snippet": "Brief supporting context"
            }
          ]
        }
      ]
    }

    Rules:
    - Generate 0-3 suggestions. Prefer fewer high-quality ones over many weak ones.
    - Every suggestion MUST have at least one evidence entry with a valid timestamp.
    - "followup" = action items or threads that need continuation.
    - "meeting_prep" = upcoming meeting context or preparation needs.
    - "workload_pattern" = productivity insight or overload warning.
    - "reminder" = something the user might have forgotten.
    - "context_switch" = help transitioning between tasks.
    - "daily_digest" = end-of-day summary or reflection prompt.
    - confidence: 0.0 to 1.0, where 1.0 means extremely confident this is useful.
    - Use absolute Unix microsecond timestamps from the input data for evidence.
    - If no strong suggestions exist, return {"suggestions": []}.
    - Do NOT fabricate evidence or timestamps not present in the input.
    """

    // MARK: - Helpers

    private static func formatTimestamp(_ us: UInt64) -> String {
        let date = Date(timeIntervalSince1970: Double(us) / 1_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func cleanJSONContent(_ content: String) -> String {
        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
