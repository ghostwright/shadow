import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "IntentClassifier")

/// Classifies user intent to determine the appropriate agent routing.
///
/// Fast routing strategy:
/// 1. When cloud is available: uses Haiku (`claude-haiku-4-5-20251001`) for ~200ms classification.
///    This is hardcoded — the user's selected model (e.g. Sonnet) is only used for actual work.
/// 2. When cloud is unavailable: falls back to keyword heuristic (instant, zero API cost).
/// 3. Injectable classifyFn for testing bypasses both paths.
enum IntentClassifier {

    // MARK: - Intent Types

    /// Classified user intent, determining orchestrator routing.
    enum UserIntent: String, Sendable, CaseIterable, Codable {
        /// Simple factual question about the user's history.
        case simpleQuestion
        /// Search across memories, transcripts, app history.
        case memorySearch
        /// Replay a previously learned procedure.
        case procedureReplay
        /// Start a new procedure learning session.
        case procedureLearning
        /// Complex multi-step reasoning or analysis.
        case complexReasoning
        /// Create or modify a directive.
        case directiveCreation
        /// UI action request — click, type, navigate, interact with an app.
        case uiAction
        /// Unable to classify — prompt user for clarification.
        case ambiguous
    }

    /// Result of intent classification with metadata.
    struct ClassificationResult: Sendable, Equatable {
        /// The classified intent.
        let intent: UserIntent
        /// Confidence score (0.0 - 1.0). LLM classifications report model confidence;
        /// heuristic classifications use fixed scores.
        let confidence: Double
        /// Which classification method was used.
        let method: ClassificationMethod
    }

    /// How the intent was classified.
    enum ClassificationMethod: String, Sendable, Equatable {
        /// Classified by an LLM provider (Haiku for routing).
        case llm
        /// Classified by keyword heuristic (fallback).
        case heuristic
        /// Default when no classification could be made.
        case defaultFallback
    }

    // MARK: - Routing Model

    /// Hardcoded Haiku model for fast intent classification.
    /// Haiku is ~10x faster and ~20x cheaper than Sonnet. Classification needs speed, not depth.
    static let routingModelId = "claude-haiku-4-5-20251001"

    // MARK: - Classification

    /// Classify user intent using fast Haiku routing with heuristic fallback.
    ///
    /// Strategy:
    /// 1. If `classifyFn` is provided (testing): use it directly.
    /// 2. If orchestrator has cloud available: use Haiku via `modelOverride` for ~200ms classification.
    /// 3. Otherwise: instant keyword heuristic (zero latency).
    ///
    /// - Parameters:
    ///   - query: The user's natural language input.
    ///   - orchestrator: LLM orchestrator for model routing.
    ///   - classifyFn: Injectable LLM function for testing. When nil, uses orchestrator with Haiku.
    /// - Returns: ClassificationResult with intent, confidence, and method.
    static func classify(
        query: String,
        orchestrator: LLMOrchestrator? = nil,
        classifyFn: (@Sendable (String) async throws -> String)? = nil
    ) async -> ClassificationResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Path 1: Injectable classifier (testing)
        if let classifyFn {
            if let result = await classifyViaLLM(query: query, classifyFn: classifyFn) {
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                logger.info("Intent classified via LLM: \(result.intent.rawValue) (\(String(format: "%.0f", elapsed))ms)")
                DiagnosticsStore.shared.increment("intent_classify_llm_total")
                return result
            }
        }

        // Path 2: Fast Haiku classification via orchestrator
        if classifyFn == nil, let orchestrator {
            let fn: @Sendable (String) async throws -> String = { prompt in
                let request = LLMRequest(
                    systemPrompt: classificationSystemPrompt,
                    userPrompt: prompt,
                    maxTokens: 64,
                    temperature: 0.0,
                    responseFormat: .text,
                    modelOverride: routingModelId
                )
                let response = try await orchestrator.generate(request: request)
                return response.content
            }
            if let result = await classifyViaLLM(query: query, classifyFn: fn) {
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                logger.info("Intent classified via Haiku: \(result.intent.rawValue) (\(String(format: "%.0f", elapsed))ms)")
                DiagnosticsStore.shared.increment("intent_classify_llm_total")
                DiagnosticsStore.shared.recordLatency("intent_classify_haiku_ms", ms: elapsed)
                return result
            }
        }

