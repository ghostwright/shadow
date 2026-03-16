import Foundation

/// Builds LLM prompts for meeting summarization.
///
/// Handles two modes:
/// - **Single-pass**: transcript fits within context window → one request
/// - **Map-reduce**: transcript exceeds context → chunk into partial summaries, then merge
enum SummaryPromptBuilder {

    /// Estimated characters per token (conservative for English + mixed content).
    private static let charsPerToken = 4

    /// Maximum tokens to reserve for input (leave room for system prompt + output).
    /// Target models: Qwen2.5-7B (~8k context) and Claude Haiku (~200k context).
    /// Use the local model's limit as the threshold for map-reduce.
    private static let maxSinglePassInputTokens = 5000

    /// Maximum tokens per map chunk.
    private static let mapChunkTokens = 3000

    // MARK: - Public API

    /// Build an LLM request for summarizing a meeting transcript.
    /// Returns a single request for short transcripts, or a map-reduce plan for long ones.
    static func buildRequest(
        transcript: String,
        sourceWindow: SourceWindow
    ) -> SummaryRequestPlan {
        let estimatedTokens = transcript.count / charsPerToken

        if estimatedTokens <= maxSinglePassInputTokens {
            let request = LLMRequest(
                systemPrompt: systemPrompt,
                userPrompt: singlePassUserPrompt(transcript: transcript, window: sourceWindow),
                tools: [],
                maxTokens: 2048,
                temperature: 0.3,
                responseFormat: .json
            )
            return .singlePass(request)
        } else {
            return buildMapReducePlan(transcript: transcript, sourceWindow: sourceWindow)
        }
    }

    // MARK: - Prompts

    private static let systemPrompt = """
    You are a meeting summarization assistant. Given a transcript, produce a structured JSON summary.

    Output ONLY valid JSON matching this exact schema (no markdown, no explanation, no code fences):

    {
      "title": "Short meeting title (max 200 chars)",
      "summary": "2-4 sentence overview of the meeting",
      "keyPoints": ["Key topic 1", "Key topic 2"],
      "decisions": ["Decision made 1"],
      "actionItems": [
        {
          "description": "What needs to be done",
          "owner": "Person responsible or null",
          "dueDateText": "By when or null",
          "evidenceTimestamps": [1708300000000000]
        }
      ],
      "openQuestions": ["Unresolved question 1"],
      "highlights": [
        {
          "text": "Notable moment description",
          "tsStart": 1708300000000000,
          "tsEnd": 1708300060000000
        }
      ]
    }

    Timestamps in the transcript:
    Each line has the format: [HH:MM:SS @<absolute_us>] (source) text
    The @<absolute_us> value is the absolute Unix microsecond timestamp for that line.
    Use these absolute values for tsStart, tsEnd in highlights and evidenceTimestamps in actionItems.

    Rules:
    - keyPoints must have at least 1 item
    - title max 200 characters
    - summary max 2000 characters
    - All timestamps in the output must be absolute Unix microseconds (the @-prefixed values from the transcript)
    - If no decisions/actionItems/openQuestions, use empty arrays
    - Do NOT include any text outside the JSON object
    """

    private static func singlePassUserPrompt(transcript: String, window: SourceWindow) -> String {
        let startDate = Date(timeIntervalSince1970: Double(window.startUs) / 1_000_000)
        let endDate = Date(timeIntervalSince1970: Double(window.endUs) / 1_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: window.timezone) ?? .current

        return """
        Meeting window: \(formatter.string(from: startDate)) to \(formatter.string(from: endDate))

        Transcript:
        \(transcript)
        """
    }

    // MARK: - Map-Reduce

    private static func buildMapReducePlan(
        transcript: String,
        sourceWindow: SourceWindow
    ) -> SummaryRequestPlan {
        let chunkSize = mapChunkTokens * charsPerToken
        let chunks = chunkTranscript(transcript, maxChars: chunkSize)

        let mapRequests = chunks.map { chunk in
            LLMRequest(
                systemPrompt: mapSystemPrompt,
                userPrompt: chunk,
                tools: [],
                maxTokens: 1024,
                temperature: 0.3,
                responseFormat: .json
            )
        }

        return .mapReduce(
            mapRequests: mapRequests,
            reduceBuilder: { partialSummaries in
                let mergedInput = partialSummaries.enumerated()
                    .map { "--- Partial Summary \($0.offset + 1) ---\n\($0.element)" }
                    .joined(separator: "\n\n")

                return LLMRequest(
                    systemPrompt: systemPrompt,
                    userPrompt: reduceUserPrompt(
                        partials: mergedInput,
                        window: sourceWindow
                    ),
                    tools: [],
                    maxTokens: 2048,
                    temperature: 0.3,
                    responseFormat: .json
                )
            }
        )
    }

    private static let mapSystemPrompt = """
    You are analyzing a portion of a meeting transcript. Produce a JSON object with these fields:
    {
      "keyPoints": ["..."],
      "decisions": ["..."],
      "actionItems": ["..."],
      "openQuestions": ["..."],
      "highlights": ["notable quotes or moments"]
    }
    Output ONLY valid JSON. No markdown, no explanation.
    """

    private static func reduceUserPrompt(partials: String, window: SourceWindow) -> String {
        return """
        Below are partial summaries from different segments of the same meeting. \
        Merge them into a single coherent meeting summary.

        \(partials)
        """
    }

    // MARK: - Chunking

    /// Split transcript into chunks at line boundaries, respecting max character count.
    private static func chunkTranscript(_ text: String, maxChars: Int) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var chunks: [String] = []
        var current = ""

        for line in lines {
            if current.count + line.count + 1 > maxChars && !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            if !current.isEmpty { current += "\n" }
            current += line
        }
        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }
}

// MARK: - Summary Request Plan

/// Either a single-pass request or a map-reduce plan for long transcripts.
enum SummaryRequestPlan: Sendable {
    /// Transcript fits in one request.
    case singlePass(LLMRequest)
    /// Transcript split into map requests, with a reduce builder that takes partial outputs.
    case mapReduce(
        mapRequests: [LLMRequest],
        reduceBuilder: @Sendable ([String]) -> LLMRequest
    )
}
