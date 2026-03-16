import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "OpenAILLMProvider")

/// Cloud LLM provider using OpenAI's Chat Completion API via URLSession + Codable.
/// No OpenAI SDK dependency — pure Foundation networking.
///
/// Supports:
/// - Tool/function calling (same ToolSpec format as the Anthropic provider)
/// - Image input (base64 JPEG in messages)
/// - Model selection (fast model for per-step decisions, powerful model for complex reasoning)
///
/// API key storage:
/// - Primary: macOS Keychain (service: "com.shadow.app.llm", account: "openai-api-key")
/// - Dev override: `SHADOW_OPENAI_API_KEY` environment variable
final class OpenAILLMProvider: @unchecked Sendable, LLMProvider {
    let providerName = "cloud_openai"

    /// Model ID configurable via UserDefaults. Not hardcoded.
    var modelId: String {
        UserDefaults.standard.string(forKey: "llmOpenAIModelId")
            ?? "gpt-4.1-nano"
    }

    static let keychainService = "com.shadow.app.llm"
    static let keychainAccount = "openai-api-key"
    private static let apiURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let timeoutInterval: TimeInterval = 30

    /// Injectable transport for testing. Defaults to URLSession.
    private let transport: any HTTPTransport

    /// Injectable API key for testing. When set, `resolveAPIKey()` returns this
    /// value without touching the Keychain.
    private let apiKeyOverride: String?

    init(transport: any HTTPTransport = URLSessionTransport(), apiKeyOverride: String? = nil) {
        self.transport = transport
        self.apiKeyOverride = apiKeyOverride
    }

    /// Technical reachability only — API key exists.
    /// Consent is checked in generate(), not here.
    var isAvailable: Bool {
        resolveAPIKey() != nil
    }

    /// Whether the user has granted cloud consent.
    private var isConsentGranted: Bool {
        UserDefaults.standard.bool(forKey: "llmCloudConsentGranted")
    }

