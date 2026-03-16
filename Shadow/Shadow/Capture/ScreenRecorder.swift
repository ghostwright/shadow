@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ScreenRecorder")

// MARK: - Per-Display Capture Handler

/// Manages capture and MP4 writing for a single display.
/// Each display gets its own SCStream, AVAssetWriter, and output delegate.
///
/// Video files use **fragmented MP4** (movieFragmentInterval) so the file is
/// always valid and seekable, even while being written. If the app crashes,
/// at most one fragment interval (~10 seconds) of data is lost.
///
/// Each recording session produces one file named by its start timestamp:
///   `display-N/YYYY-MM-DDTHH-mm-ss.mp4`
/// Files are rotated at hour boundaries for manageable sizes.
/// A SQLite `video_segments` table indexes all segments for O(1) timestamp lookup.
///
/// Thread safety model:
/// - All mutable writer state (assetWriter, writerInput, currentHour, sessionStarted)
///   is accessed exclusively from writerQueue.
/// - isPaused is written from the main actor and read from the capture queue.
///   This is a benign race — worst case is one extra/missed frame at 0.5fps.
/// - @unchecked Sendable because we enforce safety via queue discipline,
///   which the compiler can't verify.
final class DisplayCaptureHandler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let captureWidth: Int
    let captureHeight: Int

    private(set) var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var currentHour: Int = -1
    private var sessionStarted = false
    /// Wall-clock microseconds when the current writer was created (for segment index).
    private var writerStartUs: UInt64 = 0
    private let dataDir: URL

    /// Serial queue protecting all writer state mutations.
    private let writerQueue = DispatchQueue(label: "com.shadow.writer", qos: .utility)

    /// Written from main actor, read from capture queue. Benign race.
    var isPaused = false

    init(displayID: CGDirectDisplayID, captureWidth: Int, captureHeight: Int, dataDir: URL) {
        self.displayID = displayID
        self.captureWidth = captureWidth
        self.captureHeight = captureHeight
        self.dataDir = dataDir
        super.init()
    }

    // MARK: - Stream Lifecycle

    func startStream(for display: SCDisplay, queue: DispatchQueue, captureAudio: Bool = false) async throws {
        let config = SCStreamConfiguration()
        config.width = captureWidth
        config.height = captureHeight
        config.minimumFrameInterval = CMTime(value: 2, timescale: 1) // 0.5 fps
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true

        if captureAudio {
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()

        self.stream = stream
        logger.info("Started capture for display \(self.displayID, privacy: .public)")
    }

    func stopStream() async {
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                logger.error("Error stopping stream for display \(self.displayID, privacy: .public): \(error, privacy: .public)")
            }
        }
        stream = nil
        await finalizeWriter()
        logger.info("Stopped capture for display \(self.displayID, privacy: .public)")
    }

    // MARK: - SCStreamOutput (called from captureQueue)

    /// System audio writer that receives .audio buffers from this handler's stream.
    /// Set only on the designated audio handler (primary display).
    var systemAudioWriter: SystemAudioWriter?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            systemAudioWriter?.handleAudioBuffer(sampleBuffer)
            return
        }
        guard type == .screen else { return }
        guard !isPaused else { return }

        // ScreenCaptureKit may deliver status-only buffers with no image data
        guard sampleBuffer.isValid,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            return
        }

        writerQueue.async { [self] in
            self.processFrame(sampleBuffer)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Stream stopped with error for display \(self.displayID, privacy: .public): \(error, privacy: .public)")
        self.stream = nil
    }

    // MARK: - Frame Processing (runs on writerQueue)

    private func processFrame(_ sampleBuffer: CMSampleBuffer) {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)

        // Rotate writer at hour boundaries for manageable file sizes
        if hour != currentHour && currentHour != -1 {
            rotateWriter()
        }

        // Create writer on demand (first frame, or after rotation)
        if assetWriter == nil {
            do {
                try createWriter(for: now)
            } catch {
                logger.error("Failed to create writer for display \(self.displayID, privacy: .public): \(error, privacy: .public)")
                return
            }
        }

        guard let writer = assetWriter, let input = writerInput else { return }

        // Start session with the first frame's presentation timestamp
        if !sessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }

        // Append frame
        if writer.status == .writing && input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        } else if writer.status == .failed {
            logger.error("Writer failed for display \(self.displayID, privacy: .public): \(String(describing: writer.error), privacy: .public)")
        }
    }

    // MARK: - Writer Management (runs on writerQueue)

    private func createWriter(for date: Date) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let timestamp = formatter.string(from: date)
        let hour = Calendar.current.component(.hour, from: date)

        let dir = dataDir
            .appendingPathComponent("media/video/display-\(displayID)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Each recording session gets a unique file named by its start time.
        // No collisions, no suffix variants needed.
        let filename = "\(timestamp).mp4"
        let url = dir.appendingPathComponent(filename)

        let writer = try AVAssetWriter(url: url, fileType: .mp4)

        // Fragmented MP4: write a movie fragment every 10 seconds.
        // This makes the file always valid and seekable, even while being written.
        // If the app crashes, at most 10 seconds of data is lost (not the entire file).
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 1)

        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: captureWidth,
            AVVideoHeightKey: captureHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 300_000,
                AVVideoExpectedSourceFrameRateKey: 1,
            ] as [String: Any]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "ScreenRecorder", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter failed to start"])
        }

        self.assetWriter = writer
        self.writerInput = input
        self.currentHour = hour
        self.sessionStarted = false
        self.writerStartUs = UInt64(date.timeIntervalSince1970 * 1_000_000)

        // Register the segment in the index
        let filePath = url.path
        do {
            try insertVideoSegment(displayId: UInt32(displayID), startTs: writerStartUs, filePath: filePath)
        } catch {
            logger.error("Failed to register video segment: \(error, privacy: .public)")
        }

        logger.info("Created writer: \(filename, privacy: .public) for display \(self.displayID, privacy: .public)")
    }

    /// Rotate to a new hourly MP4 segment. Old writer is finalized asynchronously.
    private func rotateWriter() {
        let oldWriter = assetWriter
        let oldInput = writerInput

        assetWriter = nil
        writerInput = nil
        sessionStarted = false

        if let oldWriter, let oldInput {
            let endTs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            let filePath = oldWriter.outputURL.path
            oldInput.markAsFinished()
            oldWriter.finishWriting {
                if oldWriter.status == .failed {
                    logger.error("Failed to finalize rotated writer: \(String(describing: oldWriter.error), privacy: .public)")
                } else {
                    logger.info("Finalized rotated writer: \(oldWriter.outputURL.lastPathComponent, privacy: .public)")
                }
                // Update segment end time in the index
                do {
                    try finalizeVideoSegment(filePath: filePath, endTs: endTs)
                } catch {
                    logger.error("Failed to finalize video segment index on rotation: \(error, privacy: .public)")
                }
            }
        }
    }

    /// Finalize the current writer. Called during async shutdown via stopStream().
    /// Routes through writerQueue to drain any pending frame writes before finalizing.
    func finalizeWriter() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async { [self] in
                guard let writer = self.assetWriter, let input = self.writerInput else {
                    continuation.resume()
                    return
                }

                let endTs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
                let filePath = writer.outputURL.path

                self.assetWriter = nil
                self.writerInput = nil
                self.sessionStarted = false

                input.markAsFinished()
                writer.finishWriting {
                    if writer.status == .failed {
                        logger.error("Failed to finalize writer on stop: \(String(describing: writer.error), privacy: .public)")
                    } else {
                        logger.info("Finalized writer on stop: \(writer.outputURL.lastPathComponent, privacy: .public)")
                    }
                    // Update segment end time in the index
                    do {
                        try finalizeVideoSegment(filePath: filePath, endTs: endTs)
                    } catch {
                        logger.error("Failed to finalize video segment index on stop: \(error, privacy: .public)")
                    }
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - Screen Recorder (Orchestrator)

/// Manages screen capture across all connected displays.
/// Handles display hotplug (connect/disconnect) and sleep/wake gracefully.
///
/// @MainActor because:
/// - All public API is called from AppDelegate / SwiftUI (main thread)
/// - All notification handlers fire on the main thread
/// - The handlers dictionary must be accessed from a single isolation domain
/// - Heavy work (frame encoding, file I/O) happens in DisplayCaptureHandler on background queues
@MainActor
final class ScreenRecorder: NSObject {
    private var handlers: [CGDirectDisplayID: DisplayCaptureHandler] = [:]
    private let captureQueue = DispatchQueue(label: "com.shadow.capture", qos: .userInitiated)
    private let dataDir: URL

    private(set) var isRecording = false
    private var isPaused = false
    /// Tracks whether the user explicitly paused via the UI (vs system sleep).
    /// didWake() only auto-resumes if the user hadn't manually paused.
    private var userPaused = false

    /// System audio writer — receives SCK audio buffers from the designated primary display handler.
    /// Lifecycle managed by AppDelegate; ScreenRecorder just wires the buffer routing.
    var systemAudioWriter: SystemAudioWriter?

    /// Display ID of the handler designated for audio capture. Set once during startCapture.
    private var audioDesignatedDisplayID: CGDirectDisplayID?

    init(dataDir: String) {
        self.dataDir = URL(fileURLWithPath: dataDir)
        super.init()
        setupNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Public API

    /// Start recording all connected displays.
    /// Throws if Screen Recording permission is not granted.
    /// On partial failure (some displays started, one throws), cleans up
    /// all already-started handlers before rethrowing.
    func startCapture() async throws {
        guard !isRecording else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Designate primary display (first in list) for system audio capture
        let primaryDisplayID = content.displays.first?.displayID
        audioDesignatedDisplayID = primaryDisplayID

        do {
            for display in content.displays {
                let isAudioDesignated = display.displayID == primaryDisplayID && systemAudioWriter != nil
                try await startCaptureForDisplay(display, captureAudio: isAudioDesignated)
            }
        } catch {
            // Partial failure: some displays may have started. Stop them all
            // before rethrowing so we don't orphan live streams.
            if !handlers.isEmpty {
                logger.warning("Partial capture failure — stopping \(self.handlers.count) already-started display(s)")
                for (_, handler) in handlers {
                    await handler.stopStream()
                }
                handlers.removeAll()
            }
            throw error
        }

        isRecording = true
        logger.info("Screen recording started (\(content.displays.count, privacy: .public) display(s), audio on display \(primaryDisplayID ?? 0, privacy: .public))")
    }

    /// Stop recording all displays and finalize all MP4 files.
    func stopCapture() async {
        guard isRecording else { return }
        isRecording = false

        for (_, handler) in handlers {
            await handler.stopStream()
        }
        handlers.removeAll()

        logger.info("Screen recording stopped")
    }

    /// Pause recording (user toggle). Streams stay alive but frames are dropped.
    func pause() {
        userPaused = true
        isPaused = true
        for handler in handlers.values {
            handler.isPaused = true
        }
        logger.info("Screen recording paused")
    }

    /// Resume recording after pause. Also reconciles displays in case
    /// streams died while paused (e.g., sleep during pause).
    func resume() {
        userPaused = false
        isPaused = false
        for handler in handlers.values {
            handler.isPaused = false
        }
        logger.info("Screen recording resumed")

        // Streams may have died while we were paused (e.g., system sleep
        // kills SCK streams). Reconcile to restart dead captures.
        if isRecording {
            Task {
                await reconcileDisplays()
            }
        }
    }

    // MARK: - Display Management

    private func startCaptureForDisplay(_ display: SCDisplay, captureAudio: Bool = false) async throws {
        let displayID = display.displayID
        guard handlers[displayID] == nil else { return }

        // SCDisplay dimensions are in points. Convert to pixels via backing scale factor.
        let scale = screenScaleFactor(for: displayID)
        let pixelWidth = Int(CGFloat(display.width) * scale)
        let pixelHeight = Int(CGFloat(display.height) * scale)

        // Half resolution for storage efficiency
        let captureWidth = pixelWidth / 2
        let captureHeight = pixelHeight / 2

        let handler = DisplayCaptureHandler(
            displayID: displayID,
            captureWidth: captureWidth,
            captureHeight: captureHeight,
            dataDir: dataDir
        )
        handler.isPaused = isPaused

        // Wire system audio writer to designated handler
        if captureAudio {
            handler.systemAudioWriter = systemAudioWriter
        }

        // Register BEFORE the async stream start to prevent duplicate captures.
        // During await, the main actor can process other work (e.g., display change
        // notifications). If the handler isn't registered yet, reconcileDisplays()
        // would try to start a second capture for the same display.
        handlers[displayID] = handler

        do {
            try await handler.startStream(for: display, queue: captureQueue, captureAudio: captureAudio)
        } catch {
            handlers.removeValue(forKey: displayID)
            throw error
        }
    }

    /// Match display ID to NSScreen to get the backing scale factor.
    private func screenScaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               screenNumber == displayID {
                return screen.backingScaleFactor
            }
        }
        return 2.0 // Default Retina assumption
    }

    /// Re-enumerate displays and start/stop captures as needed.
    /// Also detects dead handlers (stream killed by system sleep) and removes them
    /// so a fresh capture can be started.
    private func reconcileDisplays() async {
        guard isRecording else { return }

        // Clean up dead handlers — SCK kills streams during sleep (error -3815),
        // leaving handlers with stream == nil. Remove them so startCaptureForDisplay
        // can create fresh ones.
        for (displayID, handler) in handlers where handler.stream == nil {
            handlers.removeValue(forKey: displayID)
            await handler.finalizeWriter()
            logger.info("Display \(displayID, privacy: .public) had dead stream — handler removed")
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let currentDisplayIDs = Set(content.displays.map { $0.displayID })
            let activeDisplayIDs = Set(handlers.keys)

            // Stop captures for disconnected displays
            for displayID in activeDisplayIDs.subtracting(currentDisplayIDs) {
                if let handler = handlers.removeValue(forKey: displayID) {
                    await handler.stopStream()
                    logger.info("Display \(displayID, privacy: .public) disconnected — capture stopped")
                }
            }

            // Start captures for newly connected (or dead-stream-recovered) displays.
            // Re-designate audio to the first new display if the audio-designated handler was removed.
            let needsAudioRedesignation = audioDesignatedDisplayID.map { !handlers.keys.contains($0) } ?? false
            var audioRedesignated = false

            for display in content.displays where !activeDisplayIDs.contains(display.displayID) {
                let shouldCaptureAudio = !audioRedesignated && needsAudioRedesignation && systemAudioWriter != nil
                do {
                    try await startCaptureForDisplay(display, captureAudio: shouldCaptureAudio)
                    if shouldCaptureAudio {
                        audioDesignatedDisplayID = display.displayID
                        audioRedesignated = true
                        logger.info("Audio capture re-designated to new display \(display.displayID, privacy: .public)")
                    }
                    logger.info("Display \(display.displayID, privacy: .public) capture started")
                } catch {
                    logger.error("Failed to start capture for display \(display.displayID, privacy: .public): \(error, privacy: .public)")
                }
            }

            // If audio still needs re-designation and no new display was started,
            // re-designate to an existing active handler by restarting its stream
            // with audio enabled. Brief video gap is acceptable on hotplug.
            if needsAudioRedesignation && !audioRedesignated && systemAudioWriter != nil {
                if let (existingID, existingHandler) = handlers.first,
                   let display = content.displays.first(where: { $0.displayID == existingID }) {
                    // Stop existing stream and restart with audio
                    await existingHandler.stopStream()
                    handlers.removeValue(forKey: existingID)
                    do {
                        try await startCaptureForDisplay(display, captureAudio: true)
                        audioDesignatedDisplayID = existingID
                        logger.info("Audio capture re-designated to existing display \(existingID, privacy: .public) (stream restarted)")
                    } catch {
                        // Restart without audio as fallback
                        logger.error("Failed to restart display \(existingID, privacy: .public) with audio: \(error, privacy: .public)")
                        do {
                            try await startCaptureForDisplay(display, captureAudio: false)
                        } catch {
                            logger.error("Failed to restart display \(existingID, privacy: .public): \(error, privacy: .public)")
                        }
                    }
                }
            }
        } catch {
            logger.error("Failed to enumerate displays during reconciliation: \(error, privacy: .public)")
        }
    }

    // MARK: - Notifications

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func displaysChanged() {
        guard isRecording, !isPaused else { return }
        Task {
            await reconcileDisplays()
        }
    }

    @objc private func willSleep() {
        logger.info("System sleeping — pausing handlers")
        // Emit sleep_start lifecycle event
        EventWriter.lifecycleEvent(type: "sleep_start")

        // Close open focus interval — no app is focused during sleep
        let now = CaptureSessionClock.wallMicros()
        do { try closeFocusInterval(endTs: now) } catch {
            logger.error("Failed to close focus interval on sleep: \(error)")
        }

        // Pause handlers so no frames are processed during sleep transition.
        // Do NOT set isPaused — that's user state. SCK will kill streams anyway.
        for handler in handlers.values {
            handler.isPaused = true
        }
    }

    @objc private func didWake() {
        logger.info("System woke (userPaused=\(self.userPaused, privacy: .public))")
        // Emit wake_end lifecycle event
        EventWriter.lifecycleEvent(type: "wake_end")

        // Check for clock drift after sleep — most common source of clock jumps
        if let clock = EventWriter.clock, let driftUs = clock.checkClockDrift() {
            let driftMs = driftUs / 1000
            logger.warning("Clock jump detected on wake: \(driftMs)ms drift")
            EventWriter.lifecycleEvent(type: "clock_jump_detected", details: [
                "drift_us": .int32(Int32(clamping: driftUs)),
                "trigger": .string("wake"),
            ])
            DiagnosticsStore.shared.postWarning(
                severity: .warning,
                subsystem: "CaptureSession",
                code: "CLOCK_JUMP_DETECTED",
                message: "Clock jump of \(driftMs)ms detected on wake"
            )
        }

        guard isRecording else { return }

        if !userPaused {
            // User wasn't paused before sleep — restore normal recording.
            isPaused = false
            for handler in handlers.values {
                handler.isPaused = false
            }
        }
        // else: User had paused before sleep — keep isPaused=true.
        // They'll call resume() explicitly when ready.

        // Always reconcile: SCK kills streams during sleep (error -3815).
        // Dead handlers need to be cleaned up and fresh streams started.
        Task {
            await reconcileDisplays()
        }
    }
}

// MARK: - Frame Cache

/// LRU cache for extracted video frames. Avoids redundant AVAssetImageGenerator
/// seeks when the user scrubs back and forth over the same region.
///
/// At 0.5fps, frames are 2 seconds apart. Timestamps are quantized to the nearest
/// 2-second boundary so nearby scrub positions hit the same cache entry.
/// Capacity of 10 frames covers a ~20-second window of cached content.
final class FrameCache: @unchecked Sendable {
    static let shared = FrameCache()

    private struct Key: Hashable {
        let displayID: UInt32
        let quantizedTimestamp: UInt64 // microseconds, quantized to 2-second intervals
    }

    private var cache: [Key: CGImage] = [:]
    private var accessOrder: [Key] = []
    private let capacity = 10
    private let lock = NSLock()

    /// Quantize a timestamp to the nearest 2-second frame boundary (in microseconds).
    static func quantize(_ timestampUs: UInt64) -> UInt64 {
        let interval: UInt64 = 2_000_000 // 2 seconds in microseconds
        return (timestampUs / interval) * interval
    }

    func get(displayID: UInt32, timestampUs: UInt64) -> CGImage? {
        let key = Key(displayID: displayID, quantizedTimestamp: Self.quantize(timestampUs))
        lock.lock()
        defer { lock.unlock() }

        guard let image = cache[key] else { return nil }

        // Move to end of access order (most recently used)
        if let idx = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: idx)
            accessOrder.append(key)
        }
        return image
    }

    func put(displayID: UInt32, timestampUs: UInt64, image: CGImage) {
        let key = Key(displayID: displayID, quantizedTimestamp: Self.quantize(timestampUs))
        lock.lock()
        defer { lock.unlock() }

        if cache[key] != nil {
            // Already cached, just update access order
            if let idx = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: idx)
                accessOrder.append(key)
            }
            return
        }

        // Evict oldest if at capacity
        while cache.count >= capacity, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }

        cache[key] = image
        accessOrder.append(key)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        accessOrder.removeAll()
    }
}

