@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "SystemAudioWriter")

/// Single-owner component for system audio capture lifecycle (M4-A2).
///
/// Receives SCK audio CMSampleBuffers from a designated SCStream output and
/// writes AAC m4a files when the system output device is actively producing audio.
///
/// Architecture:
/// - Registered as `SCStreamOutput` with `type: .audio` on one designated stream.
/// - Receives ALL audio buffers from SCK (continuously, even during silence).
/// - Gates file writing based on `OutputActivityMonitor` signal:
///   - When output device becomes active → opens segment, starts writing.
///   - When output device becomes inactive (after cooldown) → closes segment, stops writing.
/// - Owns segment lifecycle end-to-end: file creation, AVAssetWriter, SQLite
///   registration, Track 4 events, diagnostics, orphan recovery.
///
/// File format: AAC in m4a container (48kHz stereo, 128kbps).
/// Storage: `~/.shadow/data/media/audio/<timestamp>-<us>.m4a`.
///
/// Thread safety:
/// - `handleAudioBuffer()` is called from the SCK capture queue.
/// - Activity state changes arrive on main actor from OutputActivityMonitor.
/// - All writer state is confined to `writerQueue` (serial).
/// - `isActive` flag bridges main-actor activity state to capture-queue reads.
///   This is a benign race — worst case is one extra/missed buffer at boundaries.
final class SystemAudioWriter: NSObject, @unchecked Sendable {

    // MARK: - Activity State

    /// Written from main actor, read from writerQueue. Benign race at boundaries.
    private(set) var isActive = false

    /// Whether the writer is paused (user-initiated via AppDelegate).
    /// Written from main actor, read from writerQueue.
    var isPaused = false

    // MARK: - Writer State (writerQueue confined)

    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var sessionStarted = false

    private let writerQueue = DispatchQueue(label: "com.shadow.audio.system.writer", qos: .utility)
    private let dataDir: String

    // MARK: - Segment State (writerQueue confined)

    private var currentSegmentPath: String?
    private var segmentStartTs: UInt64 = 0

    /// Current hour for hourly rotation detection.
    private var currentHour: Int = -1

    // MARK: - Activity Monitor

    private let activityMonitor = OutputActivityMonitor()

    /// Cooldown timer for deactivation (main actor).
    @MainActor private var deactivationTimer: Timer?

    /// Cooldown duration before closing segment after output goes inactive (seconds).
    private let deactivationCooldown: TimeInterval = 15.0

    // MARK: - Lifecycle

    init(dataDir: String) {
        self.dataDir = dataDir
        super.init()
    }

    /// Start monitoring system audio output activity.
    /// Call from AppDelegate.startAllCapture() after ScreenRecorder setup.
    @MainActor
    func start() {
        // Finalize any orphan system audio segments from a previous crash.
        // (Handled by the shared listOrphanAudioSegments which covers all sources.)

        activityMonitor.onActive = { [weak self] in
            Task { @MainActor in
                self?.handleOutputActive()
            }
        }
        activityMonitor.onInactive = { [weak self] in
            Task { @MainActor in
                self?.handleOutputInactive()
            }
        }
        activityMonitor.start()

        DiagnosticsStore.shared.setGauge("system_audio_capture_active", value: 0)
        logger.info("SystemAudioWriter started — monitoring output activity")
    }

    /// Stop and finalize any open segment. Awaits writer completion.
    /// Safe to call after pause() — always drains the writer if one exists.
    @MainActor
    func stop() async {
        activityMonitor.stop()
        deactivationTimer?.invalidate()
        deactivationTimer = nil
        isActive = false

        // Always await finalization — a writer may be open even when isActive is false
        // (e.g., pause() dispatched async closeSegment() that hasn't completed yet).
        await finalizeCurrentSegment()

        DiagnosticsStore.shared.setGauge("system_audio_capture_active", value: 0)
        logger.info("SystemAudioWriter stopped")
    }

    /// Pause writing (user-initiated). Closes any active segment.
    @MainActor
    func pause() {
        isPaused = true
        if isActive {
            isActive = false
            deactivationTimer?.invalidate()
            deactivationTimer = nil
            writerQueue.async { self.closeSegment() }
        }
    }

    /// Resume writing (user-initiated).
    @MainActor
    func resume() {
        isPaused = false
        // If output is currently active, re-open a segment
        if activityMonitor.isOutputActive {
            handleOutputActive()
        }
    }

    // MARK: - SCK Audio Buffer Handling

