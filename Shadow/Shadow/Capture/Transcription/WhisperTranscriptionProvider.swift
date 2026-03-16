import Foundation
import WhisperKit
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "WhisperProvider")

/// Transcription provider backed by WhisperKit (CoreML Whisper).
///
/// Loaded asynchronously — `isAvailable` is false until the model is fully loaded.
/// All state is immutable after `init`, making this `@unchecked Sendable` safe.
/// WhisperKit handles its own internal concurrency for `transcribe()` calls.
final class WhisperTranscriptionProvider: @unchecked Sendable, TranscriptionProvider {
    let providerName = "whisper"
    let profile: WhisperProfile

    private let pipe: WhisperKit?
    private let _isAvailable: Bool

    /// Async init — loads CoreML models from disk. Does not download.
    /// If loading fails, the provider is created in an unavailable state.
    ///
    /// - Parameters:
    ///   - modelFolder: Parent directory containing model variant subdirectories.
    ///   - profile: Which Whisper model to load (default: `.balanced`).
    init(modelFolder: String, profile: WhisperProfile = .default) async {
        self.profile = profile

        let modelPath = modelFolder + "/" + profile.rawValue
        guard FileManager.default.fileExists(atPath: modelPath) else {
            logger.info("Whisper model not found at \(modelPath, privacy: .public)")
            self.pipe = nil
            self._isAvailable = false
            return
        }

        do {
            let kit = try await WhisperKit(
                modelFolder: modelPath,
                verbose: false,
                download: false
            )
            self.pipe = kit
            self._isAvailable = true
            DiagnosticsStore.shared.setGauge("whisper_model_loaded", value: 1)
            DiagnosticsStore.shared.setStringGauge("whisper_active_profile", value: profile.displayName)
            DiagnosticsStore.shared.setStringGauge("whisper_active_model_id", value: profile.rawValue)
            logger.info("Whisper model loaded: \(profile.rawValue, privacy: .public)")
        } catch {
            logger.error("Failed to load Whisper model: \(error, privacy: .public)")
            self.pipe = nil
            self._isAvailable = false
            DiagnosticsStore.shared.setGauge("whisper_model_loaded", value: 0)
        }
    }

    var isAvailable: Bool { _isAvailable }

    func transcribe(audioFileURL: URL) async throws -> [TranscribedWord] {
        guard let pipe else {
            throw TranscriptionProviderError.unavailable(reason: "Whisper model not loaded")
        }

        // Verify file exists and is readable
        guard FileManager.default.isReadableFile(atPath: audioFileURL.path) else {
            throw TranscriptionProviderError.badInput(reason: "Audio file not readable: \(audioFileURL.lastPathComponent)")
        }

        let options = DecodingOptions(wordTimestamps: true)

        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(audioPath: audioFileURL.path, decodeOptions: options)
        } catch {
            throw TranscriptionProviderError.transientFailure(underlying: error)
        }

        // Flatten all segments' word timings into TranscribedWord array
        var words: [TranscribedWord] = []
        for result in results {
            for segment in result.segments {
                if let wordTimings = segment.words {
                    // Word-level timings available
                    for wt in wordTimings {
                        words.append(TranscribedWord(
                            text: wt.word,
                            startSeconds: Double(wt.start),
                            durationSeconds: Double(wt.end - wt.start),
                            confidence: wt.probability
                        ))
                    }
                } else if !segment.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Fallback: segment-level timing (no per-word detail)
                    words.append(TranscribedWord(
                        text: segment.text,
                        startSeconds: Double(segment.start),
                        durationSeconds: Double(segment.end - segment.start),
                        confidence: nil
                    ))
                }
            }
        }

        return words
    }
}
