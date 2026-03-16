import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "TranscriptionOrchestrator")

/// Outcome of an orchestrated transcription attempt across all providers.
enum OrchestratedOutcome {
    /// Transcription succeeded. Words may be empty (legitimate silence).
    case success([TranscribedWord], provider: String)
    /// Audio file is corrupt/unreadable. Terminal — checkpoint should advance.
    case badInput
    /// All providers failed transiently. Retryable — checkpoint should NOT advance.
    case transientFailure
}

/// Manages a chain of transcription providers with fallback semantics.
///
/// Thread safety: `providers` array is protected by `OSAllocatedUnfairLock` for
/// safe hot-swap (Whisper loads in background, inserted at index 0 after init).
/// Lock is held only for array copies, never during transcription calls.
final class TranscriptionOrchestrator: @unchecked Sendable {
    private var providers: [any TranscriptionProvider]
    private let lock = OSAllocatedUnfairLock(initialState: ())

    init(providers: [any TranscriptionProvider]) {
        self.providers = providers
    }

    /// Insert a provider at the given index (thread-safe).
    /// Used to hot-swap Whisper into position 0 after background model loading.
    func insertProvider(_ provider: any TranscriptionProvider, at index: Int) {
        lock.withLock {
            let clampedIndex = min(index, providers.count)
            providers.insert(provider, at: clampedIndex)
        }
        logger.info("Provider \(provider.providerName) inserted at index \(index)")
    }

    /// Whether any provider is currently available to accept work.
    var hasAvailableProvider: Bool {
        let snapshot: [any TranscriptionProvider] = lock.withLock { providers }
        return snapshot.contains(where: { $0.isAvailable })
    }

    /// The active Whisper profile, if a Whisper provider is loaded.
    var activeWhisperProfile: WhisperProfile? {
        let snapshot: [any TranscriptionProvider] = lock.withLock { providers }
        for provider in snapshot {
            if let whisper = provider as? WhisperTranscriptionProvider, whisper.isAvailable {
                return whisper.profile
            }
        }
        return nil
    }

    /// Transcribe using the provider chain. Tries each provider in order:
    /// - Skip if `!isAvailable`
    /// - On success (even empty `[]`): return `.success` — no fallback on silence
    /// - On `.unavailable` or `.transientFailure`: try next provider
    /// - On `.badInput`: return `.badInput` (terminal)
    ///
    /// Fallback metric semantics (2-provider chain: whisper → apple_speech):
    /// - `transcript_provider_fallback_to_apple_total`: Whisper was attempted and failed,
    ///   then Apple succeeded for the same segment. Only incremented on actual fallback success.
    /// - `transcript_provider_whisper_unavailable_total`: Whisper threw `.unavailable`.
    /// - `transcript_provider_whisper_transient_total`: Whisper threw `.transientFailure` or unexpected error.
    ///
    /// NOTE: The `fallback_to_apple` metric is keyed to the specific provider name "apple_speech".
    /// If additional providers are added to the chain in the future, introduce per-pair fallback
    /// counters (e.g. `fallback_from_X_to_Y_total`) rather than overloading this metric.
    func transcribe(audioFileURL: URL) async -> OrchestratedOutcome {
        let snapshot: [any TranscriptionProvider] = lock.withLock { providers }

        // Track whether a prior provider was attempted and failed (for fallback metrics).
        var priorProviderFailed = false

        for provider in snapshot {
            guard provider.isAvailable else { continue }

            DiagnosticsStore.shared.increment("transcript_provider_\(provider.providerName)_attempt_total")

            do {
                let words = try await provider.transcribe(audioFileURL: audioFileURL)
                DiagnosticsStore.shared.increment("transcript_provider_\(provider.providerName)_success_total")

                // Fallback metric: a prior provider failed and this one succeeded
                if priorProviderFailed && provider.providerName == "apple_speech" {
                    DiagnosticsStore.shared.increment("transcript_provider_fallback_to_apple_total")
                }

                return .success(words, provider: provider.providerName)

            } catch let error as TranscriptionProviderError {
                switch error {
                case .unavailable(let reason):
                    logger.info("Provider \(provider.providerName) unavailable: \(reason)")
                    DiagnosticsStore.shared.increment("transcript_provider_\(provider.providerName)_fail_total")
                    if provider.providerName == "whisper" {
                        DiagnosticsStore.shared.increment("transcript_provider_whisper_unavailable_total")
                    }

                case .transientFailure(let underlying):
                    logger.warning("Provider \(provider.providerName) transient failure: \(underlying, privacy: .public)")
                    DiagnosticsStore.shared.increment("transcript_provider_\(provider.providerName)_fail_total")
                    if provider.providerName == "whisper" {
                        DiagnosticsStore.shared.increment("transcript_provider_whisper_transient_total")
                    }

                case .badInput(let reason):
                    logger.error("Bad audio input: \(reason, privacy: .public)")
                    DiagnosticsStore.shared.increment("transcript_provider_\(provider.providerName)_fail_total")
                    return .badInput
                }

            } catch {
                // Unexpected error from provider — treat as transient
                logger.warning("Provider \(provider.providerName) unexpected error: \(error, privacy: .public)")
                DiagnosticsStore.shared.increment("transcript_provider_\(provider.providerName)_fail_total")
                if provider.providerName == "whisper" {
                    DiagnosticsStore.shared.increment("transcript_provider_whisper_transient_total")
                }
            }

            priorProviderFailed = true
        }

        // All providers exhausted
        return .transientFailure
    }
}
