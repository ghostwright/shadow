import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "SemanticConsolidator")

/// Consolidates episodic memories into semantic knowledge.
///
/// This is the episodic-to-semantic knowledge pipeline:
/// 1. Takes recent episodes that haven't been consolidated yet
/// 2. Asks the LLM to extract durable facts, preferences, and patterns
/// 3. Upserts extracted knowledge into the semantic knowledge store
/// 4. Updates confidence scores for existing knowledge (reinforcement)
///
/// Runs on the heartbeat cycle, after episode synthesis completes.
/// Stateless enum (same pattern as ContextSynthesizer).
enum SemanticConsolidator {

    /// Result of a consolidation pass.
    struct ConsolidationResult: Sendable {
        let newKnowledge: Int
        let updatedKnowledge: Int
        let episodesProcessed: Int
    }

    // MARK: - Consolidate

    /// Extract semantic knowledge from recent episodes.
    ///
    /// - Parameters:
    ///   - episodes: Recent episodes to consolidate (typically 3-5)
    ///   - existingKnowledge: Current semantic knowledge for dedup/reinforcement
    ///   - generate: LLM generation function
    ///   - saveFn: Function to persist extracted knowledge
    /// - Returns: Summary of what was extracted/updated
    static func consolidate(
        episodes: [EpisodeRecord],
        existingKnowledge: [SemanticKnowledge] = [],
        generate: LLMGenerateFunction,
        saveFn: @escaping (SemanticKnowledge) throws -> Void = { knowledge in
            try SemanticMemoryStore.save(knowledge)
        }
    ) async throws -> ConsolidationResult {
        guard !episodes.isEmpty else {
            return ConsolidationResult(newKnowledge: 0, updatedKnowledge: 0, episodesProcessed: 0)
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Build the consolidation prompt
        let prompt = buildPrompt(episodes: episodes, existingKnowledge: existingKnowledge)

        let request = LLMRequest(
            systemPrompt: """
                You are a knowledge extraction engine. Analyze activity episodes and extract \
                durable facts, preferences, and behavioral patterns. Output only a JSON array.
                """,
            userPrompt: prompt,
            maxTokens: 2048,
            temperature: 0.3,
            responseFormat: .json
        )

        let response = try await generate(request)
        let extracted = parseExtractions(response.content, episodeIds: episodes.map { $0.id.uuidString })
        let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)

        // Merge with existing knowledge
        var newCount = 0
        var updatedCount = 0
        let existingMap = Dictionary(uniqueKeysWithValues: existingKnowledge.map { ($0.id, $0) })

        for var item in extracted {
            let stableId = SemanticMemoryStore.stableId(category: item.category, key: item.key)
            item = SemanticKnowledge(
                id: stableId,
                category: item.category,
                key: item.key,
                value: item.value,
                confidence: item.confidence,
                sourceEpisodeIds: item.sourceEpisodeIds,
                createdAt: existingMap[stableId]?.createdAt ?? nowUs,
                updatedAt: nowUs,
                accessCount: existingMap[stableId]?.accessCount ?? 0,
                lastAccessedAt: existingMap[stableId]?.lastAccessedAt
            )

            if let existing = existingMap[stableId] {
                // Reinforcement: boost confidence, merge episode IDs
                let mergedEpisodeIds = Set(existing.sourceEpisodeIds + item.sourceEpisodeIds)
                let boostedConfidence = min(existing.confidence * 0.3 + item.confidence * 0.7, 1.0)
                item = SemanticKnowledge(
                    id: stableId,
                    category: item.category,
                    key: item.key,
                    value: item.value,
                    confidence: boostedConfidence,
                    sourceEpisodeIds: Array(mergedEpisodeIds),
                    createdAt: existing.createdAt,
                    updatedAt: nowUs,
                    accessCount: existing.accessCount,
                    lastAccessedAt: existing.lastAccessedAt
                )
                updatedCount += 1
            } else {
                newCount += 1
            }

            try saveFn(item)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        DiagnosticsStore.shared.increment("semantic_consolidation_total")
        DiagnosticsStore.shared.recordLatency("semantic_consolidation_ms", ms: elapsed)
        DiagnosticsStore.shared.setGauge("semantic_consolidation_new", value: Double(newCount))
        DiagnosticsStore.shared.setGauge("semantic_consolidation_updated", value: Double(updatedCount))

        logger.info("Consolidation: \(newCount) new, \(updatedCount) updated from \(episodes.count) episodes (\(String(format: "%.0f", elapsed))ms)")

        return ConsolidationResult(
            newKnowledge: newCount,
            updatedKnowledge: updatedCount,
            episodesProcessed: episodes.count
        )
    }

    // MARK: - Prompt Building

    private static func buildPrompt(
        episodes: [EpisodeRecord],
        existingKnowledge: [SemanticKnowledge]
    ) -> String {
        var parts: [String] = []

        parts.append("Analyze these activity episodes and extract durable knowledge.")
        parts.append("")

        // Episodes
        parts.append("## Recent Episodes")
        for ep in episodes {
            parts.append("- [\(ep.topicTags.joined(separator: ", "))] \(ep.summary)")
            if !ep.apps.isEmpty {
                parts.append("  Apps: \(ep.apps.joined(separator: ", "))")
            }
        }

        // Existing knowledge for dedup
        if !existingKnowledge.isEmpty {
            parts.append("")
            parts.append("## Existing Knowledge (for dedup/update)")
            for k in existingKnowledge.prefix(20) {
                parts.append("- [\(k.category)] \(k.key): \(k.value) (confidence: \(String(format: "%.2f", k.confidence)))")
            }
        }

        parts.append("")
        parts.append("""
        Extract knowledge as a JSON array. Each entry:
        {
          "category": "preference|fact|pattern|relationship|skill",
          "key": "short identifier",
          "value": "description of the knowledge",
          "confidence": 0.0-1.0
        }

        Rules:
        - Only extract knowledge that would be useful across sessions
        - Prefer updating existing knowledge over creating duplicates
        - Confidence: 0.5 for single observation, 0.8+ for repeated patterns
        - Keep values concise (under 200 chars)
        - Categories: preference (user choices), fact (environment), pattern (behaviors), relationship (connections), skill (how-to)
        """)

        return parts.joined(separator: "\n")
    }

    // MARK: - Response Parsing

    private static func parseExtractions(
        _ text: String,
        episodeIds: [String]
    ) -> [SemanticKnowledge] {
        // Extract JSON array from potential markdown code blocks
        let jsonStr: String
        if let start = text.range(of: "["), let end = text.range(of: "]", options: .backwards) {
            jsonStr = String(text[start.lowerBound..<end.upperBound])
        } else {
            logger.warning("No JSON array found in consolidation response")
            return []
        }

        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            logger.warning("Failed to parse consolidation JSON")
            return []
        }

        let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let validCategories: Set<String> = ["preference", "fact", "pattern", "relationship", "skill"]

        return array.compactMap { dict -> SemanticKnowledge? in
            guard let category = dict["category"] as? String,
                  validCategories.contains(category),
                  let key = dict["key"] as? String, !key.isEmpty,
                  let value = dict["value"] as? String, !value.isEmpty else {
                return nil
            }

            let confidence = (dict["confidence"] as? Double) ?? 0.5
            let clampedConfidence = min(max(confidence, 0.0), 1.0)
            let stableId = SemanticMemoryStore.stableId(category: category, key: key)

            return SemanticKnowledge(
                id: stableId,
                category: category,
                key: key,
                value: String(value.prefix(500)),
                confidence: clampedConfidence,
                sourceEpisodeIds: episodeIds,
                createdAt: nowUs,
                updatedAt: nowUs,
                accessCount: 0,
                lastAccessedAt: nil
            )
        }
    }
}
