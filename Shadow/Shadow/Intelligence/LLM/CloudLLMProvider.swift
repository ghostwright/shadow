import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "CloudLLMProvider")

// MARK: - Injectable Transport (for testing)

/// Abstraction over URLSession for testable network calls.
/// Production uses `URLSessionTransport`; tests inject a spy.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// Default transport using URLSession.shared.
struct URLSessionTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// Cloud LLM provider using Anthropic's Messages API via URLSession + Codable.
/// No Anthropic SDK dependency — pure Foundation networking.
///
/// Privacy contract:
/// - Hard-fails with `.consentRequired` if cloud consent not granted
/// - Never sends data without explicit opt-in
/// - Audit log on every cloud request via DiagnosticsStore
///
/// API key storage:
/// - Primary: macOS Keychain (service: "com.shadow.app.llm", account: "anthropic-api-key")
/// - Dev override: `SHADOW_ANTHROPIC_API_KEY` environment variable
final class CloudLLMProvider: @unchecked Sendable, LLMProvider {
    let providerName = "cloud_claude"

    /// Model ID configurable via UserDefaults. Not hardcoded.
    var modelId: String {
        UserDefaults.standard.string(forKey: "llmCloudModelId")
            ?? "claude-sonnet-4-6"
    }

    private static let keychainService = "com.shadow.app.llm"
    private static let keychainAccount = "anthropic-api-key"
    private static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let timeoutInterval: TimeInterval = 30

    /// Injectable transport for testing. Defaults to URLSession.
    private let transport: any HTTPTransport

    /// Injectable API key for testing. When set, `resolveAPIKey()` returns this
    /// value without touching the Keychain, which avoids the macOS password
    /// prompt that fires on ad-hoc-signed test binaries.
    private let apiKeyOverride: String?

    init(transport: any HTTPTransport = URLSessionTransport(), apiKeyOverride: String? = nil) {
        self.transport = transport
        self.apiKeyOverride = apiKeyOverride
    }

    /// Technical reachability only — API key exists.
    /// Consent is checked in generate(), not here, so the orchestrator's
    /// `guard provider.isAvailable` passes and generate() can throw .consentRequired
    /// which the orchestrator catches and counts.
    var isAvailable: Bool {
        resolveAPIKey() != nil
    }

    /// Whether the user has granted cloud consent.
    private var isConsentGranted: Bool {
        UserDefaults.standard.bool(forKey: "llmCloudConsentGranted")
    }

