import XCTest
@testable import Shadow

// MARK: - Transport Spy

/// Records all calls sent through the transport. Zero calls = no network activity.
private final class SpyTransport: HTTPTransport, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    var callCount: Int { requests.count }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        // Return a valid 200 response (should never be reached in consent tests)
        let data = Data("""
        {"content":[{"type":"text","text":"spy"}],"usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil
        )!
        return (data, response)
    }
}

final class CloudLLMProviderTests: XCTestCase {

    // MARK: - Helpers

    /// Build a provider that bypasses the Keychain entirely.
    /// Uses `apiKeyOverride` so tests never trigger the macOS password prompt.
    private func makeProvider(
        spy: SpyTransport = SpyTransport(),
        apiKey: String = "sk-ant-test-key"
    ) -> (CloudLLMProvider, SpyTransport) {
        let provider = CloudLLMProvider(transport: spy, apiKeyOverride: apiKey)
        return (provider, spy)
    }

    /// Build a fake Anthropic API response JSON with text-only content blocks.
    private func textResponse(_ text: String, inputTokens: Int = 100, outputTokens: Int = 50) -> Data {
        let json = """
        {
          "content": [
            {"type": "text", "text": "\(text)"}
          ],
          "usage": {"input_tokens": \(inputTokens), "output_tokens": \(outputTokens)}
        }
        """
        return Data(json.utf8)
    }

    /// Build a fake Anthropic API response with a tool_use content block.
    private func toolUseResponse(
        toolId: String = "toolu_01",
        toolName: String = "get_weather",
        arguments: String = "{\"location\": \"San Francisco\"}"
    ) -> Data {
        let json = """
        {
          "content": [
            {"type": "tool_use", "id": "\(toolId)", "name": "\(toolName)", "input": \(arguments)}
          ],
          "usage": {"input_tokens": 80, "output_tokens": 30}
        }
        """
        return Data(json.utf8)
    }

    /// Build a fake Anthropic API response with mixed text + tool_use blocks.
    private func mixedResponse() -> Data {
        let json = """
        {
          "content": [
            {"type": "text", "text": "Let me check the weather."},
            {"type": "tool_use", "id": "toolu_01", "name": "get_weather", "input": {"location": "NYC"}},
            {"type": "text", "text": " Done checking."}
          ],
          "usage": {"input_tokens": 150, "output_tokens": 80}
        }
        """
        return Data(json.utf8)
    }

    // MARK: - Text-only response

    func testTextOnlyResponse() throws {
        let data = textResponse("Hello, world!")
        let response = try CloudLLMProvider.parseResponseData(
            data, provider: "test", modelId: "test-model", latencyMs: 100
        )

        XCTAssertEqual(response.content, "Hello, world!")
        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertEqual(response.provider, "test")
        XCTAssertEqual(response.modelId, "test-model")
        XCTAssertEqual(response.inputTokens, 100)
        XCTAssertEqual(response.outputTokens, 50)
    }

    // MARK: - Tool call parsing

    func testToolCallParsing() throws {
        let data = toolUseResponse(
            toolId: "toolu_abc",
            toolName: "search",
            arguments: "{\"query\": \"test\"}"
        )
        let response = try CloudLLMProvider.parseResponseData(
            data, provider: "cloud", modelId: "claude-haiku", latencyMs: 200
        )

        XCTAssertEqual(response.content, "")
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls[0].id, "toolu_abc")
        XCTAssertEqual(response.toolCalls[0].name, "search")
        XCTAssertEqual(response.toolCalls[0].arguments["query"], .string("test"))
    }

    // MARK: - Mixed content blocks

    func testMixedContentBlocks() throws {
        let data = mixedResponse()
        let response = try CloudLLMProvider.parseResponseData(
            data, provider: "cloud", modelId: "claude-haiku", latencyMs: 300
        )

        XCTAssertEqual(response.content, "Let me check the weather. Done checking.")
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls[0].name, "get_weather")
        XCTAssertEqual(response.toolCalls[0].arguments["location"], .string("NYC"))
    }

    // MARK: - Malformed response

    func testMalformedResponse_throwsError() {
        let badData = Data("not json".utf8)
        XCTAssertThrowsError(try CloudLLMProvider.parseResponseData(
            badData, provider: "test", modelId: "test", latencyMs: 0
        )) { error in
            guard let llmError = error as? LLMProviderError,
                  case .malformedOutput = llmError else {
                XCTFail("Expected .malformedOutput, got \(error)")
                return
            }
        }
    }

    // MARK: - Usage extraction

    func testUsageExtraction() throws {
        let data = textResponse("ok", inputTokens: 42, outputTokens: 17)
        let response = try CloudLLMProvider.parseResponseData(
            data, provider: "test", modelId: "test", latencyMs: 50
        )

        XCTAssertEqual(response.inputTokens, 42)
        XCTAssertEqual(response.outputTokens, 17)
        XCTAssertEqual(response.latencyMs, 50)
    }

    // MARK: - Consent gate: no network calls when consent denied

    /// Proves: with consent=false, generate() throws .consentRequired and the
    /// transport spy records zero calls. No data leaves the device.
    ///
    /// Uses apiKeyOverride to inject a test key without touching the Keychain.
    func testConsentDenied_zeroNetworkCalls() async {
        // Ensure consent is OFF
        UserDefaults.standard.set(false, forKey: "llmCloudConsentGranted")

        defer {
            UserDefaults.standard.removeObject(forKey: "llmCloudConsentGranted")
        }

        let (provider, spy) = makeProvider()

        // Verify isAvailable is true (API key injected via override)
        XCTAssertTrue(provider.isAvailable, "Provider must be available (API key injected)")

        let request = LLMRequest(
            systemPrompt: "Test",
            userPrompt: "Hello",
            tools: [],
            maxTokens: 100,
            temperature: 0.0,
            responseFormat: .text
        )

        do {
            _ = try await provider.generate(request: request)
            XCTFail("Expected .consentRequired to be thrown")
        } catch let error as LLMProviderError {
            guard case .consentRequired = error else {
                XCTFail("Expected .consentRequired, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // The critical assertion: transport was NEVER called
        XCTAssertEqual(spy.callCount, 0, "Transport must not be called when consent is denied")
    }

    // MARK: - JSON mode validation

    func testValidateJSON_validObject() {
        XCTAssertNoThrow(try CloudLLMProvider.validateJSONContent("{\"key\": \"value\"}"))
    }

    func testValidateJSON_validArray() {
        XCTAssertNoThrow(try CloudLLMProvider.validateJSONContent("[1, 2, 3]"))
    }

    func testValidateJSON_withWhitespace() {
        XCTAssertNoThrow(try CloudLLMProvider.validateJSONContent("  \n{\"ok\": true}\n  "))
    }

    func testValidateJSON_emptyContent_throws() {
        XCTAssertThrowsError(try CloudLLMProvider.validateJSONContent("")) { error in
            guard let llmError = error as? LLMProviderError,
                  case .malformedOutput(let detail) = llmError else {
                XCTFail("Expected .malformedOutput, got \(error)")
                return
            }
            XCTAssertTrue(detail.contains("empty"), "Detail should mention empty: \(detail)")
        }
    }

    func testValidateJSON_whitespaceOnly_throws() {
        XCTAssertThrowsError(try CloudLLMProvider.validateJSONContent("   \n\t  ")) { error in
            guard let llmError = error as? LLMProviderError,
                  case .malformedOutput = llmError else {
                XCTFail("Expected .malformedOutput, got \(error)")
                return
            }
        }
    }

    func testValidateJSON_plainText_throws() {
        XCTAssertThrowsError(try CloudLLMProvider.validateJSONContent("This is not JSON")) { error in
            guard let llmError = error as? LLMProviderError,
                  case .malformedOutput(let detail) = llmError else {
                XCTFail("Expected .malformedOutput, got \(error)")
                return
            }
            XCTAssertTrue(detail.contains("not valid JSON"), "Detail should mention invalid JSON: \(detail)")
        }
    }

    func testValidateJSON_markdownWrapped_throws() {
        // LLM sometimes wraps JSON in markdown code fences
        let content = "```json\n{\"key\": \"value\"}\n```"
        XCTAssertThrowsError(try CloudLLMProvider.validateJSONContent(content)) { error in
            guard let llmError = error as? LLMProviderError,
                  case .malformedOutput = llmError else {
                XCTFail("Expected .malformedOutput, got \(error)")
                return
            }
        }
    }

    // MARK: - Image block encoding via SpyTransport

    /// Proves: an LLMMessage with .image content encodes to the correct
    /// Anthropic API format: {"type":"image","source":{"type":"base64","media_type":"...","data":"..."}}
    func testImageBlockEncoding_correctShape() async {
        UserDefaults.standard.set(true, forKey: "llmCloudConsentGranted")

        defer {
            UserDefaults.standard.removeObject(forKey: "llmCloudConsentGranted")
        }

        let spy = SpyTransport()
        let (provider, _) = makeProvider(spy: spy)

        let imageMessage = LLMMessage(role: "user", content: [
            .image(mediaType: "image/jpeg", base64Data: "dGVzdA=="),
        ])

        let request = LLMRequest(
            systemPrompt: "Test",
            userPrompt: "",
            tools: [],
            maxTokens: 100,
            temperature: 0.0,
            responseFormat: .text,
            messages: [imageMessage]
        )

        _ = try? await provider.generate(request: request)

        XCTAssertEqual(spy.callCount, 1)

        if let body = spy.requests.first?.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let messages = json["messages"] as? [[String: Any]],
           let content = messages.first?["content"] as? [[String: Any]],
           let block = content.first {
            XCTAssertEqual(block["type"] as? String, "image")
            if let source = block["source"] as? [String: Any] {
                XCTAssertEqual(source["type"] as? String, "base64")
                XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
                XCTAssertEqual(source["data"] as? String, "dGVzdA==")
            } else {
                XCTFail("Image block missing source")
            }
        } else {
            XCTFail("Could not parse request body")
        }
    }

    /// Proves: a message with .toolResult + .image blocks encodes correctly in sequence.
    func testMixedToolResultAndImage_encodesCorrectly() async {
        UserDefaults.standard.set(true, forKey: "llmCloudConsentGranted")

        defer {
            UserDefaults.standard.removeObject(forKey: "llmCloudConsentGranted")
        }

        let spy = SpyTransport()
        let (provider, _) = makeProvider(spy: spy)

        let mixedMessage = LLMMessage(role: "user", content: [
            .toolResult(toolUseId: "tool_123", content: "Frame extracted", isError: false),
            .image(mediaType: "image/jpeg", base64Data: "aW1hZ2U="),
        ])

        let request = LLMRequest(
            systemPrompt: "Test",
            userPrompt: "",
            tools: [],
            maxTokens: 100,
            temperature: 0.0,
            responseFormat: .text,
            messages: [mixedMessage]
        )

        _ = try? await provider.generate(request: request)

        XCTAssertEqual(spy.callCount, 1)

        if let body = spy.requests.first?.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let messages = json["messages"] as? [[String: Any]],
           let content = messages.first?["content"] as? [[String: Any]] {
            XCTAssertEqual(content.count, 2, "Should have tool_result + image blocks")
            XCTAssertEqual(content[0]["type"] as? String, "tool_result")
            XCTAssertEqual(content[0]["tool_use_id"] as? String, "tool_123")
            XCTAssertEqual(content[1]["type"] as? String, "image")
        } else {
            XCTFail("Could not parse request body")
        }
    }

    /// Regression: tool_result without images encodes unchanged (no source field present).
    func testToolResultWithoutImages_unchanged() async {
        UserDefaults.standard.set(true, forKey: "llmCloudConsentGranted")

        defer {
            UserDefaults.standard.removeObject(forKey: "llmCloudConsentGranted")
        }

        let spy = SpyTransport()
        let (provider, _) = makeProvider(spy: spy)

        let toolResultMessage = LLMMessage(role: "user", content: [
            .toolResult(toolUseId: "tool_456", content: "Result text", isError: false),
        ])

        let request = LLMRequest(
            systemPrompt: "Test",
            userPrompt: "",
            tools: [],
            maxTokens: 100,
            temperature: 0.0,
            responseFormat: .text,
            messages: [toolResultMessage]
        )

        _ = try? await provider.generate(request: request)

        if let body = spy.requests.first?.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let messages = json["messages"] as? [[String: Any]],
           let content = messages.first?["content"] as? [[String: Any]],
           let block = content.first {
            XCTAssertEqual(block["type"] as? String, "tool_result")
            XCTAssertEqual(block["content"] as? String, "Result text")
            XCTAssertNil(block["source"], "tool_result should not have a source field")
            XCTAssertNil(block["is_error"], "Non-error tool_result should not have is_error")
        } else {
            XCTFail("Could not parse request body")
        }
    }
}
