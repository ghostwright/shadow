import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "AgentRuntime")

/// Agent runtime that executes tool-calling loops against an LLM provider.
///
/// Stateless enum (same pattern as `MeetingResolver`, `SummaryCoordinator`).
/// All loop state is local to `run()`. Returns `AsyncStream<AgentRunEvent>`
/// for live consumption by the UI layer.
///
/// Terminal events: `.finalAnswer`, `.runFailed`, `.runCancelled`.
/// The stream finishes immediately after a terminal event.
enum AgentRuntime {

    /// Start an agent run. Returns a stream of events.
    ///
    /// The loop sends messages+tools to the LLM, executes tool calls,
    /// and iterates until a final answer is produced or a budget/error
    /// condition is hit.
    ///
    /// Cancellation: the caller cancels by cancelling the Task that is
    /// iterating the stream. The loop checks `Task.isCancelled` between
    /// iterations and emits `.runCancelled`.
    static func run(
        request: AgentRunRequest,
        orchestrator: LLMOrchestrator,
        registry: AgentToolRegistry,
        contextStore: ContextStore? = nil,
        patternStore: PatternStore? = nil
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            let task = Task {
                await executeLoop(
                    request: request,
                    orchestrator: orchestrator,
                    registry: registry,
                    contextStore: contextStore,
                    patternStore: patternStore,
                    continuation: continuation
                )
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Loop Implementation

    private static func executeLoop(
        request: AgentRunRequest,
        orchestrator: LLMOrchestrator,
        registry: AgentToolRegistry,
        contextStore: ContextStore?,
        patternStore: PatternStore?,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async {
        let startTime = CFAbsoluteTimeGetCurrent()
        let config = request.config

        // Fail fast if no tools are registered
        if registry.isEmpty {
            continuation.yield(.runFailed(.noToolsAvailable))
            DiagnosticsStore.shared.increment("agent_run_fail_total")
            logger.warning("Agent run failed: no tools registered")
            return
        }

        var stepCount = 0
        var toolCallCount = 0
        var allToolRecords: [AgentToolCallRecord] = []
        var allEvidence: [AgentEvidenceItem] = []
        var inputTokensTotal = 0
        var outputTokensTotal = 0
        var lastProvider = ""
        var lastModelId = ""

        // Build context-enriched system prompt
        let basePrompt = AgentPromptBuilder.systemPrompt
        var systemPrompt = basePrompt
        if let ctxStore = contextStore {
            let pack = ContextPacker.pack(contextStore: ctxStore)
            if !pack.packText.isEmpty {
                systemPrompt = systemPrompt + "\n\n" + pack.packText
                logger.info("Context pack injected: \(pack.includedRecords.count) records, \(pack.estimatedTokens) est. tokens")
            }
        }

        // Mimicry Phase A: Inject behavioral context from past user interactions.
        // Search for how the user has done similar tasks before and include as prompt context.
        let behavioralContext = BehavioralSearch.searchAndFormat(
            query: request.task,
            targetApp: "",  // Empty = search all apps
            maxResults: 3
        )
        if !behavioralContext.isEmpty {
            systemPrompt = systemPrompt + "\n\n" + behavioralContext
            logger.info("Behavioral context injected into agent prompt")
        }

        // Mimicry Phase A4: Inject extracted workflows from passive observation.
        // These are recurring action sequences automatically detected from the user's data.
        let extractedWorkflows = WorkflowExtractor.extract(
            lookbackHours: 168,  // 1 week
            maxResults: 3
        )
        if !extractedWorkflows.isEmpty {
            let workflowContext = WorkflowExtractor.formatForPrompt(extractedWorkflows)
            systemPrompt = systemPrompt + "\n\n" + workflowContext
            logger.info("Injected \(extractedWorkflows.count) extracted workflows into agent prompt")
        }

        // Inject relevant patterns from previous successful runs
        var injectedPatternIds: [String] = []
        if let patternStore {
            let patternPrompt = PatternMatcher.findAndFormat(
                query: request.task,
                store: patternStore
            )
            if !patternPrompt.isEmpty {
                systemPrompt = systemPrompt + "\n\n" + patternPrompt
                injectedPatternIds = patternStore.findRelevant(query: request.task).map(\.id)
                logger.info("Injected \(injectedPatternIds.count) patterns into agent prompt")
            }
        }

        // Build initial message history
        var messages: [LLMMessage] = [
            LLMMessage(role: "user", content: [.text(request.task)])
        ]

        continuation.yield(.runStarted(task: request.task))
        DiagnosticsStore.shared.increment("agent_run_total")

        while stepCount < config.maxSteps {
            // Check cancellation
            if Task.isCancelled {
                emitCancelled(continuation)
                return
            }

            // Check timeout
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if elapsed > config.timeoutSeconds {
                emitTimeout(elapsed, continuation)
                return
            }

            stepCount += 1
            continuation.yield(.llmRequestStarted(step: stepCount))

            // Enforce maxFinalContextChars: truncate message history from the front
            // if serialized size exceeds budget. Keep first user message + trim middle.
            trimMessages(&messages, maxChars: config.maxFinalContextChars)

            // Build LLM request
            let llmRequest = LLMRequest(
                systemPrompt: systemPrompt,
                userPrompt: "",  // unused when messages is set
                tools: registry.toolSpecs,
                maxTokens: 4096,
                temperature: 0.3,
                responseFormat: .text,
                messages: messages
            )

            // Call LLM with wall-clock timeout enforcement
            let response: LLMResponse
            let remainingTimeout = config.timeoutSeconds - (CFAbsoluteTimeGetCurrent() - startTime)
            if remainingTimeout <= 0 {
                emitTimeout(CFAbsoluteTimeGetCurrent() - startTime, continuation)
                return
            }
            do {
                response = try await withTimeout(seconds: remainingTimeout) {
                    try await orchestrator.generate(request: llmRequest)
                }
            } catch {
                // Check cancellation first — the orchestrator may have wrapped
                // the CancellationError into an LLMProviderError.unavailable.
                if Task.isCancelled {
                    emitCancelled(continuation)
                    return
                }
                if error is TimeoutError {
                    emitTimeout(CFAbsoluteTimeGetCurrent() - startTime, continuation)
                    return
                }
                let runError = AgentRunError.providerError(error.localizedDescription)
                continuation.yield(.runFailed(runError))
                DiagnosticsStore.shared.increment("agent_run_fail_total")
                logger.error("Agent LLM call failed: \(error, privacy: .public)")
                // Record failure for injected patterns
                if let patternStore, !injectedPatternIds.isEmpty {
                    PatternMatcher.recordOutcome(patternIds: injectedPatternIds, success: false, store: patternStore)
                }
                return
            }

            lastProvider = response.provider
            lastModelId = response.modelId
            inputTokensTotal += response.inputTokens ?? 0
            outputTokensTotal += response.outputTokens ?? 0

            // Emit text content
            if !response.content.isEmpty {
                continuation.yield(.llmDelta(text: response.content))
            }

            // No tool calls → final answer
            if response.toolCalls.isEmpty {
                let metrics = AgentRunMetrics(
                    totalMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000,
                    stepCount: stepCount,
                    toolCallCount: toolCallCount,
                    inputTokensTotal: inputTokensTotal,
                    outputTokensTotal: outputTokensTotal,
                    provider: lastProvider,
                    modelId: lastModelId
                )
                let result = AgentRunResult(
                    answer: response.content,
                    evidence: allEvidence,
                    toolCalls: allToolRecords,
                    metrics: metrics
                )
                continuation.yield(.finalAnswer(result))
                DiagnosticsStore.shared.increment("agent_run_success_total")
                DiagnosticsStore.shared.recordLatency("agent_run_ms", ms: metrics.totalMs)
                DiagnosticsStore.shared.setGauge("agent_step_count", value: Double(stepCount))
                logger.info("Agent run completed: steps=\(stepCount) tools=\(toolCallCount) ms=\(String(format: "%.0f", metrics.totalMs))")

                // Pattern lifecycle: record outcome for injected patterns, extract new patterns
                if let patternStore {
                    if !injectedPatternIds.isEmpty {
                        PatternMatcher.recordOutcome(
                            patternIds: injectedPatternIds,
                            success: true,
                            store: patternStore
                        )
                    }
                    PatternMatcher.extractAndSaveAsync(
                        task: request.task,
                        result: result,
                        store: patternStore,
                        orchestrator: orchestrator
                    )
                }
                return
            }

            // Build assistant message with tool_use content blocks
            var assistantContent: [LLMMessageContent] = []
            if !response.content.isEmpty {
                assistantContent.append(.text(response.content))
            }
            for tc in response.toolCalls {
                assistantContent.append(.toolUse(id: tc.id, name: tc.name, input: tc.arguments))
            }
            messages.append(LLMMessage(role: "assistant", content: assistantContent))

            // Execute each tool call
            var toolResultContents: [LLMMessageContent] = []

            var budgetExhausted = false
            var cancelledDuringTools = false

            for call in response.toolCalls {
                // Check cancellation — still must provide tool_result for API contract
                if Task.isCancelled {
                    toolResultContents.append(.toolResult(
                        toolUseId: call.id,
                        content: "Tool call skipped: run cancelled",
                        isError: true))
                    cancelledDuringTools = true
                    continue
                }

                // Check tool call budget — still must provide tool_result for API contract
                if toolCallCount >= config.maxToolCalls {
                    toolResultContents.append(.toolResult(
                        toolUseId: call.id,
                        content: "Tool call skipped: budget exhausted",
                        isError: true))
                    budgetExhausted = true
                    continue
                }

                toolCallCount += 1
                DiagnosticsStore.shared.increment("agent_tool_call_total")
                continuation.yield(.toolCallStarted(name: call.name, step: stepCount))

                let toolStart = CFAbsoluteTimeGetCurrent()
                let result = await registry.execute(call)
                let toolDuration = (CFAbsoluteTimeGetCurrent() - toolStart) * 1000

                let record = AgentToolCallRecord(
                    toolName: call.name,
                    arguments: call.arguments,
                    output: result.content,
                    durationMs: toolDuration,
                    success: !result.isError
                )
                allToolRecords.append(record)

                // Extract evidence from tool output
                let evidence = extractEvidence(from: result.content, toolName: call.name)
                allEvidence.append(contentsOf: evidence)

                if result.isError {
                    continuation.yield(.toolCallFailed(name: call.name, error: result.content))
                    DiagnosticsStore.shared.increment("agent_tool_fail_total")
                } else {
                    let preview = String(result.content.prefix(200))
                    continuation.yield(.toolCallCompleted(
                        name: call.name, durationMs: toolDuration, outputPreview: preview))
                }

                toolResultContents.append(.toolResult(
                    toolUseId: call.id, content: result.content, isError: result.isError))

                // Append image blocks if present (top-level in user message)
                for img in result.images {
                    toolResultContents.append(.image(mediaType: img.mediaType, base64Data: img.base64Data))
                }
            }

            // Append user message with tool results
            messages.append(LLMMessage(role: "user", content: toolResultContents))

            // Cancellation takes priority — emit .runCancelled, not budgetExhausted
            if cancelledDuringTools {
                emitCancelled(continuation)
                return
            }

            // If budget exhausted, let the LLM produce a final answer with what it has
            if budgetExhausted {
                DiagnosticsStore.shared.increment("agent_budget_exhausted_total")
                logger.warning("Agent tool call budget exhausted: \(toolCallCount) calls")
                break
            }
        }

        // Check cancellation one final time before emitting budget error
        if Task.isCancelled {
            emitCancelled(continuation)
            return
        }

        // Max steps exhausted
        let error = AgentRunError.budgetExhausted(steps: stepCount, toolCalls: toolCallCount)
        continuation.yield(.runFailed(error))
        DiagnosticsStore.shared.increment("agent_budget_exhausted_total")
        logger.warning("Agent step budget exhausted: \(stepCount) steps")

        // Record failure for injected patterns
        if let patternStore, !injectedPatternIds.isEmpty {
            PatternMatcher.recordOutcome(
                patternIds: injectedPatternIds,
                success: false,
                store: patternStore
            )
        }
    }

    // MARK: - Terminal Event Helpers

    private static func emitCancelled(_ continuation: AsyncStream<AgentRunEvent>.Continuation) {
        continuation.yield(.runCancelled)
        DiagnosticsStore.shared.increment("agent_run_cancel_total")
    }

    private static func emitTimeout(_ elapsed: Double, _ continuation: AsyncStream<AgentRunEvent>.Continuation) {
        let error = AgentRunError.timeout(elapsedSeconds: elapsed)
        continuation.yield(.runFailed(error))
        DiagnosticsStore.shared.increment("agent_run_fail_total")
        logger.warning("Agent run timed out after \(String(format: "%.1f", elapsed))s")
    }

    // MARK: - Timeout Enforcement

    /// Sentinel error for `withTimeout`.
    private struct TimeoutError: Error {}

    /// Race an async operation against a wall-clock deadline.
    /// If the deadline fires first, cancels the operation and throws `TimeoutError`.
    /// Propagates `CancellationError` from the operation (not mapped to TimeoutError).
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // Can't nest enums in generic functions, so use Optional<T> as the
        // task group's child type. nil = timer fired, non-nil = operation result.
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil  // sentinel: timer expired
            }

            // Wait for the first task to complete.
            // If the operation throws, that error propagates.
            // If the timer finishes first, we get nil.
            while let result = try await group.next() {
                if let value = result {
                    group.cancelAll()
                    return value
                } else {
                    // Timer fired — cancel the operation and throw timeout
                    group.cancelAll()
                    throw TimeoutError()
                }
            }
            // Should not reach here
            throw TimeoutError()
        }
    }