    func generate(request: LLMRequest) async throws -> LLMResponse {
        // Consent gate — hard fail, never bypass.
        // Counter is NOT incremented here — the orchestrator is the single
        // owner of summary_cloud_blocked_no_consent_total to avoid double-counting.
        guard isConsentGranted else {
            throw LLMProviderError.consentRequired
        }

        guard let apiKey = resolveAPIKey() else {
            throw LLMProviderError.unavailable(reason: "No API key configured")
        }

        let requestId = UUID().uuidString
        let startTime = CFAbsoluteTimeGetCurrent()

        // Resolve effective model: request override takes precedence over provider default
        let effectiveModelId = request.modelOverride ?? modelId

        // Audit log
        DiagnosticsStore.shared.increment("summary_cloud_request_total")
        logger.info("Cloud LLM request: provider=\(self.providerName) model=\(effectiveModelId) requestId=\(requestId)")

        // Build system prompt — prepend JSON instruction if json response format requested
        var systemPrompt = request.systemPrompt
        if request.responseFormat == .json {
            systemPrompt = "Respond with valid JSON only.\n\n" + systemPrompt
        }

        // Map tools
        let tools: [AnthropicTool]? = request.tools.isEmpty ? nil : request.tools.map { spec in
            AnthropicTool(
                name: spec.name,
                description: spec.description,
                input_schema: spec.inputSchema
            )
        }

        // Build messages — multi-turn when request.messages is set, legacy otherwise
        let messages: [AnthropicMessage]
        if let llmMessages = request.messages {
            messages = llmMessages.map { Self.mapLLMMessage($0) }
        } else {
            messages = [AnthropicMessage(role: "user", content: .text(request.userPrompt))]
        }

        let apiRequest = AnthropicRequest(
            model: effectiveModelId,
            max_tokens: request.maxTokens,
            system: systemPrompt,
            messages: messages,
            temperature: request.temperature,
            tools: tools
        )

        let requestData: Data
        do {
            let encoder = JSONEncoder()
            requestData = try encoder.encode(apiRequest)
        } catch {
            throw LLMProviderError.terminalFailure(reason: "Failed to encode request: \(error.localizedDescription)")
        }

        var urlRequest = URLRequest(url: Self.apiURL)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = requestData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.timeoutInterval = Self.timeoutInterval

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport.send(urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw LLMProviderError.timeout
        } catch {
            throw LLMProviderError.transientFailure(underlying: error.localizedDescription)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.transientFailure(underlying: "Non-HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            throw Self.mapHTTPError(status: httpResponse.statusCode, body: body)
        }

        let llmResponse = try Self.parseResponseData(
            data,
            provider: providerName,
            modelId: effectiveModelId,
            latencyMs: elapsed
        )

        // Strict JSON mode: strip fences and validate well-formed JSON
        if request.responseFormat == .json {
            let cleaned = Self.stripMarkdownFences(llmResponse.content)
            try Self.validateJSONContent(cleaned)
            return LLMResponse(
                content: cleaned,
                toolCalls: llmResponse.toolCalls,
                provider: llmResponse.provider,
                modelId: llmResponse.modelId,
                inputTokens: llmResponse.inputTokens,
                outputTokens: llmResponse.outputTokens,
                latencyMs: llmResponse.latencyMs
            )
        }

        return llmResponse
    }

    // MARK: - Response Parsing (internal for testability)

    /// Parse raw Anthropic API response data into an LLMResponse.
    /// Extracted as a static method so tests can exercise parsing without network calls.
    internal static func parseResponseData(
        _ data: Data,
        provider: String,
        modelId: String,
        latencyMs: Double
    ) throws -> LLMResponse {
        let apiResponse: AnthropicResponse
        do {
            apiResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        } catch {
            throw LLMProviderError.malformedOutput(
                detail: "Failed to decode API response: \(error.localizedDescription)"
            )
        }

        // Extract text content
        let content = apiResponse.content
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined()

        // Extract tool calls
        let toolCalls: [ToolCall] = apiResponse.content
            .filter { $0.type == "tool_use" }
            .compactMap { block in
                guard let id = block.id, let name = block.name else { return nil }
                return ToolCall(
                    id: id,
                    name: name,
                    arguments: block.input ?? [:]
                )
            }

        return LLMResponse(
            content: content,
            toolCalls: toolCalls,
            provider: provider,
            modelId: modelId,
            inputTokens: apiResponse.usage?.input_tokens,
            outputTokens: apiResponse.usage?.output_tokens,
            latencyMs: latencyMs
        )
    }

    // MARK: - JSON Mode Validation

    /// Validate that content is well-formed JSON. Throws `.malformedOutput` if not.
    ///
    /// Also handles LLM quirks: strips markdown code fences if present.
    internal static func validateJSONContent(_ content: String) throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMProviderError.malformedOutput(detail: "JSON mode: empty response content")
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw LLMProviderError.malformedOutput(detail: "JSON mode: response is not valid UTF-8")
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LLMProviderError.malformedOutput(
                detail: "JSON mode: response is not valid JSON: \(error.localizedDescription)"
            )
        }
    }

    /// Strip markdown code fences from LLM response content.
    /// LLMs sometimes wrap JSON in ```json ... ``` even when told not to.
    internal static func stripMarkdownFences(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading ```json or ```
        if text.hasPrefix("```") {
            if let endOfFirstLine = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: endOfFirstLine)...])
            }
        }
        // Strip trailing ```
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTTP Error Mapping

    private static func mapHTTPError(status: Int, body: String) -> LLMProviderError {
        switch status {
        case 401:
            return .terminalFailure(reason: "Invalid API key (401)")
        case 429:
            return .transientFailure(underlying: "Rate limited (429): \(body)")
        case 529:
            return .transientFailure(underlying: "API overloaded (529): \(body)")
        case 500...599:
            return .transientFailure(underlying: "Server error (\(status)): \(body)")
        default:
            return .terminalFailure(reason: "HTTP \(status): \(body)")
        }
    }

    // MARK: - Multi-Turn Message Mapping

    /// Map an LLMMessage to an AnthropicMessage for the API.
    private static func mapLLMMessage(_ msg: LLMMessage) -> AnthropicMessage {
        let blocks: [AnthropicOutboundBlock] = msg.content.map { block in
            switch block {
            case .text(let t):
                return AnthropicOutboundBlock(
                    type: "text", text: t
                )
            case .toolUse(let id, let name, let input):
                return AnthropicOutboundBlock(
                    type: "tool_use",
                    id: id, name: name, input: input
                )
            case .toolResult(let toolUseId, let content, let isError):
                return AnthropicOutboundBlock(
                    type: "tool_result",
                    tool_use_id: toolUseId, content: content,
                    is_error: isError ? true : nil
                )
            case .image(let mediaType, let data):
                return AnthropicOutboundBlock(
                    type: "image",
                    source: AnthropicImageSource(
                        type: "base64",
                        media_type: mediaType,
                        data: data
                    )
                )
            }
        }
        return AnthropicMessage(role: msg.role, content: .blocks(blocks))
    }

    // MARK: - API Key Resolution

    /// Resolve API key: test override → Keychain → env var.
    private func resolveAPIKey() -> String? {
        // Test override: skip Keychain entirely (avoids password prompt
        // on ad-hoc-signed test binaries).
        if let override = apiKeyOverride {
            return override.isEmpty ? nil : override
        }

        // Primary: Keychain
        if let data = KeychainHelper.load(
            service: Self.keychainService,
            account: Self.keychainAccount
        ), let key = String(data: data, encoding: .utf8), !key.isEmpty {
            return key
        }

        // Dev override: environment variable
        if let envKey = ProcessInfo.processInfo.environment["SHADOW_ANTHROPIC_API_KEY"],
           !envKey.isEmpty {
            return envKey
        }

        return nil
    }
}

