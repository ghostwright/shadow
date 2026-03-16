import Foundation
@preconcurrency import AVFoundation
import ImageIO
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "Retention")

/// Coordinates storage retention across all tiers.
/// Runs on app launch + hourly timer.
/// Delegates planning to Rust (via UniFFI) and executes media
/// operations (keyframe extraction, deletion) in Swift.
///
/// Thread safety discipline (same pattern as OCRWorker):
/// - `sweepTimer` is created/invalidated on the main thread only.
/// - `guardedState` (isRunning) is protected by OSAllocatedUnfairLock.
/// - All heavy work runs on `workQueue` (serial, .utility QoS).
/// - NOT @MainActor -- uses queue discipline instead.
final class RetentionCoordinator: Sendable {

    private let workQueue = DispatchQueue(label: "com.shadow.retention", qos: .utility)

    /// Timer for periodic sweeps. Created/invalidated on main thread only.
    private nonisolated(unsafe) var sweepTimer: Timer?

    private struct GuardedState: Sendable {
        var isRunning = false
    }
    private let guardedState = OSAllocatedUnfairLock(initialState: GuardedState())

    /// How often to run cleanup sweeps (seconds). Default: 1 hour.
    private let sweepInterval: TimeInterval = 3600

    /// Maximum time a single sweep can run before yielding (seconds).
    private let maxSweepDuration: TimeInterval = 300 // 5 minutes

    /// JPEG compression quality for keyframes. 0.85 = sharp text, ~50-150 KB/frame.
    private let jpegQuality: CGFloat = 0.85

    /// Feature print distance threshold for keyframe selection (same as OCRWorker).
    private let changeThreshold: Float = 0.3

    // MARK: - Lifecycle (call from main thread)

    @MainActor
    func start() {
        sweepTimer = Timer.scheduledTimer(
            withTimeInterval: sweepInterval,
            repeats: true
        ) { [weak self] _ in
            self?.triggerSweep()
        }

        // Run initial sweep after a delay (let capture stabilize)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.triggerSweep()
        }

