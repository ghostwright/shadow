import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ProcedureSynthesizer")

// MARK: - Procedure Synthesizer

/// Synthesizes a ProcedureTemplate from recorded actions using LLM analysis.
///
/// Takes the raw RecordedActions from LearningRecorder and:
/// 1. Builds natural language descriptions of each step
/// 2. Sends them to the LLM for generalization
/// 3. Extracts parameters (substitutable values)
/// 4. Generates step intents (semantic meaning of each action)
/// 5. Packages everything into a ProcedureTemplate
///
/// Uses Cloud Claude for best generalization quality.
/// Fallback: Qwen 32B local (if available).
///
/// NEVER uses keyword-based classification — all analysis is LLM-powered.
actor ProcedureSynthesizer {

    private let llmProvider: LLMProvider

    init(llmProvider: LLMProvider) {
        self.llmProvider = llmProvider
    }

    // MARK: - Synthesis

    /// Synthesize a ProcedureTemplate from recorded actions.
    func synthesize(_ actions: [RecordedAction]) async throws -> ProcedureTemplate {
        guard !actions.isEmpty else {
            throw ProcedureSynthesisError.emptyRecording
        }

        // Build step descriptions
        let stepDescriptions = actions.enumerated().map { idx, action in
            describeAction(action, index: idx)
        }

        let sourceApp = actions.first?.appName ?? "Unknown"
        let sourceBundleId = actions.first?.appBundleId ?? ""

        // Build the LLM prompt
        let prompt = buildSynthesisPrompt(
            steps: stepDescriptions,
            sourceApp: sourceApp,
            actionCount: actions.count
        )

        // Call the LLM
        let request = LLMRequest(
            systemPrompt: "You are an expert at analyzing user workflows on macOS and extracting reusable procedure templates.",
            userPrompt: prompt,
            maxTokens: 2000,
            temperature: 0.3,
            responseFormat: .json
        )

        let response = try await llmProvider.generate(request: request)

        // Parse LLM response into template
        let template = try buildTemplate(
            from: response.content,
            actions: actions,
            sourceApp: sourceApp,
            sourceBundleId: sourceBundleId
        )

        logger.info("Procedure synthesized: '\(template.name)' with \(template.steps.count) steps and \(template.parameters.count) parameters")
        return template
    }

    // MARK: - Step Description

    /// Build a natural language description of a recorded action.
    private func describeAction(_ action: RecordedAction, index: Int) -> String {
        switch action.actionType {
        case .click(let x, let y, let button, let count):
            let clickDesc = count > 1 ? "\(count)x \(button) click" : "\(button) click"
            if let desc = action.targetDescription {
                return "\(clickDesc) on '\(desc)'"
            }
            return "\(clickDesc) at (\(Int(x)), \(Int(y)))"

        case .typeText(let text):
            let truncated = String(text.prefix(50))
            let suffix = text.count > 50 ? "..." : ""
            return "Typed '\(truncated)\(suffix)'"

        case .keyPress(_, let keyName, let modifiers):
            if modifiers.isEmpty {
                return "Pressed \(keyName)"
            }
            return "Pressed \(modifiers.joined(separator: "+"))+\(keyName)"

        case .appSwitch(let toApp, _):
            return "Switched to \(toApp)"

        case .scroll(let deltaX, let deltaY, _, _):
            let direction: String
            if deltaY > 0 { direction = "up" }
            else if deltaY < 0 { direction = "down" }
            else if deltaX > 0 { direction = "right" }
            else { direction = "left" }
            return "Scrolled \(direction)"
        }
    }

    // MARK: - Prompt Building

    /// Build the LLM prompt for procedure synthesis.
    private func buildSynthesisPrompt(
        steps: [String],
        sourceApp: String,
        actionCount: Int
    ) -> String {
        let numberedSteps = steps.enumerated().map { idx, desc in
            "\(idx + 1). \(desc)"
        }.joined(separator: "\n")

        return """
        You are analyzing a recorded user workflow on macOS.

        Steps performed:
        \(numberedSteps)

        Primary app: \(sourceApp)
        Total actions: \(actionCount)

        Provide a JSON analysis with:
        1. "name": A short name for this procedure (2-5 words)
        2. "description": A one-sentence description of what it accomplishes
        3. "parameters": An array of substitutable values. For each:
           - "name": parameter name (snake_case)
           - "paramType": one of "string", "number", "date", "email", "url"
           - "description": what this parameter represents
           - "stepIndices": which step numbers (0-indexed) use this parameter
           - "defaultValue": the value used in the recording (if detectable)
        4. "stepIntents": An array of strings, one per step, describing the semantic intent
        5. "tags": An array of 2-5 tags for discovering this procedure later

        Respond ONLY with valid JSON, no markdown code blocks:
        {
          "name": "...",
          "description": "...",
          "parameters": [...],
          "stepIntents": [...],
          "tags": [...]
        }
        """
    }

    // MARK: - Template Building

    /// Parse LLM response and build a ProcedureTemplate.
    private func buildTemplate(
        from llmContent: String,
        actions: [RecordedAction],
        sourceApp: String,
        sourceBundleId: String
    ) throws -> ProcedureTemplate {
        // Extract JSON from response (handle potential markdown wrapping)
        let jsonString = extractJSON(from: llmContent)

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProcedureSynthesisError.invalidLLMResponse(llmContent)
        }

        let name = json["name"] as? String ?? "Unnamed Procedure"
        let description = json["description"] as? String ?? ""
        let tags = json["tags"] as? [String] ?? []
        let stepIntents = json["stepIntents"] as? [String] ?? []

        // Parse parameters
        var parameters: [ProcedureParameter] = []
        if let paramsRaw = json["parameters"] as? [[String: Any]] {
            for param in paramsRaw {
                parameters.append(ProcedureParameter(
                    name: param["name"] as? String ?? "unnamed",
                    paramType: param["paramType"] as? String ?? "string",
                    description: param["description"] as? String ?? "",
                    stepIndices: (param["stepIndices"] as? [Int]) ?? [],
                    defaultValue: param["defaultValue"] as? String
                ))
            }
        }

        // Build steps
        let now = CaptureSessionClock.wallMicros()
        var steps: [ProcedureStep] = []
        for (idx, action) in actions.enumerated() {
            let intent = idx < stepIntents.count ? stepIntents[idx] : describeAction(action, index: idx)

            // Build parameter substitutions for this step
            var substitutions: [String: String] = [:]
            for param in parameters {
                if param.stepIndices.contains(idx), let defaultVal = param.defaultValue {
                    substitutions[param.name] = defaultVal
                }
            }

            steps.append(ProcedureStep(
                index: idx,
                intent: intent,
                actionType: action.actionType,
                targetLocator: action.targetLocator,
                targetDescription: action.targetDescription,
                parameterSubstitutions: substitutions,
                expectedPostCondition: nil,
                maxRetries: 2,
                timeoutSeconds: 5.0
            ))
        }

        return ProcedureTemplate(
            id: UUID().uuidString,
            name: name,
            description: description,
            parameters: parameters,
            steps: steps,
            createdAt: now,
            updatedAt: now,
            sourceApp: sourceApp,
            sourceBundleId: sourceBundleId,
            tags: tags,
            executionCount: 0,
            lastExecutedAt: nil
        )
    }

    /// Extract JSON from a string, handling potential markdown code block wrapping.
    private func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown JSON code blocks if present
        if trimmed.hasPrefix("```json"), let endIdx = trimmed.range(of: "```", range: trimmed.index(trimmed.startIndex, offsetBy: 7)..<trimmed.endIndex) {
            return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)..<endIdx.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.hasPrefix("```"), let endIdx = trimmed.range(of: "```", range: trimmed.index(trimmed.startIndex, offsetBy: 3)..<trimmed.endIndex) {
            return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<endIdx.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Find first { and last } for JSON extraction
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}") {
            return String(trimmed[firstBrace...lastBrace])
        }

        return trimmed
    }
}

// MARK: - Synthesis Errors

enum ProcedureSynthesisError: Error, LocalizedError {
    case emptyRecording
    case invalidLLMResponse(String)
    case synthesisTimeout

    var errorDescription: String? {
        switch self {
        case .emptyRecording: "No actions to synthesize"
        case .invalidLLMResponse(let r): "Could not parse LLM response: \(r.prefix(200))"
        case .synthesisTimeout: "Procedure synthesis timed out"
        }
    }
}
