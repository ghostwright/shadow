import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "MemoryQueryPlanner")

/// Plans and executes multi-source memory queries using LLM reasoning.
///
/// Given a natural language question, the planner decides which memory stores
/// to query and how to combine results. This replaces naive keyword matching
/// with semantic understanding of what information the agent needs.
///
/// Stateless enum (same pattern as ContextPacker, MeetingResolver).
enum MemoryQueryPlanner {

    /// A planned memory query with source and parameters.
    struct MemoryQuery: Sendable, Equatable {
        let source: MemorySource
        let category: String?
        let keywords: [String]
        let timeRangeUs: (start: UInt64, end: UInt64)?
        let limit: UInt32

        static func == (lhs: MemoryQuery, rhs: MemoryQuery) -> Bool {
            lhs.source == rhs.source
                && lhs.category == rhs.category
                && lhs.keywords == rhs.keywords
                && lhs.limit == rhs.limit
        }
    }

    /// Memory sources the planner can query.
    enum MemorySource: String, Sendable, Equatable {
        case semanticKnowledge = "semantic_knowledge"
        case directives = "directives"
        case episodes = "episodes"
        case procedures = "procedures"
    }

    /// Result of executing a memory query plan.
    struct MemoryQueryResult: Sendable {
        let source: MemorySource
        let entries: [MemoryEntry]
    }

    /// A single memory entry from any source, normalized for the agent.
    struct MemoryEntry: Sendable {
        let id: String
        let category: String
        let key: String
        let summary: String
        let confidence: Double
        let timestamp: UInt64
    }

    // MARK: - Plan Generation

    /// Generate a query plan using LLM reasoning.
    ///
    /// The LLM analyzes the user's question and determines which memory stores
    /// to search and what parameters to use. Falls back to heuristic planning
    /// if the LLM is unavailable.
    ///
    /// - Parameters:
    ///   - question: Natural language query from the user or agent
    ///   - contextHint: Optional hint about current activity context
    ///   - generate: LLM generation function
    /// - Returns: Array of planned queries, sorted by relevance
    static func plan(
        question: String,
        contextHint: String? = nil,
        generate: LLMGenerateFunction? = nil
    ) async -> [MemoryQuery] {
        if let generate {
            do {
                return try await llmPlan(question: question, contextHint: contextHint, generate: generate)
            } catch {
                logger.warning("LLM plan failed, falling back to heuristic: \(error, privacy: .public)")
            }
        }

        return heuristicPlan(question: question)
    }

    // MARK: - Query Execution

    /// Execute a query plan and collect results from all sources.
    ///
    /// Queries run sequentially to avoid overwhelming the database.
    /// Each source's results are normalized into MemoryEntry format.
    static func execute(
        plan: [MemoryQuery],
        knowledgeQueryFn: SemanticMemoryStore.QueryFn = { cat, lim in
            try querySemanticKnowledge(category: cat, limit: lim)
        },
        directiveQueryFn: DirectiveMemoryStore.QueryActiveFn = { nowUs, lim in
            try queryActiveDirectives(nowUs: nowUs, limit: lim)
        },
        contextStore: ContextStore? = nil
    ) throws -> [MemoryQueryResult] {
        var results: [MemoryQueryResult] = []

        for query in plan {
            switch query.source {
            case .semanticKnowledge:
                let records = try knowledgeQueryFn(query.category, query.limit)
                let entries = records.map { record in
                    MemoryEntry(
                        id: record.id,
                        category: record.category,
                        key: record.key,
                        summary: record.value,
                        confidence: record.confidence,
                        timestamp: record.updatedAt
                    )
                }
                results.append(MemoryQueryResult(source: .semanticKnowledge, entries: entries))

            case .directives:
                let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
                let records = try directiveQueryFn(nowUs, query.limit)
                let entries = records.map { record in
                    MemoryEntry(
                        id: record.id,
                        category: record.directiveType,
                        key: record.triggerPattern,
                        summary: record.actionDescription,
                        confidence: 1.0,
                        timestamp: record.createdAt
                    )
                }
                results.append(MemoryQueryResult(source: .directives, entries: entries))

            case .episodes:
                guard let store = contextStore else { continue }
                let episodes = Array(store.listEpisodes().prefix(Int(query.limit)))
                let entries = episodes.map { ep in
                    MemoryEntry(
                        id: ep.id.uuidString,
                        category: "episode",
                        key: ep.topicTags.joined(separator: ", "),
                        summary: ep.summary,
                        confidence: 1.0,
                        timestamp: ep.endUs
                    )
                }
                results.append(MemoryQueryResult(source: .episodes, entries: entries))

            case .procedures:
                // Procedure queries are handled by the existing get_procedures tool
                // This is a placeholder for when procedure embedding search is added
                break
            }
        }

        DiagnosticsStore.shared.increment("memory_query_plan_executed_total")
        return results
    }

    // MARK: - Format for Context

