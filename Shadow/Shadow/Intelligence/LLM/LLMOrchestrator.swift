import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "LLMOrchestrator")

/// Routes LLM requests to providers based on mode, availability, and consent.
///
/// Actor isolation eliminates manual locking — safe for concurrent callers.
///
/// Provider resolution order:
/// - `.localOnly`  → [local]
/// - `.cloudOnly`  → [cloud]
/// - `.auto`       → [local, cloud]
///
/// No silent cloud fallback in any mode. Cloud is only reached if mode allows
/// it AND consent is granted.
actor LLMOrchestrator {
    private var providers: [any LLMProvider]
    private var mode: LLMMode

    init(providers: [any LLMProvider], mode: LLMMode = .auto) {
        self.providers = providers
        self.mode = mode
    }

    /// Insert a provider at the given index.
    /// Used to hot-swap a local model into position 0 after background loading.
    func insertProvider(_ provider: any LLMProvider, at index: Int) {
        let clamped = min(index, providers.count)
        providers.insert(provider, at: clamped)
        logger.info("Provider \(provider.providerName) inserted at index \(clamped)")
    }

    /// Remove all providers with the given name.
    /// Used to dynamically remove opt-in providers (e.g. Ollama) when the user disables them.
    func removeProvider(named name: String) {
        providers.removeAll { $0.providerName == name }
        logger.info("Provider \(name) removed")
    }

    /// Update the routing mode.
    func setMode(_ newMode: LLMMode) {
        mode = newMode
        DiagnosticsStore.shared.setStringGauge("llm_mode", value: newMode.rawValue)
        logger.info("LLM mode set to \(newMode.rawValue)")
    }

    /// Current mode.
    func currentMode() -> LLMMode { mode }

    /// Whether any provider is currently available (basic reachability check).
    var hasAvailableProvider: Bool {
        resolveProviderOrder().contains(where: { $0.isAvailable })
    }

    /// Whether a generate() call would succeed right now — checks mode, availability, AND consent.
    ///
    /// Unlike `hasAvailableProvider`, this also verifies that cloud providers have consent granted,
    /// so callers can skip work rather than entering a fail/backoff path on `.consentRequired`.
    var canGenerateNow: Bool {
        let candidates = resolveProviderOrder()
        for provider in candidates {
            guard provider.isAvailable else { continue }
            // Cloud providers may be "available" (have API key) but lack consent.
            // A dry-run check: if the provider would throw .consentRequired, skip it.
            if provider.providerName.contains("cloud") {
                if !UserDefaults.standard.bool(forKey: "llmCloudConsentGranted") {
                    continue
                }
            }
            return true
        }
        return false
    }

    /// Active provider name and model ID (for UI display).
    var activeProviderInfo: (provider: String, model: String)? {
        for p in resolveProviderOrder() where p.isAvailable {
            return (p.providerName, p.modelId)
        }
        return nil
    }

    /// Generate a response using the provider chain.
    ///
    /// Tries each candidate provider in order:
    /// - Skip if `!isAvailable`
    /// - On success: record diagnostics, return
    /// - On `.consentRequired`: increment blocked counter, try next
    /// - On `.unavailable`/`.transientFailure`: try next
    /// - On `.malformedOutput`: try next provider
    /// - On `.terminalFailure`/`.timeout`: throw immediately (no retry)
    func generate(request: LLMRequest) async throws -> LLMResponse {
        let candidates = resolveProviderOrder()
        DiagnosticsStore.shared.increment("summary_request_total")

        for provider in candidates {
            guard provider.isAvailable else { continue }

            let providerKey = provider.providerName.contains("local") ? "local" : "cloud"
            DiagnosticsStore.shared.increment("summary_\(providerKey)_attempt_total")

            do {
                let response = try await provider.generate(request: request)

                // Success metrics
                DiagnosticsStore.shared.increment("summary_\(providerKey)_success_total")
                DiagnosticsStore.shared.increment("summary_success_total")
                DiagnosticsStore.shared.recordLatency("summary_\(providerKey)_ms", ms: response.latencyMs)
                DiagnosticsStore.shared.recordLatency("summary_total_ms", ms: response.latencyMs)
                DiagnosticsStore.shared.setStringGauge("llm_active_provider", value: response.provider)
                DiagnosticsStore.shared.setStringGauge("llm_active_model_id", value: response.modelId)

                logger.info("LLM generate succeeded: provider=\(response.provider) model=\(response.modelId) latency=\(String(format: "%.0f", response.latencyMs))ms")
                return response

            } catch let error as LLMProviderError {
                switch error {
                case .consentRequired:
                    DiagnosticsStore.shared.increment("summary_cloud_blocked_no_consent_total")
                    DiagnosticsStore.shared.postWarning(
                        severity: .warning,
                        subsystem: "Intelligence",
                        code: "SUMMARY_CLOUD_NOT_CONSENTED",
                        message: "Cloud LLM blocked: user consent not granted"
                    )
                    logger.info("Provider \(provider.providerName) requires consent, trying next")

                case .unavailable(let reason):
                    DiagnosticsStore.shared.increment("summary_\(providerKey)_fail_total")
                    logger.info("Provider \(provider.providerName) unavailable: \(reason)")

                case .transientFailure(let underlying):
                    DiagnosticsStore.shared.increment("summary_\(providerKey)_fail_total")
                    logger.warning("Provider \(provider.providerName) transient failure: \(underlying, privacy: .public)")

                case .malformedOutput(let detail):
                    DiagnosticsStore.shared.increment("summary_\(providerKey)_fail_total")
                    DiagnosticsStore.shared.increment("summary_schema_invalid_total")
                    DiagnosticsStore.shared.postWarning(
                        severity: .warning,
                        subsystem: "Intelligence",
                        code: "SUMMARY_SCHEMA_INVALID",
                        message: "Malformed output from \(provider.providerName): \(detail)"
                    )
                    logger.warning("Provider \(provider.providerName) malformed output: \(detail, privacy: .public)")

                case .timeout:
                    DiagnosticsStore.shared.increment("summary_\(providerKey)_fail_total")
                    DiagnosticsStore.shared.increment("summary_fail_total")
                    DiagnosticsStore.shared.postWarning(
                        severity: .warning,
                        subsystem: "Intelligence",
                        code: "SUMMARY_JOB_TIMEOUT",
                        message: "Provider \(provider.providerName) timed out"
                    )
                    throw error  // Timeout is terminal — don't retry

                case .terminalFailure:
                    DiagnosticsStore.shared.increment("summary_\(providerKey)_fail_total")
                    DiagnosticsStore.shared.increment("summary_fail_total")
                    throw error  // Terminal — don't retry
                }

            } catch {
                // Unexpected error — treat as transient
                DiagnosticsStore.shared.increment("summary_\(providerKey)_fail_total")
                logger.warning("Provider \(provider.providerName) unexpected error: \(error, privacy: .public)")
            }
        }

        // All providers exhausted
        DiagnosticsStore.shared.increment("summary_fail_total")
        DiagnosticsStore.shared.postWarning(
            severity: .warning,
            subsystem: "Intelligence",
            code: "SUMMARY_PROVIDER_UNAVAILABLE",
            message: "No LLM providers available (mode=\(mode.rawValue))"
        )
        throw LLMProviderError.unavailable(reason: "All providers exhausted (mode=\(mode.rawValue))")
    }

    // MARK: - Provider Resolution

    /// Resolve the ordered list of providers to try based on current mode.
    private func resolveProviderOrder() -> [any LLMProvider] {
        switch mode {
        case .localOnly:
            return providers.filter { $0.providerName.contains("local") }
        case .cloudOnly:
            return providers.filter { $0.providerName.contains("cloud") }
        case .auto:
            // Local first, then cloud
            let local = providers.filter { $0.providerName.contains("local") }
            let cloud = providers.filter { $0.providerName.contains("cloud") }
            return local + cloud
        }
    }
}