    /// Called from the SCK capture queue when an audio sample buffer arrives.
    /// This is the SCStreamOutput handler for `.audio` type.
    func handleAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isActive, !isPaused else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        writerQueue.async { [self] in
            self.processAudioSample(sampleBuffer)
        }
    }

    // MARK: - Writer Operations (writerQueue confined)

    private func processAudioSample(_ sampleBuffer: CMSampleBuffer) {
        // Check hourly rotation
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        if hour != currentHour && currentHour != -1 {
            rotateSegment()
        }

        // Create writer on demand (first buffer after activation, or after rotation)
        if assetWriter == nil {
            do {
                try createWriter(for: now)
            } catch {
                logger.error("Failed to create system audio writer: \(error, privacy: .public)")
                DiagnosticsStore.shared.increment("system_audio_capture_fail_total")
                return
            }
        }

        guard let writer = assetWriter, let input = writerInput else { return }

        // Start session with first buffer's presentation timestamp
        if !sessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }

        // Append audio
        if writer.status == .writing && input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        } else if writer.status == .failed {
            logger.error("System audio writer failed: \(String(describing: writer.error), privacy: .public)")
        }
    }

    private func createWriter(for date: Date) throws {
        let filePath = generateFilePath(for: date)
        let fileURL = URL(fileURLWithPath: filePath)

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .m4a)

        // AAC encoding: 48kHz stereo, 128kbps (system audio is naturally stereo)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw NSError(domain: "SystemAudioWriter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input to writer"])
        }
        writer.add(input)
        writer.startWriting()

        // Register segment in SQLite — fail-fast on index failure
        let now = CaptureSessionClock.wallMicros()
        do {
            _ = try insertAudioSegment(
                source: AudioSource.system.rawValue,
                startTs: now,
                filePath: filePath,
                displayId: nil,
                sampleRate: 48000,
                channels: 2
            )
        } catch {
            logger.error("Failed to register system audio segment — rolling back: \(error, privacy: .public)")
            DiagnosticsStore.shared.increment("system_audio_capture_fail_total")
            writer.cancelWriting()
            try? FileManager.default.removeItem(atPath: filePath)
            throw error
        }

        self.assetWriter = writer
        self.writerInput = input
        self.currentHour = Calendar.current.component(.hour, from: date)
        self.sessionStarted = false
        self.segmentStartTs = now
        self.currentSegmentPath = filePath

        EventWriter.audioEvent(
            type: "audio_segment_open",
            source: .system,
            details: [
                "file_path": .string(filePath),
                "sample_rate": .uint32(48000),
                "channels": .uint32(2),
            ]
        )

        DiagnosticsStore.shared.increment("system_audio_segments_opened_total")
        DiagnosticsStore.shared.setGauge("system_audio_capture_active", value: 1)
        logger.info("System audio segment opened: \(filePath)")
    }

    /// Close the current segment. Called from writerQueue.
    private func closeSegment() {
        guard let writer = assetWriter, let input = writerInput else { return }
        let path = currentSegmentPath

        input.markAsFinished()
        writer.finishWriting {
            if let error = writer.error {
                logger.error("System audio writer finish error: \(error, privacy: .public)")
            }
        }

        assetWriter = nil
        writerInput = nil
        sessionStarted = false
        currentHour = -1

        guard let path else { return }
        let now = CaptureSessionClock.wallMicros()
        let durationUs = now >= segmentStartTs ? now - segmentStartTs : 0

        do {
            try finalizeAudioSegment(filePath: path, endTs: now)
        } catch {
            logger.error("Failed to finalize system audio segment: \(error, privacy: .public)")
        }

        EventWriter.audioEvent(
            type: "audio_segment_close",
            source: .system,
            details: [
                "file_path": .string(path),
                "duration_us": .uint64(durationUs),
            ]
        )

        currentSegmentPath = nil
        DiagnosticsStore.shared.increment("system_audio_segments_closed_total")
        DiagnosticsStore.shared.setGauge("system_audio_capture_active", value: 0)
        logger.info("System audio segment closed: \(path) (duration: \(durationUs / 1_000_000)s)")
    }

    /// Close and await writer finalization. Called from main actor for shutdown.
    private func finalizeCurrentSegment() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async { [self] in
                guard let writer = self.assetWriter, let input = self.writerInput else {
                    continuation.resume()
                    return
                }
                let path = self.currentSegmentPath

                input.markAsFinished()
                writer.finishWriting {
                    if let error = writer.error {
                        logger.error("System audio writer finish error on stop: \(error, privacy: .public)")
                    }

                    // Finalize segment index
                    if let path {
                        let now = CaptureSessionClock.wallMicros()
                        let durationUs = now >= self.segmentStartTs ? now - self.segmentStartTs : 0
                        do {
                            try finalizeAudioSegment(filePath: path, endTs: now)
                        } catch {
                            logger.error("Failed to finalize system audio segment on stop: \(error, privacy: .public)")
                        }
                        EventWriter.audioEvent(
                            type: "audio_segment_close",
                            source: .system,
                            details: [
                                "file_path": .string(path),
                                "duration_us": .uint64(durationUs),
                            ]
                        )
                        DiagnosticsStore.shared.increment("system_audio_segments_closed_total")
                    }

                    self.assetWriter = nil
                    self.writerInput = nil
                    self.sessionStarted = false
                    self.currentHour = -1
                    self.currentSegmentPath = nil
                    DiagnosticsStore.shared.setGauge("system_audio_capture_active", value: 0)

                    continuation.resume()
                }
            }
        }
    }

    /// Rotate to a new hourly segment. Called from writerQueue.
    private func rotateSegment() {
        logger.info("Rotating system audio segment (hourly cap)")
        closeSegment()
        // Next processAudioSample call will create a fresh writer
    }

    // MARK: - Activity Handlers (Main Actor)

    @MainActor
    private func handleOutputActive() {
        guard !isPaused else { return }

        // Cancel any pending deactivation cooldown
        deactivationTimer?.invalidate()
        deactivationTimer = nil

        guard !isActive else { return }

        isActive = true
        logger.info("System audio output active — segment will open on first buffer")
    }

    @MainActor
    private func handleOutputInactive() {
        guard isActive else { return }

        // Cancel any existing timer (idempotent)
        deactivationTimer?.invalidate()

        // Start cooldown — close segment only after sustained inactivity
        deactivationTimer = Timer.scheduledTimer(
            withTimeInterval: deactivationCooldown,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.deactivationTimer = nil

                // Final check: output may have resumed during cooldown
                if self.activityMonitor.isOutputActive {
                    logger.debug("Cooldown expired but output resumed — continuing")
                    return
                }

                logger.info("System audio deactivation cooldown expired — closing segment")
                self.isActive = false
                self.writerQueue.async { self.closeSegment() }
            }
        }
    }

    // MARK: - File Path Generation

    private func generateFilePath(for date: Date) -> String {
        let audioDir = (dataDir as NSString).appendingPathComponent("media/audio")

        try? FileManager.default.createDirectory(
            atPath: audioDir,
            withIntermediateDirectories: true
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.timeZone = TimeZone.current
        let timestamp = formatter.string(from: date)

        // Microsecond suffix for collision safety
        let microseconds = Int(date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 1_000_000)
        return (audioDir as NSString).appendingPathComponent("sys-\(timestamp)-\(String(format: "%06d", microseconds)).m4a")
    }
}

