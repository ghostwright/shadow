import Cocoa
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "EmbeddingWorker")

/// Background worker that generates CLIP embeddings from recorded screen frames and
/// indexes them into the vector index for visual semantic search.
///
/// Follows the OCRWorker pattern:
/// - Timer-based periodic processing on a background queue
/// - Checkpoint-based progress tracking via `get/setIndexCheckpoint("vector")`
/// - Frame dedup via Vision feature prints (same mechanism as OCR)
/// - Bounded batch processing with size limits
/// - DiagnosticsStore integration for observability
///
/// Model detection is automatic: checks for MobileCLIP CoreML assets in the app bundle.
/// When assets are absent, the worker stays idle and posts VECTOR_MODEL_UNAVAILABLE.
///
/// Thread safety discipline:
/// - `processTimer` is created/invalidated exclusively on the main thread.
/// - `guardedState` is protected by OSAllocatedUnfairLock.
/// - Feature print state accessed exclusively on workQueue.
/// - All constants are immutable after init.
final class EmbeddingWorker: Sendable {
    /// Interval between embedding samples within a video segment (seconds).
    /// At 0.5fps capture, 10s = every 5 frames. Same cadence as OCR.
    private let sampleIntervalSeconds: Double = 10.0

    /// Maximum embeddings to index in a single batch.
    private let maxBatchSize = 50

    /// How often the periodic processor runs (seconds).
    private let processInterval: TimeInterval = 60.0

    private let workQueue = DispatchQueue(label: "com.shadow.embedding", qos: .utility)

    // MARK: - Model

    /// CLIP encoder loaded from app bundle. Nil if model assets are absent.
    private let clipEncoder: CLIPEncoder?

    /// Whether CLIP model is available for inference.
    var modelAvailable: Bool { clipEncoder != nil }

    // MARK: - Synchronized state (cross-thread)

    private struct GuardedState: Sendable {
        var isProcessing = false
        var isStopped = true
    }

    private let guardedState = OSAllocatedUnfairLock(initialState: GuardedState())

    // MARK: - Main-thread-only state

    private nonisolated(unsafe) var processTimer: Timer?

    // MARK: - WorkQueue-only state

    /// Last feature print for dedup comparison. Accessed only on workQueue.
    private nonisolated(unsafe) var lastFeaturePrint: VNFeaturePrintObservation?
    private nonisolated(unsafe) var lastFeaturePrintDisplayID: UInt32?

    // MARK: - Lifecycle

    init() {
        // Attempt to load CLIP model from bundle
        self.clipEncoder = CLIPEncoder()
    }

