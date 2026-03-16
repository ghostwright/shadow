import Foundation
import MLX
import MLXLMCommon
import MLXLLM
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "SpeculativeDecoder")

// MARK: - Configuration

/// Configuration for speculative decoding using a small MLX draft model
/// and a larger MLX verifier model, both running on the GPU.
///
/// **API status (2026-02):** mlx-swift-lm v2.30.0 does NOT expose a first-class
/// speculative decoding API at the Swift level. The `ChatSession`, `TokenIterator`,
/// and `ModelContainer` classes operate on single models only. There is no
/// `draftModel` parameter, no multi-model generation API, and no way to intercept
/// the token-level generation loop to inject draft tokens and verify them.
///
/// The underlying MLX C++ framework does support speculative decoding (used by
/// LM Studio's mlx-engine), but this is not surfaced through the Swift API.
///
/// **What this configuration enables:**
/// - Draft model provisioning and lifecycle management (ready to load)
/// - Feature flag for enabling/disabling speculative decoding
/// - Tunable parameters (draft length, acceptance threshold)
/// - Diagnostics metrics for when the API ships
///
/// When mlx-swift-lm adds speculative decoding support (likely via a
/// `SpeculativeTokenIterator` or a `draftModel` parameter on `ChatSession`),
/// the `SpeculativeDecoder` actor below will be completed to use it.
struct SpeculativeDecodingConfig: Sendable {

    /// The draft model spec (small, fast, same tokenizer family as verifier).
    let draftSpec: LocalModelSpec

    /// The verifier model spec (larger, higher quality).
    let verifierSpec: LocalModelSpec

    /// Number of tokens the draft model proposes per speculative round.
    /// Higher values amortize more overhead but risk more rejections.
    /// Typical range: 3-8. Default: 5.
    let draftLength: Int

    /// Whether speculative decoding is enabled.
    /// When false, generation always uses standard single-model decoding.
    /// When true AND both models are loaded, speculative decoding is attempted.
    let enabled: Bool

    /// Default configuration: Qwen2.5-1.5B draft + Qwen2.5-7B verifier, disabled.
    ///
    /// Disabled by default because mlx-swift-lm v2.30.0 does not expose the
    /// speculative decoding API. Enable when the API ships.
    static let `default` = SpeculativeDecodingConfig(
        draftSpec: LocalModelRegistry.draftDefault,
        verifierSpec: LocalModelRegistry.fastDefault,
        draftLength: 5,
        enabled: false
    )

    /// Check whether the draft model is provisioned on disk.
    var isDraftProvisioned: Bool {
        LocalModelRegistry.isDownloaded(draftSpec)
    }

    /// Check whether the verifier model is provisioned on disk.
    var isVerifierProvisioned: Bool {
        LocalModelRegistry.isDownloaded(verifierSpec)
    }

    /// Check whether both models are provisioned and the system has enough RAM.
    var isReady: Bool {
        guard enabled else { return false }
        guard isDraftProvisioned && isVerifierProvisioned else { return false }
        let systemRAMGB = MLXConfiguration.systemRAMGB
        // Draft + verifier must both fit. Combined estimate:
        let combinedMemoryGB = draftSpec.estimatedMemoryGB + verifierSpec.estimatedMemoryGB
        return Double(systemRAMGB) >= combinedMemoryGB * 2  // 2x headroom
    }
}

// MARK: - Result Type

/// Result from a successful speculative generation.
/// Sendable so it can be returned across actor boundaries.
struct SpeculativeResult: Sendable {
    /// The generated text.
    let text: String
    /// Number of tokens in the input prompt (if available).
    let promptTokenCount: Int?
    /// Number of tokens generated (if available).
    let generationTokenCount: Int?
    /// Number of speculative rounds executed.
    let roundsExecuted: Int
    /// Overall acceptance rate for this generation.
    let acceptanceRate: Double
}

// MARK: - Speculative Decoder

