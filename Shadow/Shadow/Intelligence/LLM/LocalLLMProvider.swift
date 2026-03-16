import Foundation
import MLX
import MLXLMCommon
import MLXLLM
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "LocalLLMProvider")

/// Local on-device LLM provider using MLX Swift for Apple Silicon inference.
///
/// Supports two tiers:
/// - **Fast tier (7B):** Qwen2.5-7B-Instruct-4bit (~4.5 GB). Default for simple requests.
/// - **Deep tier (32B):** Qwen2.5-32B-Instruct-4bit (~18 GB). For complex multi-step agent tasks.
///
/// Tier selection is automatic based on request characteristics:
/// - Deep tier is used when: the deep model is provisioned, system has sufficient RAM,
///   and the request has tools with a multi-step conversation (>2 messages).
/// - Otherwise, the fast tier is used.
/// - If the deep tier fails to load (OOM or other), falls back to fast silently.
///
/// Conforms to `LLMProvider` — the same protocol as `CloudLLMProvider`.
/// The orchestrator sees a single "local_mlx" provider; tier selection is internal.
///
/// Actor isolation serializes generate() calls and protects mutable state.
/// The `isAvailable` and `providerName` properties are nonisolated because
/// they only access immutable `let` state or perform synchronous file checks.
///
/// Tool calling uses the Hermes format: tool definitions are injected into
/// the system prompt, and tool calls are parsed from `<tool_call>` blocks
/// in the model's response. This is handled by `LocalToolCallParser`.
///
/// Lifecycle (lazy load, idle unload, mutual exclusion, memory pressure) is
/// delegated to `LocalModelLifecycle`.
///
/// **Session cache (Phase 6):** Multi-turn agent conversations benefit from
/// KV-cache reuse. When the agent runtime makes successive `generate()` calls
/// with incrementally extending message history (same system prompt), the
/// SessionCache detects the continuation and reuses the ChatSession. Only
/// the new user message needs KV-cache computation — prior turns are cached.
/// Single-pass requests always create fresh sessions.
actor LocalLLMProvider: LLMProvider {

    nonisolated let providerName = "local_mlx"
    nonisolated let modelId: String

    /// On-disk path to the fast model directory. Used for `isAvailable` check.
    /// Immutable, set in init. `nonisolated` access is safe because it's a `let`.
    nonisolated let modelPath: String

    /// Lifecycle manager — handles loading, unloading, idle timer, mutual exclusion, memory pressure.
    private let lifecycle: LocalModelLifecycle

    /// Session cache for KV-cache reuse across multi-turn agent conversations.
    private let sessionCache: SessionCache

    /// Speculative decoding infrastructure. When enabled and both draft + verifier
    /// models are loaded, generation can use speculative decoding for 1.3-1.8x speedup.
    /// Currently disabled — mlx-swift-lm v2.30.0 does not expose the required API.
    private let speculativeDecoder: SpeculativeDecoder?

    /// Speculative decoding configuration. Exposed for diagnostics/testing.
    let speculativeConfig: SpeculativeDecodingConfig

    /// Initialize the provider.
    ///
    /// The provider's `modelId` and `isAvailable` reflect the fast tier (the baseline).
    /// Deep tier is an upgrade for complex requests, not a requirement for availability.
    ///
    /// - Parameter lifecycle: Shared lifecycle manager. Pass an external instance to share
    ///   mutual exclusion and memory pressure handling with other providers (e.g., VisionLLMProvider).
    ///   If nil, creates a new lifecycle internally.
    /// - Parameter speculativeConfig: Configuration for speculative decoding.
    ///   Defaults to `.default` (disabled). Pass a custom config with `enabled: true`
    ///   to activate speculative decoding when the API becomes available.
    init(
        lifecycle: LocalModelLifecycle? = nil,
        speculativeConfig: SpeculativeDecodingConfig = .default
    ) {
        let fastSpec = LocalModelRegistry.fastDefault
        self.modelId = fastSpec.localDirectoryName
        self.modelPath = LocalModelRegistry.modelPath(for: fastSpec).path
        let sharedLifecycle = lifecycle ?? LocalModelLifecycle()
        self.lifecycle = sharedLifecycle
        self.sessionCache = SessionCache()
        self.speculativeConfig = speculativeConfig
        self.speculativeDecoder = SpeculativeDecoder(config: speculativeConfig, lifecycle: sharedLifecycle)
    }

    /// Fast synchronous check: can this provider accept work?
    ///
    /// Returns true if the fast model directory exists and contains config.json.
    /// The provider is "available" if it can handle any request via the fast tier.
    /// Deep tier is an optional upgrade, not a requirement.
    nonisolated var isAvailable: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelPath) else { return false }
        return fm.fileExists(atPath: modelPath + "/config.json")
    }

    /// Generate a response for the given request.
    ///
    /// Flow:
    /// 1. Select tier based on request characteristics
    /// 2. Ensure model is loaded (lazy load via lifecycle manager)
    /// 3. Build system prompt with optional tool definitions
    /// 4. Format multi-turn messages into Chat.Message array
    /// 5. Create a ChatSession and stream the response
    /// 6. Collect text, parse tool calls, extract token counts
    /// 7. Return complete LLMResponse with the actual model ID used
    ///
    /// If the deep tier fails to load, silently falls back to fast tier.
    ///
    /// - Parameter request: The structured LLM request.
    /// - Returns: Complete `LLMResponse` with content, tool calls, and metrics.
    /// - Throws: `LLMProviderError` on failure.
    func generate(request: LLMRequest) async throws -> LLMResponse {
        DiagnosticsStore.shared.increment("llm_local_attempt_total")

        guard isAvailable else {
            DiagnosticsStore.shared.increment("llm_local_fail_total")
            throw LLMProviderError.unavailable(
                reason: "Local model not provisioned at \(modelPath)"
            )
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. Select tier based on request characteristics
        var tier = selectTier(for: request)

        // Track tier selection
        if tier == .deep {
            DiagnosticsStore.shared.increment("llm_local_tier_deep_total")
        } else {
            DiagnosticsStore.shared.increment("llm_local_tier_fast_total")
        }

        // 1a. Invalidate session cache for any tiers unloaded since last generate().
        // Idle timer, mutual exclusion, and memory pressure all unload models without
        // going through the provider — the lifecycle records them as pending invalidations.
        let unloadedTiers = await lifecycle.drainPendingInvalidations()
        for unloadedTier in unloadedTiers {
            sessionCache.invalidate(tier: unloadedTier)
        }

        // 2. Ensure model is loaded (with OOM fallback for deep tier)
        let container: ModelContainer
        do {
            container = try await lifecycle.ensureLoaded(tier: tier)
        } catch where tier == .deep {
            // Deep tier failed to load — fall back to fast silently
            logger.warning("Deep tier load failed, falling back to fast: \(error, privacy: .public)")
            DiagnosticsStore.shared.increment("llm_local_tier_deep_fallback_total")
            tier = .fast
            do {
                container = try await lifecycle.ensureLoaded(tier: .fast)
            } catch {
                DiagnosticsStore.shared.increment("llm_local_fail_total")
                throw error
            }
        } catch {
            DiagnosticsStore.shared.increment("llm_local_fail_total")
            throw error
        }

        // Determine the actual model ID for the response
        let actualModelId = tier == .deep
            ? LocalModelRegistry.deepDefault.localDirectoryName
            : LocalModelRegistry.fastDefault.localDirectoryName

        // 3. Build system prompt (with tool definitions and JSON instruction if needed)
        var systemPrompt = request.systemPrompt
        if request.responseFormat == .json {
            systemPrompt = "Respond with valid JSON only.\n\n" + systemPrompt
        }
        if !request.tools.isEmpty {
            DiagnosticsStore.shared.increment("llm_local_tool_parse_total")
            let toolDefs = LocalToolCallParser.formatToolDefinitions(request.tools)
            if !toolDefs.isEmpty {
                systemPrompt = toolDefs + "\n\n" + systemPrompt
            }
        }

        // 4. Build message history for the ChatSession
        let (history, lastUserPrompt) = buildChatMessages(request: request)

        // 5. Configure generation parameters
        var genParams = GenerateParameters()
        genParams.maxTokens = request.maxTokens
        genParams.temperature = Float(request.temperature)

        // 5a. Attempt speculative decoding (when enabled and ready).
        // If speculativeGenerate() returns a result, skip standard generation.
        // If it returns nil (not ready or API not available), fall through.
        if tier == .fast, let decoder = speculativeDecoder {
            if let result = try await decoder.speculativeGenerate(
                prompt: lastUserPrompt,
                systemPrompt: systemPrompt,
                maxTokens: request.maxTokens,
                temperature: request.temperature
            ) {
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                let (content, toolCalls) = LocalToolCallParser.parse(response: result.text)

                let response = LLMResponse(
                    content: content,
                    toolCalls: toolCalls,
                    provider: providerName,
                    modelId: actualModelId + " (speculative)",
                    inputTokens: result.promptTokenCount,
                    outputTokens: result.generationTokenCount,
                    latencyMs: elapsed
                )

                DiagnosticsStore.shared.increment("llm_local_success_total")
                DiagnosticsStore.shared.recordLatency("llm_local_latency_ms", ms: elapsed)
                DiagnosticsStore.shared.recordLatency("speculative_latency_ms", ms: elapsed)

                logger.info("Speculative generation: \(result.text.count) chars, \(toolCalls.count) tool calls, \(String(format: "%.0f", elapsed))ms")
                return response
            }
        }

        // 6. Resolve session — reuse from cache or create fresh.
        //
        // Multi-turn optimization: When the agent runtime sends successive calls
        // with incrementally extending history (same system prompt), we can reuse
        // the ChatSession from the prior call. The KV-cache already contains all
        // prior turns, so only the new user message needs processing.
        //
        // Single-pass requests (no messages) always create fresh sessions — there
        // is no prior conversation to continue.
        let isMultiTurn = request.messages != nil && !(request.messages?.isEmpty ?? true)
        let messageCount = request.messages?.count ?? 0
        let session: ChatSession
        var sessionReused = false

        if isMultiTurn,
           let cached = sessionCache.getSession(
               tier: tier,
               systemPrompt: systemPrompt,
               messageCount: messageCount
           ),
           let reusedSession = cached.session as? ChatSession {
            session = reusedSession
            sessionReused = cached.isReused
        } else {
            // Fresh session: single-pass or no cache hit for multi-turn
            session = ChatSession(
                container,
                instructions: systemPrompt,
                history: history,
                generateParameters: genParams
            )
            if isMultiTurn {
                DiagnosticsStore.shared.increment("llm_local_session_cache_miss_total")
            }
        }

        // 7. Stream the response and collect text + completion info
        let (responseText, completionInfo) = try await streamResponse(
            session: session,
            prompt: lastUserPrompt
        )

        // 8. Store session in cache for potential multi-turn continuation.
        // Only cache multi-turn sessions — single-pass sessions cannot be meaningfully reused.
        if isMultiTurn {
            sessionCache.store(
                session: session,
                tier: tier,
                systemPrompt: systemPrompt,
                messageCount: messageCount
            )
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        // 9. Parse tool calls from the response
        var (content, toolCalls) = LocalToolCallParser.parse(response: responseText)

        // Track tool parse failures: response contained <tool_call> but parsing yielded 0 calls
        if !request.tools.isEmpty && responseText.contains("<tool_call>") && toolCalls.isEmpty {
            DiagnosticsStore.shared.increment("llm_local_tool_parse_fail_total")
            logger.warning("Tool call parsing failed: response contained <tool_call> but no valid calls extracted")
        }

        // 9a. JSON mode: strip markdown fences and validate well-formed JSON.
        // Reuses CloudLLMProvider's validation (same logic as the cloud path).
        // Throws .malformedOutput on failure so the orchestrator falls through to next provider.
        if request.responseFormat == .json {
            content = CloudLLMProvider.stripMarkdownFences(content)
            try CloudLLMProvider.validateJSONContent(content)
        }

        // 10. Build response with token counts from the MLX generation info
        let inputTokens = completionInfo?.promptTokenCount
        let outputTokens = completionInfo?.generationTokenCount

        let response = LLMResponse(
            content: content,
            toolCalls: toolCalls,
            provider: providerName,
            modelId: actualModelId,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            latencyMs: elapsed
        )

        DiagnosticsStore.shared.increment("llm_local_success_total")
        DiagnosticsStore.shared.recordLatency("llm_local_latency_ms", ms: elapsed)

        let cacheStatus = sessionReused ? "cached" : "fresh"
        logger.info("Local LLM generate: tier=\(tier.rawValue) session=\(cacheStatus) \(responseText.count) chars, \(toolCalls.count) tool calls, \(String(format: "%.0f", elapsed))ms, in=\(inputTokens ?? 0) out=\(outputTokens ?? 0)")

        return response
    }

    /// Unload all models and invalidate session cache (for shutdown or memory pressure).
    /// Called by AppDelegate during app termination.
    func shutdown() async {
        sessionCache.invalidateAll()
        await speculativeDecoder?.updateDiagnostics()
        await lifecycle.unloadAll()
    }

    // MARK: - Tier Selection

    /// Select the appropriate tier for a request.
    ///
    /// Uses deep tier when ALL of these conditions are met:
    /// 1. Deep model is provisioned on disk
    /// 2. System has enough RAM for the deep model (or deep is already loaded)
    /// 3. Request has tools (tool-calling task)
    /// 4. Request has >2 messages (multi-step agent conversation)
    ///
    /// Otherwise uses the fast tier.
    private func selectTier(for request: LLMRequest) -> LocalModelTier {
        let deepSpec = LocalModelRegistry.deepDefault
        let deepProvisioned = LocalModelRegistry.isDownloaded(deepSpec)
        let hasEnoughRAM = MLXConfiguration.systemRAMGB >= deepSpec.minimumSystemRAMGB

        guard deepProvisioned && hasEnoughRAM else { return .fast }

        // Use deep for complex multi-step agent tasks
        let hasTools = !request.tools.isEmpty
        let isMultiStep = (request.messages?.count ?? 0) > 2

        return (hasTools && isMultiStep) ? .deep : .fast
    }

    // MARK: - Multi-Turn Message Formatting

    /// Build Chat.Message history from an LLMRequest.
    ///
    /// Returns all messages except the last user message (which becomes the
    /// prompt for `ChatSession.respond(to:)`), plus that last user message
    /// as a separate string.
    ///
    /// For local models using Hermes format:
    /// - tool_use blocks become assistant text with `<tool_call>` tags
    /// - tool_result blocks become user text with formatted output
    /// - image blocks are skipped (local model doesn't support images in this tier)
    private func buildChatMessages(request: LLMRequest) -> (history: [Chat.Message], lastUserPrompt: String) {
        guard let messages = request.messages, !messages.isEmpty else {
            // Legacy single-pass mode: no history, just the user prompt
            return (history: [], lastUserPrompt: request.userPrompt)
        }

        // Convert LLMMessages to Chat.Messages
        var chatMessages: [Chat.Message] = []

        for msg in messages {
            let text = formatMessageContent(msg.content)
            let role: Chat.Message.Role = msg.role == "assistant" ? .assistant : .user
            chatMessages.append(Chat.Message(role: role, content: text))
        }

        // The last message should be a user message — it becomes the prompt
        // for ChatSession.respond(to:). Everything before it is history.
        if let last = chatMessages.last, last.role == .user {
            let history = Array(chatMessages.dropLast())
            return (history: history, lastUserPrompt: last.content)
        } else {
            // Edge case: last message is not user role. Use empty prompt.
            // This shouldn't happen in normal agent flow.
            logger.warning("Last message is not user role — using empty prompt")
            return (history: chatMessages, lastUserPrompt: "")
        }
    }

    /// Format LLMMessageContent blocks into a single text string for the local model.
    ///
    /// - text blocks are concatenated
    /// - tool_use blocks are formatted as `<tool_call>` XML blocks
    /// - tool_result blocks are formatted as structured text
    /// - image blocks are noted but not included (text models don't support images)
    private func formatMessageContent(_ content: [LLMMessageContent]) -> String {
        var parts: [String] = []

        for block in content {
            switch block {
            case .text(let text):
                if !text.isEmpty {
                    parts.append(text)
                }

            case .toolUse(let id, let name, let input):
                // Format as Hermes tool call so the model sees its own format in history
                let argsDict = input.mapValues { LocalToolCallParser.anyCodableToJSONObject($0) }
                if let data = try? JSONSerialization.data(
                    withJSONObject: ["name": name, "arguments": argsDict],
                    options: [.sortedKeys]
                ), let json = String(data: data, encoding: .utf8) {
                    parts.append("<tool_call>\n\(json)\n</tool_call>")
                } else {
                    parts.append("<tool_call>\n{\"name\": \"\(name)\"}\n</tool_call>")
                }
                _ = id  // Consumed for completeness, not needed in local format

            case .toolResult(let toolUseId, let content, let isError):
                let prefix = isError ? "[Tool Error]" : "[Tool Result]"
                // Truncate very long tool results to avoid blowing context
                let truncated = content.count > 8000 ? String(content.prefix(8000)) + "\n...(truncated)" : content
                parts.append("\(prefix) (id: \(toolUseId))\n\(truncated)")

            case .image:
                // Text models don't process images — note and skip
                parts.append("[Image content omitted — not supported by local text model]")
            }
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Streaming

    /// Stream a response from the ChatSession and collect the full text
    /// plus completion info (token counts).
    ///
    /// Uses `streamDetails` to get both text chunks and `GenerateCompletionInfo`.
    private func streamResponse(
        session: ChatSession,
        prompt: String
    ) async throws -> (text: String, info: GenerateCompletionInfo?) {
        var fullText = ""
        var completionInfo: GenerateCompletionInfo?

        let stream = session.streamDetails(to: prompt, images: [], videos: [])

        do {
            for try await generation in stream {
                switch generation {
                case .chunk(let text):
                    fullText += text
                case .info(let info):
                    completionInfo = info
                case .toolCall:
                    // MLX's built-in tool call parsing — we don't use it because
                    // we handle Hermes format ourselves via LocalToolCallParser.
                    break
                }
            }
        } catch {
            DiagnosticsStore.shared.increment("llm_local_fail_total")
            logger.error("Local LLM generation failed: \(error, privacy: .public)")
            throw LLMProviderError.transientFailure(
                underlying: "MLX generation failed: \(error.localizedDescription)"
            )
        }

        return (text: fullText, info: completionInfo)
    }
}
