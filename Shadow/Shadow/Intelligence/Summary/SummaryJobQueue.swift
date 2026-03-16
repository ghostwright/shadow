import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "SummaryJobQueue")

/// Status of a summary job.
enum SummaryJobStatus: Sendable {
    case queued
    case running
    case completed(MeetingSummary)
    case failed(String)
}

/// Handle to a queued summary job.
struct SummaryJobHandle: Sendable {
    let id: String
    let inputHash: String
    let sourceWindow: SourceWindow
}

/// Single-flight summary job queue with coalescing and backpressure.
///
/// - `maxConcurrency = 1`: only one summary runs at a time
/// - Coalesces duplicate requests by `inputHash` — same hash awaits same result
/// - Cancellation support via `cancelAll()`
/// - Rejects when queue full (`maxPending = 3`)
actor SummaryJobQueue {
    private let orchestrator: LLMOrchestrator
    private let store: SummaryStore

    private var activeJob: ActiveJob?
    private var pendingJobs: [PendingJob] = []
    private let maxPending = 3

    /// In-flight coalescing: inputHash → continuations waiting for the same result
    private var coalescingMap: [String: [CheckedContinuation<MeetingSummary, Error>]] = [:]

    init(orchestrator: LLMOrchestrator, store: SummaryStore) {
        self.orchestrator = orchestrator
        self.store = store
    }

    // MARK: - Public API

    /// Submit a summary request. Returns the generated summary.
    /// Coalesces duplicate requests (same inputHash) into a single execution.
    /// Throws if queue is full or summarization fails.
    func submit(input: AssembledMeetingInput) async throws -> MeetingSummary {
        // Check if same inputHash is already in flight — coalesce
        if coalescingMap[input.inputHash] != nil {
            DiagnosticsStore.shared.increment("summary_job_coalesced_total")
            logger.info("Coalescing summary request (hash=\(input.inputHash.prefix(8)))")
            return try await withCheckedThrowingContinuation { continuation in
                coalescingMap[input.inputHash]?.append(continuation)
            }
        }

        // Backpressure: reject if too many pending
        if activeJob != nil && pendingJobs.count >= maxPending {
            throw LLMProviderError.terminalFailure(reason: "Summary queue full (\(maxPending) pending)")
        }

        // Initialize coalescing group
        coalescingMap[input.inputHash] = []

        // If no active job, run immediately
        if activeJob == nil {
            return try await executeJob(input: input)
        }

        // Queue for later execution
        return try await withCheckedThrowingContinuation { continuation in
            pendingJobs.append(PendingJob(input: input, continuation: continuation))
        }
    }

    /// Cancel all pending and active jobs.
    func cancelAll() {
        let cancelled = pendingJobs.count + (activeJob != nil ? 1 : 0)

        // Fail all pending continuations
        for job in pendingJobs {
            job.continuation.resume(throwing: CancellationError())
        }
        pendingJobs.removeAll()

        // Fail all coalescing waiters
        for (_, continuations) in coalescingMap {
            for c in continuations {
                c.resume(throwing: CancellationError())
            }
        }
        coalescingMap.removeAll()

        activeJob = nil

        if cancelled > 0 {
            DiagnosticsStore.shared.increment("summary_job_cancelled_total", by: Int64(cancelled))
            logger.info("Cancelled \(cancelled) summary jobs")
        }
    }

    /// Current queue status for UI.
    var status: (active: SummaryJobHandle?, pendingCount: Int) {
        (activeJob?.handle, pendingJobs.count)
    }

    // MARK: - Internal

    private func executeJob(input: AssembledMeetingInput) async throws -> MeetingSummary {
        let jobId = UUID().uuidString
        let handle = SummaryJobHandle(
            id: jobId,
            inputHash: input.inputHash,
            sourceWindow: input.sourceWindow
        )
        activeJob = ActiveJob(handle: handle)

        defer {
            activeJob = nil
            drainPending()
        }

        do {
            let summary = try await runSummarization(input: input, jobId: jobId)

            // Resolve coalescing waiters
            if let waiters = coalescingMap.removeValue(forKey: input.inputHash) {
                for c in waiters {
                    c.resume(returning: summary)
                }
            }

            return summary

        } catch {
            // Fail coalescing waiters
            if let waiters = coalescingMap.removeValue(forKey: input.inputHash) {
                for c in waiters {
                    c.resume(throwing: error)
                }
            }
            throw error
        }
    }

    private func runSummarization(
        input: AssembledMeetingInput,
        jobId: String
    ) async throws -> MeetingSummary {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Build LLM request plan
        let plan = SummaryPromptBuilder.buildRequest(
            transcript: input.transcript,
            sourceWindow: input.sourceWindow
        )

        let finalResponse: LLMResponse

        switch plan {
        case .singlePass(let request):
            finalResponse = try await orchestrator.generate(request: request)

        case .mapReduce(let mapRequests, let reduceBuilder):
            // Map phase: run each chunk sequentially (single model instance)
            var partialSummaries: [String] = []
            for mapRequest in mapRequests {
                let response = try await orchestrator.generate(request: mapRequest)
                partialSummaries.append(response.content)
            }

            // Reduce phase: merge partials
            let reduceRequest = reduceBuilder(partialSummaries)
            finalResponse = try await orchestrator.generate(request: reduceRequest)
        }

        // Parse the JSON response into MeetingSummary, using the actual
        // provider/model from the response (not activeProviderInfo which
        // returns the NEXT available provider, not the one that generated this response).
        let summary = try parseSummaryResponse(
            finalResponse,
            jobId: jobId,
            input: input
        )

        // Validate
        let errors = summary.validate()
        if !errors.isEmpty {
            DiagnosticsStore.shared.increment("summary_schema_invalid_total")
            DiagnosticsStore.shared.postWarning(
                severity: .warning,
                subsystem: "Intelligence",
                code: "SUMMARY_SCHEMA_INVALID",
                message: "Summary validation failed: \(errors)"
            )
            throw LLMProviderError.malformedOutput(
                detail: "Validation failed: \(errors.map { "\($0)" }.joined(separator: ", "))"
            )
        }

        // Persist
        try store.save(summary)

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        DiagnosticsStore.shared.recordLatency("summary_total_ms", ms: elapsed)
        logger.info("Summary completed in \(String(format: "%.0f", elapsed))ms, saved as \(summary.id)")

        return summary
    }

    /// Parse LLM JSON output into a MeetingSummary, injecting metadata.
    /// Uses provider/model from the actual response rather than querying activeProviderInfo
    /// (which returns the next available provider, not the one that generated this response).
    private func parseSummaryResponse(
        _ response: LLMResponse,
        jobId: String,
        input: AssembledMeetingInput
    ) throws -> MeetingSummary {
        // Strip potential markdown code fences
        let cleaned = response.content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw LLMProviderError.malformedOutput(detail: "Response is not valid UTF-8")
        }

        // Parse the LLM's partial JSON (without id and metadata)
        let partial: PartialSummary
        do {
            partial = try JSONDecoder().decode(PartialSummary.self, from: data)
        } catch {
            throw LLMProviderError.malformedOutput(
                detail: "JSON parse failed: \(error.localizedDescription)"
            )
        }

        let metadata = SummaryMetadata(
            provider: response.provider,
            modelId: response.modelId,
            generatedAt: Date(),
            inputHash: input.inputHash,
            sourceWindow: input.sourceWindow,
            inputTokenEstimate: input.estimatedTokens
        )

        return MeetingSummary(
            id: jobId,
            title: partial.title,
            summary: partial.summary,
            keyPoints: partial.keyPoints,
            decisions: partial.decisions ?? [],
            actionItems: partial.actionItems ?? [],
            openQuestions: partial.openQuestions ?? [],
            highlights: partial.highlights ?? [],
            metadata: metadata
        )
    }

    /// Drain pending jobs, starting the next one if available.
    private func drainPending() {
        guard !pendingJobs.isEmpty else { return }
        let next = pendingJobs.removeFirst()

        Task {
            do {
                let summary = try await executeJob(input: next.input)
                next.continuation.resume(returning: summary)
            } catch {
                next.continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Internal Types

    private struct ActiveJob {
        let handle: SummaryJobHandle
    }

    private struct PendingJob {
        let input: AssembledMeetingInput
        let continuation: CheckedContinuation<MeetingSummary, Error>
    }
}

/// Partial summary as returned by the LLM (without id/metadata).
private struct PartialSummary: Codable {
    let title: String
    let summary: String
    let keyPoints: [String]
    let decisions: [String]?
    let actionItems: [ActionItem]?
    let openQuestions: [String]?
    let highlights: [TimestampedHighlight]?
}
