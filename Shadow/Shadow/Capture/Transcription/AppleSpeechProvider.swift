@preconcurrency import Speech
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "AppleSpeechProvider")

/// Transcription provider backed by Apple's `SFSpeechRecognizer` (on-device).
/// Extracted from TranscriptWorker's inline implementation.
///
/// Thread safety: all state is immutable after init. The `recognitionTask` callback
/// is bridged via a `nonisolated static` method to avoid inheriting caller's
/// actor isolation (see CLAUDE.md: Swift 6 @MainActor closure isolation gotcha).
final class AppleSpeechProvider: TranscriptionProvider, @unchecked Sendable {
    let providerName = "apple_speech"

    var isAvailable: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && SFSpeechRecognizer()?.isAvailable == true
    }

    func transcribe(audioFileURL: URL) async throws -> [TranscribedWord] {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriptionProviderError.unavailable(reason: "Speech Recognition not authorized")
        }
        guard let recognizer = SFSpeechRecognizer() else {
            throw TranscriptionProviderError.unavailable(reason: "No speech recognizer for current locale")
        }
        guard recognizer.isAvailable else {
            throw TranscriptionProviderError.transientFailure(
                underlying: NSError(domain: "AppleSpeechProvider", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Recognizer temporarily unavailable"])
            )
        }

        let result = try await Self.recognizeFile(at: audioFileURL, recognizer: recognizer)

        return result.bestTranscription.segments.map { seg in
            TranscribedWord(
                text: seg.substring,
                startSeconds: seg.timestamp,
                durationSeconds: seg.duration,
                confidence: seg.confidence
            )
        }
    }

    // MARK: - Callback Bridge

    /// `nonisolated static` to break actor isolation inheritance.
    /// `SFSpeechRecognizer.recognitionTask` calls back on a GCD queue —
    /// inheriting `@MainActor` would crash at runtime.
    private nonisolated static func recognizeFile(
        at url: URL,
        recognizer: SFSpeechRecognizer
    ) async throws -> SFSpeechRecognitionResult {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !hasResumed else { return }
                if let error = error {
                    hasResumed = true
                    continuation.resume(throwing: error)
                    return
                }
                if let result = result, result.isFinal {
                    hasResumed = true
                    continuation.resume(returning: result)
                }
            }
        }
    }
}
