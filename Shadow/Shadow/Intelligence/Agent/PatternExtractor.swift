import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "PatternExtractor")

/// Extracts generalized patterns from successful agent runs.
///
/// After a successful run with 3+ AX tool calls, the extractor:
/// 1. Serializes the tool call log into a compact format
/// 2. Calls Haiku to generalize the pattern (replace specific values with placeholders)
/// 3. Saves the pattern to the PatternStore
///
/// Extraction is async and non-blocking -- it happens after the run completes,
/// not in the critical path. If extraction fails, it's silently logged.
enum PatternExtractor {

    /// Minimum number of AX tool calls required to trigger extraction.
    /// Runs with fewer AX calls are pure-search/memory queries -- not worth extracting.
    static let minAXToolCalls = 3

    /// Maximum tool calls to include in the extraction prompt (avoid token overflow).
    static let maxToolCallsForExtraction = 30

    /// Check if a run is eligible for pattern extraction.
    static func isEligible(_ result: AgentRunResult) -> Bool {
        let axToolCalls = result.toolCalls.filter { $0.toolName.hasPrefix("ax_") || $0.toolName == "capture_live_screenshot" }
        return axToolCalls.count >= minAXToolCalls
    }

    /// Extract a pattern from a successful agent run.
    ///
    /// Calls the LLM orchestrator with Haiku to generalize the tool call sequence.
    /// Returns nil if extraction fails or the LLM returns unparseable output.
    ///
    /// - Parameters:
    ///   - task: The original user query
    ///   - result: The successful run result
    ///   - orchestrator: LLM orchestrator (will use the cheapest available model)
    /// - Returns: An `AgentPattern` ready to be saved, or nil
    static func extract(
        task: String,
        result: AgentRunResult,
        orchestrator: LLMOrchestrator
    ) async -> AgentPattern? {
        let toolLog = formatToolLog(result.toolCalls)

        let prompt = """
        Analyze this successful agent tool call sequence and extract a REUSABLE pattern.

        Original task: \(task)

        Tool call log:
        \(toolLog)

        Extract a generalized pattern in this EXACT JSON format (no markdown, no code fences):
        {
          "taskDescription": "<2-5 word generalized task, e.g. 'Add item to Amazon cart'>",
          "targetApp": "<primary app name, e.g. 'Google Chrome'>",
          "urlPattern": "<URL regex pattern if web-based, e.g. 'amazon\\\\.com', or null>",
          "steps": [
            {
              "toolName": "<tool name>",
              "purpose": "<what this step does>",
              "keyArguments": {"<arg>": "<value or {{PLACEHOLDER}}>"},
              "expectedOutcome": "<what should happen after>"
            }
          ],
          "notes": ["<1-3 lessons learned, tips, or gotchas from this run>"]
        }

        Rules:
        - Replace specific user values with {{PLACEHOLDER}} names (e.g., {{QUERY}}, {{EMAIL}}, {{URL}})
        - Keep app-specific selectors exact (button names, menu items) -- those are stable
        - Combine redundant steps (e.g., multiple tree queries into one step)
        - Include only the ESSENTIAL steps, not every single tool call
        - Notes should capture WHY something worked or failed, not WHAT happened
        """

        do {
            let request = LLMRequest(
                systemPrompt: "You are a pattern extraction engine. Output ONLY valid JSON, no explanation.",
                userPrompt: prompt,
                tools: [],
                maxTokens: 1024,
                temperature: 0.1,
                responseFormat: .text
            )

            let response = try await orchestrator.generate(request: request)
            return parsePatternResponse(response.content, task: task)
        } catch {
            logger.warning("Pattern extraction LLM call failed: \(error, privacy: .public)")
            DiagnosticsStore.shared.increment("pattern_extraction_fail_total")
            return nil
        }
    }