// MARK: - Frame Extraction

/// Extracts individual frames from recorded MP4 segments for timeline display.
///
/// Uses the `video_segments` SQLite index for O(1) timestamp-to-file lookup.
/// No directory scanning, no file guessing. The index is the source of truth.
///
/// All video files use fragmented MP4, so they are always readable — even the
/// actively-recording file. Seek offset = target_timestamp - segment.start_ts.
///
/// Results are cached in a 10-frame LRU cache (FrameCache) for fast re-scrubbing.
///
/// When a video file has been deleted by retention (warm tier), falls back to the
/// nearest keyframe JPEG via `findNearestKeyframe()`. Returns nil for cold tier
/// (no keyframes exist).
enum FrameExtractor {

    /// Extract a frame at the given absolute timestamp.
    /// - Parameters:
    ///   - timestamp: Unix timestamp (seconds) of the desired frame
    ///   - displayID: Which display's recording to use
    /// - Returns: A CGImage of the frame, or nil if no segment covers this timestamp
    static func extractFrame(at timestamp: TimeInterval, displayID: CGDirectDisplayID) async throws -> CGImage? {
        let timestampUs = UInt64(timestamp * 1_000_000)
        let displayID32 = UInt32(displayID)

        // Check cache first
        if let cached = FrameCache.shared.get(displayID: displayID32, timestampUs: timestampUs) {
            return cached
        }

        let segment: VideoSegment
        do {
            guard let found = try findVideoSegment(displayId: displayID32, timestampUs: timestampUs) else {
                // No segment row at all — try keyframe as last resort
                DiagnosticsStore.shared.increment("frame_no_segment_total")
                return loadKeyframeImage(displayID: displayID32, timestampUs: timestampUs)
            }
            segment = found
        } catch {
            DiagnosticsStore.shared.increment("frame_lookup_error_total")
            throw error
        }

        let url = URL(fileURLWithPath: segment.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Video file deleted by retention — fall back to keyframe JPEG.
            // This is the warm-tier path: segment row exists, file is gone.
            DiagnosticsStore.shared.increment("frame_file_missing_total")
            return loadKeyframeImage(displayID: displayID32, timestampUs: timestampUs)
        }

        // Hot tier: video file exists, extract frame from it
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 2, timescale: 1)
        generator.requestedTimeToleranceAfter = CMTime(value: 2, timescale: 1)

