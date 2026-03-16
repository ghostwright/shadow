import Foundation
import CryptoKit
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ContextSynthesizer")

/// Injectable LLM generate function matching LLMOrchestrator.generate() signature.
typealias LLMGenerateFunction = @Sendable (LLMRequest) async throws -> LLMResponse

/// Stateless synthesizer that assembles raw captured data into context records via LLM.
///
/// Follows MeetingInputAssembler/SummaryPromptBuilder pattern:
/// - Fetches raw data from UniFFI queries
/// - Builds structured prompts with JSON schema instructions
/// - Parses LLM output into typed records
/// - Computes input hash for dedup
enum ContextSynthesizer {

    /// Characters per token estimate (conservative).
    private static let charsPerToken = 4

    /// Page size for transcript chunk pagination.
    private static let transcriptPageSize: UInt32 = 500

    /// Maximum transcript chunks to collect before truncation.
    static let maxTranscriptChunks: Int = 2000

    /// Maximum transcript pages to fetch (safety bound on pagination loop).
    private static let maxTranscriptPages: Int = 10

    // MARK: - Episode Synthesis

    /// Synthesize an episode record from raw captured data in a time range.
    ///
    /// 1. Fetches timeline events via `queryTimeRange`
    /// 2. Fetches transcript chunks via `listTranscriptChunksInRange` (paginated)
    /// 3. Builds formatted context with `[HH:MM:SS @<us>]` timestamps
    /// 4. Calls LLM with JSON schema prompt
    /// 5. Parses response into EpisodeRecord
    static func synthesizeEpisode(
        startUs: UInt64,
        endUs: UInt64,
        generate: LLMGenerateFunction,
        queryTimeRangeFn: ((UInt64, UInt64) throws -> [TimelineEntry])? = nil,
        listTranscriptsFn: ((UInt64, UInt64, UInt32, UInt32) throws -> [TranscriptChunkResult])? = nil
    ) async throws -> EpisodeRecord {
        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. Fetch timeline events
        let events: [TimelineEntry]
        if let fn = queryTimeRangeFn {
            events = try fn(startUs, endUs)
        } else {
            events = try queryTimeRange(startUs: startUs, endUs: endUs)
        }

        // 2. Fetch transcript chunks (paginated, bounded)
        var allChunks: [TranscriptChunkResult] = []
        var offset: UInt32 = 0
        var pagesRead = 0
        while pagesRead < maxTranscriptPages && allChunks.count < maxTranscriptChunks {
            let page: [TranscriptChunkResult]
            if let fn = listTranscriptsFn {
                page = try fn(startUs, endUs, transcriptPageSize, offset)
            } else {
                page = try listTranscriptChunksInRange(
                    startUs: startUs,
                    endUs: endUs,
                    limit: transcriptPageSize,
                    offset: offset
                )
            }
            if page.isEmpty { break }
            allChunks.append(contentsOf: page)
            pagesRead += 1
            if page.count < Int(transcriptPageSize) { break }
            offset += transcriptPageSize
        }

        let truncatedTranscripts = allChunks.count >= maxTranscriptChunks || pagesRead >= maxTranscriptPages
        if truncatedTranscripts {
            allChunks = Array(allChunks.prefix(maxTranscriptChunks))
            logger.info("Transcript input truncated: \(allChunks.count) chunks, \(pagesRead) pages")
            DiagnosticsStore.shared.increment("context_transcript_truncated_total")
        }

        // 3. Build formatted context
        let context = formatEpisodeContext(events: events, chunks: allChunks, startUs: startUs)
        let inputHash = computeHash(context)

        // 4. Build LLM request
        let request = LLMRequest(
            systemPrompt: episodeSystemPrompt,
            userPrompt: """
            Time window: \(formatTimestamp(startUs)) to \(formatTimestamp(endUs))

            Activity context:
            \(context)
            """,
            tools: [],
            maxTokens: 1024,
            temperature: 0.3,
            responseFormat: .json
        )

        // 5. Call LLM and parse
        let response = try await generate(request)
        let episode = try parseEpisodeResponse(
            response,
            startUs: startUs,
            endUs: endUs,
            inputHash: inputHash
        )

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.info("Episode synthesized in \(Int(elapsed))ms: \(episode.topicTags.joined(separator: ", "))")
        DiagnosticsStore.shared.recordLatency("context_synthesis_ms", ms: elapsed)

        return episode
    }

