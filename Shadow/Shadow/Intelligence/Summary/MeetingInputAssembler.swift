import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "MeetingInputAssembler")

/// Assembled meeting input ready for LLM summarization.
struct AssembledMeetingInput: Sendable {
    /// Formatted transcript text (chronological, with timestamps).
    let transcript: String
    /// Source time window.
    let sourceWindow: SourceWindow
    /// SHA256 hash of the formatted transcript (for dedup/coalescing).
    let inputHash: String
    /// Estimated token count (~4 chars/token).
    let estimatedTokens: Int
    /// Number of transcript chunks assembled.
    let chunkCount: Int
}

/// Assembles transcript chunks from a time window into an LLM-ready packet.
///
/// 1. Fetches transcript chunks in pages via `listTranscriptChunksInRange()`
/// 2. Sorts by ts_start ascending (should already be sorted from Rust)
/// 3. Deduplicates overlapping chunks (same text within 1s window)
/// 4. Formats: `[HH:MM:SS] (mic/system) text\n` per chunk
/// 5. Computes SHA256 of formatted text
/// 6. Estimates tokens (~4 chars/token)
enum MeetingInputAssembler {

    /// Page size for fetching transcript chunks from Rust.
    private static let pageSize: UInt32 = 500

    /// Characters per token estimate (conservative for English + mixed content).
    private static let charsPerToken = 4

    /// Maximum time gap between identical chunks to consider them duplicates (microseconds).
    private static let dedupeWindowUs: UInt64 = 1_000_000  // 1 second

    // MARK: - Public API

    /// Assemble transcript chunks from a time window into LLM-ready input.
    static func assemble(
        startUs: UInt64,
        endUs: UInt64,
        timezone: String = TimeZone.current.identifier,
        sessionId: String? = nil
    ) throws -> AssembledMeetingInput {
        // Fetch all chunks in pages
        var allChunks: [TranscriptChunkResult] = []
        var offset: UInt32 = 0

        while true {
            let page = try listTranscriptChunksInRange(
                startUs: startUs,
                endUs: endUs,
                limit: pageSize,
                offset: offset
            )
            if page.isEmpty { break }
            allChunks.append(contentsOf: page)
            if page.count < Int(pageSize) { break }
            offset += pageSize
        }

        logger.info("Fetched \(allChunks.count) transcript chunks for window [\(startUs)–\(endUs)]")

        // Deduplicate overlapping chunks (same text within dedup window)
        let deduped = deduplicateChunks(allChunks)

        // Format transcript text
        let formattedText = formatTranscript(deduped, baseTimestamp: startUs)

        // Build source window
        let sourceWindow = SourceWindow(
            startUs: startUs,
            endUs: endUs,
            timezone: timezone,
            sessionId: sessionId
        )

        // Compute hash and token estimate
        let hash = computeInputHash(formattedText)
        let estimatedTokens = formattedText.count / charsPerToken

        return AssembledMeetingInput(
            transcript: formattedText,
            sourceWindow: sourceWindow,
            inputHash: hash,
            estimatedTokens: estimatedTokens,
            chunkCount: deduped.count
        )
    }

    // MARK: - Deduplication

    /// Remove duplicate transcript chunks (same text within a 1-second window).
    internal static func deduplicateChunks(
        _ chunks: [TranscriptChunkResult]
    ) -> [TranscriptChunkResult] {
        guard chunks.count > 1 else { return chunks }

        var result: [TranscriptChunkResult] = [chunks[0]]

        for i in 1..<chunks.count {
            let chunk = chunks[i]
            let prev = result.last!

            let sameText = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == prev.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let withinWindow = chunk.tsStart.subtractingReportingOverflow(prev.tsStart).partialValue <= dedupeWindowUs

            if sameText && withinWindow {
                continue  // Skip duplicate
            }
            result.append(chunk)
        }

        return result
    }

    // MARK: - Formatting

    /// Format transcript chunks into timestamped lines.
    /// Format: `[HH:MM:SS @<absolute_us>] (mic/system) transcribed text`
    /// The `@<absolute_us>` suffix provides the absolute Unix microsecond timestamp
    /// for the LLM to reference in highlights and evidence timestamps.
    internal static func formatTranscript(
        _ chunks: [TranscriptChunkResult],
        baseTimestamp: UInt64
    ) -> String {
        var lines: [String] = []

        for chunk in chunks {
            let relativeUs = chunk.tsStart >= baseTimestamp
                ? chunk.tsStart - baseTimestamp
                : 0
            let relativeSec = Int(relativeUs / 1_000_000)
            let hours = relativeSec / 3600
            let minutes = (relativeSec % 3600) / 60
            let seconds = relativeSec % 60
            let timestamp = String(format: "%02d:%02d:%02d", hours, minutes, seconds)

            let source = chunk.audioSource.isEmpty ? "unknown" : chunk.audioSource
            let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            lines.append("[\(timestamp) @\(chunk.tsStart)] (\(source)) \(text)")
        }

        return lines.joined(separator: "\n")
    }
}
