import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "AudioPlayer")

/// Singleton audio playback engine for transcript results.
/// Shared between search overlay and (future) timeline.
///
/// All AVAudioPlayer control stays on @MainActor.
/// Only segment resolution and file existence checks run off-main.
@Observable
@MainActor
final class AudioPlayer: NSObject {
    static let shared = AudioPlayer()

    // MARK: - Published State

    /// Whether audio is actively playing.
    private(set) var isPlaying = false

    /// Whether playback is paused (can resume).
    private(set) var isPaused = false

    /// The segment currently loaded (or last loaded).
    private(set) var currentSegmentId: Int64?

    /// Audio source of the current segment ("mic" or "system").
    private(set) var currentSource: String?

    /// Playback progress 0–1 within the active chunk.
    private(set) var progress: Double = 0

    /// Current playback position in seconds (within the chunk).
    private(set) var currentTime: Double = 0

    /// Duration of the active chunk in seconds.
    private(set) var duration: Double = 0

    /// Timestamp of the last result whose playback was attempted.
    /// Used to scope error display to the specific card.
    private(set) var lastAttemptedResultTs: UInt64?

    /// Non-nil when the last playback attempt failed. Scoped to `lastAttemptedResultTs`.
    private(set) var error: String?

    // MARK: - Private

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    private var autoStopTimer: Timer?

    /// The seek offset within the segment file (seconds from file start).
    /// Exposed read-only for AudioTrackView's playback position indicator.
    private(set) var seekOffsetInFile: Double = 0

    /// The chunk duration for auto-stop (seconds). Nil = play to end.
    private var chunkDuration: Double?

    /// Monotonic nonce incremented on each playTranscriptResult call.
    /// Used to discard stale async resolutions from superseded requests.
    private var requestNonce: UInt64 = 0

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Resolve the audio segment for a transcript search result and play the matched chunk.
    ///
    /// Segment resolution and file checks run off-main via Task.detached.
    /// AVAudioPlayer creation and control stays on MainActor.
    /// A monotonic nonce prevents stale async results from overwriting newer requests.
    func playTranscriptResult(_ result: SearchResult) {
        // Stop any current playback first
        stop()

        // Increment nonce — invalidates any in-flight resolution from a prior request
        requestNonce &+= 1
        let myNonce = requestNonce

        lastAttemptedResultTs = result.ts
        error = nil

        DiagnosticsStore.shared.increment("audio_playback_attempt_total")

        let source = result.audioSource
        let ts = result.ts
        let tsEnd = result.tsEnd

        // Off-main: resolve segment and validate file
        Task.detached(priority: .userInitiated) {
            let resolution = Self.resolveSegment(source: source, ts: ts, tsEnd: tsEnd)

            // Back to MainActor: apply result only if this request is still current
            await MainActor.run { [weak self] in
                guard let self, self.requestNonce == myNonce else {
                    logger.debug("Dropping stale segment resolution (nonce mismatch)")
                    return
                }

                switch resolution {
                case .success(let info):
                    self.startPlayback(
                        fileURL: info.fileURL,
                        segmentId: info.segmentId,
                        source: source,
                        seekSeconds: info.seekSeconds,
                        chunkDuration: info.chunkDuration,
                        result: result
                    )
                case .segmentNotFound:
                    self.handleMissingSegment(result: result)
                case .fileMissing:
                    self.handleMissingFile(result: result)
                case .lookupFailed(let reason):
                    self.handlePlaybackError(reason, result: result)
                }
            }
        }
    }

    // MARK: - Off-Main Segment Resolution

    /// Result of off-main segment resolution.
    private enum SegmentResolution: Sendable {
        struct PlaybackInfo: Sendable {
            let fileURL: URL
            let segmentId: Int64
            let seekSeconds: Double
            let chunkDuration: Double?
        }
        case success(PlaybackInfo)
        case segmentNotFound
        case fileMissing
        case lookupFailed(String)
    }

