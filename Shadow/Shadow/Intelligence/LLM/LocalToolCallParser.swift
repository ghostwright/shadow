import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "LocalToolCallParser")

/// Parses Hermes-format tool calls from local LLM output and formats
/// tool definitions for injection into the system prompt.
///
/// Qwen2.5-Instruct models use `<tool_call>...</tool_call>` blocks for
/// structured tool invocation. 4-bit quantized models produce malformed
/// output ~15-20% of the time, so the parser must be robust against
/// partial JSON, missing tags, and other artifacts.
enum LocalToolCallParser {

    // MARK: - Response Parsing

    /// Parse a model response into text content and tool calls.
    ///
    /// Extracts text before the first `<tool_call>` tag as content,
    /// and parses all `<tool_call>...</tool_call>` blocks as tool calls.
    /// Malformed blocks are logged and skipped, never crash.
    ///
    /// - Parameter response: Raw text output from the local LLM.
    /// - Returns: Tuple of (text content before tool calls, parsed tool calls).
    static func parse(response: String) -> (content: String, toolCalls: [ToolCall]) {
        guard !response.isEmpty else {
            return (content: "", toolCalls: [])
        }

        var toolCalls: [ToolCall] = []

        // Find the first <tool_call> tag to split content from tool calls
        let content: String
        if let firstTagRange = response.range(of: "<tool_call>") {
            content = String(response[response.startIndex..<firstTagRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // No tool calls at all — entire response is content
            return (content: response.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: [])
        }

        // Extract all <tool_call>...</tool_call> blocks
        var searchStart = response.startIndex
        while let openRange = response.range(of: "<tool_call>", range: searchStart..<response.endIndex) {
            let jsonStart = openRange.upperBound

            guard let closeRange = response.range(of: "</tool_call>", range: jsonStart..<response.endIndex) else {
                // Opening tag without closing tag — log and stop
                logger.warning("Unclosed <tool_call> tag at offset \(response.distance(from: response.startIndex, to: openRange.lowerBound))")
                break
            }

            let jsonString = String(response[jsonStart..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let toolCall = parseToolCallJSON(jsonString) {
                toolCalls.append(toolCall)
            }

            searchStart = closeRange.upperBound
        }

        return (content: content, toolCalls: toolCalls)
    }

    // MARK: - Tool Definition Formatting

    /// Format tool definitions for injection into the system prompt.
    ///
    /// Produces the Hermes tool-calling format that Qwen2.5-Instruct models
    /// understand: a `<tools>` block with JSON tool schemas and instructions
    /// for using `<tool_call>` blocks.
    ///
    /// - Parameter tools: Tool specifications from the agent registry.
    /// - Returns: Formatted string to prepend to the system prompt.
    static func formatToolDefinitions(_ tools: [ToolSpec]) -> String {
        guard !tools.isEmpty else { return "" }

        let toolDefs: [[String: Any]] = tools.map { spec in
            [
                "type": "function",
                "function": [
                    "name": spec.name,
                    "description": spec.description,
                    "parameters": anyCodableDictToJSONObject(spec.inputSchema)
                ] as [String: Any]
            ]
        }

        // Serialize to JSON — use sortedKeys for deterministic output
        let toolsJSON: String
        if let data = try? JSONSerialization.data(
            withJSONObject: toolDefs,
            options: [.sortedKeys]
        ), let str = String(data: data, encoding: .utf8) {
            toolsJSON = str
        } else {
            logger.error("Failed to serialize tool definitions to JSON")
            return ""
        }

        return """
        You are a helpful assistant with access to the following tools:

        <tools>
        \(toolsJSON)
        </tools>

        When you want to call a tool, output:
        <tool_call>
        {"name": "tool_name", "arguments": {"arg": "value"}}
        </tool_call>

        You may call multiple tools in one response. Include your reasoning before tool calls.
        """
    }

    // MARK: - Internal Helpers

    /// Parse a single tool call JSON string into a ToolCall.
    /// Returns nil if JSON is malformed or missing required fields.
    private static func parseToolCallJSON(_ jsonString: String) -> ToolCall? {
        guard let data = jsonString.data(using: .utf8) else {
            logger.warning("Tool call JSON is not valid UTF-8")
            return nil
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            logger.warning("Malformed tool call JSON: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let dict = parsed as? [String: Any] else {
            logger.warning("Tool call JSON is not a dictionary")
            return nil
        }

        guard let name = dict["name"] as? String, !name.isEmpty else {
            logger.warning("Tool call missing 'name' field")
            return nil
        }

        // Arguments can be a dictionary or missing (some models omit empty args)
        let rawArgs = dict["arguments"] as? [String: Any] ?? [:]
        let arguments = jsonObjectToAnyCodableDict(rawArgs)

        return ToolCall(
            id: UUID().uuidString,
            name: name,
            arguments: arguments
        )
    }

    /// Convert an AnyCodable dictionary to a plain JSON-compatible dictionary.
    private static func anyCodableDictToJSONObject(_ dict: [String: AnyCodable]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dict {
            result[key] = anyCodableToJSONObject(value)
        }
        return result
    }

    /// Convert a single AnyCodable value to a JSON-compatible value.
    /// Internal (not private) so LocalLLMProvider can reuse it for message formatting.
    static func anyCodableToJSONObject(_ value: AnyCodable) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let b):
            return b
        case .int(let i):
            return i
        case .double(let d):
            return d
        case .string(let s):
            return s
        case .array(let arr):
            return arr.map { anyCodableToJSONObject($0) }
        case .dictionary(let dict):
            return anyCodableDictToJSONObject(dict)
        }
    }

    /// Convert a plain JSON dictionary to an AnyCodable dictionary.
    /// Internal visibility so OllamaProvider can reuse it.
    static func jsonObjectToAnyCodableDict(_ dict: [String: Any]) -> [String: AnyCodable] {
        var result: [String: AnyCodable] = [:]
        for (key, value) in dict {
            result[key] = jsonObjectToAnyCodable(value)
        }
        return result
    }

    /// Convert a plain JSON value to AnyCodable.
    /// Internal visibility so OllamaProvider can reuse it.
    static func jsonObjectToAnyCodable(_ value: Any) -> AnyCodable {
        if value is NSNull {
            return .null
        } else if let b = value as? Bool {
            // Must check Bool before Int/Double because NSNumber bridges
            // booleans to Int/Double. CFBooleanGetTypeID() distinguishes them.
            return .bool(b)
        } else if let i = value as? Int {
            return .int(i)
        } else if let d = value as? Double {
            return .double(d)
        } else if let s = value as? String {
            return .string(s)
        } else if let arr = value as? [Any] {
            return .array(arr.map { jsonObjectToAnyCodable($0) })
        } else if let dict = value as? [String: Any] {
            return .dictionary(jsonObjectToAnyCodableDict(dict))
        } else {
            return .null
        }
    }
}