    // MARK: - Context Size Enforcement

    /// Estimate the character count of a message array (conservative: sum of text content).
    private static func estimateMessageChars(_ messages: [LLMMessage]) -> Int {
        var total = 0
        for msg in messages {
            for block in msg.content {
                switch block {
                case .text(let s):
                    total += s.count
                case .toolUse(_, _, let input):
                    // Rough estimate: key + value lengths
                    for (k, v) in input {
                        total += k.count
                        if let s = v.stringValue { total += s.count }
                        else { total += 10 } // small constant for numbers/bools
                    }
                case .toolResult(_, let content, _):
                    total += content.count
                case .image(_, _):
                    total += 200  // Fixed overhead; actual payload is base64, not counted in char budget
                }
            }
        }
        return total
    }

    /// Trim middle messages (preserving first user message and most recent messages)
    /// until estimated size is within budget.
    ///
    /// Removes in **pairs** (assistant + user) starting from position 1 to preserve
    /// the Anthropic API contract: every `tool_use` block must have a corresponding
    /// `tool_result` in the immediately following user message.
    private static func trimMessages(_ messages: inout [LLMMessage], maxChars: Int) {
        // Need at least 3 messages to trim (first user + at least one pair + current)
        while messages.count > 3 && estimateMessageChars(messages) > maxChars {
            // Remove two messages at position 1 (an assistant+user pair)
            // to keep tool_use/tool_result blocks paired.
            messages.remove(at: 1)
            if messages.count > 1 {
                messages.remove(at: 1)
            }
        }
    }

