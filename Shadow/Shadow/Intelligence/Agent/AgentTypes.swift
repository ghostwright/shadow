import Foundation

// MARK: - Agent Run Request

/// Request to execute an agent run.
struct AgentRunRequest: Sendable {
    /// Natural language task from the user (e.g. the search query).
    let task: String
    /// Configuration for budget enforcement.
    let config: AgentRunConfig
}

/// Budget and limit configuration for an agent run.
///
/// Generous defaults to support real-world multi-step workflows:
/// - A simple Gmail email send needs ~15 tool calls minimum
/// - Complex multi-app workflows with error recovery need 30-50+
/// - Claude Code has essentially unlimited tool calls -- the agent needs room to work
struct AgentRunConfig: Sendable {
    /// Maximum LLM round-trips before the loop terminates.
    var maxSteps: Int = 50
    /// Maximum total tool calls across all steps.
    var maxToolCalls: Int = 100
    /// Wall-clock timeout in seconds.
    var timeoutSeconds: Double = 300
    /// Hard cap on characters per tool output. Truncated with marker when exceeded.
    var maxToolOutputCharsPerCall: Int = 16_000
    /// Maximum context characters sent to the LLM (pre-context-engine temporary cap).
    /// 128K chars ~ 32K tokens, well within Anthropic's 200K context window.
    var maxFinalContextChars: Int = 128_000
}

// MARK: - Agent Run Result

/// Final result of a completed agent run.
struct AgentRunResult: Sendable {
    /// The agent's final answer text.
    let answer: String
    /// Evidence items extracted from tool outputs.
    let evidence: [AgentEvidenceItem]
    /// Complete record of all tool calls made during the run.
    let toolCalls: [AgentToolCallRecord]
    /// Performance and attribution metrics.
    let metrics: AgentRunMetrics
}

/// Performance metrics for a completed agent run.
struct AgentRunMetrics: Sendable, Equatable {
    /// Total wall-clock time in milliseconds.
    let totalMs: Double
    /// Number of LLM round-trips completed.
    let stepCount: Int
    /// Number of tool calls executed.
    let toolCallCount: Int
    /// Cumulative input tokens across all LLM calls.
    let inputTokensTotal: Int
    /// Cumulative output tokens across all LLM calls.
    let outputTokensTotal: Int
    /// Provider that generated the final answer.
    let provider: String
    /// Model ID that generated the final answer.
    let modelId: String
}

// MARK: - Agent Run Events

/// Events emitted by the agent runtime during execution.
/// Consumed by the UI layer via `AsyncStream<AgentRunEvent>`.
/// The terminal event is always one of: `.finalAnswer`, `.runFailed`, or `.runCancelled`.
enum AgentRunEvent: Sendable {
    /// Agent run has started with the given task text.
    case runStarted(task: String)
    /// An LLM request is being sent (step N of the loop).
    case llmRequestStarted(step: Int)
    /// Token chunk received from the LLM (full content for non-streaming providers).
    case llmDelta(text: String)
    /// A tool call is being executed.
    case toolCallStarted(name: String, step: Int)
    /// A tool call completed successfully.
    case toolCallCompleted(name: String, durationMs: Double, outputPreview: String)
    /// A tool call failed.
    case toolCallFailed(name: String, error: String)
    /// Agent run completed with a final answer.
    case finalAnswer(AgentRunResult)
    /// Agent run failed with an error.
    case runFailed(AgentRunError)
    /// Agent run was cancelled by the user.
    case runCancelled
    /// Orchestration metadata: classified intent. Non-terminal, informational only.
    case intentClassified(intent: String, confidence: Double, method: String)
}

// MARK: - Tool Call Record

/// Record of a single tool call for auditing and diagnostics.
struct AgentToolCallRecord: Sendable {
    /// Name of the tool invoked.
    let toolName: String
    /// Arguments passed to the tool.
    let arguments: [String: AnyCodable]
    /// Tool output (may be truncated).
    let output: String
    /// Execution time in milliseconds.
    let durationMs: Double
    /// Whether the tool call succeeded.
    let success: Bool
}

// MARK: - Evidence

/// A piece of evidence extracted from a tool output.
/// Used for deep-links and citation rendering in the UI.
struct AgentEvidenceItem: Sendable, Equatable {
    /// Timestamp in Unix microseconds.
    let timestamp: UInt64
    /// App name at the time of the evidence.
    let app: String?
    /// Source kind (e.g. "search", "transcript", "timeline", "summary").
    let sourceKind: String
    /// Display ID where the evidence was captured.
    let displayId: UInt32?
    /// URL if the evidence came from a browser page.
    let url: String?
    /// Text snippet for display.
    let snippet: String
}

// MARK: - Agent Run Error

/// Typed errors from the agent runtime.
enum AgentRunError: Error, Sendable {
    /// Loop exceeded the configured step or tool call budget.
    case budgetExhausted(steps: Int, toolCalls: Int)
    /// Wall-clock timeout exceeded.
    case timeout(elapsedSeconds: Double)
    /// LLM provider returned an error.
    case providerError(String)
    /// No tools are registered in the tool registry.
    case noToolsAvailable
    /// Run was cancelled by the caller.
    case cancelled
    /// Unexpected internal error.
    case internalError(String)
}