    // MARK: - Daily Synthesis

    /// Synthesize a daily record from episodes and activity data.
    ///
    /// 1. Fetches day summary via `getDaySummary`
    /// 2. Loads today's episodes from ContextStore
    /// 3. Loads transcript highlights
    /// 4. Builds prompt from episodes + activity
    /// 5. Parses response into DailyRecord
    static func synthesizeDaily(
        date: String,
        episodes: [EpisodeRecord],
        generate: LLMGenerateFunction,
        getActivityBlocksFn: ((String) throws -> [ActivityBlock])? = nil
    ) async throws -> DailyRecord {
        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. Fetch day summary (array of activity blocks)
        let activityBlocks: [ActivityBlock]
        if let fn = getActivityBlocksFn {
            activityBlocks = try fn(date)
        } else {
            activityBlocks = try getDaySummary(dateStr: date)
        }

        // 2. Build context from episodes + activity blocks
        let context = formatDailyContext(date: date, activityBlocks: activityBlocks, episodes: episodes)
        let inputHash = computeHash(context)

        // 3. Build LLM request
        let request = LLMRequest(
            systemPrompt: dailySystemPrompt,
            userPrompt: """
            Date: \(date)

            \(context)
            """,
            tools: [],
            maxTokens: 2048,
            temperature: 0.3,
            responseFormat: .json
        )

        // 4. Call LLM and parse
        let response = try await generate(request)
        let daily = try parseDailyResponse(response, date: date, inputHash: inputHash)

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.info("Daily record synthesized for \(date) in \(Int(elapsed))ms")
        DiagnosticsStore.shared.recordLatency("context_synthesis_ms", ms: elapsed)

        return daily
    }

    // MARK: - Context Formatting

