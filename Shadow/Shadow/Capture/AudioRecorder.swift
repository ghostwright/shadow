@preconcurrency import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "AudioRecorder")

/// Audio source type for Track 4 events.
enum AudioSource: String {
    case microphone = "mic"
    case system = "system"
}

/// Manages mic-active audio recording lifecycle (M4-A1: mic capture only).
///
/// Trigger model (no-gap):
/// 1. MicActivityMonitor detects mic activation via CoreAudio's
///    `kAudioDevicePropertyDeviceIsRunningSomewhere` (rising edge only).
/// 2. AudioRecorder starts AVCaptureSession for mic capture.
/// 3. While recording, KVO-observes `AVCaptureDevice.isInUseByAnotherApplication`
///    with a 2-second polling fallback. When it becomes `false` (only Shadow is
///    using the mic), starts a 30-second cooldown. If the property stays `false`
///    for the full cooldown, capture stops. If it goes back to `true` (another app
///    restarted mic), cooldown is cancelled.
/// 4. No capture interruptions. No gaps. No periodic stop/restart.
///
/// Self-trigger safety:
/// `isInUseByAnotherApplication` correctly excludes our own process. When only
/// Shadow is using the mic (external app stopped), it returns `false`. This is
/// the definitive signal that external usage ended.
///
/// File format: AAC in m4a container (48kHz mono, 128kbps).
/// Storage: `~/.shadow/data/media/audio/<timestamp>-<us>.m4a`.
/// Segment metadata: SQLite audio_segments table via Rust UniFFI.
/// Track 4 events: `audio_segment_open` / `audio_segment_close`.
/// Hourly rotation prevents unbounded file sizes.
/// Orphan segments (end_ts = 0) finalized on startup for crash safety.
///
/// Thread safety:
/// - Public API is `@MainActor`.
/// - AVCaptureSession delegate fires on a dedicated serial queue.
/// - AVAssetWriter access is confined to the capture queue.
@MainActor
final class AudioRecorder {
    /// Whether the recorder is started (monitoring for mic activity).
    private(set) var isStarted = false

    /// Whether the recorder is paused (user-initiated).
    private(set) var isPaused = false

    /// Whether audio capture is currently active (writing to file).
    private(set) var isCapturing = false

    private let micMonitor = MicActivityMonitor()
    private let dataDir: String

    // MARK: - Capture session state

    private var captureSession: AVCaptureSession?
    private var captureDevice: AVCaptureDevice?
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var sessionStarted = false

    /// Serial queue for AVCaptureSession delegate callbacks and writer access.
    private let captureQueue = DispatchQueue(label: "com.shadow.audio.capture", qos: .utility)

    /// Delegate that receives audio buffers and writes to AVAssetWriter.
    private var outputDelegate: AudioOutputDelegate?

    // MARK: - External usage observation

    /// KVO observation on AVCaptureDevice.isInUseByAnotherApplication.
    private var externalUsageObservation: NSKeyValueObservation?

    /// Polling fallback timer for external usage detection (2-second interval).
    /// Supplements KVO in case it doesn't fire reliably on all hardware.
    private var externalUsagePollTimer: Timer?

    /// Cooldown timer: fires when external usage has been false for the cooldown window.
    private var deactivationCooldownTimer: Timer?

    /// Cooldown duration before stopping capture after external usage ends (seconds).
    private let deactivationCooldown: TimeInterval = 30.0

    /// Polling interval for external usage fallback (seconds).
    private let externalUsagePollInterval: TimeInterval = 2.0

    // MARK: - Segment state

    private var currentSegmentPath: String?
    private var segmentStartTs: UInt64 = 0

    /// Timer for hourly rotation of audio segments.
    private var rotationTimer: Timer?

    /// Maximum segment duration before forced rotation (1 hour).
    private let maxSegmentDuration: TimeInterval = 3600.0

    // MARK: - Lifecycle

    init(dataDir: String) {
        self.dataDir = dataDir
    }

    /// Start the audio recorder. Begins monitoring for mic activity.
    /// Call from AppDelegate.startAllCapture().
    func start() {
        guard !isStarted else { return }

        // Finalize any orphan segments from a previous crash
        finalizeOrphanSegments()

        // Wire mic activity callbacks
        micMonitor.onMicActive = { [weak self] in
            self?.handleMicActive()
        }
        micMonitor.onMicInactive = { [weak self] in
            self?.handleMicInactive()
        }
        micMonitor.start()

        isStarted = true
        DiagnosticsStore.shared.setGauge("audio_capture_active", value: 0)
        logger.info("AudioRecorder started — monitoring for mic activity")
    }

