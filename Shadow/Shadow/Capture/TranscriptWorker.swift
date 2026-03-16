import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "TranscriptWorker")

/// Background worker that transcribes sealed audio segments using the transcription orchestrator.
/// Processes both mic and system audio segments, splits transcripts into timestamped chunks,
/// and indexes them into Tantivy via Rust for searchable recall.
///
/// Thread safety discipline:
/// - `processTimer` is created/invalidated exclusively on the main thread.
/// - `guardedState` (isProcessing, isStopped, consecutiveFailures) is protected by
///   OSAllocatedUnfairLock and accessed from both main thread and background tasks.
/// - All constants are immutable after init.
///
/// Key design constraints:
/// - Never blocks capture callbacks or the main thread
/// - Checkpoint uses segment_id (monotonic, skip-safe) not timestamps
/// - Checkpoint advances ONLY on success or documented terminal skip
/// - Transient failures do NOT advance checkpoint — segment is retried next cycle
/// - After maxRetriesPerSegment consecutive failures, segment is skipped with warning
/// - On-device recognition only (no cloud dependency)
/// - Never triggers permission prompts — checks state passively and no-ops if not granted
/// - Bounded CPU budget via batch size limits
final class TranscriptWorker: Sendable {
    /// Transcription orchestrator — set once before `start()`.
    /// Uses `nonisolated(unsafe)` because it's written once (before start) and read many
    /// times (during processing). No concurrent mutation.
    nonisolated(unsafe) var orchestrator: TranscriptionOrchestrator?

    /// Maximum audio segments to process in a single batch run.
    private let maxBatchSize: UInt32 = 10

    /// Target chunk duration in seconds. Words are grouped into chunks of approximately
    /// this duration. Balances search granularity vs index size.
    private let chunkDurationSeconds: Double = 30.0

    /// How often the periodic processor runs (seconds).
    private let processInterval: TimeInterval = 60.0

    /// Maximum consecutive transient failures on the same segment before skipping it.
    /// At 60s intervals, 5 retries = 5 minutes of attempts before giving up.
    /// Skip policy: after maxRetries, the segment is permanently skipped with a
    /// diagnostic warning. This prevents a single corrupt/unreadable file from
    /// blocking the entire transcript pipeline forever.
    private let maxRetriesPerSegment: Int = 5

    // MARK: - Synchronized state (cross-thread)

    private struct GuardedState: Sendable {
        var isProcessing = false
        var isStopped = true
        /// Count of consecutive transient failures on the current head-of-queue segment.
        /// Resets to 0 on success or terminal skip. Persists across processing cycles.
        var consecutiveFailures: Int = 0
        /// Whether the "no provider available" warning has been emitted this session.
        /// Rate-limits the warning to once (resets on successful provider availability).
        var noProviderWarningEmitted = false
    }

    /// Lock-protected state accessed from both main thread and background tasks.
    private let guardedState = OSAllocatedUnfairLock(initialState: GuardedState())

    // MARK: - Main-thread-only state

    /// Timer for periodic processing. Created/invalidated exclusively on main thread.
    private nonisolated(unsafe) var processTimer: Timer?

    // MARK: - Lifecycle

