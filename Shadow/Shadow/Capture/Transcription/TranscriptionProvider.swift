import Foundation

/// Normalized word timing from any transcription provider.
/// Named `TranscribedWord` (not `WordTiming`) to avoid collision with WhisperKit's own `WordTiming` type.
struct TranscribedWord: Sendable {
    let text: String
    let startSeconds: Double
    let durationSeconds: Double
    let confidence: Float?
}

/// Whisper model profile — controls quality/speed tradeoff.
/// Config-level only (no UI in this pass).
enum WhisperProfile: String, Sendable, CaseIterable {
    case fast     = "openai_whisper-small.en"
    case balanced = "openai_whisper-medium.en"
    case accurate = "openai_whisper-large-v3"

    static let `default`: WhisperProfile = .balanced

    var displayName: String {
        switch self {
        case .fast: return "small.en"
        case .balanced: return "medium.en"
        case .accurate: return "large-v3"
        }
    }

    /// Required entries for a structurally valid Whisper model directory.
    /// WhisperKit needs config.json + all three .mlmodelc payload directories.
    static let requiredModelEntries = [
        "config.json",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
    ]

    /// Core payload directories that must be actual directories (not files).
    private static let payloadDirs = [
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
    ]

    /// Discover all structurally valid provisioned profiles on disk,
    /// ordered by preference (balanced > fast > accurate).
    ///
    /// A profile is valid if its directory contains config.json and all three
    /// .mlmodelc payload directories (verified as actual directories, not files).
    /// Returns empty array if none are valid.
    static func discoverProvisionedCandidates(in modelFolder: String) -> [WhisperProfile] {
        let fm = FileManager.default
        let preferenceOrder: [WhisperProfile] = [.balanced, .fast, .accurate]
        return preferenceOrder.filter { profile in
            let dir = modelFolder + "/" + profile.rawValue
            // config.json must exist
            guard fm.fileExists(atPath: dir + "/config.json") else { return false }
            // Each .mlmodelc must exist as a directory
            for mlmodelc in payloadDirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir + "/" + mlmodelc, isDirectory: &isDir),
                      isDir.boolValue else {
                    return false
                }
            }
            return true
        }
    }
}

/// Errors thrown by transcription providers.
enum TranscriptionProviderError: Error {
    /// Provider cannot operate (model not loaded, permission denied). Try next provider.
    case unavailable(reason: String)
    /// Temporary failure (recognizer busy, model hiccup). Try next provider.
    case transientFailure(underlying: Error)
    /// Audio file is corrupt or unreadable. Terminal — no provider can help.
    case badInput(reason: String)
}

/// Protocol for pluggable transcription backends.
protocol TranscriptionProvider: Sendable {
    /// Short identifier for diagnostics and logging (e.g. "whisper", "apple_speech").
    var providerName: String { get }

    /// Fast synchronous check — can this provider currently accept work?
    var isAvailable: Bool { get }

    /// Transcribe the audio file at `audioFileURL` and return normalized word timings.
    /// Empty array means legitimate silence (no speech detected).
    /// Throws `TranscriptionProviderError` on failure.
    func transcribe(audioFileURL: URL) async throws -> [TranscribedWord]
}