    func generate(request: LLMRequest) async throws -> LLMResponse {
        // Consent gate — hard fail, never bypass.
        guard isConsentGranted else {
            throw LLMProviderError.consentRequired
        }

        guard let apiKey = resolveAPIKey() else {
            throw LLMProviderError.unavailable(reason: "No OpenAI API key configured")
        }

        let requestId = UUID().uuidString
        let startTime = CFAbsoluteTimeGetCurrent()

        // Resolve effective model: request override takes precedence over provider default
        let effectiveModelId = request.modelOverride ?? modelId

        // Audit log
        DiagnosticsStore.shared.increment("summary_cloud_request_total")
        logger.info("OpenAI LLM request: provider=\(self.providerName) model=\(effectiveModelId) requestId=\(requestId)")

        // Build messages
        // OpenAI requires each tool_result to be a separate message with role "tool",
        // so mapLLMMessages returns a flat array (one LLMMessage can expand to many OpenAI messages).
        let messages: [OpenAIMessage]
        if let llmMessages = request.messages {
            var mapped: [OpenAIMessage] = []
            // Add system message first
            if !request.systemPrompt.isEmpty {
                mapped.append(OpenAIMessage(
                    role: "system",
                    content: .text(request.systemPrompt)
                ))
            }
            for msg in llmMessages {
                mapped.append(contentsOf: Self.mapLLMMessage(msg))
            }
            messages = mapped
        } else {
            var msgs: [OpenAIMessage] = []
            if !request.systemPrompt.isEmpty {
                msgs.append(OpenAIMessage(
                    role: "system",
                    content: .text(request.systemPrompt)
                ))
            }
            msgs.append(OpenAIMessage(
                role: "user",
                content: .text(request.userPrompt)
            ))
            messages = msgs
        }

        // Map tools to OpenAI function calling format
        let tools: [OpenAITool]? = request.tools.isEmpty ? nil : request.tools.map { spec in
            OpenAITool(
                type: "function",
                function: OpenAIFunction(
                    name: spec.name,
                    description: spec.description,
                    parameters: spec.inputSchema
                )
            )
        }

        let apiRequest = OpenAIRequest(
            model: effectiveModelId,
            messages: messages,
            max_tokens: request.maxTokens,
            temperature: request.temperature,
            tools: tools,
            tool_choice: tools != nil ? .string("auto") : nil,
            response_format: request.responseFormat == .json
                ? OpenAIResponseFormat(type: "json_object") : nil
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
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

        return try Self.parseResponseData(
            data,
            provider: providerName,
            modelId: effectiveModelId,
            latencyMs: elapsed
        )
    }

    // MARK: - Response Parsing

    /// Parse raw OpenAI API response data into an LLMResponse.
    internal static func parseResponseData(
        _ data: Data,
        provider: String,
        modelId: String,
        latencyMs: Double
    ) throws -> LLMResponse {
        let apiResponse: OpenAIResponse
        do {
            apiResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        } catch {
            throw LLMProviderError.malformedOutput(
                detail: "Failed to decode OpenAI response: \(error.localizedDescription)"
            )
        }

        guard let choice = apiResponse.choices.first else {
            throw LLMProviderError.malformedOutput(detail: "No choices in OpenAI response")
        }

        let message = choice.message

        // Extract text content
        let content = message.content ?? ""

        // Extract tool calls
        let toolCalls: [ToolCall] = (message.tool_calls ?? []).compactMap { tc in
            // Parse the function arguments JSON string into [String: AnyCodable]
            guard let argsData = tc.function.arguments.data(using: .utf8) else { return nil }
            guard let argsObj = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else {
                return nil
            }
            let arguments = argsObj.mapValues { AnyCodable.from($0) }
            return ToolCall(
                id: tc.id,
                name: tc.function.name,
                arguments: arguments
            )
        }

        return LLMResponse(
            content: content,
            toolCalls: toolCalls,
            provider: provider,
            modelId: modelId,
            inputTokens: apiResponse.usage?.prompt_tokens,
            outputTokens: apiResponse.usage?.completion_tokens,
            latencyMs: latencyMs
        )
    }

    // MARK: - HTTP Error Mapping

    private static func mapHTTPError(status: Int, body: String) -> LLMProviderError {
        switch status {
        case 401:
            return .terminalFailure(reason: "Invalid OpenAI API key (401)")
        case 429:
            return .transientFailure(underlying: "Rate limited (429): \(body)")
        case 500...599:
            return .transientFailure(underlying: "Server error (\(status)): \(body)")
        default:
            return .terminalFailure(reason: "HTTP \(status): \(body)")
        }
    }

    // MARK: - Multi-Turn Message Mapping

    /// Map an LLMMessage to one or more OpenAI messages.
    ///
    /// Returns an array because OpenAI requires each tool result to be a separate
    /// message with role "tool" and a tool_call_id, unlike Anthropic which combines
    /// them into a single user message. A single LLMMessage containing N tool results
    /// expands into N OpenAI messages.
    private static func mapLLMMessage(_ msg: LLMMessage) -> [OpenAIMessage] {
        if msg.role == "assistant" {
            // Assistant messages can have tool_calls
            var textContent: String? = nil
            var toolCalls: [OpenAIOutboundToolCall] = []

            for block in msg.content {
                switch block {
                case .text(let t):
                    textContent = (textContent ?? "") + t
                case .toolUse(let id, let name, let input):
                    // Encode the input dict as a JSON string
                    let argsString: String
                    if let data = try? JSONEncoder().encode(input),
                       let str = String(data: data, encoding: .utf8) {
                        argsString = str
                    } else {
                        argsString = "{}"
                    }
                    toolCalls.append(OpenAIOutboundToolCall(
                        id: id,
                        type: "function",
                        function: OpenAIOutboundFunction(
                            name: name,
                            arguments: argsString
                        )
                    ))
                default:
                    break
                }
            }

            return [OpenAIMessage(
                role: "assistant",
                content: textContent.map { .text($0) },
                tool_calls: toolCalls.isEmpty ? nil : toolCalls
            )]
        } else if msg.role == "user" {
            // User messages can have text, images, and tool results.
            // OpenAI requires each tool_result as a separate role="tool" message.
            var results: [OpenAIMessage] = []

            // Separate tool results from other content
            var nonToolParts: [OpenAIContentPart] = []

            for block in msg.content {
                switch block {
                case .toolResult(let toolUseId, let content, let isError):
                    results.append(OpenAIMessage(
                        role: "tool",
                        content: .text(isError ? "Error: \(content)" : content),
                        tool_call_id: toolUseId
                    ))
                case .text(let t):
                    nonToolParts.append(OpenAIContentPart(type: "text", text: t))
                case .image(let mediaType, let data):
                    nonToolParts.append(OpenAIContentPart(
                        type: "image_url",
                        image_url: OpenAIImageURL(
                            url: "data:\(mediaType);base64,\(data)"
                        )
                    ))
                default:
                    break
                }
            }

            // If there are tool results, they come first (OpenAI expects tool results
            // right after the assistant message that called them)
            if !results.isEmpty {
                // Append any non-tool content as a separate user message
                if !nonToolParts.isEmpty {
                    if nonToolParts.count == 1, nonToolParts[0].image_url == nil {
                        results.append(OpenAIMessage(
                            role: "user",
                            content: .text(nonToolParts[0].text ?? "")
                        ))
                    } else {
                        results.append(OpenAIMessage(
                            role: "user",
                            content: .parts(nonToolParts)
                        ))
                    }
                }
                return results
            }

            // No tool results — build a regular user message
            if nonToolParts.count == 1, nonToolParts[0].image_url == nil {
                return [OpenAIMessage(
                    role: "user",
                    content: .text(nonToolParts[0].text ?? "")
                )]
            }
            if !nonToolParts.isEmpty {
                return [OpenAIMessage(
                    role: "user",
                    content: .parts(nonToolParts)
                )]
            }
            return [OpenAIMessage(role: "user", content: .text(""))]
        }

        // Fallback for other roles (system, etc.)
        let text = msg.content.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined()
        return [OpenAIMessage(role: msg.role, content: .text(text))]
    }

    // MARK: - API Key Resolution

    /// Resolve API key: test override -> Keychain -> env var.
    private func resolveAPIKey() -> String? {
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
        if let envKey = ProcessInfo.processInfo.environment["SHADOW_OPENAI_API_KEY"],
           !envKey.isEmpty {
            return envKey
        }

        return nil
    }
}

// MARK: - OpenAI API Codable Types

private struct OpenAIRequest: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let max_tokens: Int
    let temperature: Double
    let tools: [OpenAITool]?
    let tool_choice: OpenAIToolChoice?
    let response_format: OpenAIResponseFormat?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(max_tokens, forKey: .max_tokens)
        try container.encode(temperature, forKey: .temperature)
        if let tools = tools, !tools.isEmpty {
            try container.encode(tools, forKey: .tools)
        }
        if let tool_choice = tool_choice {
            try container.encode(tool_choice, forKey: .tool_choice)
        }
        if let response_format = response_format {
            try container.encode(response_format, forKey: .response_format)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case model, messages, max_tokens, temperature, tools, tool_choice, response_format
    }
}

