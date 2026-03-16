import XCTest
@testable import Shadow

// MARK: - Mock Transport

/// Transport spy that returns preconfigured responses for Ollama tests.
private final class OllamaSpyTransport: HTTPTransport, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    var callCount: Int { requests.count }

    /// Response to return for /api/tags (ping endpoint)
    var tagsResponse: (Data, HTTPURLResponse)?
    /// Response to return for /api/chat (generate endpoint)
    var chatResponse: (Data, HTTPURLResponse)?

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)

        let path = request.url?.path ?? ""

        if path.hasSuffix("/api/tags"), let resp = tagsResponse {
            return (resp.0, resp.1)
        }
        if path.hasSuffix("/api/chat"), let resp = chatResponse {
            return (resp.0, resp.1)
        }

        // Default: return 200 for tags, 404 for unknown
        if path.hasSuffix("/api/tags") {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (Data("{}".utf8), response)
        }

        throw URLError(.cannotConnectToHost)
    }
}

/// Transport that always throws connection refused — simulates Ollama not running.
private final class OllamaOfflineTransport: HTTPTransport, @unchecked Sendable {
    var callCount = 0

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        throw URLError(.cannotConnectToHost)
    }
}

// MARK: - Tests

final class OllamaProviderTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: "ollamaModelId")
        UserDefaults.standard.removeObject(forKey: "ollamaEnabled")
    }

    // MARK: - Provider Identity

    func testProviderName() {
        let transport = OllamaOfflineTransport()
        let provider = OllamaProvider(transport: transport)
        XCTAssertEqual(provider.providerName, "ollama_local")
    }

    func testProviderNameContainsLocal() {
        let transport = OllamaOfflineTransport()
        let provider = OllamaProvider(transport: transport)
        XCTAssertTrue(provider.providerName.contains("local"),
            "Provider name must contain 'local' for orchestrator routing")
    }

    func testDefaultModelId() {
        UserDefaults.standard.removeObject(forKey: "ollamaModelId")
        let transport = OllamaOfflineTransport()
        let provider = OllamaProvider(transport: transport)
        XCTAssertEqual(provider.modelId, "qwen2.5:7b-instruct")
    }

    func testModelIdFromUserDefaults() {
        UserDefaults.standard.set("llama3.1:8b", forKey: "ollamaModelId")
        let transport = OllamaOfflineTransport()
        let provider = OllamaProvider(transport: transport)
        XCTAssertEqual(provider.modelId, "llama3.1:8b")
    }

    // MARK: - Availability

    func testIsAvailable_returnsFalseWhenOllamaNotRunning() {
        let transport = OllamaOfflineTransport()
        let provider = OllamaProvider(transport: transport)
        // Initially false because the background ping hasn't succeeded yet
        // and the default cached value is false.
        XCTAssertFalse(provider.isAvailable)
    }

    func testIsAvailable_returnsTrueAfterSuccessfulPing() async throws {
        let transport = OllamaSpyTransport()
        transport.tagsResponse = (
            Data("{}".utf8),
            HTTPURLResponse(
                url: URL(string: "http://localhost:11434/api/tags")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )

        let provider = OllamaProvider(transport: transport)

        // Wait for the initial background ping to complete
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(provider.isAvailable)
    }

    // MARK: - Generate Errors

    func testGenerate_throwsUnavailableWhenOllamaNotRunning() async {
        let transport = OllamaOfflineTransport()
        let provider = OllamaProvider(transport: transport)

        let request = LLMRequest(
            systemPrompt: "Test",
            userPrompt: "Hello",
            maxTokens: 100,
            temperature: 0.3,
            responseFormat: .text
        )

        do {
            _ = try await provider.generate(request: request)
            XCTFail("Expected unavailable error")
        } catch let error as LLMProviderError {
            if case .unavailable(let reason) = error {
                XCTAssertTrue(reason.contains("Ollama"),
                    "Error should mention Ollama, got: \(reason)")
            } else {
                XCTFail("Expected .unavailable error, got \(error)")
            }
        } catch {
            XCTFail("Expected LLMProviderError, got \(error)")
        }
    }

    // MARK: - Request Body Construction

    func testRequestBody_containsModelAndMessages() async throws {
        let transport = OllamaSpyTransport()
        // Make tags return 200 so provider is available
        transport.tagsResponse = (
            Data("{}".utf8),
            HTTPURLResponse(
                url: URL(string: "http://localhost:11434/api/tags")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )
        // Return a valid chat response
        transport.chatResponse = (
            ollamaTextResponse("Hello there!"),
            HTTPURLResponse(
                url: URL(string: "http://localhost:11434/api/chat")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )

        let provider = OllamaProvider(transport: transport)

        let request = LLMRequest(
            systemPrompt: "You are helpful.",
            userPrompt: "Hi",
            maxTokens: 100,
            temperature: 0.5,
            responseFormat: .text
        )

        _ = try await provider.generate(request: request)

        // Find the chat request
        let chatRequest = transport.requests.first { $0.url?.path.hasSuffix("/api/chat") == true }
        XCTAssertNotNil(chatRequest, "Should have made a /api/chat request")

        if let body = chatRequest?.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            XCTAssertEqual(json["model"] as? String, "qwen2.5:7b-instruct")
            XCTAssertEqual(json["stream"] as? Bool, false)

            if let messages = json["messages"] as? [[String: Any]] {
                // First message should be system
                XCTAssertEqual(messages[0]["role"] as? String, "system")
                XCTAssertEqual(messages[0]["content"] as? String, "You are helpful.")
                // Second message should be user
                XCTAssertEqual(messages[1]["role"] as? String, "user")
                XCTAssertEqual(messages[1]["content"] as? String, "Hi")
            } else {
                XCTFail("Messages not found in request body")
            }

            if let options = json["options"] as? [String: Any] {
                XCTAssertEqual(options["temperature"] as? Double, 0.5)
                XCTAssertEqual(options["num_predict"] as? Int, 100)
            } else {
                XCTFail("Options not found in request body")
            }

            // Tools should not be present when empty
            XCTAssertNil(json["tools"], "Tools should not be present when empty")
        } else {
            XCTFail("Could not parse request body")
        }
    }

    func testRequestBody_includesToolsWhenProvided() async throws {
        let transport = OllamaSpyTransport()
        transport.tagsResponse = (
            Data("{}".utf8),
            HTTPURLResponse(
                url: URL(string: "http://localhost:11434/api/tags")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )
        transport.chatResponse = (
            ollamaTextResponse("result"),
            HTTPURLResponse(
                url: URL(string: "http://localhost:11434/api/chat")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )

        let provider = OllamaProvider(transport: transport)

        let tools = [ToolSpec(
            name: "search_hybrid",
            description: "Search across content",
            inputSchema: [
                "type": .string("object"),
                "properties": .dictionary([
                    "query": .dictionary([
                        "type": .string("string"),
                        "description": .string("Search query")
                    ])
                ]),
                "required": .array([.string("query")])
            ]
        )]

        let request = LLMRequest(
            systemPrompt: "Test",
            userPrompt: "Search for cats",
            tools: tools,
            maxTokens: 500,
            temperature: 0.3,
            responseFormat: .text
        )

        _ = try await provider.generate(request: request)

        let chatRequest = transport.requests.first { $0.url?.path.hasSuffix("/api/chat") == true }
        if let body = chatRequest?.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let toolsArray = json["tools"] as? [[String: Any]] {
            XCTAssertEqual(toolsArray.count, 1)
            if let function = toolsArray[0]["function"] as? [String: Any] {
                XCTAssertEqual(function["name"] as? String, "search_hybrid")
                XCTAssertEqual(function["description"] as? String, "Search across content")
            } else {
                XCTFail("Tool function not found")
            }
        } else {
            XCTFail("Tools not found in request body")
        }
    }

    // MARK: - Response Parsing

    func testParseTextResponse() throws {
        let data = ollamaTextResponse("Hello, world!", inputTokens: 42, outputTokens: 17)
        let response = try OllamaProvider.parseResponseData(
            data, provider: "test", modelId: "test-model", latencyMs: 100
        )

        XCTAssertEqual(response.content, "Hello, world!")
        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertEqual(response.provider, "test")
        XCTAssertEqual(response.modelId, "test-model")
        XCTAssertEqual(response.inputTokens, 42)
        XCTAssertEqual(response.outputTokens, 17)
        XCTAssertEqual(response.latencyMs, 100)
    }

    func testParseNativeToolCallResponse() throws {
        let data = ollamaNativeToolCallResponse(
            toolName: "search_hybrid",
            arguments: ["query": "test data"]
        )
        let response = try OllamaProvider.parseResponseData(
            data, provider: "ollama", modelId: "qwen2.5:7b", latencyMs: 500
        )

        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls[0].name, "search_hybrid")
        XCTAssertEqual(response.toolCalls[0].arguments["query"], .string("test data"))
        XCTAssertFalse(response.toolCalls[0].id.isEmpty, "Tool call should have a generated ID")
    }

    func testParseHermesFallbackToolCall() throws {
        let content = """
        Let me search for that.
        <tool_call>
        {"name": "search_hybrid", "arguments": {"query": "meeting notes"}}
        </tool_call>
        """
        let data = ollamaTextResponse(content)
        let response = try OllamaProvider.parseResponseData(
            data, provider: "ollama", modelId: "qwen2.5:7b", latencyMs: 300
        )

        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls[0].name, "search_hybrid")
        XCTAssertEqual(response.toolCalls[0].arguments["query"], .string("meeting notes"))
        XCTAssertEqual(response.content, "Let me search for that.")
    }

    func testParseNativeToolCallsTakePrecedence() throws {
        // When native tool_calls are present, Hermes parsing is not attempted
        let json = """
        {
          "message": {
            "role": "assistant",
            "content": "<tool_call>{\\"name\\": \\"old_tool\\", \\"arguments\\": {}}</tool_call>",
            "tool_calls": [
              {
                "function": {
                  "name": "native_tool",
                  "arguments": {"key": "value"}
                }
              }
            ]
          },
          "prompt_eval_count": 10,
          "eval_count": 5
        }
        """
        let data = Data(json.utf8)
        let response = try OllamaProvider.parseResponseData(
            data, provider: "ollama", modelId: "test", latencyMs: 100
        )

        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls[0].name, "native_tool")
    }

    func testParseMalformedResponse() {
        let data = Data("not json at all".utf8)
        XCTAssertThrowsError(try OllamaProvider.parseResponseData(
            data, provider: "test", modelId: "test", latencyMs: 0
        )) { error in
            guard let llmError = error as? LLMProviderError,
                  case .malformedOutput = llmError else {
                XCTFail("Expected .malformedOutput, got \(error)")
                return
            }
        }
    }

    func testParseMissingMessageField() {
        let data = Data("{\"not_message\": {}}".utf8)
        XCTAssertThrowsError(try OllamaProvider.parseResponseData(
            data, provider: "test", modelId: "test", latencyMs: 0
        )) { error in
            guard let llmError = error as? LLMProviderError,
                  case .malformedOutput(let detail) = llmError else {
                XCTFail("Expected .malformedOutput, got \(error)")
                return
            }
            XCTAssertTrue(detail.contains("message"), "Detail should mention missing message: \(detail)")
        }
    }

    func testParseErrorResponse() {
        let data = Data("{\"error\": \"model not found\"}".utf8)
        XCTAssertThrowsError(try OllamaProvider.parseResponseData(
            data, provider: "test", modelId: "test", latencyMs: 0
        )) { error in
            guard let llmError = error as? LLMProviderError,
                  case .terminalFailure(let reason) = llmError else {
                XCTFail("Expected .terminalFailure, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("model not found"), "Error should contain Ollama message: \(reason)")
        }
    }

    // MARK: - Multi-Turn Message Formatting

    func testMapLLMMessage_textContent() {
        let msg = LLMMessage(role: "user", content: [.text("Hello")])
        let mapped = OllamaProvider.mapLLMMessage(msg)

        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0]["role"] as? String, "user")
        XCTAssertEqual(mapped[0]["content"] as? String, "Hello")
    }

    func testMapLLMMessage_toolUseContent() {
        let msg = LLMMessage(role: "assistant", content: [
            .text("Searching..."),
            .toolUse(id: "tool_1", name: "search", input: ["query": .string("test")])
        ])
        let mapped = OllamaProvider.mapLLMMessage(msg)

        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0]["role"] as? String, "assistant")
        XCTAssertEqual(mapped[0]["content"] as? String, "Searching...")

        if let toolCalls = mapped[0]["tool_calls"] as? [[String: Any]],
           let first = toolCalls.first,
           let function = first["function"] as? [String: Any] {
            XCTAssertEqual(function["name"] as? String, "search")
            if let args = function["arguments"] as? [String: Any] {
                XCTAssertEqual(args["query"] as? String, "test")
            } else {
                XCTFail("Tool call arguments missing")
            }
        } else {
            XCTFail("Tool calls not found in mapped message")
        }
    }

    func testMapLLMMessage_toolResultContent() {
        let msg = LLMMessage(role: "user", content: [
            .toolResult(toolUseId: "tool_1", content: "Found 3 results", isError: false)
        ])
        let mapped = OllamaProvider.mapLLMMessage(msg)

        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0]["role"] as? String, "tool")
        XCTAssertEqual(mapped[0]["content"] as? String, "Found 3 results")
    }

    func testMapLLMMessage_imageContent() {
        let msg = LLMMessage(role: "user", content: [
            .text("What is this?"),
            .image(mediaType: "image/jpeg", base64Data: "dGVzdA==")
        ])
        let mapped = OllamaProvider.mapLLMMessage(msg)

        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0]["content"] as? String, "What is this?")
        if let images = mapped[0]["images"] as? [String] {
            XCTAssertEqual(images, ["dGVzdA=="])
        } else {
            XCTFail("Images not found in mapped message")
        }
    }

    func testMapLLMMessage_mixedToolUseAndResult() {
        // An assistant message with text + tool_use, followed by tool_result
        let msg = LLMMessage(role: "user", content: [
            .toolResult(toolUseId: "tool_1", content: "Result text", isError: false),
            .text("Thanks")
        ])
        let mapped = OllamaProvider.mapLLMMessage(msg)

        // Should produce 2 messages: the text message and the tool result
        XCTAssertEqual(mapped.count, 2)
        // First message is the text (inserted at index 0)
        XCTAssertEqual(mapped[0]["content"] as? String, "Thanks")
        // Second is the tool result
        XCTAssertEqual(mapped[1]["role"] as? String, "tool")
        XCTAssertEqual(mapped[1]["content"] as? String, "Result text")
    }

    // MARK: - Helpers

    private func ollamaTextResponse(
        _ text: String,
        inputTokens: Int = 100,
        outputTokens: Int = 50
    ) -> Data {
        let json = """
        {
          "message": {
            "role": "assistant",
            "content": \(escapeJSONString(text))
          },
          "prompt_eval_count": \(inputTokens),
          "eval_count": \(outputTokens)
        }
        """
        return Data(json.utf8)
    }

    private func ollamaNativeToolCallResponse(
        toolName: String,
        arguments: [String: String]
    ) -> Data {
        let argsJSON = arguments.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ", ")
        let json = """
        {
          "message": {
            "role": "assistant",
            "content": "",
            "tool_calls": [
              {
                "function": {
                  "name": "\(toolName)",
                  "arguments": {\(argsJSON)}
                }
              }
            ]
          },
          "prompt_eval_count": 80,
          "eval_count": 30
        }
        """
        return Data(json.utf8)
    }

    /// Escape a string for embedding in JSON.
    private func escapeJSONString(_ str: String) -> String {
        let escaped = str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