// MARK: - Anthropic API Codable Types

private struct AnthropicRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let messages: [AnthropicMessage]
    let temperature: Double
    let tools: [AnthropicTool]?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(max_tokens, forKey: .max_tokens)
        try container.encode(system, forKey: .system)
        try container.encode(messages, forKey: .messages)
        try container.encode(temperature, forKey: .temperature)
        // Anthropic API rejects empty tools array — omit when nil
        if let tools = tools, !tools.isEmpty {
            try container.encode(tools, forKey: .tools)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case model, max_tokens, system, messages, temperature, tools
    }
}

/// Anthropic message with polymorphic content: either a plain string
/// (legacy single-pass) or an array of content blocks (multi-turn tool-calling).
private struct AnthropicMessage: Encodable {
    let role: String
    let content: AnthropicContent
}

/// Polymorphic content — encodes as `"content": "string"` or `"content": [blocks]`.
/// The Anthropic Messages API accepts both forms.
private enum AnthropicContent: Encodable {
    /// Plain text content (used for legacy single-user-prompt path).
    case text(String)
    /// Array of typed content blocks (used for multi-turn tool-calling).
    case blocks([AnthropicOutboundBlock])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s):
            try container.encode(s)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }
}

/// Source descriptor for base64 image blocks in the Anthropic API.
private struct AnthropicImageSource: Encodable {
    let type: String        // "base64"
    let media_type: String  // "image/jpeg"
    let data: String        // base64 encoded
}

/// Outbound content block for encoding in API requests.
/// Covers text, tool_use (assistant), tool_result (user), and image block types.
private struct AnthropicOutboundBlock: Encodable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: [String: AnyCodable]?
    let tool_use_id: String?
    let content: String?
    let is_error: Bool?
    let source: AnthropicImageSource?

    init(
        type: String, text: String? = nil,
        id: String? = nil, name: String? = nil, input: [String: AnyCodable]? = nil,
        tool_use_id: String? = nil, content: String? = nil, is_error: Bool? = nil,
        source: AnthropicImageSource? = nil
    ) {
        self.type = type
        self.text = text
        self.id = id
        self.name = name
        self.input = input
        self.tool_use_id = tool_use_id
        self.content = content
        self.is_error = is_error
        self.source = source
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch type {
        case "text":
            try container.encodeIfPresent(text, forKey: .text)
        case "tool_use":
            try container.encodeIfPresent(id, forKey: .id)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(input, forKey: .input)
        case "tool_result":
            try container.encodeIfPresent(tool_use_id, forKey: .tool_use_id)
            try container.encodeIfPresent(content, forKey: .content)
            if let isErr = is_error, isErr {
                try container.encode(isErr, forKey: .is_error)
            }
        case "image":
            try container.encodeIfPresent(source, forKey: .source)
        default:
            break
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, tool_use_id, content, is_error, source
    }
}

private struct AnthropicTool: Encodable {
    let name: String
    let description: String
    let input_schema: [String: AnyCodable]
}

private struct AnthropicResponse: Codable {
    let content: [AnthropicContentBlock]
    let usage: AnthropicUsage?
}

/// Handles both "text" and "tool_use" content blocks from Anthropic API responses.
private struct AnthropicContentBlock: Codable {
    let type: String          // "text" or "tool_use"
    let text: String?         // present for type == "text"
    let id: String?           // present for type == "tool_use"
    let name: String?         // present for type == "tool_use"
    let input: [String: AnyCodable]?  // present for type == "tool_use"
}

private struct AnthropicUsage: Codable {
    let input_tokens: Int
    let output_tokens: Int
}
