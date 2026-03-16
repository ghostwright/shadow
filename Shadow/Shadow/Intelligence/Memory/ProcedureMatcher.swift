import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ProcedureMatcher")

/// Matches current user context against saved procedures to suggest automation.
///
/// Two matching strategies:
/// 1. Context matching: Compare current app/window against procedure sourceApp/tags
/// 2. LLM semantic matching: Ask the LLM if any procedure is relevant to current activity
///
/// Stateless enum (same pattern as ContextPacker, MeetingResolver).
enum ProcedureMatcher {

    /// A scored procedure match with reason.
    struct ProcedureMatch: Sendable, Equatable {
        let procedureId: String
        let procedureName: String
        let score: Double       // 0.0-1.0
        let matchReason: String // Why this procedure matches
        let sourceApp: String
    }

    /// Context about what the user is currently doing.
    struct ActivityContext: Sendable {
        let currentApp: String
        let currentBundleId: String?
        let windowTitle: String?
        let url: String?
        let recentApps: [String]
    }

    // MARK: - Match

    /// Find procedures that match the current activity context.
    ///
    /// - Parameters:
    ///   - context: Current user activity
    ///   - store: Procedure store to search
    ///   - generate: Optional LLM for semantic matching (falls back to heuristic)
    ///   - maxResults: Maximum matches to return
    /// - Returns: Scored matches, sorted by score descending
    static func match(
        context: ActivityContext,
        store: ProcedureStore,
        generate: LLMGenerateFunction? = nil,
        maxResults: Int = 5
    ) async -> [ProcedureMatch] {
        let procedures = await store.listAll()
        guard !procedures.isEmpty else { return [] }

        // Phase 1: Heuristic pre-filter (fast, no LLM)
        var candidates = heuristicMatch(context: context, procedures: procedures)

        // Phase 2: LLM semantic refinement (if available and candidates exist)
        if let generate, !candidates.isEmpty {
            do {
                candidates = try await llmRefine(
                    context: context,
                    candidates: candidates,
                    procedures: procedures,
                    generate: generate
                )
            } catch {
                logger.warning("LLM refinement failed: \(error, privacy: .public)")
                // Fall through with heuristic results
            }
        }

        DiagnosticsStore.shared.increment("procedure_match_total")
        return Array(candidates.sorted { $0.score > $1.score }.prefix(maxResults))
    }

    // MARK: - Heuristic Matching

    /// Fast matching based on app name, bundle ID, and tags.
    ///
    /// Scoring:
    /// - 0.9: Exact bundle ID match
    /// - 0.8: Exact app name match
    /// - 0.6: App in recent apps list
    /// - 0.4: Tag matches window title keywords
    /// - 0.0: No match
    static func heuristicMatch(
        context: ActivityContext,
        procedures: [ProcedureTemplate]
    ) -> [ProcedureMatch] {
        var matches: [ProcedureMatch] = []

        for proc in procedures {
            var score = 0.0
            var reason = ""

            // Bundle ID match (strongest signal)
            if let bundleId = context.currentBundleId,
               proc.sourceBundleId.lowercased() == bundleId.lowercased() {
                score = max(score, 0.9)
                reason = "Same app (bundle ID match)"
            }

            // App name match
            if proc.sourceApp.lowercased() == context.currentApp.lowercased() {
                score = max(score, 0.8)
                if reason.isEmpty { reason = "Same app (name match)" }
            }

            // Recent app match
            if context.recentApps.contains(where: { $0.lowercased() == proc.sourceApp.lowercased() }) {
                score = max(score, 0.6)
                if reason.isEmpty { reason = "Recently used app" }
            }

            // Tag-based matching against window title
            if let title = context.windowTitle?.lowercased() {
                let matchingTags = proc.tags.filter { tag in
                    title.contains(tag.lowercased())
                }
                if !matchingTags.isEmpty {
                    score = max(score, 0.4)
                    if reason.isEmpty { reason = "Tag match: \(matchingTags.joined(separator: ", "))" }
                }
            }

            if score > 0.0 {
                matches.append(ProcedureMatch(
                    procedureId: proc.id,
                    procedureName: proc.name,
                    score: score,
                    matchReason: reason,
                    sourceApp: proc.sourceApp
                ))
            }
        }

        return matches
    }

    // MARK: - LLM Refinement

    /// Refine heuristic matches with LLM semantic reasoning.
    ///
    /// The LLM evaluates whether each candidate procedure is actually useful
    /// in the current context, adjusting scores and adding explanations.
    private static func llmRefine(
        context: ActivityContext,
        candidates: [ProcedureMatch],
        procedures: [ProcedureTemplate],
        generate: LLMGenerateFunction
    ) async throws -> [ProcedureMatch] {
        let procMap = Dictionary(uniqueKeysWithValues: procedures.map { ($0.id, $0) })

        var contextDesc = "Current app: \(context.currentApp)"
        if let title = context.windowTitle { contextDesc += "\nWindow: \(title)" }
        if let url = context.url { contextDesc += "\nURL: \(url)" }
        if !context.recentApps.isEmpty {
            contextDesc += "\nRecent apps: \(context.recentApps.prefix(5).joined(separator: ", "))"
        }

        var procDescs: [String] = []
        for match in candidates.prefix(10) {
            guard let proc = procMap[match.procedureId] else { continue }
            let steps = proc.steps.prefix(3).map { "  - \($0.intent)" }.joined(separator: "\n")
            procDescs.append("""
            [\(proc.id)] \(proc.name): \(proc.description)
            Steps:\n\(steps)
            """)
        }

        let prompt = """
        Given the user's current activity, score each procedure's relevance (0.0-1.0):

        ## Current Activity
        \(contextDesc)

        ## Candidate Procedures
        \(procDescs.joined(separator: "\n\n"))

        Respond with a JSON array:
        [{"id": "proc-id", "score": 0.8, "reason": "why it's relevant"}]

        Score guide:
        - 0.9+: Procedure directly applies to current task
        - 0.7-0.8: Procedure is useful in current app context
        - 0.3-0.6: Loosely related
        - 0.0: Not relevant
        """

        let request = LLMRequest(
            systemPrompt: "Score procedure relevance. Respond with only a JSON array.",
            userPrompt: prompt,
            maxTokens: 1024,
            temperature: 0.2,
            responseFormat: .json
        )

        let response = try await generate(request)
        return parseRefinedScores(response.content, fallback: candidates)
    }

    /// Parse the LLM's refined scores, falling back to original candidates on failure.
    private static func parseRefinedScores(
        _ text: String,
        fallback: [ProcedureMatch]
    ) -> [ProcedureMatch] {
        let jsonStr: String
        if let start = text.range(of: "["), let end = text.range(of: "]", options: .backwards) {
            jsonStr = String(text[start.lowerBound..<end.upperBound])
        } else {
            return fallback
        }

        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return fallback
        }

        let fallbackMap = Dictionary(uniqueKeysWithValues: fallback.map { ($0.procedureId, $0) })

        return array.compactMap { dict -> ProcedureMatch? in
            guard let id = dict["id"] as? String,
                  let score = dict["score"] as? Double,
                  let original = fallbackMap[id] else { return nil }

            let reason = (dict["reason"] as? String) ?? original.matchReason

            return ProcedureMatch(
                procedureId: id,
                procedureName: original.procedureName,
                score: min(max(score, 0.0), 1.0),
                matchReason: reason,
                sourceApp: original.sourceApp
            )
        }
    }
}