    /// Format query results as text for agent context injection.
    ///
    /// Each source's results are formatted as a section with entries.
    /// The total output is bounded by maxChars.
    static func formatForContext(
        results: [MemoryQueryResult],
        maxChars: Int = 4000
    ) -> String {
        var sections: [String] = []
        var totalChars = 0

        for result in results where !result.entries.isEmpty {
            let header = "[\(result.source.rawValue)]"
            var lines: [String] = [header]

            for entry in result.entries {
                let line: String
                if entry.category.isEmpty {
                    line = "- \(entry.key): \(entry.summary)"
                } else {
                    line = "- [\(entry.category)] \(entry.key): \(entry.summary)"
                }

                let candidateSize = totalChars + lines.joined(separator: "\n").count + line.count + 2
                if candidateSize > maxChars { break }

                lines.append(line)
            }

            let section = lines.joined(separator: "\n")
            if totalChars + section.count + 2 > maxChars { break }
            sections.append(section)
            totalChars += section.count + 2
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - LLM Planning

    private static func llmPlan(
        question: String,
        contextHint: String?,
        generate: LLMGenerateFunction
    ) async throws -> [MemoryQuery] {
        let contextLine = contextHint.map { "\nCurrent context: \($0)" } ?? ""

        let prompt = """
        You are a memory query planner. Given a question, decide which memory stores to search.

        Available sources:
        - semantic_knowledge: Long-term facts, preferences, patterns (has categories: preference, fact, pattern, relationship, skill)
        - directives: Active instructions and reminders
        - episodes: Recent activity summaries (last few hours/days)

        Question: \(question)\(contextLine)

        Respond with a JSON array of queries:
        [{"source": "semantic_knowledge", "category": "preference", "limit": 10}]

        Rules:
        - Include only relevant sources
        - Use category filter when the question targets a specific domain
        - Keep limits reasonable (5-20)
        - Order by relevance (most relevant first)
        """

        let request = LLMRequest(
            systemPrompt: "You are a memory query planner. Respond with only a JSON array.",
            userPrompt: prompt,
            maxTokens: 512,
            temperature: 0.2,
            responseFormat: .json
        )

        let response = try await generate(request)
        return parseQueryPlan(response.content)
    }

    /// Parse the LLM's JSON response into query objects.
    private static func parseQueryPlan(_ text: String) -> [MemoryQuery] {
        // Extract JSON from potential markdown code blocks
        let jsonStr: String
        if let start = text.range(of: "["), let end = text.range(of: "]", options: .backwards) {
            jsonStr = String(text[start.lowerBound..<end.upperBound])
        } else {
            return heuristicPlan(question: "")
        }

        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return heuristicPlan(question: "")
        }

        return array.compactMap { dict -> MemoryQuery? in
            guard let sourceStr = dict["source"] as? String,
                  let source = MemorySource(rawValue: sourceStr) else { return nil }
            let category = dict["category"] as? String
            let limit = (dict["limit"] as? Int).map { UInt32($0) } ?? 10
            return MemoryQuery(source: source, category: category, keywords: [], timeRangeUs: nil, limit: limit)
        }
    }

    // MARK: - Heuristic Planning

    /// Fallback query plan when LLM is unavailable.
    ///
    /// Simple keyword-based routing: checks for trigger words
    /// that indicate which memory sources are relevant.
    private static func heuristicPlan(question: String) -> [MemoryQuery] {
        let q = question.lowercased()
        var queries: [MemoryQuery] = []

        // Check for preference-related keywords
        let prefKeywords = ["prefer", "like", "usually", "favorite", "default", "setting"]
        if prefKeywords.contains(where: { q.contains($0) }) {
            queries.append(MemoryQuery(
                source: .semanticKnowledge,
                category: "preference",
                keywords: [],
                timeRangeUs: nil,
                limit: 10
            ))
        }

        // Check for directive-related keywords
        let dirKeywords = ["remind", "when", "alert", "watch", "notify", "should"]
        if dirKeywords.contains(where: { q.contains($0) }) {
            queries.append(MemoryQuery(
                source: .directives,
                category: nil,
                keywords: [],
                timeRangeUs: nil,
                limit: 10
            ))
        }

        // Check for recent activity keywords
        let actKeywords = ["recent", "today", "yesterday", "earlier", "last", "was doing"]
        if actKeywords.contains(where: { q.contains($0) }) {
            queries.append(MemoryQuery(
                source: .episodes,
                category: nil,
                keywords: [],
                timeRangeUs: nil,
                limit: 5
            ))
        }

        // Default: search everything if no keywords matched
        if queries.isEmpty {
            queries = [
                MemoryQuery(source: .semanticKnowledge, category: nil, keywords: [], timeRangeUs: nil, limit: 10),
                MemoryQuery(source: .directives, category: nil, keywords: [], timeRangeUs: nil, limit: 5),
                MemoryQuery(source: .episodes, category: nil, keywords: [], timeRangeUs: nil, limit: 3),
            ]
        }

        return queries
    }
}
