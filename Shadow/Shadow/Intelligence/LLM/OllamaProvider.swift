import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "OllamaProvider")

/// Opt-in LLM provider for power users running Ollama locally.
///
/// Connects to `localhost:11434` via HTTP. Must be explicitly enabled
/// by the user in Diagnostics/Settings. Never in the default provider chain.
///
/// Availability is probed periodically (every 30 seconds) via `/api/tags`
/// and cached in a thread-safe boolean so `isAvailable` remains synchronous.
final class OllamaProvider: @unchecked Sendable, LLMProvider {

    /// Contains "local" so the orchestrator includes it in auto/localOnly modes.
    let providerName = "ollama_local"

    /// Model ID configurable via UserDefaults. Default: "qwen2.5:7b-instruct".
    var modelId: String {
        UserDefaults.standard.string(forKey: "ollamaModelId")
            ?? "qwen2.5:7b-instruct"
    }

    // MARK: - Configuration

    private static let baseURL = URL(string: "http://localhost:11434")!
    private static let chatEndpoint = URL(string: "http://localhost:11434/api/chat")!
    private static let tagsEndpoint = URL(string: "http://localhost:11434/api/tags")!
    private static let timeoutInterval: TimeInterval = 60
    private static let pingTimeout: TimeInterval = 2
    private static let pingInterval: TimeInterval = 30

    // MARK: - State

    private let transport: any HTTPTransport
    private let availabilityLock = OSAllocatedUnfairLock(initialState: false)
    private var pingTask: Task<Void, Never>?

    // MARK: - Init / Deinit

