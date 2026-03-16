import Cocoa
import Vision
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "OCRWorker")

/// Background worker that extracts text from recorded screen frames using Apple Vision OCR.
/// Processes video segments at regular intervals, deduplicates near-identical frames
/// using Vision feature prints, and indexes recognized text into Tantivy via Rust.
///
/// Thread safety discipline:
/// - `processTimer` is created/invalidated exclusively on the main thread.
/// - `guardedState` (isProcessing, isStopped) is protected by OSAllocatedUnfairLock
///   and accessed from both main thread and workQueue.
/// - Feature print state (lastFeaturePrint, lastFeaturePrintDisplayID) is accessed
///   exclusively on workQueue — no lock needed.
/// - All constants (sampleIntervalSeconds, maxBatchSize, etc.) are immutable after init.
///
/// Key design constraints:
/// - Never blocks capture callbacks or the main thread
/// - Checkpoint advances only to the last actually-processed frame timestamp
/// - Bounded CPU budget via throttling and batch size limits
/// - Frame dedup via VNFeaturePrintObservation distance to skip static screens
/// - App context enrichment uses timeline data for temporal accuracy
final class OCRWorker: Sendable {
    /// Interval between OCR samples within a video segment (seconds).
    /// At 0.5fps capture, 10s = every 5 frames. Balances coverage vs CPU cost.
    private let sampleIntervalSeconds: Double = 10.0

    /// Maximum OCR entries to index in a single batch. Prevents large commits.
    private let maxBatchSize = 50

    /// Feature print distance threshold for dedup. Below this, frames are considered identical.
    /// Empirically, 0.3 works well for "same screen, minor cursor/clock changes".
    private let dedupThreshold: Float = 0.3

    /// Minimum confidence for recognized text to be indexed.
    private let minConfidence: Float = 0.3

    /// How often the periodic processor runs (seconds).
    private let processInterval: TimeInterval = 60.0

    private let workQueue = DispatchQueue(label: "com.shadow.ocr", qos: .utility)

    // MARK: - Synchronized state (cross-thread)

    private struct GuardedState: Sendable {
        var isProcessing = false
        var isStopped = true
    }

    /// Lock-protected state accessed from both main thread and workQueue.
    private let guardedState = OSAllocatedUnfairLock(initialState: GuardedState())

    // MARK: - Main-thread-only state

    /// Timer for periodic processing. Created/invalidated exclusively on main thread.
    /// Not guarded by lock because it's single-thread-confined.
    private nonisolated(unsafe) var processTimer: Timer?

    // MARK: - WorkQueue-only state (no lock needed)

    /// Last feature print for dedup comparison. Accessed only on workQueue.
    private nonisolated(unsafe) var lastFeaturePrint: VNFeaturePrintObservation?
    /// Display ID of the last feature print (reset on display change). Accessed only on workQueue.
    private nonisolated(unsafe) var lastFeaturePrintDisplayID: UInt32?

    // MARK: - Lifecycle