        // Path 3: Instant heuristic fallback (no API call, zero latency)
        let result = classifyViaHeuristic(query: query)
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.info("Intent classified via heuristic: \(result.intent.rawValue) (\(String(format: "%.0f", elapsed))ms)")
        DiagnosticsStore.shared.increment("intent_classify_heuristic_total")
        return result
    }

    // MARK: - LLM Classification

    /// System prompt for intent classification. Designed for Haiku — fast, minimal tokens.
    static let classificationSystemPrompt = """
        Classify the user's request into exactly one category. \
        Respond with ONLY the category name, nothing else.

        Categories:
        - simpleQuestion: Factual questions about history — what the user did, when, which app, what time, what's on screen
        - memorySearch: Searching for specific content, text, conversations, visual memories, "find", "show me when"
        - procedureReplay: Perform a multi-step task — "do X for me", "file my expense report", "send the email"
        - procedureLearning: Learn/record a new procedure — "watch me", "learn how I do this", "teach you"
        - complexReasoning: Analysis, comparison, summarization of patterns — "analyze my week", "time allocation"
        - directiveCreation: Create rules/reminders/triggers — "if X happens do Y", "remind me when", "alert me"
        - uiAction: Direct UI interaction — "click", "open", "type", "scroll", "press", "switch to", "navigate to"
        - ambiguous: Cannot determine intent
        """

    /// Attempt LLM-based classification.
    private static func classifyViaLLM(
        query: String,
        classifyFn: @Sendable (String) async throws -> String
    ) async -> ClassificationResult? {
        do {
            let response = try await classifyFn(query)
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            // Parse the raw intent string
            if let intent = parseIntentString(trimmed) {
                return ClassificationResult(
                    intent: intent,
                    confidence: 0.85,
                    method: .llm
                )
            }

            // LLM returned something unparseable
            logger.warning("LLM returned unparseable intent: \(trimmed)")
            return nil
        } catch {
            logger.warning("LLM intent classification failed: \(error, privacy: .public)")
            return nil
        }
    }

    /// Parse an intent string (case-insensitive, with flexible matching).
    ///
    /// Only performs partial matching on short strings (under 40 chars) to avoid
    /// false positives when the LLM returns prose instead of a category name.
    static func parseIntentString(_ raw: String) -> UserIntent? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")

        // Direct match (works on any length)
        for intent in UserIntent.allCases {
            if cleaned == intent.rawValue.lowercased() {
                return intent
            }
        }

        // Partial match — only for short responses that look like category output,
        // not for prose responses where keywords appear incidentally.
        guard cleaned.count < 40 else { return nil }

        if cleaned.contains("simplequestion") || cleaned.contains("question") { return .simpleQuestion }
        if cleaned.contains("memorysearch") || cleaned.contains("search") { return .memorySearch }
        if cleaned.contains("procedurereplay") || cleaned.contains("replay") { return .procedureReplay }
        if cleaned.contains("procedurelearning") || cleaned.contains("learning") { return .procedureLearning }
        if cleaned.contains("complexreasoning") || cleaned.contains("reasoning") { return .complexReasoning }
        if cleaned.contains("directivecreation") || cleaned.contains("directive") { return .directiveCreation }
        if cleaned.contains("uiaction") || cleaned.contains("action") { return .uiAction }
        if cleaned.contains("ambiguous") { return .ambiguous }

        return nil
    }

    // MARK: - Heuristic Classification

    /// Keyword-based classification fallback.
    /// Ordered by specificity: most specific patterns first, broadest last.
    static func classifyViaHeuristic(query: String) -> ClassificationResult {
        let lower = query.lowercased()

        // Directive creation patterns
        let directiveKeywords = ["remind me", "if i open", "when i open", "when i switch",
                                  "if .* happens", "whenever", "every time i", "alert me",
                                  "notify me when", "set a rule"]
        for keyword in directiveKeywords {
            if lower.contains(keyword) || lower.range(of: keyword, options: .regularExpression) != nil {
                return ClassificationResult(intent: .directiveCreation, confidence: 0.7, method: .heuristic)
            }
        }

        // Procedure learning patterns
        let learningKeywords = ["watch me", "learn how", "record this", "teach you",
                                 "let me show", "observe how", "learn this procedure"]
        for keyword in learningKeywords {
            if lower.contains(keyword) {
                return ClassificationResult(intent: .procedureLearning, confidence: 0.75, method: .heuristic)
            }
        }

        // Procedure replay patterns
        let replayKeywords = ["do this for me", "file my", "submit my", "send the",
                               "run the procedure", "replay", "automate", "execute the"]
        for keyword in replayKeywords {
            if lower.contains(keyword) {
                return ClassificationResult(intent: .procedureReplay, confidence: 0.7, method: .heuristic)
            }
        }

        // UI action patterns — direct interaction with screen elements
        let uiActionKeywords = ["click on", "click the", "type in", "type into", "press the",
                                 "scroll down", "scroll up", "open the app", "switch to",
                                 "navigate to", "go to the", "go to ", "close the", "minimize",
                                 "maximize", "focus on"]
        // Also match "open X" at the start of the query (e.g., "open Chrome", "open gmail.com")
        if lower.hasPrefix("open ") {
            return ClassificationResult(intent: .uiAction, confidence: 0.7, method: .heuristic)
        }
        for keyword in uiActionKeywords {
            if lower.contains(keyword) {
                return ClassificationResult(intent: .uiAction, confidence: 0.7, method: .heuristic)
            }
        }

        // Complex reasoning patterns
        let complexKeywords = ["analyze", "compare", "pattern", "trend", "breakdown",
                                "how much time", "time allocation", "productivity", "summarize my week"]
        for keyword in complexKeywords {
            if lower.contains(keyword) {
                return ClassificationResult(intent: .complexReasoning, confidence: 0.65, method: .heuristic)
            }
        }

        // Memory search patterns
        let searchKeywords = ["find", "search", "where did", "look for",
                               "show me when", "any mention of", "did i see"]
        for keyword in searchKeywords {
            if lower.contains(keyword) {
                return ClassificationResult(intent: .memorySearch, confidence: 0.6, method: .heuristic)
            }
        }

        // Simple question patterns (broad — catches most remaining queries)
        let questionKeywords = ["what was", "what did", "when did", "who said", "what app",
                                 "what time", "how long", "what's on my screen", "what am i",
                                 "what happened", "tell me about", "summarize"]
        for keyword in questionKeywords {
            if lower.contains(keyword) {
                return ClassificationResult(intent: .simpleQuestion, confidence: 0.55, method: .heuristic)
            }
        }

        // Default: simple question for short queries, ambiguous for longer ones
        if query.count <= 40 {
            return ClassificationResult(intent: .simpleQuestion, confidence: 0.4, method: .heuristic)
        }

        return ClassificationResult(intent: .ambiguous, confidence: 0.3, method: .defaultFallback)
    }
}