    /// Resolve audio segment and validate file existence. Synchronous, called from detached task.
    private static nonisolated func resolveSegment(
        source: String,
        ts: UInt64,
        tsEnd: UInt64
    ) -> SegmentResolution {
        let segment: AudioSegment?
        do {
            segment = try findAudioSegment(source: source, timestampUs: ts)
        } catch {
            logger.error("Segment lookup failed: \(error, privacy: .public)")
            return .lookupFailed("Segment lookup failed")
        }

        guard let segment else {
            logger.warning("No audio segment found for source=\(source), ts=\(ts)")
            return .segmentNotFound
        }

        let filePath = segment.filePath
        guard FileManager.default.fileExists(atPath: filePath) else {
            logger.warning("Audio file missing: \(filePath)")
            return .fileMissing
        }

        let fileURL = URL(fileURLWithPath: filePath)
        let seekSec = Double(ts - segment.startTs) / 1_000_000
        let durSec = Double(tsEnd - ts) / 1_000_000

        return .success(SegmentResolution.PlaybackInfo(
            fileURL: fileURL,
            segmentId: segment.segmentId,
            seekSeconds: seekSec,
            chunkDuration: durSec > 0 ? durSec : nil
        ))
    }

    func pause() {
        guard isPlaying, let player else { return }
        player.pause()
        isPlaying = false
        isPaused = true
        stopProgressTimer()
        stopAutoStopTimer()
        logger.debug("Audio paused at \(self.currentTime, format: .fixed(precision: 1))s")
    }

    func resume() {
        guard isPaused, let player else { return }
        player.play()
        isPlaying = true
        isPaused = false
        startProgressTimer()
        scheduleAutoStop()
        logger.debug("Audio resumed at \(self.currentTime, format: .fixed(precision: 1))s")
    }

    func stop() {
        // Invalidate any in-flight async resolution
        requestNonce &+= 1
        player?.stop()
        player = nil
        isPlaying = false
        isPaused = false
        progress = 0
        currentTime = 0
        duration = 0
        seekOffsetInFile = 0
        chunkDuration = nil
        stopProgressTimer()
        stopAutoStopTimer()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else if isPaused {
            resume()
        }
        // If neither playing nor paused (stopped), do nothing — caller should use playTranscriptResult
    }

    /// Convenience for AudioTrackView's playback position indicator.
    var seekOffsetSeconds: Double { seekOffsetInFile }

    /// Play a known segment directly (from timeline click). No segment resolution needed.
    /// The caller is responsible for verifying the file exists before calling.
    func playSegment(_ segment: AudioSegment, seekSeconds: Double, chunkDuration: Double? = nil) {
        stop()

        requestNonce &+= 1
        lastAttemptedResultTs = nil
        error = nil

        DiagnosticsStore.shared.increment("audio_playback_attempt_total")

        let fileURL = URL(fileURLWithPath: segment.filePath)

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: fileURL)
            newPlayer.delegate = self
            newPlayer.currentTime = max(0, seekSeconds)
            newPlayer.play()

            self.player = newPlayer
            self.currentSegmentId = segment.segmentId
            self.currentSource = segment.source
            self.seekOffsetInFile = seekSeconds
            self.chunkDuration = chunkDuration
            self.duration = chunkDuration ?? (newPlayer.duration - seekSeconds)
            self.isPlaying = true
            self.isPaused = false
            self.progress = 0
            self.currentTime = 0
            self.error = nil

            startProgressTimer()
            scheduleAutoStop()