    /// Start the embedding worker. Must be called from the main thread.
    @MainActor
    func start() {
        guardedState.withLock { $0.isStopped = false }

        guard modelAvailable else {
            logger.warning("Embedding worker started but no CLIP model available — vector lane disabled")
            DiagnosticsStore.shared.postWarning(
                severity: .warning,
                subsystem: "Vector",
                code: "VECTOR_MODEL_UNAVAILABLE",
                message: "No CLIP CoreML model found in app bundle. Run scripts/provision-clip-models.py and rebuild."
            )
            return
        }

        DiagnosticsStore.shared.setGauge("vector_model_loaded", value: 1)

        processTimer = Timer.scheduledTimer(
            withTimeInterval: processInterval,
            repeats: true
        ) { [weak self] _ in
            self?.triggerProcessing()
        }
        // Initial catch-up after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.triggerProcessing()
        }
        logger.info("Embedding worker started (model: \(self.clipEncoder?.modelId ?? "none"), interval: \(self.processInterval)s)")
    }

    /// Stop the embedding worker. Must be called from the main thread.
    @MainActor
    func stop() {
        guardedState.withLock { $0.isStopped = true }
        processTimer?.invalidate()
        processTimer = nil
        logger.info("Embedding worker stopped")
    }

    private func triggerProcessing() {
        workQueue.async { [weak self] in
            self?.processNewFrames()
        }
    }

    // MARK: - Frame Processing Pipeline (workQueue only)

    private struct SegmentResult {
        let entries: [VectorEntry]
        let lastVisitedTs: UInt64
        let hitBatchCap: Bool
    }

    private func processNewFrames() {
        guard modelAvailable else { return }

        let canProceed = guardedState.withLock { state -> Bool in
            guard !state.isProcessing, !state.isStopped else { return false }
            state.isProcessing = true
            return true
        }
        guard canProceed else { return }
        defer { guardedState.withLock { $0.isProcessing = false } }

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let checkpoint = try getIndexCheckpoint(indexName: "vector")
            let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
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
                    let count = try insertVectorEntries(entries: result.entries)
                    totalIndexed += count
                    globalBatchRemaining -= Int(count)
                    DiagnosticsStore.shared.increment("vector_entries_indexed_total", by: Int64(count))
                }

                if result.lastVisitedTs > lastProcessedTs {
                    lastProcessedTs = result.lastVisitedTs
                }

                if result.hitBatchCap { break }
            }

            if lastProcessedTs > checkpoint {
                try setIndexCheckpoint(indexName: "vector", lastTs: lastProcessedTs)
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            if totalIndexed > 0 {
                logger.info("Embedding processed \(segments.count) segment(s), indexed \(totalIndexed) entries in \(Int(elapsed))ms")
                DiagnosticsStore.shared.recordLatency("vector_batch_ms", ms: elapsed)
            }

        } catch {
            logger.error("Embedding processing failed: \(error, privacy: .public)")
            DiagnosticsStore.shared.increment("vector_process_fail_total")
            DiagnosticsStore.shared.postWarning(
                severity: .warning,
                subsystem: "Vector",
                code: "VECTOR_PROCESS_FAILED",
                message: "Embedding processing failed: \(error.localizedDescription)"
            )
        }
    }

    private func processSegment(
        _ segment: VideoSegment,
        fromTs: UInt64,
        batchBudget: Int
    ) -> SegmentResult {
        let url = URL(fileURLWithPath: segment.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            DiagnosticsStore.shared.increment("vector_file_missing_total")
            return SegmentResult(entries: [], lastVisitedTs: .min, hitBatchCap: false)
        }

        let asset = AVURLAsset(url: url)
        let segStartUs = segment.startTs
        let segEndUs = segment.endTs > 0 ? segment.endTs : UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let processStartUs = max(segStartUs, fromTs)

        var entries: [VectorEntry] = []
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

            lastVisitedTs = currentUs
            DiagnosticsStore.shared.increment("vector_frames_received_total")

            let relativeSeconds = Double(currentUs - segStartUs) / 1_000_000.0
            let seekTime = CMTime(seconds: relativeSeconds, preferredTimescale: 600)

            if let image = extractFrame(from: asset, at: seekTime) {
                // Dedup: skip if frame is too similar to previous
                if !isFrameNew(image, displayID: segment.displayId) {
                    DiagnosticsStore.shared.increment("vector_frames_deduped_total")
                    currentUs += sampleIntervalUs
                    continue
                }

                // Generate CLIP embedding via CoreML
                if let vector = clipEncoder?.embedImage(image) {
                    let frameOffsetUs = currentUs - segStartUs
                    let entry = VectorEntry(
                        ts: currentUs,
                        displayId: segment.displayId,
                        filePath: segment.filePath,
                        frameOffsetUs: frameOffsetUs,
                        vector: vector
                    )
                    entries.append(entry)
                } else {
                    DiagnosticsStore.shared.increment("vector_embed_infer_fail_total")
                }
            }

            currentUs += sampleIntervalUs
        }

        return SegmentResult(entries: entries, lastVisitedTs: lastVisitedTs, hitBatchCap: hitCap)
    }

    // MARK: - Frame Extraction

    private func extractFrame(from asset: AVURLAsset, at time: CMTime) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 2, timescale: 1)
        generator.requestedTimeToleranceAfter = CMTime(value: 2, timescale: 1)
        generator.maximumSize = CGSize(width: 960, height: 540)

        do {
            return try generator.copyCGImage(at: time, actualTime: nil)
        } catch {
            return nil
        }
    }

    // MARK: - Frame Dedup via Feature Prints (workQueue only)

    private func isFrameNew(_ image: CGImage, displayID: UInt32) -> Bool {
        if lastFeaturePrintDisplayID != displayID {
            lastFeaturePrint = nil
            lastFeaturePrintDisplayID = displayID
        }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return true
        }

        guard let observation = request.results?.first else {
            return true
        }

        defer {
            lastFeaturePrint = observation
        }

        guard let previous = lastFeaturePrint else {
            return true
        }

        var distance: Float = 0
        do {
            try previous.computeDistance(&distance, to: observation)
        } catch {
            return true
        }

        return distance > 0.3 // Same threshold as OCR
    }
}

import Vision