    // MARK: - Evidence Extraction

    /// Extract evidence items from a tool output string.
    /// Parses JSON lines looking for `ts`, `app`, `sourceKind`, `displayId`, `url`, `snippet` fields.
    static func extractEvidence(from output: String, toolName: String) -> [AgentEvidenceItem] {
        var items: [AgentEvidenceItem] = []

        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Need at least a timestamp to be evidence.
            // Safe unsigned parsing: negative Int values are skipped (not trapped).
            let ts: UInt64
            if let t = obj["ts"] as? UInt64 {
                ts = t
            } else if let t = obj["ts"] as? Int, t >= 0 {
                ts = UInt64(t)
            } else if let t = obj["tsStart"] as? UInt64 {
                ts = t
            } else if let t = obj["tsStart"] as? Int, t >= 0 {
                ts = UInt64(t)
            } else if let t = obj["startTs"] as? UInt64 {
                ts = t
            } else if let t = obj["startTs"] as? Int, t >= 0 {
                ts = UInt64(t)
            } else {
                continue
            }

            let app = obj["app"] as? String ?? obj["appName"] as? String
            let url = obj["url"] as? String
            let snippet = obj["snippet"] as? String
                ?? obj["text"] as? String
                ?? obj["title"] as? String
                ?? obj["windowTitle"] as? String
                ?? ""

            let displayId: UInt32?
            if let d = obj["displayId"] as? UInt32 {
                displayId = d
            } else if let d = obj["displayId"] as? Int, d >= 0, d <= UInt32.max {
                displayId = UInt32(d)
            } else {
                displayId = nil
            }

            items.append(AgentEvidenceItem(
                timestamp: ts,
                app: app,
                sourceKind: toolName,
                displayId: displayId,
                url: url,
                snippet: String(snippet.prefix(200))
            ))
        }

        return items
    }
}