    /// Start the transcript worker. Must be called from the main thread.
    @MainActor
    func start() {
        guardedState.withLock { $0.isStopped = false }

        processTimer = Timer.scheduledTimer(
            withTimeInterval: processInterval,
            repeats: true
        ) { [weak self] _ in
            self?.triggerProcessing()
        }
        // Initial catch-up after delay (let audio capture stabilize + produce segments)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.triggerProcessing()
        }
        logger.info("Transcript worker started (interval: \(self.processInterval)s, chunk: \(self.chunkDurationSeconds)s)")
    }

    /// Stop the transcript worker. Must be called from the main thread.
    @MainActor
    func stop() {
        guardedState.withLock { $0.isStopped = true }
        processTimer?.invalidate()
        processTimer = nil
        logger.info("Transcript worker stopped")
    }

    private func triggerProcessing() {
        Task.detached(priority: .utility) { [weak self] in
            await self?.processNewSegments()
        }
    }

    // MARK: - Segment Processing Pipeline

    /// Outcome of transcribing a single segment.
    private enum SegmentOutcome {
        /// Transcription succeeded. Entries may be empty (silence/noise — no speech detected).
        case success([TranscriptEntry])
        /// File does not exist on disk. Terminal — will never succeed. Advance checkpoint.
        case fileMissing
        /// File exists but is corrupt/unreadable. Terminal — separate counter from fileMissing.
        case badInput
        /// Transient error (recognizer unavailable, model loading, etc.). Do NOT advance checkpoint.
        case transientFailure
    }

    private func processNewSegments() async {
        // Check and set isProcessing atomically
        let canProceed = guardedState.withLock { state -> Bool in
            guard !state.isProcessing, !state.isStopped else { return false }
            state.isProcessing = true
            return true
        }
        guard canProceed else { return }
        defer { guardedState.withLock { $0.isProcessing = false } }

        // Check that at least one provider is ready. No-ops if Whisper is still loading
        // and Apple Speech isn't authorized.
        guard orchestrator?.hasAvailableProvider == true else {
            DiagnosticsStore.shared.increment("transcript_no_provider_available_total")
            let shouldWarn = guardedState.withLock { state -> Bool in
                guard !state.noProviderWarningEmitted else { return false }
                state.noProviderWarningEmitted = true
                return true
            }
            if shouldWarn {
                logger.warning("No transcription provider available — transcript pipeline idle")
                DiagnosticsStore.shared.postWarning(
                    severity: .warning,
                    subsystem: "Transcript",
                    code: "TRANSCRIPT_NO_PROVIDER",
                    message: "No transcription provider available (Whisper not loaded, Speech not authorized)"
                )
            }
            return
        }
        // Provider became available — reset the rate-limit flag so future outages are visible
        guardedState.withLock { $0.noProviderWarningEmitted = false }

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            // Checkpoint stores last processed segment_id (as u64).
            // segment_id is monotonically increasing INTEGER PRIMARY KEY — skip-safe.
            let checkpoint = try getIndexCheckpoint(indexName: "transcript")
            let lastSegmentId = Int64(checkpoint)

            let segments = try listAudioSegmentsAfterCheckpoint(
                lastSegmentId: lastSegmentId,
                limit: maxBatchSize
            )
            guard !segments.isEmpty else { return }

            // Report backlog size for diagnostics (total pending segments).
            DiagnosticsStore.shared.setGauge("transcript_backlog_segments", value: Double(segments.count))

            var totalIndexed: UInt32 = 0

            segmentLoop: for segment in segments {
                if guardedState.withLock({ $0.isStopped }) { break }

                let outcome = await transcribeSegment(segment)

                switch outcome {
                case .success(let entries):
                    if !entries.isEmpty {
                        let count = try indexTranscriptText(entries: entries)
                        totalIndexed += count
                        DiagnosticsStore.shared.increment("transcript_chunks_indexed_total", by: Int64(count))
                    } else {
                        // No speech detected — silence/noise. Terminal: advance past it.
                        DiagnosticsStore.shared.increment("transcript_segments_empty_total")
                    }
                    DiagnosticsStore.shared.increment("transcript_segments_processed_total")
                    try setIndexCheckpoint(indexName: "transcript", lastTs: UInt64(segment.segmentId))
                    guardedState.withLock { $0.consecutiveFailures = 0 }

                case .fileMissing:
                    // Terminal: file will never appear. Skip with diagnostic.
                    DiagnosticsStore.shared.increment("transcript_segments_processed_total")
                    try setIndexCheckpoint(indexName: "transcript", lastTs: UInt64(segment.segmentId))
                    guardedState.withLock { $0.consecutiveFailures = 0 }

                case .badInput:
                    // Terminal: file exists but is corrupt/unreadable. Skip with diagnostic.
                    DiagnosticsStore.shared.increment("transcript_segments_processed_total")
                    try setIndexCheckpoint(indexName: "transcript", lastTs: UInt64(segment.segmentId))
                    guardedState.withLock { $0.consecutiveFailures = 0 }

                case .transientFailure:
                    let failures = guardedState.withLock { state -> Int in
                        state.consecutiveFailures += 1
                        return state.consecutiveFailures
                    }
                    DiagnosticsStore.shared.increment("transcript_segments_retried_total")

                    if failures >= maxRetriesPerSegment {
                        // Exhausted retries — skip this segment to unblock the pipeline.
                        logger.warning("Skipping segment \(segment.segmentId) after \(failures) consecutive failures")
                        DiagnosticsStore.shared.increment("transcript_segments_skipped_total")
                        DiagnosticsStore.shared.postWarning(
                            severity: .warning,
                            subsystem: "Transcript",
                            code: "TRANSCRIPT_SEGMENT_SKIPPED",
                            message: "Segment \(segment.segmentId) skipped after \(failures) retries"
                        )
                        try setIndexCheckpoint(indexName: "transcript", lastTs: UInt64(segment.segmentId))
                        guardedState.withLock { $0.consecutiveFailures = 0 }
                    } else {
                        // Don't advance checkpoint — same segment will be retried next cycle.
                        logger.info("Segment \(segment.segmentId) failed (\(failures)/\(self.maxRetriesPerSegment)), will retry")
                        break segmentLoop
                    }
                }
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            if totalIndexed > 0 {
                logger.info("Transcript: processed \(segments.count) segment(s), indexed \(totalIndexed) chunks in \(Int(elapsed))ms")
                DiagnosticsStore.shared.recordLatency("transcript_batch_ms", ms: elapsed)
            }

        } catch {
            logger.error("Transcript processing failed: \(error, privacy: .public)")
            DiagnosticsStore.shared.increment("transcript_process_fail_total")
            DiagnosticsStore.shared.postWarning(
                severity: .warning,
                subsystem: "Transcript",
                code: "TRANSCRIPT_PROCESS_FAILED",
                message: "Transcript processing failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Per-Segment Transcription

    /// Transcribe a single audio segment and classify the outcome.
    private func transcribeSegment(_ segment: AudioSegment) async -> SegmentOutcome {
        let url = URL(fileURLWithPath: segment.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            DiagnosticsStore.shared.increment("transcript_file_missing_total")
            logger.warning("Audio file missing for segment \(segment.segmentId): \(segment.filePath, privacy: .public)")
            return .fileMissing
        }

        guard let orchestrator else { return .transientFailure }

        switch await orchestrator.transcribe(audioFileURL: url) {
        case .success(let words, _):
            guard !words.isEmpty else {
                return .success([]) // No speech detected — silence/noise
            }
            let chunks = buildChunks(from: words, audioSegment: segment)
            return .success(chunks)

        case .badInput:
            DiagnosticsStore.shared.increment("transcript_bad_input_total")
            logger.warning("Bad audio input for segment \(segment.segmentId): \(segment.filePath, privacy: .public)")
            return .badInput

        case .transientFailure:
            DiagnosticsStore.shared.increment("transcript_recognition_fail_total")
            return .transientFailure
        }
    }

    // MARK: - Chunk Building

    /// Group transcribed words into time-bounded chunks.
    /// Each chunk covers approximately `chunkDurationSeconds` of audio.
    /// Word timestamps (relative to audio start) are converted to absolute Unix microseconds
    /// using the audio segment's start_ts.
    private func buildChunks(
        from words: [TranscribedWord],
        audioSegment: AudioSegment
    ) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        var currentWords: [String] = []
        var chunkStartOffset: Double = words[0].startSeconds
        var totalConfidence: Float = 0
        var wordCount: Int = 0

        for (i, word) in words.enumerated() {
            currentWords.append(word.text)
            totalConfidence += word.confidence ?? 0
            wordCount += 1

            let wordEndOffset = word.startSeconds + word.durationSeconds
            let chunkDuration = wordEndOffset - chunkStartOffset
            let isLast = (i == words.count - 1)

            if chunkDuration >= chunkDurationSeconds || isLast {
                let text = currentWords.joined(separator: " ")
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                    currentWords.removeAll()
                    if !isLast, i + 1 < words.count {
                        chunkStartOffset = words[i + 1].startSeconds
                    }
                    totalConfidence = 0
                    wordCount = 0
                    continue
                }

                // Convert relative offsets to absolute Unix microseconds
                let chunkStartUs = audioSegment.startTs + UInt64(chunkStartOffset * 1_000_000)
                let chunkEndUs = audioSegment.startTs + UInt64(wordEndOffset * 1_000_000)
                let avgConfidence = wordCount > 0 ? totalConfidence / Float(wordCount) : 0

                // Look up temporally accurate app context
                let appContext = try? findAppAtTimestamp(timestampUs: chunkStartUs)

                let entry = TranscriptEntry(
                    audioSegmentId: audioSegment.segmentId,
                    source: audioSegment.source,
                    tsStart: chunkStartUs,
                    tsEnd: chunkEndUs,
                    text: text,
                    confidence: avgConfidence > 0 ? avgConfidence : nil,
                    appName: appContext?.appName,
                    windowTitle: nil
                )
                entries.append(entry)

                // Reset for next chunk
                currentWords.removeAll()
                if !isLast, i + 1 < words.count {
                    chunkStartOffset = words[i + 1].startSeconds
                }
                totalConfidence = 0
                wordCount = 0
            }
        }

        return entries
    }
}