    /// Format timeline events and transcript chunks into a structured context string.
    static func formatEpisodeContext(
        events: [TimelineEntry],
        chunks: [TranscriptChunkResult],
        startUs: UInt64
    ) -> String {
        var lines: [String] = []

        // Timeline events
        if !events.isEmpty {
            lines.append("--- Timeline Events ---")
            for event in events.prefix(200) {
                let ts = formatRelativeTimestamp(event.ts, base: startUs)
                let app = event.appName ?? "unknown"
                let title = event.windowTitle ?? ""
                lines.append("[\(ts) @\(event.ts)] \(app): \(title)")
            }
        }

        // Transcript chunks
        if !chunks.isEmpty {
            lines.append("")
            lines.append("--- Transcript ---")
            for chunk in chunks {
                let ts = formatRelativeTimestamp(chunk.tsStart, base: startUs)
                let source = chunk.audioSource.isEmpty ? "unknown" : chunk.audioSource
                let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lines.append("[\(ts) @\(chunk.tsStart)] (\(source)) \(text)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Format daily context from activity blocks and episodes.
    static func formatDailyContext(
        date: String,
        activityBlocks: [ActivityBlock],
        episodes: [EpisodeRecord]
    ) -> String {
        var lines: [String] = []

        // Activity blocks summary
        lines.append("--- Day Activity ---")
        let totalEvents = activityBlocks.reduce(0) { $0 + $1.eventCount }
        let uniqueApps = Set(activityBlocks.map(\.appName))
        lines.append("Total events: \(totalEvents)")
        lines.append("Active apps: \(uniqueApps.sorted().joined(separator: ", "))")
        lines.append("Activity blocks: \(activityBlocks.count)")
        for block in activityBlocks.prefix(20) {
            let durationMin = Int((block.endTs - block.startTs) / 60_000_000)
            lines.append("  \(block.appName): \(durationMin)min (\(block.eventCount) events)")
        }

        // Episodes
        if !episodes.isEmpty {
            lines.append("")
            lines.append("--- Episodes (\(episodes.count)) ---")
            for (i, ep) in episodes.enumerated() {
                lines.append("\(i + 1). [\(formatTimestamp(ep.startUs)) - \(formatTimestamp(ep.endUs))]")
                lines.append("   Summary: \(ep.summary)")
                lines.append("   Topics: \(ep.topicTags.joined(separator: ", "))")
                lines.append("   Apps: \(ep.apps.joined(separator: ", "))")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Response Parsing

    /// Parse LLM JSON response into an EpisodeRecord.
    static func parseEpisodeResponse(
        _ response: LLMResponse,
        startUs: UInt64,
        endUs: UInt64,
        inputHash: String
    ) throws -> EpisodeRecord {
        let content = cleanJSONContent(response.content)
        guard let data = content.data(using: .utf8) else {
            throw LLMProviderError.malformedOutput(detail: "Non-UTF8 response")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let json else {
            throw LLMProviderError.malformedOutput(detail: "Response is not a JSON object")
        }

        let summary = json["summary"] as? String ?? ""
        let topicTags = json["topicTags"] as? [String] ?? []
        let apps = json["apps"] as? [String] ?? []
        let keyArtifacts = json["keyArtifacts"] as? [String] ?? []

        // Parse evidence
        let evidenceArray = json["evidence"] as? [[String: Any]] ?? []
        let evidence: [ContextEvidence] = evidenceArray.compactMap { parseEvidence($0) }

        guard !summary.isEmpty else {
            throw LLMProviderError.malformedOutput(detail: "Episode summary is empty")
        }

        return EpisodeRecord(
            id: UUID(),
            startUs: startUs,
            endUs: endUs,
            summary: summary,
            topicTags: topicTags,
            apps: apps,
            keyArtifacts: keyArtifacts,
            evidence: evidence,
            provenance: RecordProvenance(
                provider: response.provider,
                modelId: response.modelId,
                generatedAt: Date(),
                inputHash: inputHash
            )
        )
    }

    /// Parse LLM JSON response into a DailyRecord.
    static func parseDailyResponse(
        _ response: LLMResponse,
        date: String,
        inputHash: String
    ) throws -> DailyRecord {
        let content = cleanJSONContent(response.content)
        guard let data = content.data(using: .utf8) else {
            throw LLMProviderError.malformedOutput(detail: "Non-UTF8 response")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let json else {
            throw LLMProviderError.malformedOutput(detail: "Response is not a JSON object")
        }

        let summary = json["summary"] as? String ?? ""
        let wins = json["wins"] as? [String] ?? []
        let openLoops = json["openLoops"] as? [String] ?? []
        let meetingHighlights = json["meetingHighlights"] as? [String] ?? []

        // Parse focus blocks (safe numeric parsing — reject negative/overflow values)
        let focusBlockArray = json["focusBlocks"] as? [[String: Any]] ?? []
        let focusBlocks: [FocusBlock] = focusBlockArray.compactMap { dict in
            guard let app = dict["app"] as? String,
                  let startUsNum = dict["startUs"] as? NSNumber,
                  let startUs = safeUInt64(startUsNum),
                  let endUsNum = dict["endUs"] as? NSNumber,
                  let endUs = safeUInt64(endUsNum),
                  let durationNum = dict["durationMinutes"] as? NSNumber,
                  durationNum.intValue >= 0
            else { return nil }
            return FocusBlock(app: app, startUs: startUs, endUs: endUs, durationMinutes: durationNum.intValue)
        }

        // Parse evidence
        let evidenceArray = json["evidence"] as? [[String: Any]] ?? []
        let evidence: [ContextEvidence] = evidenceArray.compactMap { parseEvidence($0) }

        guard !summary.isEmpty else {
            throw LLMProviderError.malformedOutput(detail: "Daily summary is empty")
        }

        return DailyRecord(
            date: date,
            summary: summary,
            wins: wins,
            openLoops: openLoops,
            meetingHighlights: meetingHighlights,
            focusBlocks: focusBlocks,
            evidence: evidence,
            provenance: RecordProvenance(
                provider: response.provider,
                modelId: response.modelId,
                generatedAt: Date(),
                inputHash: inputHash
            )
        )
    }

    // MARK: - Prompts

    private static let episodeSystemPrompt = """
    You are a work-session summarizer. Given timeline events and transcript data from a user's \
    computer activity, produce a structured JSON summary of this work episode.

    Output ONLY valid JSON matching this exact schema (no markdown, no explanation, no code fences):

    {
      "summary": "2-3 sentence description of what the user was doing",
      "topicTags": ["tag1", "tag2"],
      "apps": ["App1", "App2"],
      "keyArtifacts": ["file or document mentioned"],
      "evidence": [
        {
          "timestamp": 1708300000000000,
          "app": "AppName",
          "sourceKind": "timeline",
          "snippet": "Brief context"
        }
      ]
    }

    Rules:
    - summary must be 1-3 sentences describing the work activity
    - topicTags: 2-5 short topic labels (e.g., "code review", "email", "meeting")
    - apps: list of applications used (from the timeline data)
    - keyArtifacts: files, documents, URLs, or projects mentioned (empty array if none)
    - evidence: 1-5 supporting data points with absolute Unix microsecond timestamps
    - Timestamps in the input use format: [HH:MM:SS @<absolute_us>] — use the @-prefixed values
    - Transcript entries marked (mic) are the USER's own voice — things they said aloud
    - Transcript entries marked (system) are OTHER PARTICIPANTS — meeting attendees, video/call audio
    - Use this distinction: attribute actions and commitments correctly (e.g., "User said they would..." vs "A colleague asked for...")
    - Do NOT include any text outside the JSON object
    """

    private static let dailySystemPrompt = """
    You are a daily work summarizer. Given a day's episodes and activity data, produce a \
    structured JSON summary of the entire day.

    Output ONLY valid JSON matching this exact schema (no markdown, no explanation, no code fences):

    {
      "summary": "3-5 sentence overview of the day",
      "wins": ["Accomplishment 1", "Accomplishment 2"],
      "openLoops": ["Unfinished item 1"],
      "meetingHighlights": ["Key meeting takeaway"],
      "focusBlocks": [
        {
          "app": "AppName",
          "startUs": 1708300000000000,
          "endUs": 1708303600000000,
          "durationMinutes": 60
        }
      ],
      "evidence": [
        {
          "timestamp": 1708300000000000,
          "app": "AppName",
          "sourceKind": "episode",
          "snippet": "Brief context"
        }
      ]
    }

    Rules:
    - summary: 3-5 sentences covering the day's major activities
    - wins: concrete accomplishments (empty array if none identified)
    - openLoops: items started but not finished, or questions left open
    - meetingHighlights: notable meeting outcomes (empty array if no meetings)
    - focusBlocks: significant continuous work periods (30+ minutes)
    - evidence: 1-5 supporting data points
    - Transcript entries marked (mic) are the USER's own voice — things they said aloud
    - Transcript entries marked (system) are OTHER PARTICIPANTS — meeting attendees, video/call audio
    - Use this distinction: attribute actions and commitments correctly (e.g., "User said they would..." vs "A colleague asked for...")
    - Do NOT include any text outside the JSON object
    """

    // MARK: - Helpers

    private static func parseEvidence(_ dict: [String: Any]) -> ContextEvidence? {
        guard let tsNumber = dict["timestamp"] as? NSNumber,
              let timestamp = safeUInt64(tsNumber) else { return nil }
        let displayId: UInt32? = (dict["displayId"] as? NSNumber).flatMap { safeUInt32($0) }
        return ContextEvidence(
            timestamp: timestamp,
            app: dict["app"] as? String,
            sourceKind: dict["sourceKind"] as? String ?? "unknown",
            displayId: displayId,
            url: dict["url"] as? String,
            snippet: dict["snippet"] as? String ?? ""
        )
    }

    /// Strip markdown code fences and whitespace from JSON content.
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

    /// SHA256 hash of input content for dedup.
    static func computeHash(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Format a Unix microsecond timestamp as "YYYY-MM-DD HH:mm:ss".
    private static func formatTimestamp(_ us: UInt64) -> String {
        let date = Date(timeIntervalSince1970: Double(us) / 1_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// Format a relative timestamp as "HH:MM:SS".
    private static func formatRelativeTimestamp(_ us: UInt64, base: UInt64) -> String {
        let relativeUs = us >= base ? us - base : 0
        let relativeSec = Int(relativeUs / 1_000_000)
        let hours = relativeSec / 3600
        let minutes = (relativeSec % 3600) / 60
        let seconds = relativeSec % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// Safe conversion from NSNumber to UInt64. Rejects negative values.
    static func safeUInt64(_ number: NSNumber) -> UInt64? {
        let doubleVal = number.doubleValue
        guard doubleVal >= 0, doubleVal <= Double(UInt64.max) else { return nil }
        return number.uint64Value
    }

    /// Safe conversion from NSNumber to UInt32. Rejects negative values and overflow.
    static func safeUInt32(_ number: NSNumber) -> UInt32? {
        let doubleVal = number.doubleValue
        guard doubleVal >= 0, doubleVal <= Double(UInt32.max) else { return nil }
        return number.uint32Value
    }
}