    /// Start the OCR worker. Must be called from the main thread.
    @MainActor
    func start() {
        guardedState.withLock { $0.isStopped = false }

        processTimer = Timer.scheduledTimer(
            withTimeInterval: processInterval,
            repeats: true
        ) { [weak self] _ in
            self?.triggerProcessing()
        }
        // Run initial catch-up after a short delay (let capture stabilize)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.triggerProcessing()
        }
        logger.info("OCR worker started (interval: \(self.processInterval)s, sample: \(self.sampleIntervalSeconds)s)")
    }

    /// Stop the OCR worker. Must be called from the main thread.
    @MainActor
    func stop() {
        guardedState.withLock { $0.isStopped = true }
        processTimer?.invalidate()
        processTimer = nil
        logger.info("OCR worker stopped")
    }

    private func triggerProcessing() {
        workQueue.async { [weak self] in
            self?.processNewFrames()
        }
    }

    // MARK: - Frame Processing Pipeline (workQueue only)

    /// Result of processing a segment: entries to index and the last timestamp actually visited.
    private struct SegmentResult {
        let entries: [OcrEntry]
        /// The timestamp of the last frame we actually visited (processed or skipped via dedup).
        /// UInt64.min if no frames were visited.
        let lastVisitedTs: UInt64
        /// True if processing was truncated by maxBatchSize.
        let hitBatchCap: Bool
    }

    private func processNewFrames() {
        // Check and set isProcessing atomically
        let canProceed = guardedState.withLock { state -> Bool in
            guard !state.isProcessing, !state.isStopped else { return false }
            state.isProcessing = true
            return true
        }
        guard canProceed else { return }
        defer { guardedState.withLock { $0.isProcessing = false } }

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let checkpoint = try getIndexCheckpoint(indexName: "ocr")
            let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)

            // Resume from checkpoint + 1 so we never revisit the last processed timestamp.
            // Checkpoint semantics: "everything up to and including checkpoint has been processed."
            let resumeFrom = checkpoint > 0 ? checkpoint + 1 : 0
            let segments = try listVideoSegments(startUs: resumeFrom, endUs: now)
            guard !segments.isEmpty else { return }

            var totalIndexed: UInt32 = 0
            var lastProcessedTs: UInt64 = checkpoint
            var globalBatchRemaining = maxBatchSize

            for segment in segments {
                if guardedState.withLock({ $0.isStopped }) { break }
                if globalBatchRemaining <= 0 { break }

                let result = processSegment(
                    segment,
                    fromTs: resumeFrom,
                    batchBudget: globalBatchRemaining
                )

                if !result.entries.isEmpty {
                    let count = try indexOcrText(entries: result.entries)
                    totalIndexed += count
                    globalBatchRemaining -= Int(count)
                    DiagnosticsStore.shared.increment("ocr_entries_indexed_total", by: Int64(count))
                }

                // Advance checkpoint only to what we actually visited.
                // If we hit the batch cap, stop here — next run will resume from this point.
                if result.lastVisitedTs > lastProcessedTs {
                    lastProcessedTs = result.lastVisitedTs
                }

                if result.hitBatchCap {
                    break
                }
            }

            // Persist checkpoint
            if lastProcessedTs > checkpoint {
                try setIndexCheckpoint(indexName: "ocr", lastTs: lastProcessedTs)
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            if totalIndexed > 0 {
                logger.info("OCR processed \(segments.count) segment(s), indexed \(totalIndexed) entries in \(Int(elapsed))ms")
                DiagnosticsStore.shared.recordLatency("ocr_batch_ms", ms: elapsed)
            }

        } catch {
            logger.error("OCR processing failed: \(error, privacy: .public)")
            DiagnosticsStore.shared.increment("ocr_process_fail_total")
            DiagnosticsStore.shared.postWarning(
                severity: .warning,
                subsystem: "OCR",
                code: "OCR_PROCESS_FAILED",
                message: "OCR processing failed: \(error.localizedDescription)"
            )
        }
    }

    /// Process a single video segment, extracting OCR text at sample intervals.
    /// Returns entries and the last timestamp actually visited.
    /// `batchBudget` limits how many entries this segment can produce.
    private func processSegment(
        _ segment: VideoSegment,
        fromTs: UInt64,
        batchBudget: Int
    ) -> SegmentResult {
        let url = URL(fileURLWithPath: segment.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            DiagnosticsStore.shared.increment("ocr_file_missing_total")
            return SegmentResult(entries: [], lastVisitedTs: .min, hitBatchCap: false)
        }

        let asset = AVURLAsset(url: url)

        let segStartUs = segment.startTs
        let segEndUs = segment.endTs > 0 ? segment.endTs : UInt64(Date().timeIntervalSince1970 * 1_000_000)

        // Start from whichever is later: segment start or checkpoint
        let processStartUs = max(segStartUs, fromTs)

        var entries: [OcrEntry] = []
        var currentUs = processStartUs
        let sampleIntervalUs = UInt64(sampleIntervalSeconds * 1_000_000)
        var lastVisitedTs: UInt64 = .min
        var hitCap = false

        // Snap to next sample boundary
        if currentUs > segStartUs {
            let offset = (currentUs - segStartUs) % sampleIntervalUs
            if offset > 0 {
                currentUs += sampleIntervalUs - offset
            }
        }

        while currentUs < segEndUs {
            if guardedState.withLock({ $0.isStopped }) { break }
            if entries.count >= batchBudget {
                hitCap = true
                break
            }

            // Record that we visited this timestamp regardless of OCR outcome.
            lastVisitedTs = currentUs

            // Seek offset relative to segment start
            let relativeSeconds = Double(currentUs - segStartUs) / 1_000_000.0
            let seekTime = CMTime(seconds: relativeSeconds, preferredTimescale: 600)

            if let image = extractFrame(from: asset, at: seekTime) {
                let (isNew, distance) = computeFrameDistance(image, displayID: segment.displayId)

                // Persist visual change distance for EVERY sample (one SQLite INSERT, negligible cost).
                // This MUST happen BEFORE the isNew check — we want distance recorded for every
                // 10-second sample, whether or not OCR runs on it.
                do {
                    try recordVisualChange(
                        displayId: segment.displayId,
                        timestampUs: currentUs,
                        distance: distance
                    )
                } catch {
                    // Non-fatal — visual change log is advisory, not critical path
                    logger.debug("Failed to record visual change: \(error)")
                }

                // Dedup: skip if frame is too similar to previous
                if !isNew {
                    DiagnosticsStore.shared.increment("ocr_frames_deduped_total")
                    currentUs += sampleIntervalUs
                    continue
                }

                // Run OCR
                if let text = performOCR(on: image) {
                    // Look up which app was focused at this frame's timestamp (temporally accurate)
                    let appContext = lookupAppContext(at: currentUs)

                    let entry = OcrEntry(
                        ts: currentUs,
                        displayId: segment.displayId,
                        text: text,
                        appName: appContext?.appName,
                        windowTitle: nil,
                        confidence: nil
                    )
                    entries.append(entry)
                    DiagnosticsStore.shared.increment("ocr_frames_processed_total")
                }
            }

            currentUs += sampleIntervalUs
        }

        return SegmentResult(entries: entries, lastVisitedTs: lastVisitedTs, hitBatchCap: hitCap)
    }

    // MARK: - Frame Extraction

    /// Extract a single frame from an AVAsset at the given time.
    /// Synchronous — called on workQueue only.
    private func extractFrame(from asset: AVURLAsset, at time: CMTime) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 2, timescale: 1)
        generator.requestedTimeToleranceAfter = CMTime(value: 2, timescale: 1)

        // Use half resolution for OCR — still very readable, half the pixel processing
        generator.maximumSize = CGSize(width: 960, height: 540)

        do {
            let image = try generator.copyCGImage(at: time, actualTime: nil)
            return image
        } catch {
            // Expected at segment boundaries or for very short segments
            return nil
        }
    }

    // MARK: - Frame Dedup via Feature Prints (workQueue only)

    /// Compute the perceptual distance between this frame and the previous one.
    /// Returns a tuple: (isNew: whether distance exceeds dedup threshold, distance: the raw value).
    /// Uses VNFeaturePrintObservation for perceptual similarity comparison.
    /// Must be called on workQueue only — accesses lastFeaturePrint without locking.
    private func computeFrameDistance(_ image: CGImage, displayID: UInt32) -> (isNew: Bool, distance: Float) {
        // Reset feature print when display changes
        if lastFeaturePrintDisplayID != displayID {
            lastFeaturePrint = nil
            lastFeaturePrintDisplayID = displayID
        }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
        } catch {
            // If feature print fails, assume frame is new (safe fallback)
            return (true, 1.0)
        }

        guard let observation = request.results?.first else {
            return (true, 1.0)
        }

        defer {
            lastFeaturePrint = observation
        }

        guard let previous = lastFeaturePrint else {
            // First frame — always new
            return (true, 1.0)
        }

        var distance: Float = 0
        do {
            try previous.computeDistance(&distance, to: observation)
        } catch {
            return (true, 1.0)
        }

        // Low distance = similar frames
        return (distance > dedupThreshold, distance)
    }

    // MARK: - OCR via Apple Vision (workQueue only)

    /// Run OCR on a CGImage using VNRecognizeTextRequest.
    /// Returns concatenated recognized text, or nil if no text found.
    private func performOCR(on image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            DiagnosticsStore.shared.increment("ocr_recognition_fail_total")
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }

        // Collect text blocks with sufficient confidence
        var textBlocks: [String] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            if candidate.confidence >= minConfidence {
                textBlocks.append(candidate.string)
            }
        }

        guard !textBlocks.isEmpty else { return nil }

        // Join with spaces. Vision returns observations roughly in reading order.
        let fullText = textBlocks.joined(separator: " ")

        // Skip very short text (likely noise — UI chrome, single characters)
        guard fullText.count >= 10 else { return nil }

        return fullText
    }

    // MARK: - App Context (temporally accurate)

    /// Look up which app was focused at a specific timestamp using the timeline's
    /// app_focus_intervals table. Returns nil if no interval covers that timestamp
    /// (e.g., during gaps, sleep, or before recording started).
    ///
    /// This replaces the old `currentAppContext()` which incorrectly used
    /// NSWorkspace.shared.frontmostApplication — attaching the current app
    /// to historical frames that may be minutes or hours old.
    private func lookupAppContext(at timestampUs: UInt64) -> AppContext? {
        do {
            return try findAppAtTimestamp(timestampUs: timestampUs)
        } catch {
            // Non-fatal: OCR text is still valuable without app context
            return nil
        }
    }
}