        // Seek offset = target time - segment start time.
        // The video's internal timeline starts at 0 from its first frame.
        let startSeconds = Double(segment.startTs) / 1_000_000
        let relativeSeconds = timestamp - startSeconds
        let time = CMTime(seconds: max(0, relativeSeconds), preferredTimescale: 600)

        do {
            let (image, _) = try await generator.image(at: time)
            FrameCache.shared.put(displayID: displayID32, timestampUs: timestampUs, image: image)
            return image
        } catch {
            DiagnosticsStore.shared.increment("frame_decode_fail_total")
            throw error
        }
    }

    /// Load a keyframe JPEG as fallback for warm-tier (video deleted) or cold-tier (returns nil).
    private static func loadKeyframeImage(displayID: UInt32, timestampUs: UInt64) -> CGImage? {
        guard let keyframePath = try? findNearestKeyframe(
            displayId: displayID,
            timestampUs: timestampUs
        ), !keyframePath.isEmpty else {
            // Cold tier or no keyframes: nothing to show
            return nil
        }

        guard let data = FileManager.default.contents(atPath: keyframePath),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  jpegDataProviderSource: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            DiagnosticsStore.shared.increment("frame_keyframe_load_fail_total")
            return nil
        }

        FrameCache.shared.put(displayID: displayID, timestampUs: timestampUs, image: image)
        DiagnosticsStore.shared.increment("frame_keyframe_fallback_total")
        return image
    }
}
