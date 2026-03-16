import Foundation
import os.log

#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "com.shadow.app", category: "AppleFoundationProvider")

/// Apple Foundation Models provider for sub-500ms classification and extraction.
///
/// Uses Apple's on-device ~3B model via the FoundationModels framework (macOS 26+).
/// Runs on the Neural Engine (ANE), not GPU — zero contention with MLX models.
///
/// The 4096-token context window (input + output combined) means prompts must be compact.
/// Best for: classification, entity extraction, intent detection, nudge gating.
/// Not for: multi-step agent tasks, long generation, tool calling.
///
/// On macOS < 26 or when FoundationModels is not in the SDK, this provider
/// simply reports unavailable and all generate() calls throw.
///
/// Provider name contains "local" so the orchestrator includes it in auto/localOnly
/// routing via `resolveProviderOrder()`.
final class AppleFoundationProvider: @unchecked Sendable, LLMProvider {

    // MARK: - Provider Identity

    /// Contains "local" for orchestrator routing (resolveProviderOrder filters on this).
    let providerName = "local_apple_foundation"
    let modelId = "apple-on-device"

    // MARK: - Configuration

    /// Maximum combined prompt length in characters. The Apple Foundation Model has a
    /// ~4096-token context window (input + output). At ~4 chars/token, we budget ~2000
    /// chars for the prompt to leave room for output.
    static let maxPromptChars = 2000

    /// Maximum number of messages before the request is considered too complex.
    /// Apple Foundation Models is for single-pass classification, not multi-turn.
    static let maxMessages = 2

    // MARK: - State

    /// Cached availability. Updated at init and on each generate() call.
    private let availabilityLock = OSAllocatedUnfairLock(initialState: false)

    // MARK: - Init

    init() {
        updateAvailability()
    }

    // MARK: - LLMProvider Conformance

    /// Synchronous availability check (protocol requirement).
    /// Returns true only when FoundationModels is in the SDK AND the on-device model
    /// reports `.available` on macOS 26+.
    var isAvailable: Bool {
        availabilityLock.withLock { $0 }
    }

    func generate(request: LLMRequest) async throws -> LLMResponse {
        let startTime = CFAbsoluteTimeGetCurrent()
        updateAvailability()

        DiagnosticsStore.shared.increment("apple_foundation_attempt_total")

        // Gate 1: Framework/OS availability
        guard isAvailable else {
            DiagnosticsStore.shared.increment("apple_foundation_fail_total")
            throw LLMProviderError.unavailable(
                reason: "Apple Foundation Models not available (requires macOS 26+ with Apple Intelligence)"
            )
        }

        // Gate 2: Tool calling not supported — Apple Foundation Models has a 4096-token
        // context window and no native tool-calling protocol compatible with our ToolSpec.
        if !request.tools.isEmpty {
            DiagnosticsStore.shared.increment("apple_foundation_skip_total")
            logger.debug("Skipping: request has \(request.tools.count) tools")
            throw LLMProviderError.unavailable(
                reason: "Apple Foundation Models does not support tool calling"
            )
        }

        // Gate 3: Multi-turn conversations exceed the context window.
        if let messages = request.messages, messages.count > Self.maxMessages {
            DiagnosticsStore.shared.increment("apple_foundation_skip_total")
            logger.debug("Skipping: request has \(messages.count) messages (max \(Self.maxMessages))")
            throw LLMProviderError.unavailable(
                reason: "Apple Foundation Models context too small for multi-turn (\(messages.count) messages)"
            )
        }

        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let response = try await generateWithFoundationModels(request: request, startTime: startTime)
            return response
        }
        #endif

        // Should not reach here if isAvailable was true, but handle defensively.
        DiagnosticsStore.shared.increment("apple_foundation_fail_total")
        throw LLMProviderError.unavailable(
            reason: "Apple Foundation Models requires macOS 26+"
        )
    }

    // MARK: - Availability

    private func updateAvailability() {
        let available = Self.checkFrameworkAvailability()
        availabilityLock.withLock { $0 = available }
        DiagnosticsStore.shared.setGauge("apple_foundation_available", value: available ? 1 : 0)
    }

    /// Pure check — no mutable state. Extracted to avoid capturing `var` in closure.
    private static func checkFrameworkAvailability() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    // MARK: - Generation (FoundationModels)

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private func generateWithFoundationModels(
        request: LLMRequest,
        startTime: CFAbsoluteTime
    ) async throws -> LLMResponse {
        // Build compact system prompt — truncate to stay within context budget.
        // Prepend JSON instruction if JSON response format requested.
        var rawPrompt = request.systemPrompt
        if request.responseFormat == .json {
            rawPrompt = "Respond with valid JSON only.\n\n" + rawPrompt
        }
        let systemPrompt = String(rawPrompt.prefix(Self.maxPromptChars / 2))

        // Build user prompt from messages or legacy userPrompt
        let userPrompt: String
        if let messages = request.messages, let lastUser = messages.last(where: { $0.role == "user" }) {
            // Extract text content from the last user message
            userPrompt = lastUser.content.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }.joined(separator: "\n")
        } else {
            userPrompt = request.userPrompt
        }

        // Truncate combined prompt to fit context window
        let remainingBudget = Self.maxPromptChars - systemPrompt.count
        let truncatedUserPrompt = String(userPrompt.prefix(max(remainingBudget, 200)))

        // Create session with system instructions and generate.
        // LanguageModelSession accepts instructions as a trailing closure.
        let instructions = systemPrompt  // Capture for closure
        let session = LanguageModelSession { instructions }

        let responseText: String
        do {
            let response = try await session.respond(to: truncatedUserPrompt)
            responseText = response.content
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            DiagnosticsStore.shared.increment("apple_foundation_fail_total")
            DiagnosticsStore.shared.recordLatency("apple_foundation_latency_ms", ms: elapsed)
            logger.error("Apple Foundation Models generation failed: \(error, privacy: .public)")
            throw LLMProviderError.transientFailure(
                underlying: "Apple Foundation Models error: \(error.localizedDescription)"
            )
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        // JSON mode: strip markdown fences and validate well-formed JSON.
        // Throws .malformedOutput on failure so the orchestrator falls through to next provider.
        var content = responseText
        if request.responseFormat == .json {
            content = CloudLLMProvider.stripMarkdownFences(content)
            try CloudLLMProvider.validateJSONContent(content)
        }

        // Metrics
        DiagnosticsStore.shared.increment("apple_foundation_success_total")
        DiagnosticsStore.shared.recordLatency("apple_foundation_latency_ms", ms: elapsed)

        logger.info("Apple Foundation generate: \(responseText.count) chars, \(String(format: "%.0f", elapsed))ms")

        return LLMResponse(
            content: content,
            toolCalls: [],
            provider: providerName,
            modelId: modelId,
            inputTokens: nil,   // Foundation Models does not expose token counts
            outputTokens: nil,
            latencyMs: elapsed
        )
    }
    #endif
}