        logger.info("RetentionCoordinator started (interval: \(self.sweepInterval)s)")
    }

    @MainActor
    func stop() {
        sweepTimer?.invalidate()
        sweepTimer = nil
        logger.info("RetentionCoordinator stopped")
    }

    private func triggerSweep() {
        workQueue.async { [weak self] in
            self?.runSweep()
        }
    }

    // MARK: - Sweep Execution (runs on workQueue)

    private func runSweep() {
        let alreadyRunning = guardedState.withLock { state -> Bool in
            if state.isRunning { return true }
            state.isRunning = true
            return false
        }
        guard !alreadyRunning else {
            logger.info("Sweep already running, skipping")
            return
        }
        defer { guardedState.withLock { $0.isRunning = false } }

        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("Starting retention sweep")

        // 1. Record storage usage snapshot
        do {
            let usage = try getStorageUsage()
            DiagnosticsStore.shared.setGauge("storage_total_gb",
                value: Double(usage.totalBytes) / (1024 * 1024 * 1024))
            DiagnosticsStore.shared.setGauge("storage_video_gb",
                value: Double(usage.videoBytes) / (1024 * 1024 * 1024))
            DiagnosticsStore.shared.setGauge("storage_disk_available_gb",
                value: Double(usage.diskAvailableBytes) / (1024 * 1024 * 1024))
            DiagnosticsStore.shared.setGauge("storage_audio_gb",
                value: Double(usage.audioBytes) / (1024 * 1024 * 1024))
            DiagnosticsStore.shared.setGauge("storage_keyframes_gb",
                value: Double(usage.keyframesBytes) / (1024 * 1024 * 1024))
            DiagnosticsStore.shared.setGauge("storage_indices_gb",
                value: Double(usage.indicesBytes) / (1024 * 1024 * 1024))
            DiagnosticsStore.shared.setGauge("storage_events_gb",
                value: Double(usage.eventsBytes) / (1024 * 1024 * 1024))
        } catch {
            logger.error("Failed to get storage usage: \(error)")
        }

        // 2. Get cleanup plan from Rust
        let plan: CleanupPlan
        do {
            plan = try planRetentionSweep()
        } catch {
            logger.error("Failed to plan retention sweep: \(error)")
            return
        }

        var totalFreed: UInt64 = 0

        // 3. Extract keyframes from aging hot-tier segments (hot -> warm)
        for segmentPath in plan.segmentsToKeyframe {
            if shouldYield(startTime: startTime) { break }
            extractKeyframes(segmentPath: segmentPath)
        }

        // 4. Delete keyframe files for cold-tier segments (warm -> cold)
        //    Phase 5 will implement this. For now, log and skip.
        for sourceSegment in plan.segmentsToDeleteKeyframes {
            if shouldYield(startTime: startTime) { break }
            deleteKeyframesForSegment(sourceSegment: sourceSegment)
        }

        // 5. Delete audio segments
        for segmentPath in plan.audioSegmentsToDelete {
            if shouldYield(startTime: startTime) { break }
            do {
                let freed = try deleteAudioFile(filePath: segmentPath)
                totalFreed += freed
            } catch {
                logger.error("Failed to delete audio segment \(segmentPath): \(error)")
            }
        }

        // 6. Index compaction (infrequent, weekly)
        if plan.shouldCompactIndices {
            logger.info("Index compaction scheduled but not yet implemented")
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let freedMB = Double(totalFreed) / (1024 * 1024)
        logger.info("Retention sweep complete: freed \(String(format: "%.1f", freedMB)) MB in \(String(format: "%.1f", elapsed))s")
        DiagnosticsStore.shared.increment("retention_sweeps_total")
        DiagnosticsStore.shared.recordLatency("retention_sweep_ms", ms: elapsed * 1000)
    }

    private func shouldYield(startTime: CFAbsoluteTime) -> Bool {
        return (CFAbsoluteTimeGetCurrent() - startTime) > maxSweepDuration
    }

    // MARK: - Keyframe Extraction (Hot -> Warm Transition)

    /// Extract keyframes from a video segment at visual change points,
    /// register them in the DB, and delete the source video.
    /// Runs on workQueue only.
    private func extractKeyframes(segmentPath: String) {
        guard FileManager.default.fileExists(atPath: segmentPath) else {
            // Video file already gone (crash during previous sweep, or manual deletion).
            // Transition to warm tier so we stop retrying every sweep.
            // FrameExtractor will try keyframe fallback; if none exist, returns nil (cold-tier behavior).
            logger.warning("Segment file missing, marking as warm: \(segmentPath)")
            try? updateVideoSegmentTier(filePath: segmentPath, tier: "warm")
            return
        }

        // Look up segment metadata from the timeline index
        let segment: VideoSegment
        do {
            guard let found = try findVideoSegmentByPath(filePath: segmentPath) else {
                logger.warning("No segment row for path, skipping: \(segmentPath)")
                return
            }
            segment = found
        } catch {
            logger.error("Failed to look up segment: \(error)")
            return
        }

        guard segment.endTs > segment.startTs else {
            logger.warning("Segment has invalid time range (\(segment.startTs)-\(segment.endTs)), skipping")
            return
        }

        // Query visual change points within this segment's time range
        let changeTimestamps: [UInt64]
        do {
            changeTimestamps = try queryVisualChanges(
                displayId: segment.displayId,
                startTs: segment.startTs,
                endTs: segment.endTs,
                minDistance: changeThreshold
            )
        } catch {
            logger.error("Failed to query visual changes: \(error)")
            return
        }

        // Build unique sorted timestamp list: always include first frame + all change points
        var timestampSet = Set<UInt64>()
        timestampSet.insert(segment.startTs)
        for ts in changeTimestamps {
            timestampSet.insert(ts)
        }
        let timestamps = timestampSet.sorted()

        // Set up AVAssetImageGenerator (same pattern as OCRWorker)
        let url = URL(fileURLWithPath: segmentPath)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 2, timescale: 1)
        generator.requestedTimeToleranceAfter = CMTime(value: 2, timescale: 1)

        var keyframes: [KeyframeRecord] = []

        for ts in timestamps {
            let relativeSeconds = Double(ts - segment.startTs) / 1_000_000.0
            let seekTime = CMTime(seconds: max(0, relativeSeconds), preferredTimescale: 600)

            do {
                let image = try generator.copyCGImage(at: seekTime, actualTime: nil)
                if let record = saveKeyframeJPEG(
                    image: image,
                    displayId: segment.displayId,
                    timestampUs: ts,
                    sourceSegment: segmentPath
                ) {
                    keyframes.append(record)
                }
            } catch {
                // Expected at segment boundaries or for very short segments
                logger.debug("Failed to extract frame at \(ts) from \(segmentPath): \(error)")
            }
        }

        finalizeKeyframes(keyframes: keyframes, segmentPath: segmentPath)
    }

    /// Save a CGImage as a JPEG keyframe file.
    /// Path: ~/.shadow/data/media/keyframes/display-N/YYYY-MM-DD/HH/<timestamp_us>.jpg
    private func saveKeyframeJPEG(
        image: CGImage,
        displayId: UInt32,
        timestampUs: UInt64,
        sourceSegment: String
    ) -> KeyframeRecord? {
        let date = Date(timeIntervalSince1970: Double(timestampUs) / 1_000_000.0)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: date)
        let hour = Calendar.current.component(.hour, from: date)

        let dir = URL(fileURLWithPath: shadowDataDir())
            .appendingPathComponent("media/keyframes/display-\(displayId)/\(dateStr)/\(String(format: "%02d", hour))")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create keyframe directory: \(error)")
            return nil
        }

        let jpegPath = dir.appendingPathComponent("\(timestampUs).jpg")

        guard let destination = CGImageDestinationCreateWithURL(
            jpegPath as CFURL,
            "public.jpeg" as CFString,
            1, nil
        ) else {
            logger.error("Failed to create image destination for \(jpegPath.path)")
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            logger.error("Failed to finalize JPEG at \(jpegPath.path)")
            return nil
        }

        let fileSize = (try? FileManager.default.attributesOfItem(
            atPath: jpegPath.path
        )[.size] as? UInt64) ?? 0

        return KeyframeRecord(
            displayId: displayId,
            ts: timestampUs,
            filePath: jpegPath.path,
            sizeBytes: fileSize
        )
    }

    /// Register keyframes in DB, delete source video, then update tier to warm.
    /// The tier is ONLY updated after the video file is confirmed deleted.
    /// If deletion fails, the segment stays 'hot' — next sweep will retry
    /// (keyframe inserts are INSERT OR IGNORE, so re-extraction is idempotent).
    private func finalizeKeyframes(keyframes: [KeyframeRecord], segmentPath: String) {
        guard !keyframes.isEmpty else {
            logger.info("No keyframes extracted from \(segmentPath), skipping finalization")
            return
        }

        do {
            let count = try registerKeyframes(
                sourceSegment: segmentPath,
                keyframes: keyframes
            )
            logger.info("Registered \(count) keyframes from \(segmentPath)")
            DiagnosticsStore.shared.increment("retention_keyframes_extracted_total",
                by: Int64(count))
        } catch {
            logger.error("Failed to register keyframes: \(error)")
            return  // Don't delete the source if registration failed
        }

        // Delete the source video now that keyframes are saved
        do {
            let freed = try deleteVideoFile(filePath: segmentPath)
            logger.info("Deleted source video: \(freed / 1024) KB freed")
            DiagnosticsStore.shared.increment("retention_segments_deleted_total")
        } catch {
            logger.error("Failed to delete source video \(segmentPath): \(error)")
            // Video file still exists — do NOT update tier.
            // Segment stays 'hot'. Next sweep will retry.
            return
        }

        // ONLY set tier to 'warm' after video file is confirmed deleted
        do {
            try updateVideoSegmentTier(filePath: segmentPath, tier: "warm")
        } catch {
            logger.error("Failed to update tier for \(segmentPath): \(error)")
        }
    }

    // MARK: - Keyframe Deletion (Warm -> Cold Transition)

    /// Delete keyframes for a specific source segment (warm -> cold transition).
    /// Uses the keyframes table to get individual file paths, then deletes each file.
    /// This is per-segment, NOT per-directory, to avoid deleting keyframes from
    /// younger segments that share the same hour folder.
    ///
    /// Ordering for retry safety: list paths -> delete files -> delete DB rows -> set tier='cold'.
    /// If we crash after files are deleted but before DB rows are removed, the next
    /// sweep will re-list the same rows, attempt to delete the (already gone) files
    /// (FileManager.removeItem on a missing file is harmless), then clean up the rows.
    private func deleteKeyframesForSegment(sourceSegment: String) {
        do {
            // Step 1: List paths from DB (does NOT delete rows yet)
            let paths = try listKeyframePaths(sourceSegment: sourceSegment)
            guard !paths.isEmpty else {
                // No keyframes to delete — just update tier
                try updateVideoSegmentTier(filePath: sourceSegment, tier: "cold")
                return
            }

            // Step 2: Delete files first. Track real failures vs already-gone.
            var deleted = 0
            var failed = 0
            for path in paths {
                do {
                    try FileManager.default.removeItem(atPath: path)
                    deleted += 1
                } catch let error as NSError where error.domain == NSCocoaErrorDomain
                    && error.code == NSFileNoSuchFileError {
                    // File already gone (ENOENT) — benign, count as success
                    deleted += 1
                } catch {
                    // Real error (permission, I/O) — do NOT count as deleted
                    logger.warning("Failed to delete keyframe \(path): \(error)")
                    failed += 1
                }
            }

            if failed > 0 {
                // Some files could not be deleted — do NOT remove DB rows or set tier.
                // Next sweep will retry.
                logger.error("Keyframe deletion incomplete for \(sourceSegment): \(deleted) deleted, \(failed) failed")
                DiagnosticsStore.shared.increment("retention_keyframe_delete_errors_total", by: Int64(failed))
                return
            }

            // Step 3: All files gone — safe to delete DB rows
            try deleteKeyframeRows(sourceSegment: sourceSegment)

            if deleted > 0 {
                DiagnosticsStore.shared.increment("retention_keyframes_deleted_total", by: Int64(deleted))
                logger.info("Deleted \(deleted) keyframes for \(sourceSegment)")
            }

            // Step 4: Update the video segment to cold tier
            try updateVideoSegmentTier(filePath: sourceSegment, tier: "cold")
        } catch {
            logger.error("Failed to delete keyframes for \(sourceSegment): \(error)")
        }
    }
}