/// Infrastructure for speculative decoding using MLX draft + verifier models.
///
/// **Current status:** This actor provides the configuration, lifecycle management,
/// and diagnostics infrastructure for speculative decoding. The actual speculative
/// generation loop is NOT implemented because mlx-swift-lm v2.30.0 does not
/// expose the required APIs (token-level generation control, multi-model KV-cache
/// coordination, logit access for verification).
///
/// **What would be needed from mlx-swift-lm:**
/// 1. Access to raw logits from a forward pass (not just sampled tokens)
/// 2. Ability to run a forward pass on multiple tokens simultaneously (batch verify)
/// 3. KV-cache management across two models (draft and verifier)
/// 4. A `TokenIterator`-like API that supports speculative generation
///
/// **When the API ships**, complete `speculativeGenerate()` with:
/// 1. Draft model generates `draftLength` tokens autoregressively
/// 2. Verifier processes all draft tokens in a single forward pass
/// 3. Compare draft vs verifier logits at each position
/// 4. Accept prefix where draft and verifier agree (within tolerance)
/// 5. On rejection, use verifier's token at the rejection point
/// 6. Repeat from step 1 with the accepted prefix
///
/// Expected speedup: 1.3-1.8x for the Qwen2.5-1.5B/7B pair.
actor SpeculativeDecoder {

    /// Configuration for draft/verifier model pair and tuning parameters.
    let config: SpeculativeDecodingConfig

    /// Reference to the lifecycle manager for loading models.
    private let lifecycle: LocalModelLifecycle

    /// Running total of tokens accepted from draft model.
    private var acceptedTokens: Int64 = 0

    /// Running total of tokens rejected from draft model.
    private var rejectedTokens: Int64 = 0

    /// Number of speculative rounds attempted.
    private var roundsAttempted: Int64 = 0

    init(config: SpeculativeDecodingConfig = .default, lifecycle: LocalModelLifecycle) {
        self.config = config
        self.lifecycle = lifecycle
    }

    // MARK: - Readiness

    /// Whether speculative decoding can be used right now.
    ///
    /// Checks: config enabled, both models provisioned, sufficient RAM.
    var isReady: Bool {
        config.isReady
    }

    /// Report the current acceptance rate (accepted / total proposed).
    /// Returns nil if no rounds have been attempted.
    var acceptanceRate: Double? {
        let total = acceptedTokens + rejectedTokens
        guard total > 0 else { return nil }
        return Double(acceptedTokens) / Double(total)
    }

    // MARK: - Diagnostics

    /// Update all speculative decoding diagnostics gauges.
    func updateDiagnostics() {
        let store = DiagnosticsStore.shared
        store.setGauge("speculative_enabled", value: config.enabled ? 1.0 : 0.0)
        store.setGauge("speculative_draft_provisioned", value: config.isDraftProvisioned ? 1.0 : 0.0)
        store.setGauge("speculative_ready", value: isReady ? 1.0 : 0.0)

        if let rate = acceptanceRate {
            store.setGauge("speculative_acceptance_rate", value: rate)
        }

        logger.info("Speculative decoding status: enabled=\(self.config.enabled) draft_provisioned=\(self.config.isDraftProvisioned) verifier_provisioned=\(self.config.isVerifierProvisioned) ready=\(self.isReady)")
    }

    // MARK: - Speculative Generation (Stub)

    /// Attempt speculative generation. Falls back to standard generation if
    /// speculative decoding is not available.
    ///
    /// **Current implementation:** Always returns nil, indicating the caller
    /// should fall back to standard single-model generation. This will be
    /// replaced with the speculative decoding loop when mlx-swift-lm ships
    /// the required API.
    ///
    /// The API accepts only plain strings (not `Chat.Message` or `GenerateParameters`)
    /// because the actual speculative decoding implementation will need to reconstruct
    /// model-specific inputs within this actor's isolation context. Using strings also
    /// avoids Sendable issues with non-Sendable MLX types across actor boundaries.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt text.
    ///   - systemPrompt: The system prompt (with tool definitions if applicable).
    ///   - maxTokens: Maximum tokens to generate.
    ///   - temperature: Sampling temperature.
    /// - Returns: Generated text and token counts, or nil if speculative
    ///   decoding is not available/ready.
    func speculativeGenerate(
        prompt: String,
        systemPrompt: String,
        maxTokens: Int?,
        temperature: Double
    ) async throws -> SpeculativeResult? {

        guard isReady else {
            logger.debug("Speculative decoding not ready — falling back to standard generation")
            return nil
        }

        // --- API NOT YET AVAILABLE ---
        //
        // When mlx-swift-lm exposes speculative decoding, implement here:
        //
        // 1. Load draft model container via lifecycle
        //    (Need a way to load the 1.5B draft specifically — may require lifecycle changes)
        //
        // 2. Load verifier model container via lifecycle
        //
        // 3. Run the speculative decoding loop:
        //    - Draft generates `config.draftLength` tokens
        //    - Verifier batch-evaluates all draft tokens in one forward pass
        //    - Accept matching prefix, reject at first divergence
        //    - Track accepted/rejected counts
        //
        // 4. Update diagnostics:
        //    DiagnosticsStore.shared.increment("speculative_attempt_total")
        //    DiagnosticsStore.shared.increment("speculative_accepted_tokens_total", by: accepted)
        //    DiagnosticsStore.shared.increment("speculative_rejected_tokens_total", by: rejected)
        //
        // For now, return nil to signal fallback to standard generation.

        logger.info("Speculative decoding API not yet available in mlx-swift-lm — falling back")
        return nil
    }

    // MARK: - Internal Token Accounting (for future use)

    /// Record accepted/rejected tokens from a speculative round.
    /// Called by the speculative generation loop when implemented.
    func recordRound(accepted: Int, rejected: Int) {
        acceptedTokens += Int64(accepted)
        rejectedTokens += Int64(rejected)
        roundsAttempted += 1

        DiagnosticsStore.shared.increment("speculative_attempt_total")
        DiagnosticsStore.shared.increment("speculative_accepted_tokens_total", by: Int64(accepted))
        DiagnosticsStore.shared.increment("speculative_rejected_tokens_total", by: Int64(rejected))

        if let rate = acceptanceRate {
            DiagnosticsStore.shared.setGauge("speculative_acceptance_rate", value: rate)
        }
    }
}