// MARK: - Output Activity Monitor

/// Monitors the default system audio output device to detect when any app
/// is producing audio. Uses CoreAudio property listener on
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` (output device).
///
/// No self-trigger concern: Shadow doesn't produce system audio output,
/// so its own capture session doesn't affect the output device running state.
///
/// Thread safety: Same model as MicActivityMonitor.
/// - Public API is @MainActor.
/// - CoreAudio callbacks dispatch to main actor.
/// - `guardedState` protects the minimal cross-thread state (device ID).
final class OutputActivityMonitor: Sendable {

    nonisolated(unsafe) var onActive: (@MainActor () -> Void)?
    nonisolated(unsafe) var onInactive: (@MainActor () -> Void)?

    // MARK: - Constants

    private let activationDelay: TimeInterval = 2.0
    private let deactivationDelay: TimeInterval = 5.0

    // MARK: - Guarded state (CoreAudio callback access)

    private struct GuardedState: Sendable {
        var monitoredDeviceID: AudioDeviceID = 0
        var isStopped: Bool = true
    }

    private let guardedState = OSAllocatedUnfairLock(initialState: GuardedState())

    // MARK: - Main-actor-only state

    nonisolated(unsafe) private var _isOutputActive = false
    nonisolated(unsafe) private var activationTimer: Timer?
    nonisolated(unsafe) private var deactivationTimer: Timer?
    nonisolated(unsafe) private var runningListenerBlock: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// Polling fallback timer (2-second interval).
    nonisolated(unsafe) private var pollTimer: Timer?

    // MARK: - Public API

    @MainActor
    var isOutputActive: Bool { _isOutputActive }

    @MainActor
    func start() {
        guardedState.withLock { $0.isStopped = false }
        installDefaultDeviceListener()
        let deviceID = currentDefaultOutputDevice()
        if deviceID != kAudioObjectUnknown {
            startMonitoringDevice(deviceID)
        } else {
            logger.info("No default output device found — will monitor for device changes")
        }

        // Polling fallback (2s) — supplements property listeners
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let deviceID = self.guardedState.withLock { $0.monitoredDeviceID }
                guard deviceID != 0 else { return }
                let running = self.isDeviceRunning(deviceID)
                self.handleRunningStateChanged(running)
            }
        }

        logger.info("OutputActivityMonitor started")
    }

    @MainActor
    func stop() {
        guardedState.withLock { $0.isStopped = true }
        activationTimer?.invalidate()
        activationTimer = nil
        deactivationTimer?.invalidate()
        deactivationTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil

        removeRunningListener()
        removeDefaultDeviceListener()

        if _isOutputActive {
            _isOutputActive = false
        }
        logger.info("OutputActivityMonitor stopped")
    }

    // MARK: - Device Monitoring

    @MainActor
    private func startMonitoringDevice(_ deviceID: AudioDeviceID) {
        removeRunningListener()

        guardedState.withLock { $0.monitoredDeviceID = deviceID }

        let isRunning = isDeviceRunning(deviceID)
        logger.info("Monitoring output device \(deviceID), currently running: \(isRunning)")

        if isRunning && !_isOutputActive {
            scheduleActivation()
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let stopped = self.guardedState.withLock { $0.isStopped }
            guard !stopped else { return }

            let running = self.isDeviceRunning(deviceID)
            Task { @MainActor in
                self.handleRunningStateChanged(running)
            }
        }

        runningListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        if status != noErr {
            logger.error("Failed to add running listener on output device \(deviceID): \(status)")
        }
    }

    @MainActor
    private func removeRunningListener() {
        let deviceID = guardedState.withLock { $0.monitoredDeviceID }
        guard deviceID != 0, let block = runningListenerBlock else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        runningListenerBlock = nil
        guardedState.withLock { $0.monitoredDeviceID = 0 }
    }

    // MARK: - Default Device Change Listener

    @MainActor
    private func installDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let stopped = self.guardedState.withLock { $0.isStopped }
            guard !stopped else { return }

            let newDevice = self.currentDefaultOutputDevice()
            Task { @MainActor in
                self.handleDefaultDeviceChanged(newDevice)
            }
        }

        defaultDeviceListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            logger.error("Failed to add default output device listener: \(status)")
        }
    }

    @MainActor
    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultDeviceListenerBlock = nil
    }

    @MainActor
    private func handleDefaultDeviceChanged(_ newDevice: AudioDeviceID) {
        let currentDevice = guardedState.withLock { $0.monitoredDeviceID }
        guard newDevice != currentDevice else { return }

        logger.info("Default output device changed: \(currentDevice) → \(newDevice)")

        if newDevice == kAudioObjectUnknown {
            removeRunningListener()
            if _isOutputActive {
                handleRunningStateChanged(false)
            }
        } else {
            startMonitoringDevice(newDevice)
        }
    }

    // MARK: - Running State Changes (with debounce)

    @MainActor
    private func handleRunningStateChanged(_ isRunning: Bool) {
        if isRunning {
            deactivationTimer?.invalidate()
            deactivationTimer = nil

            if !_isOutputActive {
                scheduleActivation()
            }
        } else {
            activationTimer?.invalidate()
            activationTimer = nil

            if _isOutputActive {
                scheduleDeactivation()
            }
        }
    }

    @MainActor
    private func scheduleActivation() {
        guard activationTimer == nil else { return }

        activationTimer = Timer.scheduledTimer(withTimeInterval: activationDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.activationTimer = nil

                let deviceID = self.guardedState.withLock { $0.monitoredDeviceID }
                guard deviceID != 0, self.isDeviceRunning(deviceID) else { return }

                self._isOutputActive = true
                logger.info("System audio output became active (after \(self.activationDelay)s debounce)")
                self.onActive?()
            }
        }
    }

    @MainActor
    private func scheduleDeactivation() {
        guard deactivationTimer == nil else { return }

        deactivationTimer = Timer.scheduledTimer(withTimeInterval: deactivationDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.deactivationTimer = nil

                let deviceID = self.guardedState.withLock { $0.monitoredDeviceID }
                if deviceID != 0, self.isDeviceRunning(deviceID) {
                    return
                }

                self._isOutputActive = false
                logger.info("System audio output became inactive (after \(self.deactivationDelay)s debounce)")
                self.onInactive?()
            }
        }
    }

    // MARK: - CoreAudio Queries

    private func currentDefaultOutputDevice() -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )
        if status != noErr {
            logger.error("Failed to get default output device: \(status)")
            return kAudioObjectUnknown
        }
        return deviceID
    }

    private func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        if status != noErr {
            return false
        }
        return isRunning != 0
    }
}