    /// Stop the audio recorder. Finalizes any active segment.
    /// Awaits writer finalization before returning.
    /// Safe to call after pause() — always drains the writer if one exists.
    /// Call from AppDelegate.applicationShouldTerminate().
    func stop() async {
        guard isStarted else { return }
        isStarted = false

        micMonitor.stop()

        // Always await writer drain — a writer may still be open even when
        // isCapturing is false (e.g., pause() dispatched async finishWriting).
        await stopCaptureAndAwaitWriter()

        DiagnosticsStore.shared.setGauge("audio_capture_active", value: 0)
        logger.info("AudioRecorder stopped")
    }

    /// Pause audio recording (user-initiated pause).
    func pause() {
        isPaused = true
        if isCapturing {
            stopCapture()
        }
    }

    /// Resume audio recording (user-initiated resume).
    func resume() {
        isPaused = false
        // If mic is still active, restart capture
        if micMonitor.isMicActive {
            handleMicActive()
        }
    }

    // MARK: - Mic Activity Handlers

    private func handleMicActive() {
        guard isStarted, !isPaused else { return }
        guard !isCapturing else { return }

        startCapture()
    }

    private func handleMicInactive() {
        // This fires when CoreAudio property goes false.
        // While we are capturing, the property stays true (self-trigger),
        // so this only fires when we are NOT capturing. Safe to act on directly.
        guard isCapturing else { return }
        stopCapture()
    }

    // MARK: - Capture Start/Stop

    private func startCapture() {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            logger.error("No audio capture device available")
            DiagnosticsStore.shared.increment("audio_capture_fail_total")
            return
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            logger.error("Failed to create audio input: \(error, privacy: .public)")
            DiagnosticsStore.shared.increment("audio_capture_fail_total")
            return
        }