    init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
        startPeriodicPing()
    }

    deinit {
        pingTask?.cancel()
    }

    // MARK: - Availability

    /// Synchronous availability check — reads cached ping result.
    var isAvailable: Bool {
        availabilityLock.withLock { $0 }
    }

    /// Probe Ollama reachability by hitting `/api/tags`.
    /// Updates the cached availability flag.
    private func checkAvailability() async {
        var request = URLRequest(url: Self.tagsEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.pingTimeout

        let reachable: Bool
        do {
            let (_, response) = try await transport.send(request)
            if let http = response as? HTTPURLResponse {
                reachable = http.statusCode == 200
            } else {
                reachable = false
            }
        } catch {
            reachable = false
        }

        let previous = availabilityLock.withLock { current -> Bool in
            let prev = current
            current = reachable
            return prev
        }

        DiagnosticsStore.shared.setGauge("ollama_available", value: reachable ? 1 : 0)

        // Log only on state transitions
        if reachable != previous {
            if reachable {
                logger.info("Ollama detected at localhost:11434")
            } else {
                logger.info("Ollama not reachable at localhost:11434")
            }
        }
    }

    private func startPeriodicPing() {
        pingTask = Task.detached(priority: .utility) { [weak self] in
            // Initial check
            await self?.checkAvailability()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pingInterval))
                guard !Task.isCancelled else { break }
                await self?.checkAvailability()
            }
        }
    }

    // MARK: - Generate

    func generate(request: LLMRequest) async throws -> LLMResponse {
        // Fresh availability check (don't rely solely on cached value)
        await checkAvailability()

        guard isAvailable else {
            throw LLMProviderError.unavailable(reason: "Ollama not running at localhost:11434")
        }

        let requestId = UUID().uuidString
        let startTime = CFAbsoluteTimeGetCurrent()

        DiagnosticsStore.shared.increment("ollama_attempt_total")
        logger.info("Ollama request: model=\(self.modelId) requestId=\(requestId)")

        // Build system prompt — prepend JSON instruction if json format requested
        var systemPrompt = request.systemPrompt
        if request.responseFormat == .json {
            systemPrompt = "Respond with valid JSON only.\n\n" + systemPrompt
        }

        // Build messages array
        let messages = buildMessages(request: request, systemPrompt: systemPrompt)

        // Build tools array (Ollama native format)
        let tools: [[String: Any]]? = request.tools.isEmpty ? nil : request.tools.map { spec in
            [
                "type": "function",
                "function": [
                    "name": spec.name,
                    "description": spec.description,
                    "parameters": LocalToolCallParser.anyCodableToJSONObject(
                        .dictionary(spec.inputSchema)
                    )
                ] as [String: Any]
            ]
        }

        // Build request body
        var body: [String: Any] = [
            "model": modelId,
            "messages": messages,
            "stream": false,
            "options": [
                "temperature": request.temperature,
                "num_predict": request.maxTokens
            ] as [String: Any]
        ]

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

        // Constrain output to valid JSON at the token level when JSON format requested.
        // Ollama's native "format": "json" mode forces the model to produce valid JSON.
        if request.responseFormat == .json {
            body["format"] = "json"
        }

        let requestData: Data
        do {
            requestData = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw LLMProviderError.terminalFailure(
                reason: "Failed to encode Ollama request: \(error.localizedDescription)"
            )
        }

        var urlRequest = URLRequest(url: Self.chatEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = requestData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = Self.timeoutInterval

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport.send(urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            DiagnosticsStore.shared.increment("ollama_fail_total")
            throw LLMProviderError.timeout
        } catch let error as URLError where error.code == .cannotConnectToHost {
            DiagnosticsStore.shared.increment("ollama_fail_total")
            availabilityLock.withLock { $0 = false }
            throw LLMProviderError.unavailable(reason: "Cannot connect to Ollama: \(error.localizedDescription)")
        } catch {
            DiagnosticsStore.shared.increment("ollama_fail_total")
            throw LLMProviderError.transientFailure(underlying: error.localizedDescription)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        guard let httpResponse = response as? HTTPURLResponse else {
            DiagnosticsStore.shared.increment("ollama_fail_total")
            throw LLMProviderError.transientFailure(underlying: "Non-HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            DiagnosticsStore.shared.increment("ollama_fail_total")
            let responseBody = String(data: data, encoding: .utf8) ?? "no body"
            throw Self.mapHTTPError(status: httpResponse.statusCode, body: responseBody)
        }

        let llmResponse: LLMResponse
        do {
            llmResponse = try Self.parseResponseData(
                data,
                provider: providerName,
                modelId: modelId,
                latencyMs: elapsed
            )
        } catch {
            DiagnosticsStore.shared.increment("ollama_fail_total")
            throw error
        }

        // JSON mode: strip markdown fences and validate well-formed JSON.
        // Even with Ollama's native "format": "json", validate defensively.
        if request.responseFormat == .json {
            let cleaned = CloudLLMProvider.stripMarkdownFences(llmResponse.content)
            try CloudLLMProvider.validateJSONContent(cleaned)
            let validated = LLMResponse(
                content: cleaned,
                toolCalls: llmResponse.toolCalls,
                provider: llmResponse.provider,
                modelId: llmResponse.modelId,
                inputTokens: llmResponse.inputTokens,
                outputTokens: llmResponse.outputTokens,
                latencyMs: llmResponse.latencyMs
            )

            DiagnosticsStore.shared.increment("ollama_success_total")
            DiagnosticsStore.shared.recordLatency("ollama_latency_ms", ms: elapsed)
            logger.info("Ollama response: model=\(self.modelId) latency=\(String(format: "%.0f", elapsed))ms tokens_in=\(validated.inputTokens ?? 0) tokens_out=\(validated.outputTokens ?? 0)")
            return validated
        }

        DiagnosticsStore.shared.increment("ollama_success_total")
        DiagnosticsStore.shared.recordLatency("ollama_latency_ms", ms: elapsed)
        logger.info("Ollama response: model=\(self.modelId) latency=\(String(format: "%.0f", elapsed))ms tokens_in=\(llmResponse.inputTokens ?? 0) tokens_out=\(llmResponse.outputTokens ?? 0)")

        return llmResponse
    }

    // MARK: - Message Building

    /// Build the messages array for the Ollama API.
    /// Maps LLMRequest to Ollama's message format.
    private func buildMessages(request: LLMRequest, systemPrompt: String) -> [[String: Any]] {
        var messages: [[String: Any]] = []

        // System message
        if !systemPrompt.isEmpty {
            messages.append([
                "role": "system",
                "content": systemPrompt
            ])
        }

        if let llmMessages = request.messages {
            // Multi-turn: convert each LLMMessage
            for msg in llmMessages {
                let converted = Self.mapLLMMessage(msg)
                messages.append(contentsOf: converted)
            }
        } else {
            // Legacy single-pass: user prompt only
            messages.append([
                "role": "user",
                "content": request.userPrompt
            ])
        }

        return messages
    }

    /// Map an LLMMessage to one or more Ollama message dictionaries.
    ///
    /// A single LLMMessage can contain mixed content blocks (text, tool_use, tool_result, image).
    /// Ollama expects separate messages for different roles (assistant text, assistant tool_calls,
    /// tool results), so we split as needed.
    internal static func mapLLMMessage(_ msg: LLMMessage) -> [[String: Any]] {
        var results: [[String: Any]] = []

        // Collect text blocks and tool_use blocks for assistant messages
        var textParts: [String] = []
        var toolCalls: [[String: Any]] = []
        var images: [String] = []

        for block in msg.content {
            switch block {
            case .text(let t):
                textParts.append(t)

            case .toolUse(_, let name, let input):
                // Convert AnyCodable dict to plain dict
                var args: [String: Any] = [:]
                for (key, value) in input {
                    args[key] = LocalToolCallParser.anyCodableToJSONObject(value)
                }
                toolCalls.append([
                    "function": [
                        "name": name,
                        "arguments": args
                    ] as [String: Any]
                ])

            case .toolResult(_, let content, _):
                // Tool results are separate messages with role "tool"
                results.append([
                    "role": "tool",
                    "content": content
                ])

            case .image(_, let base64Data):
                images.append(base64Data)
            }
        }

        // Build the primary message (text + images + tool_calls)
        if !textParts.isEmpty || !toolCalls.isEmpty || !images.isEmpty {
            var message: [String: Any] = ["role": msg.role]

            let text = textParts.joined()
            if !text.isEmpty {
                message["content"] = text
            }

            if !toolCalls.isEmpty {
                message["tool_calls"] = toolCalls
            }

            if !images.isEmpty {
                message["images"] = images
            }

            // Insert before any tool results (tool results come after the assistant message)
            results.insert(message, at: 0)
        }

        return results
    }

    // MARK: - Response Parsing

    /// Parse raw Ollama API response data into an LLMResponse.
    /// Extracted as a static method so tests can exercise parsing without network calls.
    internal static func parseResponseData(
        _ data: Data,
        provider: String,
        modelId: String,
        latencyMs: Double
    ) throws -> LLMResponse {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LLMProviderError.malformedOutput(
                detail: "Failed to decode Ollama response: \(error.localizedDescription)"
            )
        }

        guard let dict = parsed as? [String: Any] else {
            throw LLMProviderError.malformedOutput(detail: "Ollama response is not a JSON object")
        }

        // Check for error response
        if let errorMsg = dict["error"] as? String {
            throw LLMProviderError.terminalFailure(reason: "Ollama error: \(errorMsg)")
        }

        guard let message = dict["message"] as? [String: Any] else {
            throw LLMProviderError.malformedOutput(detail: "Ollama response missing 'message' field")
        }

        let content = message["content"] as? String ?? ""

        // Extract tool calls — try Ollama native format first
        var toolCalls: [ToolCall] = []

        if let rawToolCalls = message["tool_calls"] as? [[String: Any]] {
            // Ollama native tool call format
            for rawCall in rawToolCalls {
                if let function = rawCall["function"] as? [String: Any],
                   let name = function["name"] as? String {
                    let rawArgs = function["arguments"] as? [String: Any] ?? [:]
                    let arguments = LocalToolCallParser.jsonObjectToAnyCodableDict(rawArgs)
                    toolCalls.append(ToolCall(
                        id: UUID().uuidString,
                        name: name,
                        arguments: arguments
                    ))
                }
            }
        }

        // Hermes format fallback — if no native tool calls found, try parsing content
        if toolCalls.isEmpty && content.contains("<tool_call>") {
            let parsed = LocalToolCallParser.parse(response: content)
            toolCalls = parsed.toolCalls
            // If Hermes parsing found tool calls, use the text content before the first tag
            if !toolCalls.isEmpty {
                let inputTokens = dict["prompt_eval_count"] as? Int
                let outputTokens = dict["eval_count"] as? Int
                return LLMResponse(
                    content: parsed.content,
                    toolCalls: toolCalls,
                    provider: provider,
                    modelId: modelId,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    latencyMs: latencyMs
                )
            }
        }

        // Token counts
        let inputTokens = dict["prompt_eval_count"] as? Int
        let outputTokens = dict["eval_count"] as? Int

        return LLMResponse(
            content: content,
            toolCalls: toolCalls,
            provider: provider,
            modelId: modelId,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            latencyMs: latencyMs
        )
    }

    // MARK: - HTTP Error Mapping

    private static func mapHTTPError(status: Int, body: String) -> LLMProviderError {
        switch status {
        case 404:
            return .terminalFailure(reason: "Model not found (404): \(body)")
        case 400...499:
            return .terminalFailure(reason: "HTTP \(status): \(body)")
        case 500...599:
            return .transientFailure(underlying: "Server error (\(status)): \(body)")
        default:
            return .terminalFailure(reason: "HTTP \(status): \(body)")
        }
    }

}
