import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "SummaryCoordinator")

/// Result of a summarization attempt.
enum SummarizationResult: Sendable {
    /// Successfully generated a meeting summary.
    case success(MeetingSummary)
    /// No meeting found in the lookback window.
    case noMeetingFound
    /// Multiple candidate meetings found — caller should disambiguate.
    case disambiguation([MeetingCandidate])
}

/// Stateless coordinator that chains MeetingResolver → MeetingInputAssembler → SummaryJobQueue.
///
/// Same pattern as MeetingResolver (enum with static methods, no mutable state).
enum SummaryCoordinator {

    /// Summarize the most recent meeting.
    ///
    /// Flow:
    /// 1. MeetingResolver.resolveLatestMeeting() → find candidate windows
    /// 2. If single candidate → assemble input → submit to queue → return result
    /// 3. If multiple candidates → return disambiguation list
    /// 4. If none → return .noMeetingFound
    static func summarizeLatestMeeting(queue: SummaryJobQueue) async throws -> SummarizationResult {
        let candidates: [MeetingCandidate]
        do {
            candidates = try MeetingResolver.resolveLatestMeeting()
        } catch {
            logger.error("Meeting resolution failed: \(error, privacy: .public)")
            throw error
        }

        guard let candidate = candidates.first else {
            logger.info("No meeting candidates found")
            return .noMeetingFound
        }

        if candidates.count > 1 {
            logger.info("Multiple meeting candidates (\(candidates.count)), picking top (confidence=\(candidate.confidence, format: .fixed(precision: 2)))")
        }
        logger.info("Summarizing meeting: app=\(candidate.app) window=[\(candidate.startUs)–\(candidate.endUs)]")

        let input: AssembledMeetingInput
        do {
            input = try MeetingInputAssembler.assemble(
                startUs: candidate.startUs,
                endUs: candidate.endUs
            )
        } catch {
            logger.error("Input assembly failed: \(error, privacy: .public)")
            throw error
        }

        let summary = try await queue.submit(input: input)
        return .success(summary)
    }
}