            DiagnosticsStore.shared.increment("audio_playback_success_total")
            logger.info("Playing segment \(segment.segmentId) (\(segment.source)) at \(seekSeconds, format: .fixed(precision: 1))s from timeline")
        } catch {
            logger.error("AVAudioPlayer init failed: \(error, privacy: .public)")
            self.error = "Cannot play audio: \(error.localizedDescription)"
            DiagnosticsStore.shared.increment("audio_playback_fail_total")
            DiagnosticsStore.shared.postWarning(
                severity: .warning,
                subsystem: "AudioPlayback",
                code: "PLAYER_INIT_FAILED",
                message: "AVAudioPlayer init failed (timeline): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Private: Playback

    private func startPlayback(
        fileURL: URL,
        segmentId: Int64,
        source: String,
        seekSeconds: Double,
        chunkDuration: Double?,
        result: SearchResult
    ) {
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: fileURL)
            newPlayer.delegate = self
            newPlayer.currentTime = max(0, seekSeconds)
            newPlayer.play()

            self.player = newPlayer
            self.currentSegmentId = segmentId
            self.currentSource = source
            self.seekOffsetInFile = seekSeconds
            self.chunkDuration = chunkDuration
            self.duration = chunkDuration ?? (newPlayer.duration - seekSeconds)
            self.isPlaying = true
            self.isPaused = false
            self.progress = 0
            self.currentTime = 0
            self.error = nil

            startProgressTimer()
            scheduleAutoStop()

            DiagnosticsStore.shared.increment("audio_playback_success_total")
            logger.info("Playing segment \(segmentId) (\(source)) at \(seekSeconds, format: .fixed(precision: 1))s, chunk=\(chunkDuration ?? -1, format: .fixed(precision: 1))s")
        } catch {
            logger.error("AVAudioPlayer init failed: \(error, privacy: .public)")
            self.error = "Cannot play audio: \(error.localizedDescription)"
            DiagnosticsStore.shared.increment("audio_playback_fail_total")
            DiagnosticsStore.shared.postWarning(
                severity: .warning,
                subsystem: "AudioPlayback",
                code: "PLAYER_INIT_FAILED",
                message: "AVAudioPlayer init failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Private: Error Handlers

    private func handlePlaybackError(_ reason: String, result: SearchResult) {
        error = reason
        DiagnosticsStore.shared.increment("audio_playback_fail_total")
        DiagnosticsStore.shared.postWarning(
            severity: .warning,
            subsystem: "AudioPlayback",
            code: "SEGMENT_LOOKUP_FAILED",
            message: reason
        )
    }

    private func handleMissingSegment(result: SearchResult) {
        error = "Audio segment not found"
        DiagnosticsStore.shared.increment("audio_playback_fail_total")
        DiagnosticsStore.shared.increment("audio_playback_missing_segment_total")
        DiagnosticsStore.shared.postWarning(
            severity: .warning,
            subsystem: "AudioPlayback",
            code: "SEGMENT_NOT_FOUND",
            message: "No audio segment for source=\(result.audioSource), ts=\(result.ts)"
        )
    }

    private func handleMissingFile(result: SearchResult) {
        error = "Audio file missing"
        DiagnosticsStore.shared.increment("audio_playback_fail_total")
        DiagnosticsStore.shared.postWarning(
            severity: .warning,
            subsystem: "AudioPlayback",
            code: "AUDIO_FILE_MISSING",
            message: "Audio file not found on disk for segment"
        )
    }

    // MARK: - Private: Timers

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateProgress()
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateProgress() {
        guard let player, isPlaying else { return }
        let elapsed = player.currentTime - seekOffsetInFile
        currentTime = max(0, elapsed)
        if duration > 0 {
            progress = min(1.0, currentTime / duration)
        }
    }

    private func scheduleAutoStop() {
        stopAutoStopTimer()
        guard let chunkDuration, chunkDuration > 0 else { return }
        let remaining = chunkDuration - currentTime
        guard remaining > 0 else {
            stop()
            return
        }
        autoStopTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
                logger.debug("Auto-stopped after chunk duration")
            }
        }
    }

    private func stopAutoStopTimer() {
        autoStopTimer?.invalidate()
        autoStopTimer = nil
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stop()
            if !flag {
                logger.warning("Audio playback finished unsuccessfully")
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in
            logger.error("Audio decode error: \(error?.localizedDescription ?? "unknown")")
            self.error = "Audio decode error"
            self.stop()
            DiagnosticsStore.shared.increment("audio_playback_fail_total")
        }
    }
}