/// OpenAI message with polymorphic content.
private struct OpenAIMessage: Encodable {
    let role: String
    let content: OpenAIContent?
    let tool_calls: [OpenAIOutboundToolCall]?
    let tool_call_id: String?

    init(
        role: String,
        content: OpenAIContent? = nil,
        tool_calls: [OpenAIOutboundToolCall]? = nil,
        tool_call_id: String? = nil
    ) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)

        if let content = content {
            try container.encode(content, forKey: .content)
        }
        if let tool_calls = tool_calls, !tool_calls.isEmpty {
            try container.encode(tool_calls, forKey: .tool_calls)
        }
        if let tool_call_id = tool_call_id {
            try container.encode(tool_call_id, forKey: .tool_call_id)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, tool_calls, tool_call_id
    }
}

/// Polymorphic content — encodes as `"content": "string"` or `"content": [parts]`.
private enum OpenAIContent: Encodable {
    case text(String)
    case parts([OpenAIContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s):
            try container.encode(s)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

/// Content part for multimodal messages.
private struct OpenAIContentPart: Encodable {
    let type: String        // "text" or "image_url"
    let text: String?
    let image_url: OpenAIImageURL?

    init(type: String, text: String? = nil, image_url: OpenAIImageURL? = nil) {
        self.type = type
        self.text = text
        self.image_url = image_url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if let text = text {
            try container.encode(text, forKey: .text)
        }
        if let image_url = image_url {
            try container.encode(image_url, forKey: .image_url)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, image_url
    }
}

/// Image URL for multimodal messages. Supports data: URIs for base64 images.
private struct OpenAIImageURL: Encodable {
    let url: String
}

/// Tool definition for OpenAI function calling.
private struct OpenAITool: Encodable {
    let type: String  // "function"
    let function: OpenAIFunction
}

/// Function definition within a tool.
private struct OpenAIFunction: Encodable {
    let name: String
    let description: String
    let parameters: [String: AnyCodable]
}

/// Outbound tool call in assistant messages.
private struct OpenAIOutboundToolCall: Encodable {
    let id: String
    let type: String  // "function"
    let function: OpenAIOutboundFunction
}

/// Function call details in an outbound tool call.
private struct OpenAIOutboundFunction: Encodable {
    let name: String
    let arguments: String  // JSON string
}

/// Tool choice — either "auto", "none", or a specific function.
private enum OpenAIToolChoice: Encodable {
    case string(String)  // "auto", "none", "required"

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try container.encode(s)
        }
    }
}

/// Response format specification.
private struct OpenAIResponseFormat: Encodable {
    let type: String  // "json_object" or "text"
}

// MARK: - Response Types

private struct OpenAIResponse: Codable {
    let id: String
    let choices: [OpenAIChoice]
    let usage: OpenAIUsage?
}

private struct OpenAIChoice: Codable {
    let index: Int
    let message: OpenAIResponseMessage
    let finish_reason: String?
}

private struct OpenAIResponseMessage: Codable {
    let role: String
    let content: String?
    let tool_calls: [OpenAIResponseToolCall]?
}

private struct OpenAIResponseToolCall: Codable {
    let id: String
    let type: String
    let function: OpenAIResponseFunction
}

private struct OpenAIResponseFunction: Codable {
    let name: String
    let arguments: String  // JSON string
}

private struct OpenAIUsage: Codable {
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int
}

// MARK: - AnyCodable Helpers

extension AnyCodable {
    /// Convert a Foundation object to AnyCodable.
    static func from(_ value: Any) -> AnyCodable {
        if let str = value as? String {
            return .string(str)
        } else if let num = value as? NSNumber {
            // Check if it's a boolean (NSNumber wraps Bool)
            if CFBooleanGetTypeID() == CFGetTypeID(num) {
                return .bool(num.boolValue)
            }
            if let intVal = value as? Int {
                return .int(intVal)
            }
            return .double(num.doubleValue)
        } else if let dict = value as? [String: Any] {
            return .dictionary(dict.mapValues { AnyCodable.from($0) })
        } else if let arr = value as? [Any] {
            return .array(arr.map { AnyCodable.from($0) })
        } else if value is NSNull {
            return .string("")
        }
        return .string(String(describing: value))
    }
}