        let session = AVCaptureSession()
        guard session.canAddInput(input) else {
            logger.error("Cannot add audio input to session")
            DiagnosticsStore.shared.increment("audio_capture_fail_total")
            return
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        guard session.canAddOutput(output) else {
            logger.error("Cannot add audio output to session")
            DiagnosticsStore.shared.increment("audio_capture_fail_total")
            return
        }
        session.addOutput(output)

        // Generate collision-proof file path (microsecond timestamp)
        let filePath = generateFilePath()
        let fileURL = URL(fileURLWithPath: filePath)

        // Create asset writer for AAC output
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: fileURL, fileType: .m4a)
        } catch {
            logger.error("Failed to create AVAssetWriter: \(error, privacy: .public)")
            DiagnosticsStore.shared.increment("audio_capture_fail_total")
            return
        }

        // AAC encoding settings: 48kHz mono, 128kbps
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(writerInput) else {
            logger.error("Cannot add writer input to AVAssetWriter")
            DiagnosticsStore.shared.increment("audio_capture_fail_total")
            return
        }
        writer.add(writerInput)
        writer.startWriting()

        // Register segment in index BEFORE committing to capture state.
        // If this fails, roll back: stop session, cancel writer, delete partial file.
        let now = CaptureSessionClock.wallMicros()
        do {
            _ = try insertAudioSegment(
                source: AudioSource.microphone.rawValue,
                startTs: now,
                filePath: filePath,
                displayId: nil,
                sampleRate: 48000,
                channels: 1
            )
        } catch {
            logger.error("Failed to register audio segment — rolling back capture: \(error, privacy: .public)")
            DiagnosticsStore.shared.increment("audio_capture_fail_total")
            session.stopRunning()
            writer.cancelWriting()
            try? FileManager.default.removeItem(atPath: filePath)
            return
        }

        self.captureSession = session
        self.captureDevice = device
        self.assetWriter = writer
        self.writerInput = writerInput
        self.sessionStarted = false

        // Set up delegate
        let delegate = AudioOutputDelegate(
            writerInput: writerInput,
            onFirstSample: { [weak self] time in
                writer.startSession(atSourceTime: time)
                Task { @MainActor in
                    self?.sessionStarted = true
                }
            }
        )
        self.outputDelegate = delegate
        output.setSampleBufferDelegate(delegate, queue: captureQueue)

        // Start capture
        session.startRunning()

        segmentStartTs = now
        currentSegmentPath = filePath
        isCapturing = true

        EventWriter.audioEvent(
            type: "audio_segment_open",
            source: .microphone,
            details: [
                "file_path": .string(filePath),
                "sample_rate": .uint32(48000),
                "channels": .uint32(1),
            ]
        )

        // Schedule hourly rotation
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(
            withTimeInterval: maxSegmentDuration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rotateSegment()
            }
        }

        // Observe isInUseByAnotherApplication for deactivation detection.
        // KVO + polling fallback for reliable detection across all hardware.
        startExternalUsageObservation(device: device)

        DiagnosticsStore.shared.increment("audio_segments_opened_total")
        DiagnosticsStore.shared.setGauge("audio_capture_active", value: 1)
        logger.info("Audio capture started: \(filePath)")
    }

    /// Stop capture without awaiting writer finalization.
    /// Used for rotation, pause, and deactivation cooldown (non-shutdown paths).
    private func stopCapture() {
        guard let session = captureSession else { return }

        rotationTimer?.invalidate()
        rotationTimer = nil
        stopExternalUsageObservation()

        // Stop the capture session (synchronous — stops buffer delivery)
        session.stopRunning()

        // Finalize writer on capture queue to drain pending buffers
        let writer = assetWriter
        let input = self.writerInput

        captureQueue.async {
            input?.markAsFinished()
            writer?.finishWriting {
                if let error = writer?.error {
                    logger.error("AVAssetWriter finish error: \(error, privacy: .public)")
                }
            }
        }

        finalizeSegmentState()
    }

    /// Stop capture and await writer finalization. Used for shutdown.
    /// Safe to call when no capture is active — drains the capture queue
    /// to ensure any in-flight finishWriting (from pause) has completed.
    private func stopCaptureAndAwaitWriter() async {
        if let session = captureSession {
            rotationTimer?.invalidate()
            rotationTimer = nil
            stopExternalUsageObservation()

            // Stop the capture session (synchronous — stops buffer delivery)
            session.stopRunning()

            // Finalize writer on capture queue, awaiting completion
            let writer = assetWriter
            let input = self.writerInput

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                captureQueue.async {
                    input?.markAsFinished()
                    guard let writer else {
                        continuation.resume()
                        return
                    }
                    writer.finishWriting {
                        if let error = writer.error {
                            logger.error("AVAssetWriter finish error: \(error, privacy: .public)")
                        }
                        continuation.resume()
                    }
                }
            }

            finalizeSegmentState()
        } else {
            // No active capture session, but a previous stopCapture() may have
            // dispatched finishWriting async. Drain the capture queue to ensure
            // any in-flight work completes before shutdown proceeds.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                captureQueue.async {
                    continuation.resume()
                }
            }
        }
    }

    /// Common segment finalization after capture stops (both sync and async paths).
    private func finalizeSegmentState() {
        // Clear capture state
        captureSession = nil
        captureDevice = nil
        assetWriter = nil
        self.writerInput = nil
        outputDelegate = nil
        sessionStarted = false
        isCapturing = false

        // Finalize segment in index
        guard let path = currentSegmentPath else { return }
        let now = CaptureSessionClock.wallMicros()
        let durationUs = now >= segmentStartTs ? now - segmentStartTs : 0

        do {
            try finalizeAudioSegment(filePath: path, endTs: now)
        } catch {
            logger.error("Failed to finalize audio segment: \(error, privacy: .public)")
        }

        EventWriter.audioEvent(
            type: "audio_segment_close",
            source: .microphone,
            details: [
                "file_path": .string(path),
                "duration_us": .uint64(durationUs),
            ]
        )

        currentSegmentPath = nil
        DiagnosticsStore.shared.increment("audio_segments_closed_total")
        DiagnosticsStore.shared.setGauge("audio_capture_active", value: 0)
        logger.info("Audio capture stopped: \(path) (duration: \(durationUs / 1_000_000)s)")
    }

    // MARK: - External Usage Observation (isInUseByAnotherApplication)

    /// Start KVO observation + polling fallback on AVCaptureDevice.isInUseByAnotherApplication.
    /// When this becomes `false`, only Shadow is using the mic. After cooldown,
    /// capture stops. When it's `true`, another app is also using the mic.
    private func startExternalUsageObservation(device: AVCaptureDevice) {
        stopExternalUsageObservation()

        // KVO observation (primary)
        externalUsageObservation = device.observe(
            \.isInUseByAnotherApplication,
            options: [.new]
        ) { [weak self] device, _ in
            let inUse = device.isInUseByAnotherApplication
            Task { @MainActor in
                self?.handleExternalUsageChanged(inUse)
            }
        }

        // Polling fallback (2-second interval) — catches cases where KVO
        // doesn't fire reliably on all hardware configurations.
        externalUsagePollTimer = Timer.scheduledTimer(
            withTimeInterval: externalUsagePollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCapturing, let device = self.captureDevice else { return }
                self.handleExternalUsageChanged(device.isInUseByAnotherApplication)
            }
        }

        // Check initial state: if external usage is already false (race condition
        // where the external app stopped between MicActivityMonitor trigger and
        // capture start), begin cooldown immediately.
        if !device.isInUseByAnotherApplication {
            logger.info("External mic usage already ended at capture start — starting cooldown")
            scheduleDeactivationCooldown()
        }
    }

    private func stopExternalUsageObservation() {
        externalUsageObservation?.invalidate()
        externalUsageObservation = nil
        externalUsagePollTimer?.invalidate()
        externalUsagePollTimer = nil
        cancelDeactivationCooldown()
    }

    private func handleExternalUsageChanged(_ isInUseByOther: Bool) {
        guard isCapturing else { return }

        if isInUseByOther {
            // Another app started using the mic — cancel any pending cooldown
            cancelDeactivationCooldown()
            logger.debug("External mic usage resumed — cooldown cancelled")
        } else {
            // Only Shadow is using the mic now — start cooldown
            // (scheduleDeactivationCooldown is idempotent — won't double-schedule)
            scheduleDeactivationCooldown()
        }
    }

    private func scheduleDeactivationCooldown() {
        guard deactivationCooldownTimer == nil else { return }

        logger.debug("External mic usage ended — starting \(self.deactivationCooldown)s cooldown")
        deactivationCooldownTimer = Timer.scheduledTimer(
            withTimeInterval: deactivationCooldown,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.deactivationCooldownTimer = nil

                // Final check: re-verify external usage hasn't resumed during cooldown
                if let device = self.captureDevice, device.isInUseByAnotherApplication {
                    logger.debug("Cooldown expired but external usage resumed — continuing")
                    return
                }

                logger.info("Deactivation cooldown expired — stopping capture")
                self.stopCapture()
            }
        }
    }

    private func cancelDeactivationCooldown() {
        deactivationCooldownTimer?.invalidate()
        deactivationCooldownTimer = nil
    }

    // MARK: - Segment Rotation

    /// Rotate the current audio segment (hourly boundary).
    /// Stops current capture and immediately starts a new segment.
    private func rotateSegment() {
        guard isCapturing else { return }
        logger.info("Rotating audio segment (hourly cap)")
        stopCapture()

        // If mic is still active and we're not paused, start a new segment
        if isStarted && !isPaused {
            startCapture()
        }
    }

    // MARK: - Crash Safety

    /// Finalize any audio segments that have end_ts = 0 (orphans from crash).
    private func finalizeOrphanSegments() {
        do {
            let count = try listOrphanAudioSegments()
            if count > 0 {
                logger.warning("Finalized \(count) orphan audio segment(s) from previous session")
                DiagnosticsStore.shared.increment("audio_orphan_closed_total", by: Int64(count))
            }
        } catch {
            logger.error("Failed to finalize orphan audio segments: \(error, privacy: .public)")
        }
    }

    // MARK: - File Path Generation

    /// Generate a collision-proof file path with microsecond timestamp.
    private func generateFilePath() -> String {
        let audioDir = (dataDir as NSString).appendingPathComponent("media/audio")

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            atPath: audioDir,
            withIntermediateDirectories: true
        )

        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.timeZone = TimeZone.current
        let timestamp = formatter.string(from: now)

        // Append microseconds for collision safety during rapid rotation
        let microseconds = Int(now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 1_000_000)
        return (audioDir as NSString).appendingPathComponent("\(timestamp)-\(String(format: "%06d", microseconds)).m4a")
    }
}

// MARK: - AVCaptureAudioDataOutput Delegate

/// Receives audio sample buffers from AVCaptureSession and writes them to AVAssetWriter.
/// Confined to the capture queue — no locking needed.
private final class AudioOutputDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let writerInput: AVAssetWriterInput
    private let onFirstSample: (CMTime) -> Void
    private var firstSampleReceived = false

    init(writerInput: AVAssetWriterInput, onFirstSample: @escaping (CMTime) -> Void) {
        self.writerInput = writerInput
        self.onFirstSample = onFirstSample
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if !firstSampleReceived {
            firstSampleReceived = true
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            onFirstSample(time)
        }

        if writerInput.isReadyForMoreMediaData {
            writerInput.append(sampleBuffer)
        }
    }
}