    /// Extract a pattern without calling the LLM. Uses heuristics instead.
    /// This is the fallback when no LLM is available or for simpler runs.
    static func extractHeuristic(
        task: String,
        result: AgentRunResult
    ) -> AgentPattern? {
        let toolCalls = result.toolCalls
        guard toolCalls.count >= minAXToolCalls else { return nil }

        // Determine target app from ax_focus_app calls
        let focusCalls = toolCalls.filter { $0.toolName == "ax_focus_app" }
        let targetApp = focusCalls.first?.arguments["app"]?.stringValue ?? "Unknown"

        // Build step sequence from tool calls (compact: skip duplicate queries)
        var steps: [PatternStep] = []
        var lastTool = ""

        for call in toolCalls {
            // Skip consecutive duplicate tool calls (e.g., multiple ax_tree_query)
            if call.toolName == lastTool && call.toolName == "ax_tree_query" {
                continue
            }
            lastTool = call.toolName

            var keyArgs: [String: String] = [:]
            for (k, v) in call.arguments {
                if let s = v.stringValue {
                    keyArgs[k] = s
                }
            }

            steps.append(PatternStep(
                toolName: call.toolName,
                purpose: call.success ? "Succeeded" : "Failed",
                keyArguments: keyArgs,
                expectedOutcome: nil
            ))

            // Cap at reasonable length
            if steps.count >= 15 { break }
        }

        let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        return AgentPattern(
            id: UUID().uuidString,
            taskDescription: String(task.prefix(60)),
            targetApp: targetApp,
            urlPattern: nil,
            toolSequence: steps,
            notes: [],
            successCount: 1,
            failureCount: 0,
            createdAt: nowUs,
            lastUsedAt: nowUs,
            archived: false
        )
    }

    // MARK: - Helpers

    /// Format tool calls into a compact log for the extraction prompt.
    private static func formatToolLog(_ toolCalls: [AgentToolCallRecord]) -> String {
        let capped = Array(toolCalls.prefix(maxToolCallsForExtraction))
        return capped.enumerated().map { i, call in
            let args = call.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            let status = call.success ? "OK" : "FAIL"
            let outputPreview = String(call.output.prefix(200))
            return "\(i + 1). \(call.toolName)(\(args)) -> [\(status), \(Int(call.durationMs))ms] \(outputPreview)"
        }.joined(separator: "\n")
    }

    /// Parse the LLM response JSON into an AgentPattern.
    private static func parsePatternResponse(_ content: String, task: String) -> AgentPattern? {
        // Extract JSON from the response (handle potential markdown fences)
        let jsonStr: String
        if let start = content.range(of: "{"),
           let end = content.range(of: "}", options: .backwards) {
            jsonStr = String(content[start.lowerBound...end.upperBound])
        } else {
            logger.warning("Pattern extraction: no JSON found in response")
            return nil
        }

        guard let data = jsonStr.data(using: .utf8) else { return nil }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let json else {
                logger.warning("Pattern extraction: response is not a JSON object")
                return nil
            }

            let taskDesc = json["taskDescription"] as? String ?? String(task.prefix(60))
            let targetApp = json["targetApp"] as? String ?? "Unknown"
            let urlPattern = json["urlPattern"] as? String

            var steps: [PatternStep] = []
            if let stepsArray = json["steps"] as? [[String: Any]] {
                for stepDict in stepsArray {
                    let toolName = stepDict["toolName"] as? String ?? ""
                    let purpose = stepDict["purpose"] as? String ?? ""
                    let keyArgs = stepDict["keyArguments"] as? [String: String] ?? [:]
                    let expectedOutcome = stepDict["expectedOutcome"] as? String

                    steps.append(PatternStep(
                        toolName: toolName,
                        purpose: purpose,
                        keyArguments: keyArgs,
                        expectedOutcome: expectedOutcome
                    ))
                }
            }

            let notes = json["notes"] as? [String] ?? []

            let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            let pattern = AgentPattern(
                id: UUID().uuidString,
                taskDescription: taskDesc,
                targetApp: targetApp,
                urlPattern: urlPattern,
                toolSequence: steps,
                notes: notes,
                successCount: 1,
                failureCount: 0,
                createdAt: nowUs,
                lastUsedAt: nowUs,
                archived: false
            )

            DiagnosticsStore.shared.increment("pattern_extraction_success_total")
            logger.info("Extracted pattern: '\(taskDesc)' for '\(targetApp)' with \(steps.count) steps")
            return pattern
        } catch {
            logger.warning("Pattern extraction JSON parse failed: \(error, privacy: .public)")
            return nil
        }
    }
}
