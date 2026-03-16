import Foundation

// MARK: - Provider Mode

/// Routing mode for LLM provider selection.
enum LLMMode: String, Codable, Sendable {
    /// Only use local on-device models. Never contact cloud services.
    case localOnly
    /// Only use cloud provider. Requires consent.
    case cloudOnly
    /// Prefer local, fallback to cloud if local unavailable and consent granted.
    case auto
}

// MARK: - Error Taxonomy

/// Typed errors from LLM providers and orchestrator.
/// Each case carries enough context for diagnostics without exposing internals.
enum LLMProviderError: Error, Sendable, LocalizedError {
    /// Provider cannot operate (model not loaded, service unreachable).
    case unavailable(reason: String)
    /// Cloud provider blocked because user has not granted consent.
    case consentRequired
    /// Provider did not respond within the allowed time.
    case timeout
    /// Provider returned output that does not conform to the expected schema.
    case malformedOutput(detail: String)
    /// Temporary failure (network hiccup, model busy). Retryable.
    case transientFailure(underlying: String)
    /// Permanent failure. Do not retry.
    case terminalFailure(reason: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return "Provider unavailable: \(reason)"
        case .consentRequired: return "Cloud consent required"
        case .timeout: return "Request timed out"
        case .malformedOutput(let detail): return "Malformed response: \(detail)"
        case .transientFailure(let underlying): return "Temporary failure: \(underlying)"
        case .terminalFailure(let reason): return "Provider error: \(reason)"
        }
    }
}

// MARK: - Response Format

/// Expected output format from the LLM.
enum LLMResponseFormat: Sendable {
    case text
    case json
}

// MARK: - Tool-Calling Shapes

/// Describes a tool the LLM can invoke.
struct ToolSpec: Codable, Sendable {
    let name: String
    let description: String
    let inputSchema: [String: AnyCodable]
}

/// A tool invocation requested by the LLM.
struct ToolCall: Codable, Sendable {
    let id: String
    let name: String
    let arguments: [String: AnyCodable]
}

/// Result of executing a tool call.
struct ToolResult: Codable, Sendable {
    let toolCallId: String
    let content: String
    let isError: Bool
    let images: [ImageData]

    init(toolCallId: String, content: String, isError: Bool, images: [ImageData] = []) {
        self.toolCallId = toolCallId
        self.content = content
        self.isError = isError
        self.images = images
    }
}

/// Base64-encoded image data for multi-modal LLM tool results.
struct ImageData: Sendable, Equatable, Codable {
    let mediaType: String   // e.g. "image/jpeg"
    let base64Data: String
}

// MARK: - Multi-Turn Messages

/// A single message in a multi-turn conversation.
/// Used by the agent runtime for iterative tool-calling loops.
struct LLMMessage: Sendable {
    let role: String  // "user", "assistant"
    let content: [LLMMessageContent]
}

/// Content block within a multi-turn message.
enum LLMMessageContent: Sendable {
    /// Plain text content.
    case text(String)
    /// A tool invocation by the assistant.
    case toolUse(id: String, name: String, input: [String: AnyCodable])
    /// Result of a tool invocation, sent by the user role.
    case toolResult(toolUseId: String, content: String, isError: Bool)
    /// Base64-encoded image content for multi-modal messages.
    case image(mediaType: String, base64Data: String)
}

// MARK: - LLM Request / Response

/// A structured request to an LLM provider.
///
/// Two modes:
/// - **Legacy (summary path):** `messages` is nil. Provider uses `systemPrompt` + `userPrompt`.
/// - **Agent (multi-turn):** `messages` is set. Provider sends the message array with content blocks.
struct LLMRequest: Sendable {
    let systemPrompt: String
    let userPrompt: String
    let tools: [ToolSpec]
    let maxTokens: Int
    let temperature: Double
    let responseFormat: LLMResponseFormat
    /// Multi-turn messages for agent loop. Nil = legacy single-pass mode.
    let messages: [LLMMessage]?
    /// Override the provider's default model ID. Used for routing-specific models
    /// (e.g., Haiku for fast classification). Nil = use provider default.
    let modelOverride: String?

    init(
        systemPrompt: String,
        userPrompt: String,
        tools: [ToolSpec] = [],
        maxTokens: Int,
        temperature: Double,
        responseFormat: LLMResponseFormat,
        messages: [LLMMessage]? = nil,
        modelOverride: String? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.tools = tools
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.responseFormat = responseFormat
        self.messages = messages
        self.modelOverride = modelOverride
    }
}

/// A structured response from an LLM provider.
struct LLMResponse: Sendable {
    let content: String
    /// Tool calls requested by the model (empty for summary v1).
    let toolCalls: [ToolCall]
    let provider: String
    let modelId: String
    let inputTokens: Int?
    let outputTokens: Int?
    let latencyMs: Double
}

// MARK: - Provider Protocol

/// Contract for pluggable LLM backends. Implemented by local (MLX) and cloud (Claude).
///
/// Follows the same pattern as `TranscriptionProvider`:
/// - `providerName`: short identifier for diagnostics
/// - `isAvailable`: fast synchronous check
/// - `generate()`: async throws, caller handles fallback
protocol LLMProvider: Sendable {
    /// Short identifier for diagnostics and logging (e.g. "local_mlx", "cloud_claude").
    var providerName: String { get }

    /// Model identifier (e.g. "Qwen2.5-7B-Instruct-4bit", "claude-haiku-4-5-20251001").
    var modelId: String { get }

    /// Fast synchronous check — can this provider currently accept work?
    var isAvailable: Bool { get }

    /// Generate a response for the given request.
    /// Throws `LLMProviderError` on failure.
    func generate(request: LLMRequest) async throws -> LLMResponse
}
